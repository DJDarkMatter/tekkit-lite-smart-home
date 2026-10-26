-- SmartHome OS installer: bundled-v1
-- Upload this ONE file to Pastebin. All role files are included below.
-- Usage: inst server|io|monitor [--startup]
-- Installation makes NO HTTP requests. Existing Configs are preserved.
local sources = {
    ["Lib/storage.lua"] = [=[-- Lua 5.1 / ComputerCraft 1.5. Only plain, serializable data belongs here.
local storage = {}

local function readTable(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    local ok, value = pcall(textutils.unserialize, contents)
    if ok and type(value) == "table" then return value end
end

function storage.load(path, validate)
    for _, candidate in ipairs({path, path .. ".tmp", path .. ".bak"}) do
        local value = readTable(candidate)
        if value and (not validate or validate(value)) then return value, candidate end
    end
end

function storage.save(path, value)
    local ok, err = pcall(function()
        local contents = textutils.serialize(value)
        -- fs.getDir was only added in CC 1.63; Tekkit Lite uses older CC.
        local dir = path:match("^(.*)/[^/]+$") or ""
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local file = assert(fs.open(path .. ".tmp", "w"), "Cannot write " .. path)
        file.write(contents)
        file.close()
        if fs.exists(path) then
            if readTable(path) then
                if fs.exists(path .. ".bak") then fs.delete(path .. ".bak") end
                fs.move(path, path .. ".bak")
            else
                -- A corrupt primary must not replace a good backup.
                fs.delete(path)
            end
        end
        fs.move(path .. ".tmp", path)
    end)
    return ok, err
end

function storage.config(path, defaults)
    local value = storage.load(path)
    if value then
        for key, default in pairs(defaults) do
            if value[key] == nil then value[key] = default end
        end
        return value
    end
    for _, suffix in ipairs({"", ".tmp", ".bak"}) do
        assert(not fs.exists(path .. suffix), "Unreadable config: " .. path .. suffix)
    end
    local ok, err = storage.save(path, defaults)
    assert(ok, err)
    return defaults
end

return storage
]=],
    ["Lib/network.lua"] = [=[-- All wire packets are serialized strings, including on old CC modems.
local Network = {}
local sides = {"top", "bottom", "left", "right", "front", "back"}
local protocol = "SmartHomeOS/1"

local function integer(value, low, high)
    return type(value) == "number" and value == math.floor(value)
        and value >= low and value <= high
end

function Network.new(config, isServer)
    assert(type(config.networkId) == "string" and #config.networkId > 0,
        "Set networkId in Configs/network.txt")
    assert(integer(config.channel, 1, 65532), "Invalid network channel")
    assert(config.serverId == nil or integer(config.serverId, 0, 2147483647),
        "serverId must be a computer ID")
    local net = {id = os.getComputerID(), config = config, isServer = isServer}
    -- Destination IDs still disambiguate computers if reply channels collide.
    net.replyChannel = 1000 + (net.id % 40000)
    if net.replyChannel == config.channel then net.replyChannel = 41001 end
    net.listenChannel = isServer and config.channel or net.replyChannel

    function net.ensureModem()
        if net.modem then return true end
        for _, side in ipairs(sides) do
            if peripheral.getType(side) == "modem" then
                local modem = peripheral.wrap(side)
                -- isWireless is absent in some early versions; channels are required.
                if modem and modem.transmit and modem.open
                    and (not modem.isWireless or modem.isWireless()) then
                    local ok = pcall(modem.open, net.listenChannel)
                    if ok then
                        net.modem, net.side = modem, side
                        print("Wireless modem: " .. side .. ", channel " .. net.listenChannel)
                        return true
                    end
                end
            end
        end
        return false
    end

    function net.peripheralChanged(side)
        if side == net.side then net.modem, net.side = nil, nil end
        return net.ensureModem()
    end

    function net.send(channel, targetId, message)
        if not net.ensureModem() then return false end
        local packet = {}
        for key, value in pairs(message) do packet[key] = value end
        packet.protocol, packet.networkId = protocol, config.networkId
        packet.sender, packet.recipient = net.id, targetId
        local ok = pcall(net.modem.transmit, channel, net.listenChannel,
            textutils.serialize(packet))
        if not ok then net.modem, net.side = nil, nil end
        return ok
    end

    function net.toServer(message)
        return net.send(config.channel, config.serverId, message)
    end

    function net.toClient(client, message)
        return net.send(client.channel, client.computerId, message)
    end

    function net.receive(side, channel, replyChannel, raw)
        if side ~= net.side or channel ~= net.listenChannel then return nil end
        if not integer(replyChannel, 1, 65532) or type(raw) ~= "string"
            or #raw > 65536 then return nil end
        local ok, packet = pcall(textutils.unserialize, raw)
        if not ok or type(packet) ~= "table" or packet.protocol ~= protocol
            or packet.networkId ~= config.networkId
            or not integer(packet.sender, 0, 2147483647)
            or packet.sender == net.id or type(packet.type) ~= "string" then return nil end
        if packet.recipient ~= nil and packet.recipient ~= net.id then return nil end
        if not isServer then
            if packet.recipient ~= net.id or replyChannel ~= config.channel then return nil end
            if config.serverId and packet.sender ~= config.serverId then return nil end
        else
            local expected = 1000 + (packet.sender % 40000)
            if expected == config.channel then expected = 41001 end
            if replyChannel ~= expected then return nil end
        end
        return packet
    end

    return net
end

Network.sides = sides
Network.integer = integer
return Network
]=],
    ["Lib/server.lua"] = [=[-- Central state, app lifecycle, desktops and logical IO routing. No redstone here.
local Server = {}
local sideSet = {top = true, bottom = true, left = true, right = true, front = true, back = true}
local function integer(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end
local function colour(value)
    if not integer(value, 1, 32768) then return false end
    while value > 1 do
        if value % 2 ~= 0 then return false end
        value = value / 2
    end
    return true
end
local function sortedKeys(values)
    local keys = {}
    for key in pairs(values) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function validState(value)
    for _, key in ipairs({"windows", "appRegistry", "appStates", "outputs", "outputMap", "managedSides"}) do
        if value[key] ~= nil and type(value[key]) ~= "table" then return false end
    end
    for name, mapping in pairs(value.outputMap or {}) do
        if type(name) ~= "string" or type(mapping) ~= "table" or type(mapping.clientId) ~= "string"
            or not sideSet[mapping.side] or (mapping.color ~= nil and not colour(mapping.color)) then return false end
    end
    for id, entries in pairs(value.managedSides or {}) do
        if type(id) ~= "string" or type(entries) ~= "table" then return false end
        for side, enabled in pairs(entries) do if not sideSet[side] or enabled ~= true then return false end end
    end
    return true
end

local function validApp(app)
    if type(app) ~= "table" then return false end
    for _, key in ipairs({"minWidth", "maxWidth", "minHeight", "maxHeight"}) do
        if app[key] ~= nil and not integer(app[key], 1, 512) then return false end
    end
    for _, key in ipairs({"init", "background", "render", "handleTouch"}) do
        if app[key] ~= nil and type(app[key]) ~= "function" then return false end
    end
    return (not app.maxWidth or app.maxWidth >= (app.minWidth or 8))
        and (not app.maxHeight or app.maxHeight >= (app.minHeight or 2))
end

function Server.new(net, storage, config)
    local loaded, source = storage.load(config.saveFile, validState)
    local state = loaded or {}
    for _, name in ipairs({"windows", "appRegistry", "appStates", "outputs", "outputMap", "managedSides"}) do
        if type(state[name]) ~= "table" then state[name] = {} end
    end
    local server = {state = state, monitors = {}, ioClients = {}, sensorClients = {}, apps = {},
        gameTime = "?:??", playerOnline = false, lastSave = 0, lastTick = os.clock()}
    local api, errors = {}, {}
    server.api = api
    state.nextWindowId = 1
    for id, win in pairs(state.windows) do
        if not integer(id, 1, 2147483646) or type(win) ~= "table"
            or type(win.appName) ~= "string" or type(win.monitorId) ~= "string" then
            state.windows[id] = nil
        else
            state.nextWindowId = math.max(state.nextWindowId, id + 1)
            win.id, win.order = id, tonumber(win.order) or id
            if not state.appStates[win.appName] and type(win.appState) == "table" then
                state.appStates[win.appName] = win.appState
            end
            win.appState = nil -- App state is shared with its background service.
        end
    end
    state.bootCounter = (tonumber(state.bootCounter) or 0) + 1
    server.session = tostring(net.id) .. ":" .. state.bootCounter
    if source and source ~= config.saveFile then print("Recovered state from " .. source) end
    if not loaded and fs.exists(config.saveFile) then print("Unreadable OS state; starting with defaults") end

    function server.save()
        local saved = {}
        for _, name in ipairs({"windows", "appRegistry", "appStates", "outputs", "outputMap", "managedSides",
            "nextWindowId", "bootCounter"}) do saved[name] = state[name] end
        local ok, err = storage.save(config.saveFile, saved)
        if not ok then print("State save failed: " .. tostring(err)) else server.lastSave = os.clock() end
        return ok, err
    end
    api.save = server.save

    local function appCall(name, hook, ...)
        local app = server.apps[name]
        if not app or not app[hook] then return true end
        local ok, a, b = pcall(app[hook], ...)
        if not ok then
            local key = name .. "." .. hook
            if errors[key] ~= a then print("App " .. key .. " failed: " .. tostring(a)); errors[key] = a end
        end
        return ok, a, b
    end

    local function outputSnapshot(clientId)
        local snapshot = {}
        for side in pairs(state.managedSides[clientId] or {}) do
            snapshot[side] = {bundled = 0, digital = false}
        end
        for name, mapping in pairs(state.outputMap) do
            if mapping.clientId == clientId and sideSet[mapping.side] then
                local values = snapshot[mapping.side] or {bundled = 0, digital = false}
                snapshot[mapping.side] = values
                if state.outputs[name] == true then
                    if mapping.color then values.bundled = colors.combine(values.bundled, mapping.color)
                    else values.digital = true end
                end
            end
        end
        return snapshot
    end

    function server.syncIO(clientId, changed)
        local client = server.ioClients[clientId]
        if not client then return end
        if changed then client.revision = client.revision + 1 end
        if not client.online then return end
        local snapshot = outputSnapshot(clientId)
        for side in pairs(snapshot) do
            if not client.capabilities[side] then
                print("IO " .. clientId .. ": mapped side " .. side .. " is unavailable")
                snapshot[side] = nil
            end
        end
        net.toClient(client, {type = "ioCommand", command = "syncOutputs", clientId = clientId,
            serverSession = server.session, revision = client.revision, outputs = snapshot})
        client.lastSent = os.clock()
    end

    function api.mapOutput(name, clientId, side, color)
        if type(name) ~= "string" or not name:match("^[%w_-]+$")
            or type(clientId) ~= "string" or clientId == "" or not sideSet[side]
            or (color ~= nil and not colour(color)) then return false, "Invalid output mapping" end
        local client = server.ioClients[clientId]
        if client and client.online and not client.capabilities[side] then
            return false, "That side is unavailable (possibly occupied by the modem)"
        end
        for other, mapping in pairs(state.outputMap) do
            if other ~= name and mapping.clientId == clientId and mapping.side == side
                and mapping.color == color then return false, "Wire already mapped to " .. other end
        end
        local previous, oldManaged = state.outputMap[name], copy(state.managedSides)
        state.outputMap[name] = {clientId = clientId, side = side, color = color}
        state.managedSides[clientId] = state.managedSides[clientId] or {}
        state.managedSides[clientId][side] = true
        if previous then
            state.managedSides[previous.clientId] = state.managedSides[previous.clientId] or {}
            state.managedSides[previous.clientId][previous.side] = true
        end
        local ok, err = server.save()
        if not ok then state.outputMap[name], state.managedSides = previous, oldManaged; return false, err end
        if previous and previous.clientId ~= clientId then server.syncIO(previous.clientId, true) end
        server.syncIO(clientId, true)
        return true
    end

    function api.setOutput(name, value)
        local mapping = state.outputMap[name]
        if not mapping then return false, "Unknown output: " .. tostring(name) end
        if type(value) ~= "boolean" then return false, "Output value must be boolean" end
        local previous = state.outputs[name]
        state.outputs[name] = value
        -- Commit desired state before commanding hardware; failed writes are visible.
        local ok, err = server.save()
        if not ok then state.outputs[name] = previous; return false, err end
        server.syncIO(mapping.clientId, true)
        return true
    end

    function api.getOutput(name) return state.outputs[name] == true end
    function api.getOutputs()
        local result = {}
        for _, name in ipairs(sortedKeys(state.outputMap)) do
            local item = copy(state.outputMap[name])
            local client = server.ioClients[item.clientId]
            item.name, item.value, item.online = name, api.getOutput(name), client and client.online or false
            item.confirmed = item.online and client.capabilities[item.side]
                and client.ackedRevision == client.revision or false
            result[#result + 1] = item
        end
        return result
    end
    function api.getInput(clientId, side)
        local client = server.ioClients[clientId]
        if client and client.online then return copy(client.inputs[side]) end
    end
    function api.getSensor(clientId, name)
        local client = server.sensorClients[clientId]
        if client and client.online then return copy(client.values[name]) end
    end
    function api.getClients()
        local result = {}
        for kind, group in pairs({io = server.ioClients, monitor = server.monitors, sensor = server.sensorClients}) do
            for id, client in pairs(group) do
                result[#result + 1] = {id = id, type = kind, online = client.online, computerId = client.computerId}
            end
        end
        table.sort(result, function(a, b) return a.id < b.id end)
        return result
    end
    function api.getSystem() return {gameTime = server.gameTime, playerOnline = server.playerOnline} end

    local function windowsFor(monitorId)
        local list = {}
        for _, win in pairs(state.windows) do
            if win.monitorId == monitorId then list[#list + 1] = win end
        end
        table.sort(list, function(a, b) return a.order < b.order end)
        return list
    end
    local function focus(win)
        local order = 0
        for _, other in pairs(state.windows) do order = math.max(order, other.order) end
        win.order, win.minimized = order + 1, false
    end
    local function fit(win, monitor)
        local app = server.apps[win.appName]
        if not app then return false end
        local minW, minH = (app.minWidth or 8) + 2, (app.minHeight or 2) + 2
        local maxW = math.min(monitor.width, (app.maxWidth or monitor.width) + 2)
        local maxH = math.min(monitor.height - 2, (app.maxHeight or monitor.height) + 2)
        if maxW < minW or maxH < minH then win.doesNotFit = true; return false end
        win.width = math.max(minW, math.min(tonumber(win.width) or maxW, maxW))
        win.height = math.max(minH, math.min(tonumber(win.height) or maxH, maxH))
        win.x = math.max(1, math.min(tonumber(win.x) or 1, monitor.width - win.width + 1))
        win.y = math.max(3, math.min(tonumber(win.y) or 3, monitor.height - win.height + 1))
        win.x, win.y = math.floor(win.x), math.floor(win.y)
        win.width, win.height, win.doesNotFit = math.floor(win.width), math.floor(win.height), false
        return true
    end
    local function compatible(name, monitor)
        local app = server.apps[name]
        return app.render and monitor.width >= (app.minWidth or 8) + 2
            and monitor.height >= (app.minHeight or 2) + 4
    end

    function api.openApp(name, monitorId, x, y, width, height)
        local app, monitor = server.apps[name], server.monitors[monitorId]
        if not app then return nil, "Unknown app" end
        if not monitor or not monitor.online then return nil, "Monitor is offline or unknown" end
        if not compatible(name, monitor) then return nil, "App does not fit this monitor" end
        local win = {id = state.nextWindowId, appName = name, monitorId = monitorId,
            x = x, y = y, width = width, height = height, order = 0}
        fit(win, monitor)
        -- Find a free rectangle first; fall back to overlap with explicit focus.
        if not x and not y then
            local existing, placed = windowsFor(monitorId), false
            for cy = 3, monitor.height - win.height + 1 do
                for cx = 1, monitor.width - win.width + 1 do
                    local free = true
                    for _, other in ipairs(existing) do
                        if not other.minimized and fit(other, monitor) and cx < other.x + other.width
                            and cx + win.width > other.x and cy < other.y + other.height
                            and cy + win.height > other.y then free = false; break end
                    end
                    if free then win.x, win.y, placed = cx, cy, true; break end
                end
                if placed then break end
            end
        end
        focus(win)
        state.windows[win.id], state.nextWindowId = win, win.id + 1
        server.save()
        return win.id
    end
    function api.closeWindow(id)
        if not state.windows[id] then return false, "Unknown window" end
        state.windows[id] = nil
        server.save()
        return true
    end
    function api.placeWindow(id, x, y, width, height)
        local win = state.windows[id]
        if not win then return false, "Unknown window" end
        local monitor = server.monitors[win.monitorId]
        if not monitor or not monitor.online then return false, "Monitor is offline" end
        for _, value in pairs({x = x, y = y, width = width, height = height}) do
            if not integer(value, 1, 512) then return false, "Expected positive integer coordinates/sizes" end
        end
        win.x, win.y, win.width, win.height = x or win.x, y or win.y, width or win.width, height or win.height
        fit(win, monitor)
        focus(win)
        server.save()
        return true
    end

    local function renderMonitor(id, monitor)
        local lines = {}
        for y = 1, monitor.height do lines[y] = string.rep(" ", monitor.width) end
        local function write(x, y, text, limit)
            if y < 1 or y > monitor.height or x < 1 or x > monitor.width then return end
            text = tostring(text or ""):sub(1, math.min(limit or monitor.width, monitor.width - x + 1))
            lines[y] = lines[y]:sub(1, x - 1) .. text .. lines[y]:sub(x + #text)
        end
        write(1, 1, " SmartHome OS | " .. server.gameTime)
        write(1, 2, "[+]")
        monitor.taskbar, monitor.launcherApps = {}, {}
        local tx = 5
        for _, win in ipairs(windowsFor(id)) do
            local label = "[" .. (win.minimized and "_" or "") .. win.appName .. "]"
            if tx <= monitor.width then
                write(tx, 2, label)
                monitor.taskbar[#monitor.taskbar + 1] = {x1 = tx, x2 = math.min(monitor.width, tx + #label - 1), id = win.id}
            end
            tx = tx + #label + 1
            if fit(win, monitor) and not win.minimized then
                local title = win.appName:sub(1, win.width - 2)
                write(win.x, win.y, "+" .. title .. string.rep("-", win.width - #title - 2) .. "X", win.width)
                for y = win.y + 1, win.y + win.height - 2 do
                    write(win.x, y, "|" .. string.rep(" ", win.width - 2) .. "|")
                end
                write(win.x, win.y + win.height - 1, "+" .. string.rep("-", win.width - 2) .. "+")
                local ok, content = appCall(win.appName, "render", win.width - 2, win.height - 2,
                    state.appStates[win.appName], api)
                if not ok or type(content) ~= "table" then content = {"App render failed"} end
                for y = 1, win.height - 2 do write(win.x + 1, win.y + y, content[y] or "", win.width - 2) end
            end
        end
        if monitor.launcher then
            for y = 3, monitor.height do lines[y] = string.rep(" ", monitor.width) end
            local y = 3
            for _, name in ipairs(sortedKeys(server.apps)) do
                if compatible(name, monitor) and y <= monitor.height then
                    write(1, y, name)
                    monitor.launcherApps[y], y = name, y + 1
                end
            end
            if y == 3 then write(1, 3, "No apps fit this screen") end
        end
        return lines
    end

    function server.refreshMonitors(force)
        for id, monitor in pairs(server.monitors) do
            if monitor.online then
                local lines = renderMonitor(id, monitor)
                local signature = table.concat(lines, "\n")
                if force or signature ~= monitor.lastRender then
                    if net.toClient(monitor, {type = "render", clientId = id, monitorId = id,
                        serverSession = server.session, lines = lines, width = monitor.width, height = monitor.height}) then
                        monitor.lastRender = signature
                    end
                end
            end
        end
    end

    local function touch(id, x, y)
        local monitor = server.monitors[id]
        if not integer(x, 1, monitor.width) or not integer(y, 1, monitor.height) then return end
        if y == 2 then
            if x <= 3 then monitor.launcher = not monitor.launcher; return end
            local list = windowsFor(id)
            local active
            for _, win in ipairs(list) do if not win.minimized and not win.doesNotFit then active = win.id end end
            for _, box in ipairs(monitor.taskbar or {}) do
                if x >= box.x1 and x <= box.x2 then
                    local win = state.windows[box.id]
                    if active == win.id then win.minimized = true else focus(win) end
                    monitor.launcher = false
                    server.save()
                    return
                end
            end
            return
        end
        if monitor.launcher then
            local name = (monitor.launcherApps or {})[y]
            if name then api.openApp(name, id); monitor.launcher = false end
            return
        end
        local list = windowsFor(id)
        for index = #list, 1, -1 do
            local win = list[index]
            if not win.minimized and not win.doesNotFit and x >= win.x and x < win.x + win.width
                and y >= win.y and y < win.y + win.height then
                if y == win.y and x == win.x + win.width - 1 then api.closeWindow(win.id); return end
                focus(win)
                if x > win.x and x < win.x + win.width - 1 and y > win.y and y < win.y + win.height - 1 then
                    local ok, handled, replacement = appCall(win.appName, "handleTouch", x - win.x, y - win.y,
                        win.width - 2, win.height - 2, state.appStates[win.appName], api)
                    if ok and type(replacement) == "table" then state.appStates[win.appName] = replacement end
                end
                server.save()
                return
            end
        end
    end

    local function registered(group, message, replyChannel)
        local client = group[message.clientId]
        if client and client.online and client.computerId == message.sender and client.channel == replyChannel
            and message.serverSession == server.session then return client end
    end

    function server.handle(message, replyChannel, now)
        if type(message.clientId) ~= "string" or #message.clientId == 0 or #message.clientId > 64 then return end
        local id = message.clientId
        if message.type == "announce" then
            if not integer(message.nonce, 1, 2147483647) then return end
            local groups = {io = server.ioClients, monitor = server.monitors, sensor = server.sensorClients}
            local group = groups[message.clientType]
            if not group then return end
            for _, otherGroup in pairs(groups) do
                local other = otherGroup[id]
                if other and (otherGroup ~= group or (other.online and other.computerId ~= message.sender)) then
                    print("Duplicate clientId rejected: " .. id .. " (computer " .. message.sender .. ")")
                    return
                end
            end
            if message.clientType == "monitor" and (not integer(message.width, 1, 256)
                or not integer(message.height, 2, 128)) then return end
            local client = group[id]
            local reconnect = not client or not client.online or client.computerId ~= message.sender
            client = client or {inputs = {}, values = {}, revision = 0, ackedRevision = -1}
            client.computerId, client.channel, client.lastSeen, client.online = message.sender, replyChannel, now, true
            if reconnect then client.inputs, client.values = {}, {} end
            group[id] = client
            if message.clientType == "monitor" then
                client.width, client.height = message.width, message.height
                client.lastRender = nil -- Periodic full repaint also recovers a lost frame.
            elseif message.clientType == "io" then
                client.capabilities = {}
                if type(message.capabilities) == "table" then
                    for side, flags in pairs(message.capabilities) do
                        if sideSet[side] and type(flags) == "table" and flags.bundled and flags.digital then
                            client.capabilities[side] = true
                        end
                    end
                end
            end
            net.toClient(client, {type = "welcome", clientId = id, nonce = message.nonce, serverSession = server.session})
            if reconnect then print(message.clientType .. " connected: " .. id .. " (computer " .. message.sender .. ")") end
            if message.clientType == "io" then
                client.ackedRevision = -1
                server.syncIO(id, false)
            end
            server.refreshMonitors(false)
        elseif message.type == "inputData" then
            local client = registered(server.ioClients, message, replyChannel)
            if not client or not client.capabilities[message.side] or not integer(message.value, 0, 65535)
                or type(message.digital) ~= "boolean" then return end
            client.inputs[message.side] = {value = message.value, digital = message.digital}
            client.lastSeen = now
        elseif message.type == "ioAck" then
            local client = registered(server.ioClients, message, replyChannel)
            if client and message.revision == client.revision then
                client.ackedRevision, client.lastSeen = message.revision, now
            end
        elseif message.type == "sensorData" then
            local client = registered(server.sensorClients, message, replyChannel)
            if not client or type(message.varName) ~= "string" then return end
            local value = message.value
            if type(value) ~= "number" and type(value) ~= "string" and type(value) ~= "boolean" then return end
            if message.varName == "playerOnline" then
                if type(value) ~= "boolean" then return end
                server.playerOnline = value
            elseif message.varName == "gameTime" then
                if type(value) ~= "string" then return end
                server.gameTime = value:sub(1, 32)
            end
            -- Never assign arbitrary network-provided keys into OS state.
            client.values[message.varName], client.lastSeen = value, now
        elseif message.type == "touch" then
            if registered(server.monitors, message, replyChannel) then
                touch(id, message.x, message.y)
                server.refreshMonitors(false)
            end
        elseif message.type == "resize" then
            local client = registered(server.monitors, message, replyChannel)
            if client and integer(message.width, 1, 256) and integer(message.height, 2, 128) then
                client.width, client.height = message.width, message.height
                client.lastRender, client.lastSeen = nil, now
                server.refreshMonitors(false)
            end
        end
    end

    function server.start()
        -- A persisted boot generation prevents stale output commands after an OS reboot.
        assert(server.save(), "Cannot checkpoint OS startup")
        if not fs.exists("Apps") then fs.makeDir("Apps") end
        for _, file in ipairs(fs.list("Apps")) do
            if file:match("%.lua$") and not fs.isDir("Apps/" .. file) then
                local name = file:gsub("%.lua$", "")
                if state.appRegistry[name] ~= false then
                    local chunk, err = loadfile("Apps/" .. file)
                    local ok, app = false, err
                    if chunk then ok, app = pcall(chunk) end
                    if ok and validApp(app) then
                        server.apps[name], state.appRegistry[name] = app, true
                        if type(state.appStates[name]) ~= "table" then state.appStates[name] = {} end
                        appCall(name, "init", state.appStates[name], api)
                        print("Loaded app: " .. name)
                    else print("Cannot load app " .. name .. ": " .. tostring(app)) end
                end
            end
        end
        net.ensureModem()
        print("SmartHome OS computer " .. net.id .. ", network " .. net.config.networkId)
        if not net.modem then print("Attach a wireless modem; waiting...") end
    end

    function server.tick(now)
        net.ensureModem()
        for _, group in ipairs({server.ioClients, server.monitors, server.sensorClients}) do
            for id, client in pairs(group) do
                if client.online and now - client.lastSeen >= config.clientTimeout then
                    client.online = false
                    print("Client offline: " .. id)
                    if client.values then
                        if client.values.playerOnline ~= nil then server.playerOnline = false end
                        if client.values.gameTime ~= nil then server.gameTime = "?:??" end
                    end
                end
            end
        end
        local dt = math.max(0, now - server.lastTick)
        server.lastTick = now
        for name in pairs(server.apps) do appCall(name, "background", dt, state.appStates[name], api) end
        for id, client in pairs(server.ioClients) do
            if client.online and client.ackedRevision ~= client.revision
                and now - (client.lastSent or -math.huge) >= config.retryInterval then server.syncIO(id, false) end
        end
        server.refreshMonitors(false)
        if now - server.lastSave >= config.saveInterval then server.save() end
    end

    function server.command(line)
        local args = {}
        for word in line:gmatch("%S+") do args[#args + 1] = word end
        local cmd = args[1]
        if not cmd then return {} end
        if cmd == "help" then return {
            "clients | inputs <client> | outputs | apps",
            "map <name> <client> <side> <color|digital>",
            "set <name> <on|off> | toggle <name>",
            "open <app> <monitor> | close <windowId>",
            "move <id> <x> <y> | resize <id> <width> <height>",
            "save | quit (saves and exits)",
        } end
        if cmd == "clients" then
            local lines = {}
            for _, item in ipairs(api.getClients()) do
                lines[#lines + 1] = item.id .. " " .. item.type .. " " .. (item.online and "ONLINE" or "offline")
                    .. " computer=" .. item.computerId
            end
            if #lines == 0 then lines[1] = "No clients connected yet" end
            return lines
        elseif cmd == "outputs" then
            local lines = {}
            for _, item in ipairs(api.getOutputs()) do
                lines[#lines + 1] = item.name .. "=" .. (item.value and "ON" or "OFF") .. " -> " .. item.clientId
                    .. ":" .. item.side .. ":" .. tostring(item.color or "digital")
                    .. (item.confirmed and " confirmed" or " pending/offline")
            end
            if #lines == 0 then lines[1] = "No mappings. Use: map test io_ID left white" end
            return lines
        elseif cmd == "inputs" then
            local client = server.ioClients[args[2]]
            if not client or not client.online then return {"Client unknown or offline"} end
            local lines = {}
            for _, side in ipairs(sortedKeys(client.inputs)) do
                local input = client.inputs[side]
                lines[#lines + 1] = side .. ": bundled=" .. input.value .. " digital=" .. tostring(input.digital)
            end
            return lines
        elseif cmd == "apps" then return sortedKeys(server.apps)
        elseif cmd == "map" then
            local color = args[5] ~= "digital" and (colors[args[5] or ""] or tonumber(args[5])) or nil
            if args[5] ~= "digital" and not colour(color) then return {"Choose a CC color name/bit or digital"} end
            local ok, err = api.mapOutput(args[2], args[3], args[4], color)
            return {ok and "Mapping saved" or tostring(err)}
        elseif cmd == "set" or cmd == "toggle" then
            if not args[2] then return {"Specify an output name"} end
            if cmd == "set" and args[3] ~= "on" and args[3] ~= "off" then return {"Use set <name> on|off"} end
            local value = args[3] == "on"
            if cmd == "toggle" then value = not api.getOutput(args[2]) end
            local ok, err = api.setOutput(args[2], value)
            return {ok and "Desired state saved; use outputs to check acknowledgement" or tostring(err)}
        elseif cmd == "open" then
            local id, err = api.openApp(args[2], args[3])
            server.refreshMonitors(false)
            return {id and ("Opened window " .. id) or tostring(err)}
        elseif cmd == "close" then
            local ok, err = api.closeWindow(tonumber(args[2]))
            server.refreshMonitors(false)
            return {ok and "Window closed" or tostring(err)}
        elseif cmd == "move" or cmd == "resize" then
            local a, b = tonumber(args[3]), tonumber(args[4])
            if not a or not b then return {"Specify two positive integers"} end
            local ok, err
            if cmd == "move" then ok, err = api.placeWindow(tonumber(args[2]), a, b)
            else ok, err = api.placeWindow(tonumber(args[2]), nil, nil, a, b) end
            server.refreshMonitors(false)
            return {ok and "Window updated" or tostring(err)}
        elseif cmd == "save" or cmd == "quit" then
            local ok, err = server.save()
            return {ok and "State saved" or tostring(err)}, cmd == "quit" and ok
        end
        return {"Unknown command; type help"}
    end

    return server
end

return Server
]=],
    ["Lib/io.lua"] = [=[local IO = {}
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
]=],
    ["Lib/monitor.lua"] = [=[-- A display/input bridge only. All app code and hit testing stay on the OS.
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
]=],
    ["main_os.lua"] = [=[-- Start from / with: main_os.lua
local storage = dofile("Lib/storage.lua")
local Network = dofile("Lib/network.lua")
local Server = dofile("Lib/server.lua")
local networkConfig = storage.config("Configs/network.txt", {networkId = "home", channel = 45231})
local config = storage.config("Configs/os.txt", {
    saveFile = "Configs/os_state.txt", tickInterval = 0.5,
    saveInterval = 30, clientTimeout = 15, retryInterval = 2,
})
for _, name in ipairs({"tickInterval", "saveInterval", "clientTimeout", "retryInterval"}) do
    assert(type(config[name]) == "number" and config[name] > 0, "Invalid OS setting: " .. name)
end
local net = Network.new(networkConfig, true)
local server = Server.new(net, storage, config)
server.start()
print("Type help for commands")

-- parallel gives the console and network independent event queues. read() cannot
-- discard modem/timer events needed by the server, and there is no sleep in it.
parallel.waitForAny(function()
    local timer = os.startTimer(config.tickInterval)
    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()
        if event == "modem_message" then
            local message = net.receive(p1, p2, p3, p4)
            if message then server.handle(message, p3, os.clock()) end
        elseif event == "timer" and p1 == timer then
            server.tick(os.clock())
            timer = os.startTimer(config.tickInterval)
        elseif event == "peripheral" or event == "peripheral_detach" then
            net.peripheralChanged(p1)
        end
    end
end, function()
    while true do
        write("> ")
        local lines, quit = server.command(read())
        for _, line in ipairs(lines) do print(line) end
        if quit then return end
    end
end)
]=],
    ["Clients/io_client.lua"] = [=[-- Run from the computer root. Configs survive program updates.
local storage = dofile("Lib/storage.lua")
local Network = dofile("Lib/network.lua")
local IO = dofile("Lib/io.lua")
local networkConfig = storage.config("Configs/network.txt", {networkId = "home", channel = 45231})
local config = storage.config("Configs/io.txt", {
    clientId = "io_" .. os.getComputerID(), sides = Network.sides,
    announceInterval = 5, timeout = 15, safeOff = true,
})
assert(type(config.announceInterval) == "number" and config.announceInterval >= 1, "Invalid announceInterval")
assert(type(config.timeout) == "number" and config.timeout > config.announceInterval, "Invalid timeout")
assert(type(config.sides) == "table", "Invalid IO sides")
local net = Network.new(networkConfig, false)
local client = IO.new(net, config)
net.ensureModem()
client.clearOutputs()
print("IO client: " .. config.clientId .. " (computer " .. net.id .. ")")
if not net.modem then print("Attach a wireless modem; waiting...") end
client.tick(os.clock())
local timer = os.startTimer(1)
while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
        local message = net.receive(p1, p2, p3, p4)
        if message then client.handle(message, os.clock()) end
    elseif event == "redstone" then
        client.readInputs(false)
    elseif event == "timer" and p1 == timer then
        client.tick(os.clock())
        timer = os.startTimer(1)
    elseif event == "peripheral" or event == "peripheral_detach" then
        net.peripheralChanged(p1)
        if not net.modem then client.disconnect() end
        client.lastAnnounce = -math.huge
        client.tick(os.clock())
    end
end
]=],
    ["Clients/monitor_client.lua"] = [=[local storage = dofile("Lib/storage.lua")
local Network = dofile("Lib/network.lua")
local Monitor = dofile("Lib/monitor.lua")
local networkConfig = storage.config("Configs/network.txt", {networkId = "home", channel = 45231})
local config = storage.config("Configs/monitor.txt", {
    clientId = "monitor_" .. os.getComputerID(), textScale = 0.5,
    announceInterval = 5, timeout = 15,
})
assert(type(config.textScale) == "number" and config.textScale >= 0.5 and config.textScale <= 5
    and config.textScale * 2 == math.floor(config.textScale * 2), "Invalid textScale")
assert(type(config.announceInterval) == "number" and config.announceInterval >= 1, "Invalid announceInterval")
assert(type(config.timeout) == "number" and config.timeout > config.announceInterval, "Invalid timeout")
local net = Network.new(networkConfig, false)
local client = Monitor.new(net, config)
print("Monitor client: " .. config.clientId)
client.scan()
if not next(client.devices) then print("Attach one or more monitors; waiting...") end
client.tick(os.clock())
local timer = os.startTimer(1)
while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
        local message = net.receive(p1, p2, p3, p4)
        if message then client.handle(message, os.clock()) end
    elseif event == "monitor_touch" then
        client.touch(p1, p2, p3)
    elseif event == "timer" and p1 == timer then
        client.tick(os.clock())
        timer = os.startTimer(1)
    elseif event == "peripheral" or event == "peripheral_detach" or event == "monitor_resize" then
        if event ~= "monitor_resize" then net.peripheralChanged(p1) end
        client.scan()
        client.tick(os.clock())
    end
end
]=],
    ["Apps/switchboard.lua"] = [=[-- No modem, redstone, filesystem or machine-specific wiring in an app.
local app = {minWidth = 18, minHeight = 4}
function app.render(width, height, state, osApi)
    local outputs = osApi.getOutputs()
    if #outputs == 0 then
        return {"No outputs mapped.", "On the OS console:", "map test io_ID left white", "set test on"}
    end
    local lines = {"Touch a row to toggle"}
    for i = 1, math.min(#outputs, height - 1) do
        local output = outputs[i]
        lines[i + 1] = output.name .. ": " .. (output.value and "ON" or "OFF")
            .. (output.confirmed and "" or (output.online and " (pending)" or " (offline)"))
    end
    if state.lastError then lines[height] = "Error: " .. state.lastError end
    return lines
end
function app.handleTouch(x, y, width, height, state, osApi)
    local output = osApi.getOutputs()[y - 1]
    if output and y <= height then
        local ok, err = osApi.setOutput(output.name, not output.value)
        state.lastError = not ok and tostring(err) or nil
        return true
    end
    return false
end
return app
]=],
}
local args = {...}
local role, autorun = args[1], false
local entry = {server = "main_os.lua", io = "Clients/io_client.lua", monitor = "Clients/monitor_client.lua"}
print("SmartHome installer: bundled-v1")
if not entry[role] then
    print("Usage: inst server|io|monitor [--startup]")
    return
end
for index = 2, #args do
    assert(args[index] == "--startup", "Usage: inst server|io|monitor [--startup]")
    autorun = true
end
assert(shell.dir() == "", "Run cd / first")
local files = {"Lib/storage.lua", "Lib/network.lua"}
if role == "server" then
    files[#files + 1] = "Lib/server.lua"
    files[#files + 1] = "Apps/switchboard.lua"
elseif role == "io" then files[#files + 1] = "Lib/io.lua"
else files[#files + 1] = "Lib/monitor.lua" end
files[#files + 1] = entry[role]
if autorun then
    sources.startup = 'shell.setDir("/")\nshell.run("' .. entry[role] .. '")\n'
    files[#files + 1] = "startup"
end
-- Check every file before replacing any installed program.
for _, path in ipairs(files) do
    local contents = assert(sources[path], "Missing bundled file: " .. path)
    local chunk, err = loadstring(contents, path)
    assert(chunk, "Invalid bundled Lua: " .. path .. ": " .. tostring(err))
end
for _, path in ipairs(files) do
    local dir = path:match("^(.*)/[^/]+$") or ""
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local file = assert(fs.open(path .. ".download", "w"), "Cannot stage " .. path)
    file.write(sources[path])
    file.close()
end
for _, path in ipairs(files) do
    if fs.exists(path) then
        if fs.exists(path .. ".pre_update") then fs.delete(path .. ".pre_update") end
        fs.move(path, path .. ".pre_update")
    end
    fs.move(path .. ".download", path)
    print("Installed " .. path)
end
print("Installed " .. role .. " from the bundled files")
if autorun then
    print("Autorun enabled; an existing startup is kept as startup.pre_update")
    print("Run reboot to start automatically")
else print("Autorun unchanged; add --startup to enable it") end
print("Start with: " .. entry[role])
