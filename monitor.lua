-- A display/input bridge only. All app code and hit testing stay on the OS.
local Monitor = {}
local sides = {"top", "bottom", "left", "right", "front", "back"}

function Monitor.new(net, config)
    assert(type(config.clientId) == "string" and #config.clientId > 0, "Invalid monitor clientId")
    local client = {devices = {}}
    local function status(device, text)
        device.peripheral.clear()
        device.peripheral.setCursorPos(1, 1)
        device.peripheral.write(text:sub(1, device.width))
        device.cache = {}
    end
    function client.scan()
        local present = {}
        for _, side in ipairs(sides) do
            if peripheral.getType(side) == "monitor" then
                present[side] = true
                local device = client.devices[side]
                local wrapped = peripheral.wrap(side)
                if wrapped.setBackgroundColor then wrapped.setBackgroundColor(colors.black) end
                if wrapped.setTextColor then wrapped.setTextColor(colors.white) end
                wrapped.setTextScale(config.textScale)
                local width, height = wrapped.getSize()
                if not device then
                    device = {id = config.clientId .. ":" .. side, side = side, peripheral = wrapped,
                        width = width, height = height, nonce = 0, lastAnnounce = -math.huge,
                        lastServer = 0, connected = false}
                    client.devices[side] = device
                    status(device, "Connecting to SmartHome OS...")
                else
                    device.peripheral = wrapped
                    if width ~= device.width or height ~= device.height then
                        device.width, device.height, device.lastAnnounce = width, height, -math.huge
                        device.cache = {}
                    end
                end
            end
        end
        for side in pairs(client.devices) do if not present[side] then client.devices[side] = nil end end
    end
    function client.handle(message, now)
        for _, device in pairs(client.devices) do
            if message.clientId == device.id then
                if message.type == "welcome" and message.nonce == device.nonce
                    and type(message.serverSession) == "string"
                    and (not device.connected or message.sender == device.serverId) then
                    local changed = not device.connected or device.serverSession ~= message.serverSession
                    device.connected, device.lastServer = true, now
                    device.serverId, device.serverSession = message.sender, message.serverSession
                    if changed then
                        print("Monitor " .. device.side .. " connected to OS " .. message.sender)
                        device.cache = {}
                    end
                elseif message.type == "render" and device.connected
                    and message.sender == device.serverId and message.serverSession == device.serverSession
                    and message.width == device.width and message.height == device.height
                    and type(message.lines) == "table" then
                    for y = 1, device.height do
                        local line = message.lines[y]
                        if type(line) ~= "string" then line = "" end
                        line = line:sub(1, device.width)
                        line = line .. string.rep(" ", device.width - #line)
                        if device.cache[y] ~= line then
                            device.peripheral.setCursorPos(1, y)
                            device.peripheral.write(line)
                            device.cache[y] = line
                        end
                    end
                    device.lastServer = now
                end
                return
            end
        end
    end
    function client.touch(side, x, y)
        local device = client.devices[side]
        if device and device.connected then
            net.send(net.config.channel, device.serverId, {type = "touch", clientId = device.id,
                monitorId = device.id, x = x, y = y, serverSession = device.serverSession})
        end
    end
    function client.tick(now)
        local available = net.ensureModem()
        for _, device in pairs(client.devices) do
            if device.connected and (not available or now - device.lastServer >= config.timeout) then
                device.connected = false
                status(device, "OS offline; reconnecting...")
            end
            if available and now - device.lastAnnounce >= config.announceInterval then
                device.nonce = device.nonce + 1
                net.toServer({type = "announce", clientType = "monitor", clientId = device.id,
                    nonce = device.nonce, width = device.width, height = device.height})
                device.lastAnnounce = now
            end
        end
    end
    return client
end
return Monitor
