local IO = {}
local sides = {"top", "bottom", "left", "right", "front", "back"}

local function integer(value, high)
    return type(value) == "number" and value == math.floor(value)
        and value >= 0 and value <= high
end

function IO.new(net, config)
    assert(type(config.clientId) == "string" and #config.clientId > 0, "Invalid IO clientId")
    assert(type(config.safeOff) == "boolean", "safeOff must be boolean")
    local validSides = {}
    for _, side in ipairs(sides) do validSides[side] = true end
    for _, side in ipairs(config.sides) do assert(validSides[side], "Invalid IO side: " .. tostring(side)) end
    local client = {connected = false, nonce = 0, lastRevision = -1, lastAnnounce = -math.huge,
        lastInputs = -math.huge, lastServer = 0, inputs = {}}

    local function allowed(side)
        if side == net.side then return false end
        for _, name in ipairs(config.sides) do if name == side then return true end end
        return false
    end

    function client.clearOutputs()
        for _, side in ipairs(sides) do
            if allowed(side) then
                redstone.setBundledOutput(side, 0)
                redstone.setOutput(side, false)
            end
        end
    end

    function client.disconnect()
        if client.connected then print("OS disconnected; retrying") end
        client.connected = false
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
            if client.connected and message.sender ~= client.serverId then return end
            local restarted = message.serverSession ~= client.serverSession
            local reconnected = not client.connected or restarted
            client.serverId, client.serverSession = message.sender, message.serverSession
            client.connected, client.lastServer = true, now
            if restarted then client.lastRevision = -1 end
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
            if message.revision >= client.lastRevision then
                for side, values in pairs(message.outputs) do
                    redstone.setBundledOutput(side, values.bundled)
                    redstone.setOutput(side, values.digital)
                end
                client.lastRevision = message.revision
            end
            client.lastServer = now
            net.send(net.config.channel, client.serverId, {type = "ioAck", clientId = config.clientId,
                serverSession = client.serverSession, revision = client.lastRevision})
        end
    end

    function client.tick(now)
        if not net.ensureModem() then
            if client.connected then client.disconnect() end
            return
        end
        if client.connected and now - client.lastServer >= config.timeout then client.disconnect() end
        if now - client.lastAnnounce >= config.announceInterval then client.announce(now) end
        if now - client.lastInputs >= config.announceInterval then
            client.readInputs(true)
            client.lastInputs = now
        end
    end

    return client
end

return IO
