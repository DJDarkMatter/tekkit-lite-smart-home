local IO = {}
local sides = {"top", "bottom", "left", "right", "front", "back"}

local function integer(value, high)
    return type(value) == "number" and value == math.floor(value)
        and value >= 0 and value <= high
end

function IO.new(net, config)
    assert(type(config.clientId) == "string" and #config.clientId > 0, "Invalid IO clientId")
    assert(type(config.safeOff) == "boolean", "safeOff must be boolean")
    local outputInterval = config.outputInterval or 0.6
    assert(type(outputInterval) == "number" and outputInterval >= 0.5 and outputInterval < math.huge,
        "outputInterval must be at least 0.5 seconds")
    local validSides = {}
    for _, side in ipairs(sides) do validSides[side] = true end
    for _, side in ipairs(config.sides) do assert(validSides[side], "Invalid IO side: " .. tostring(side)) end
    local client = {connected = false, nonce = 0, lastRevision = -1, appliedRevision = -1, lastAnnounce = -math.huge,
        lastInputs = -math.huge, lastServer = 0, inputs = {}}
    local outputs, targets, pendingRevision = {}, {}, nil

    local function allowed(side)
        if side == net.side then return false end
        for _, name in ipairs(config.sides) do if name == side then return true end end
        return false
    end

    local function outputState(side, now)
        if not outputs[side] then
            outputs[side] = {bundled = redstone.getBundledOutput(side), digital = redstone.getOutput(side),
                nextWrite = now + outputInterval}
        end
        return outputs[side]
    end

    local function acknowledge()
        if client.connected and client.appliedRevision >= 0 then
            net.send(net.config.channel, client.serverId, {type = "ioAck", clientId = config.clientId,
                serverSession = client.serverSession, revision = client.appliedRevision})
        end
    end

    local function flushOutputs(now)
        local complete = true
        for side, wanted in pairs(targets) do
            if allowed(side) then
                local actual = outputState(side, now)
                if now + 0.000001 >= actual.nextWrite then
                    local kind
                    -- IDT-Fix shares one cooldown between bundled and digital
                    -- writes on each side. Prefer clearing an old signal first.
                    if actual.bundled ~= wanted.bundled and wanted.bundled == 0 then kind = "bundled"
                    elseif actual.digital ~= wanted.digital and not wanted.digital then kind = "digital"
                    elseif actual.bundled ~= wanted.bundled then kind = "bundled"
                    elseif actual.digital ~= wanted.digital then kind = "digital" end
                    if kind then
                        if kind == "bundled" then redstone.setBundledOutput(side, wanted[kind])
                        else redstone.setOutput(side, wanted[kind]) end
                        actual[kind], actual.nextWrite = wanted[kind], now + outputInterval
                    end
                end
                if actual.bundled ~= wanted.bundled or actual.digital ~= wanted.digital then complete = false end
            else
                targets[side] = nil
            end
        end
        if complete then
            client.clearing = false
            if client.connected and pendingRevision ~= nil then
                client.appliedRevision, pendingRevision = pendingRevision, nil
                acknowledge()
            end
        end
    end

    function client.clearOutputs()
        local now = os.clock()
        targets, pendingRevision, client.appliedRevision, client.clearing = {}, nil, -1, true
        for _, side in ipairs(sides) do
            if allowed(side) then
                outputState(side, now)
                targets[side] = {bundled = 0, digital = false}
            end
        end
        flushOutputs(now)
    end

    function client.disconnect()
        if client.connected then print("OS disconnected; retrying") end
        client.connected = false
        client.lastAnnounce, client.appliedRevision, client.clearing = -math.huge, -1, false
        targets, pendingRevision = {}, nil
        if config.safeOff then client.clearOutputs() end
    end

    function client.announce(now)
        client.nonce = client.nonce + 1
        local capabilities = {}
        for _, side in ipairs(sides) do
            if allowed(side) then capabilities[side] = {bundled = true, digital = true} end
        end
        net.toServer({type = "announce", clientType = "io", clientId = config.clientId,
            nonce = client.nonce, capabilities = capabilities})
        client.lastAnnounce = now
    end

    function client.readInputs(force)
        if not client.connected then return end
        for _, side in ipairs(sides) do
            if allowed(side) then
                local value = redstone.getBundledInput(side)
                local digital = redstone.getInput(side)
                local previous = client.inputs[side]
                if force or not previous or previous.value ~= value or previous.digital ~= digital then
                    net.send(net.config.channel, client.serverId, {type = "inputData", clientId = config.clientId,
                        side = side, value = value, digital = digital,
                        serverSession = client.serverSession})
                    client.inputs[side] = {value = value, digital = digital}
                end
            end
        end
    end

    function client.handle(message, now)
        if message.clientId ~= config.clientId then return end
        if message.type == "welcome" then
            if message.nonce ~= client.nonce or type(message.serverSession) ~= "string" then return end
            if client.clearing then return end
            if client.connected and message.sender ~= client.serverId then return end
            local restarted = message.serverSession ~= client.serverSession
            local reconnected = not client.connected or restarted
            client.serverId, client.serverSession = message.sender, message.serverSession
            client.connected, client.lastServer = true, now
            if restarted then
                client.lastRevision, client.appliedRevision = -1, -1
                targets, pendingRevision = {}, nil
            end
            if reconnected then
                print("Connected to OS computer " .. client.serverId)
                client.readInputs(true)
            end
        elseif message.type == "ioCommand" and client.connected
            and message.sender == client.serverId and message.serverSession == client.serverSession
            and message.command == "syncOutputs" and integer(message.revision, 2147483647)
            and type(message.outputs) == "table" then
            -- Validate the entire snapshot before changing any wire.
            for side, values in pairs(message.outputs) do
                if not allowed(side) or type(values) ~= "table" or not integer(values.bundled, 65535)
                    or type(values.digital) ~= "boolean" then return end
            end
            client.lastServer = now
            if message.revision < client.lastRevision
                or (message.revision == client.appliedRevision and pendingRevision == nil) then
                acknowledge()
                return
            end
            if message.revision > client.lastRevision or pendingRevision == nil then
                targets = {}
                for side, values in pairs(message.outputs) do
                    targets[side] = {bundled = values.bundled, digital = values.digital}
                end
                client.lastRevision, pendingRevision = message.revision, message.revision
            end
            flushOutputs(now)
        end
    end

    function client.tick(now)
        local modemPresent = net.ensureModem()
        if not modemPresent then
            if client.connected then client.disconnect() end
        end
        if client.connected and now - client.lastServer >= config.timeout then client.disconnect() end
        -- Timer-driven writes keep all modem/input events flowing during cooldown.
        -- Finish startup/safe-off before accepting restored output commands.
        flushOutputs(now)
        if not modemPresent or client.clearing then return end
        if now - client.lastAnnounce >= config.announceInterval then client.announce(now) end
        if now - client.lastInputs >= config.announceInterval then
            client.readInputs(true)
            client.lastInputs = now
        end
    end

    return client
end

return IO
