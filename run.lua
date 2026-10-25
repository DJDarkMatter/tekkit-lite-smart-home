-- Run from the repository root: lua5.1 tests/run.lua
-- Executes the real entry points in separate Lua 5.1 environments. The virtual
-- modem accepts strings only; computers have independent disks and event queues.
local hostLoadfile, hostPrint = loadfile, print
local function equal(actual, expected, message)
    assert(actual == expected, (message or "Values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function serialize(value, seen)
    local kind = type(value)
    if kind == "string" then return string.format("%q", value) end
    if kind == "number" or kind == "boolean" or kind == "nil" then return tostring(value) end
    assert(kind == "table", "Cannot serialize " .. kind)
    seen = seen or {}
    assert(not seen[value], "Cyclic table")
    seen[value] = true
    local parts = {}
    for key, item in pairs(value) do parts[#parts + 1] = "[" .. serialize(key, seen) .. "]=" .. serialize(item, seen) end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end
local function unserialize(value)
    local fn = loadstring("return " .. value)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, result = pcall(fn)
    if ok then return result end
end
local function combine(a, b)
    local result, power = 0, 1
    for _ = 1, 16 do
        if a % 2 == 1 or b % 2 == 1 then result = result + power end
        a, b, power = math.floor(a / 2), math.floor(b / 2), power * 2
    end
    return result
end
local function newBus()
    local bus = {now = 0, computers = {}, events = {}, timers = {}, wire = {}}
    function bus.queue(comp, event)
        bus.events[#bus.events + 1] = {comp = comp, event = event}
    end
    function bus.pump()
        local count = 0
        while #bus.events > 0 do
            count = count + 1
            assert(count < 10000, "Network event loop")
            local item = table.remove(bus.events, 1)
            if item.comp.active then
                local ok, err = coroutine.resume(item.comp.thread, unpack(item.event))
                assert(ok, "Computer " .. item.comp.id .. ": " .. tostring(err))
                if coroutine.status(item.comp.thread) == "dead" then item.comp.active = false end
            end
        end
    end
    function bus.advance(seconds)
        local target = bus.now + seconds
        while true do
            local nextIndex, nextTime
            for i, timer in ipairs(bus.timers) do
                if timer.time <= target and (not nextTime or timer.time < nextTime) then
                    nextIndex, nextTime = i, timer.time
                end
            end
            if not nextIndex then break end
            local timer = table.remove(bus.timers, nextIndex)
            bus.now = timer.time
            if timer.comp.active then bus.queue(timer.comp, {"timer", timer.id}) end
            bus.pump()
        end
        bus.now = target
        bus.pump()
    end
    function bus.command(comp, text)
        for i = 1, #text do bus.queue(comp, {"char", text:sub(i, i)}) end
        bus.queue(comp, {"key", 28})
        bus.pump()
    end
    function bus.computer(id, role, options)
        options = options or {}
        local previous = bus.computers[id]
        if previous then previous.active = false end
        local comp = {id = id, role = role, modemSide = options.modemSide or "back", open = {}, log = {},
            disk = options.disk or {files = {}, dirs = {Apps = role == "server"}}, bundled = {}, digital = {},
            bundledInputs = {}, digitalInputs = {}, monitors = options.monitors or {}, started = bus.now,
            appSources = options.apps or {}, timerId = 0, active = true}
        bus.computers[id] = comp
        local env = setmetatable({}, {__index = _G})
        comp.env, env._G = env, env
        env.print = function(...)
            local parts = {}
            for _, item in ipairs({...}) do parts[#parts + 1] = tostring(item) end
            comp.log[#comp.log + 1] = table.concat(parts, " ")
        end
        env.write = function() end
        env.textutils = {serialize = serialize, unserialize = unserialize}
        env.colors = {combine = combine}
        local colorNames = {"white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
            "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black"}
        for i, name in ipairs(colorNames) do env.colors[name] = 2 ^ (i - 1) end
        env.os = {
            clock = function() return bus.now - comp.started end,
            getComputerID = function() return id end,
            startTimer = function(delay)
                comp.timerId = comp.timerId + 1
                bus.timers[#bus.timers + 1] = {comp = comp, time = bus.now + delay, id = comp.timerId}
                return comp.timerId
            end,
            pullEvent = function(filter)
                while true do
                    local event = {coroutine.yield(filter)}
                    if event[1] == "terminate" then error("Terminated") end
                    if not filter or event[1] == filter then return unpack(event) end
                end
            end,
        }
        env.read = function()
            local text = ""
            while true do
                local event, key = env.os.pullEvent()
                if event == "char" then text = text .. key
                elseif event == "key" and key == 28 then return text end
            end
        end
        env.parallel = {waitForAny = function(...)
            local threads, filters = {}, {}
            for i, fn in ipairs({...}) do
                threads[i] = coroutine.create(fn)
                local ok, filter = coroutine.resume(threads[i])
                assert(ok, filter)
                filters[i] = filter
                if coroutine.status(threads[i]) == "dead" then return i end
            end
            while true do
                local event = {coroutine.yield()}
                for i, thread in ipairs(threads) do
                    if not filters[i] or filters[i] == event[1] or event[1] == "terminate" then
                        local ok, filter = coroutine.resume(thread, unpack(event))
                        assert(ok, filter)
                        filters[i] = filter
                        if coroutine.status(thread) == "dead" then return i end
                    end
                end
            end
        end}
        local disk = comp.disk
        env.fs = {
            exists = function(path) return disk.files[path] ~= nil or disk.dirs[path] == true end,
            isDir = function(path) return disk.dirs[path] == true end,
            getDir = function(path) return path:match("^(.*)/[^/]+$") or "" end,
            makeDir = function(path) disk.dirs[path] = true end,
            delete = function(path) disk.files[path], disk.dirs[path] = nil, nil end,
            move = function(from, to)
                if disk.failMove and from:sub(-4) == ".tmp" then error("Simulated interrupted replace") end
                assert(disk.files[from] ~= nil and disk.files[to] == nil, "Invalid move")
                disk.files[to], disk.files[from] = disk.files[from], nil
            end,
            list = function(path)
                if path == "Apps" and role == "server" then
                    local list = {"switchboard.lua"}
                    for name in pairs(comp.appSources) do list[#list + 1] = name:match("[^/]+$") end
                    table.sort(list)
                    return list
                end
                return {}
            end,
            open = function(path, mode)
                if mode == "w" then
                    if disk.failWrite then return nil end
                    disk.files[path] = ""
                    return {write = function(value) disk.files[path] = disk.files[path] .. value end, close = function() end}
                end
                if disk.files[path] == nil then return nil end
                return {readAll = function() return disk.files[path] end, close = function() end}
            end,
        }
        local function checkSide(side)
            assert(({top = true, bottom = true, left = true, right = true, front = true, back = true})[side], "Invalid redstone side")
            assert(role ~= "server", "Central OS touched redstone")
        end
        env.redstone = {
            getBundledInput = function(side) checkSide(side); return comp.bundledInputs[side] or 0 end,
            getInput = function(side) checkSide(side); return comp.digitalInputs[side] or false end,
            setBundledOutput = function(side, value)
                checkSide(side)
                assert(type(value) == "number" and value >= 0 and value <= 65535 and value == math.floor(value), "Invalid mask")
                comp.bundled[side] = value
            end,
            setOutput = function(side, value) checkSide(side); equal(type(value), "boolean"); comp.digital[side] = value end,
        }
        local modem = {
            open = function(channel) comp.open[channel] = true end,
            transmit = function(channel, reply, raw)
                equal(type(raw), "string", "CC 1.5 wire format")
                assert(#raw <= 65536, "Oversized packet")
                local packet = {sender = comp, channel = channel, reply = reply, raw = raw, message = unserialize(raw)}
                bus.wire[#bus.wire + 1] = packet
                if bus.drop and bus.drop(packet) then return end
                for _, receiver in pairs(bus.computers) do
                    if receiver ~= comp and receiver.active and receiver.open[channel] then
                        bus.queue(receiver, {"modem_message", receiver.modemSide, channel, reply, raw, 12})
                    end
                end
            end,
        }
        -- Deliberately no isWireless method: early-modem compatibility.
        env.peripheral = {
            getType = function(side)
                if side == comp.modemSide then return "modem" end
                if comp.monitors[side] then return "monitor" end
            end,
            wrap = function(side)
                if side == comp.modemSide then return modem end
                return comp.monitors[side]
            end,
        }
        env.loadfile = function(path)
            local chunk, err
            if comp.appSources[path] then chunk, err = loadstring(comp.appSources[path], path)
            else chunk, err = hostLoadfile(path) end
            if chunk then setfenv(chunk, env) end
            return chunk, err
        end
        env.dofile = function(path)
            local value = assert(env.loadfile(path))()
            if path == "Lib/server.lua" or path == "Lib/io.lua" or path == "Lib/monitor.lua" then
                local constructor = value.new
                value.new = function(...)
                    local object = constructor(...)
                    if path == "Lib/server.lua" then comp.server = object else comp.client = object end
                    return object
                end
            end
            return value
        end
        if options.network then disk.dirs.Configs = true; disk.files["Configs/network.txt"] = serialize(options.network) end
        function comp.start()
            local path = ({server = "main_os.lua", io = "Clients/io_client.lua", monitor = "Clients/monitor_client.lua"})[role]
            comp.thread = coroutine.create(function() env.dofile(path) end)
            local ok, err = coroutine.resume(comp.thread)
            assert(ok, "Boot computer " .. id .. ": " .. tostring(err))
            bus.pump()
            return comp
        end
        return comp
    end
    return bus
end
local function monitor(width, height)
    local screen = {width = width, height = height, lines = {}, x = 1, y = 1}
    function screen.setTextScale() end
    function screen.getSize() return screen.width, screen.height end
    function screen.clear() screen.lines = {} end
    function screen.setCursorPos(x, y)
        assert(x >= 1 and y >= 1 and x == math.floor(x) and y == math.floor(y), "Invalid monitor cursor")
        screen.x, screen.y = x, y
    end
    function screen.write(text)
        assert(screen.x + #text - 1 <= screen.width, "Monitor write overflow")
        screen.lines[screen.y] = text
    end
    return screen
end
local function pair(options)
    local bus = newBus()
    local os = bus.computer(10, "server", options):start()
    local io = bus.computer(11, "io", {modemSide = "right"}):start()
    return bus, os, io
end
local tests = {}
function tests.client_before_server_and_zero_inputs()
    local bus = newBus()
    local io = bus.computer(11, "io", {modemSide = "right"}):start()
    equal(io.client.connected, false)
    local os = bus.computer(10, "server", {modemSide = "left"}):start()
    bus.advance(5)
    equal(io.client.connected, true)
    equal(os.server.api.getInput("io_11", "left").value, 0)
    equal(os.server.api.getInput("io_11", "left").digital, false)
    equal(os.server.ioClients.io_11.online, true)
    io.bundledInputs.left, io.digitalInputs.left = 16384, true
    bus.queue(io, {"redstone"}); bus.pump()
    equal(os.server.api.getInput("io_11", "left").value, 16384)
    io.bundledInputs.left, io.digitalInputs.left = 0, false
    bus.queue(io, {"redstone"}); bus.pump()
    equal(os.server.api.getInput("io_11", "left").value, 0)
end
function tests.bundled_off_preserves_other_colors_and_routes_to_one_client()
    local bus, os, io = pair()
    local other = bus.computer(40011, "io", {modemSide = "right"}):start() -- same reply channel
    bus.command(os, "map white_test io_11 left white")
    bus.command(os, "map red_test io_11 left red")
    bus.command(os, "set white_test on")
    bus.command(os, "set red_test on")
    equal(io.bundled.left, 16385)
    bus.command(os, "set white_test off")
    equal(io.bundled.left, 16384)
    equal(other.bundled.left, 0)
    equal(os.server.api.getOutputs()[1].confirmed, true)
    bus.command(os, "map lamp io_11 front digital")
    bus.command(os, "set lamp on")
    equal(io.digital.front, true)
    local ok = os.server.api.mapOutput("duplicate", "io_11", "front", nil)
    equal(ok, false)
end
function tests.packet_loss_retry_ack_and_stale_revision()
    local bus, os, io = pair()
    assert(os.server.api.mapOutput("test", "io_11", "left", 1)); bus.pump()
    local dropped = false
    bus.drop = function(packet)
        if not dropped and packet.message.type == "ioCommand" then dropped = true; return true end
    end
    assert(os.server.api.setOutput("test", true)); bus.pump()
    equal(io.bundled.left, 0)
    equal(os.server.api.getOutputs()[1].confirmed, false)
    bus.advance(2)
    equal(io.bundled.left, 1)
    equal(os.server.api.getOutputs()[1].confirmed, true)
    local old = bus.wire[#bus.wire - 1]
    equal(old.message.type, "ioCommand")
    assert(os.server.api.setOutput("test", false)); bus.pump()
    equal(io.bundled.left, 0)
    io.client.disconnect()
    io.client.lastAnnounce = -math.huge
    io.client.tick(io.env.os.clock()); bus.pump()
    equal(io.client.connected, true)
    bus.queue(io, {"modem_message", "right", 1011, 45231, old.raw, 12}); bus.pump()
    equal(io.bundled.left, 0, "Old revisions must not restore old outputs")
end
function tests.reboots_restore_desired_outputs_and_reject_old_session()
    local bus, os, io = pair()
    assert(os.server.api.mapOutput("test", "io_11", "left", 1))
    assert(os.server.api.setOutput("test", true)); bus.pump()
    local stale
    for _, packet in ipairs(bus.wire) do if packet.message.type == "ioCommand" then stale = packet end end
    local oldSession = os.server.session
    os = bus.computer(10, "server", {disk = os.disk}):start()
    bus.advance(5)
    assert(os.server.session ~= oldSession)
    equal(io.client.serverSession, os.server.session)
    equal(io.bundled.left, 1)
    io = bus.computer(11, "io", {disk = io.disk, modemSide = "right"}):start()
    equal(io.bundled.left, 1)
    assert(os.server.api.setOutput("test", false)); bus.pump()
    bus.queue(io, {"modem_message", "right", 1011, 45231, stale.raw, 12}); bus.pump()
    equal(io.bundled.left, 0)
    assert(os.server.api.setOutput("test", true)); bus.pump()
    os.active = false
    bus.advance(16)
    equal(io.client.connected, false)
    equal(io.bundled.left, 0, "Disconnect safe-off")
    os = bus.computer(10, "server", {disk = os.disk}):start()
    bus.advance(5)
    equal(io.bundled.left, 1)
end
function tests.modem_relocation_and_io_remapping_clear_old_wires()
    local bus, os, io = pair()
    assert(os.server.api.mapOutput("test", "io_11", "left", 1))
    assert(os.server.api.setOutput("test", true)); bus.pump()
    io.modemSide, io.open = nil, {}
    bus.queue(io, {"peripheral_detach", "right"}); bus.pump()
    equal(io.bundled.left, 0)
    io.modemSide = "front"
    bus.queue(io, {"peripheral", "front"}); bus.pump()
    equal(io.bundled.left, 1)
    assert(os.server.api.mapOutput("test", "io_11", "bottom", 1)); bus.pump()
    equal(io.bundled.left, 0)
    equal(io.bundled.bottom, 1)
    local other = bus.computer(12, "io"):start()
    assert(os.server.api.mapOutput("test", "io_12", "left", 1)); bus.pump()
    equal(io.bundled.bottom, 0)
    equal(other.bundled.left, 1)
end
function tests.background_clock_fault_isolation_and_periodic_save_without_network()
    local bus = newBus()
    local os = bus.computer(10, "server", {apps = {
        ["Apps/clock.lua"] = "return {background=function(dt,s) s.elapsed=(s.elapsed or 0)+dt; s.ticks=(s.ticks or 0)+1 end}",
        ["Apps/broken.lua"] = "return {background=function() error('deliberate app failure') end}",
    }}):start()
    for _ = 1, 50 do bus.queue(os, {"unrelated_event"}) end
    bus.pump()
    equal(os.server.state.appStates.clock.ticks, nil)
    bus.advance(31)
    equal(os.server.state.appStates.clock.elapsed, 31)
    equal(os.server.state.appStates.clock.ticks, 62)
    local saved = unserialize(os.disk.files["Configs/os_state.txt"])
    equal(saved.appStates.clock.elapsed, 30)
end
function tests.monitors_forward_touches_close_minimize_resize_and_restore_window_ids()
    local bus, os, io = pair()
    assert(os.server.api.mapOutput("test", "io_11", "left", 1)); bus.pump()
    local top, left = monitor(50, 20), monitor(30, 12)
    local display = bus.computer(13, "monitor", {monitors = {top = top, left = left}}):start()
    assert(os.server.monitors["monitor_13:top"].online)
    assert(os.server.monitors["monitor_13:left"].online)
    -- Launcher -> app; no client-supplied window IDs.
    bus.queue(display, {"monitor_touch", "top", 2, 2}); bus.pump()
    bus.queue(display, {"monitor_touch", "top", 2, 3}); bus.pump()
    local win = os.server.state.windows[1]
    assert(win)
    bus.queue(display, {"monitor_touch", "top", win.x + 1, win.y + 2}); bus.pump()
    equal(io.bundled.left, 1)
    bus.queue(display, {"monitor_touch", "top", 6, 2}); bus.pump()
    equal(win.minimized, true)
    bus.queue(display, {"monitor_touch", "top", 6, 2}); bus.pump()
    equal(win.minimized, false)
    assert(os.server.api.placeWindow(1, 1, 3, 20, 6))
    local id = assert(os.server.api.openApp("switchboard", "monitor_13:top", nil, nil, 20, 6))
    equal(id, 2)
    local second = os.server.state.windows[id]
    assert(second.x >= 21, "Free space should be used for side-by-side windows")
    os.server.refreshMonitors(true); bus.pump()
    equal(top.lines[second.y]:sub(second.x + second.width - 1, second.x + second.width - 1), "X")
    bus.queue(display, {"monitor_touch", "top", second.x + second.width - 1, second.y}); bus.pump()
    equal(os.server.state.windows[2], nil)
    top.width, top.height = 8, 4
    bus.queue(display, {"monitor_resize", "top"}); bus.pump()
    equal(win.doesNotFit, true)
    top.width, top.height = 50, 20
    bus.queue(display, {"monitor_resize", "top"}); bus.pump()
    equal(win.doesNotFit, false)
    assert(os.server.api.save())
    os = bus.computer(10, "server", {disk = os.disk}):start()
    bus.advance(5)
    equal(os.server.state.windows[1].appName, "switchboard")
    local newId = assert(os.server.api.openApp("switchboard", "monitor_13:top"))
    assert(newId > 1, "Restored windows must not be overwritten")
end
function tests.malformed_packets_wrong_network_and_pinned_server_are_ignored()
    local bus, os, io = pair()
    local before = io.bundled.left
    for _, raw in ipairs({"hello", "{", "42", "nil", "{type='announce'}", true, {type = "announce"}}) do
        bus.queue(os, {"modem_message", "back", 45231, 1011, raw, 12})
        bus.queue(io, {"modem_message", "right", 1011, 45231, raw, 12})
    end
    bus.pump()
    equal(io.bundled.left, before)
    local stranger = bus.computer(14, "io", {network = {networkId = "other", channel = 45231}}):start()
    bus.advance(5)
    equal(stranger.client.connected, false)
    equal(os.server.ioClients.io_14, nil)
    local pinned = bus.computer(15, "io", {network = {networkId = "home", channel = 45231, serverId = 999}}):start()
    bus.advance(5)
    equal(pinned.client.connected, false)
    equal(os.server.ioClients.io_15, nil)
    equal(type(os.server.state.windows), "table")
end
function tests.failed_save_does_not_command_hardware_and_interrupted_save_recovers()
    local bus, os, io = pair()
    assert(os.server.api.mapOutput("test", "io_11", "left", 1)); bus.pump()
    os.disk.failWrite = true
    local ok = os.server.api.setOutput("test", true)
    equal(ok, false)
    equal(os.server.api.getOutput("test"), false)
    bus.pump()
    equal(io.bundled.left, 0)
    os.disk.failWrite = false
    assert(os.server.api.setOutput("test", true)); bus.pump()
    os.disk.failMove = true
    equal(os.server.save(), false)
    assert(os.disk.files["Configs/os_state.txt.tmp"])
    os.disk.failMove = false
    os = bus.computer(10, "server", {disk = os.disk}):start()
    bus.advance(5)
    equal(io.bundled.left, 1)
    -- Malformed primary falls back to the previous complete checkpoint.
    os.disk.files["Configs/os_state.txt"] = "corrupted"
    os = bus.computer(10, "server", {disk = os.disk}):start()
    bus.advance(5)
    equal(os.server.api.getOutput("test"), true)
end
function tests.lost_handshake_acknowledgement_and_render_recover()
    local bus = newBus()
    local os = bus.computer(10, "server"):start()
    assert(os.server.api.mapOutput("test", "io_11", "left", 1))
    assert(os.server.api.setOutput("test", true))
    local droppedWelcome, droppedAck, droppedRender = false, false, false
    bus.drop = function(packet)
        local kind = packet.message.type
        if kind == "welcome" and not droppedWelcome then droppedWelcome = true; return true end
        if kind == "ioAck" and not droppedAck then droppedAck = true; return true end
        if kind == "render" and not droppedRender then droppedRender = true; return true end
    end
    local io = bus.computer(11, "io"):start()
    equal(io.client.connected, false)
    bus.advance(5)
    equal(io.client.connected, true)
    equal(io.bundled.left, 1)
    equal(os.server.api.getOutputs()[1].confirmed, false)
    bus.advance(2)
    equal(os.server.api.getOutputs()[1].confirmed, true)
    local screen = monitor(40, 12)
    bus.computer(13, "monitor", {monitors = {top = screen}}):start()
    assert(screen.lines[1]:find("Connecting", 1, true))
    bus.advance(5)
    assert(screen.lines[1]:find("SmartHome OS", 1, true))
    assert(droppedWelcome and droppedAck and droppedRender)
end
function tests.sensor_data_cannot_overwrite_os_structures_and_times_out()
    local bus, os = pair()
    local sensor = bus.computer(22, "sensor")
    sensor.thread = coroutine.create(function() while true do coroutine.yield() end end)
    assert(coroutine.resume(sensor.thread))
    local net = sensor.env.dofile("Lib/network.lua").new({networkId = "home", channel = 45231}, false)
    assert(net.ensureModem())
    net.toServer({type = "announce", clientType = "sensor", clientId = "sensor_22", nonce = 1}); bus.pump()
    for name, value in pairs({windows = "corrupt", playerOnline = true, gameTime = "12:34"}) do
        net.toServer({type = "sensorData", clientId = "sensor_22", varName = name, value = value,
            serverSession = os.server.session})
    end
    bus.pump()
    equal(type(os.server.state.windows), "table")
    equal(os.server.api.getSensor("sensor_22", "windows"), "corrupt")
    equal(os.server.api.getSystem().playerOnline, true)
    equal(os.server.api.getSystem().gameTime, "12:34")
    bus.advance(16)
    equal(os.server.api.getSensor("sensor_22", "windows"), nil)
    equal(os.server.api.getSystem().playerOnline, false)
end
function tests.invalid_snapshot_is_rejected_atomically_and_bad_app_metadata_isolated()
    local bus, os, io = pair({apps = {["Apps/invalid.lua"] = 'return {minWidth="invalid", render=function() return {} end}'}})
    equal(os.server.apps.invalid, nil)
    local raw = serialize({protocol = "SmartHomeOS/1", networkId = "home", sender = 10, recipient = 11,
        type = "ioCommand", clientId = "io_11", serverSession = os.server.session,
        command = "syncOutputs", revision = 1234,
        outputs = {left = {bundled = 1, digital = true}, top = {bundled = -1, digital = false}}})
    bus.queue(io, {"modem_message", "right", 1011, 45231, raw, 12}); bus.pump()
    equal(io.bundled.left, 0)
    equal(io.digital.left, false)
    -- A syntactically valid but structurally invalid primary also uses the backup.
    assert(os.server.api.mapOutput("test", "io_11", "left", 1))
    assert(os.server.save())
    os.disk.files["Configs/os_state.txt"] = '{outputMap={test=42}}'
    os = bus.computer(10, "server", {disk = os.disk}):start()
    equal(os.server.state.outputMap.test.clientId, "io_11")
end
function tests.installer_installs_every_role_from_downloaded_files_and_keeps_configs()
    for _, role in ipairs({"server", "io", "monitor"}) do
        local bus = newBus()
        local comp = bus.computer(10, role)
        local existing = '{networkId="saved-home",channel=45231}'
        comp.disk.dirs.Configs = true
        comp.disk.files["Configs/network.txt"] = existing
        comp.disk.files.startup = "-- previous startup"
        comp.env.shell = {dir = function() return "" end}
        comp.env.http = {get = function(url)
            local path = assert(url:match("/main/(.+)$"))
            local file = assert(io.open(path, "r"))
            local contents = file:read("*a"); file:close()
            return {readAll = function() return contents end, close = function() end}
        end}
        local entry = ({server = "main_os.lua", io = "Clients/io_client.lua", monitor = "Clients/monitor_client.lua"})[role]
        comp.disk.files[entry] = "-- previous program"
        assert(comp.env.loadfile("install.lua"))(role, "main")
        equal(comp.disk.files["Configs/network.txt"], existing)
        equal(comp.disk.files.startup, "-- previous startup")
        equal(comp.disk.files[entry .. ".pre_update"], "-- previous program")
        -- Boot only what was downloaded, so missing role dependencies cannot hide.
        comp.env.loadfile = function(path)
            local contents = comp.disk.files[path]
            if not contents then return nil, "Missing installed file: " .. path end
            local fn, err = loadstring(contents, path)
            if fn then setfenv(fn, comp.env) end
            return fn, err
        end
        comp:start()
        assert(role == "server" and comp.server or comp.client)
    end
end
function tests.installer_download_failure_does_not_replace_existing_programs()
    local bus = newBus()
    local comp = bus.computer(10, "server")
    comp.disk.files["main_os.lua"] = "-- keep existing"
    comp.env.shell = {dir = function() return "" end}
    local requests = 0
    comp.env.http = {get = function()
        requests = requests + 1
        if requests == 3 then return nil end
        return {readAll = function() return "return {}" end, close = function() end}
    end}
    local ok = pcall(assert(comp.env.loadfile("install.lua")), "server", "main")
    equal(ok, false)
    equal(comp.disk.files["main_os.lua"], "-- keep existing")
    equal(comp.disk.files["Lib/network.lua"], nil)
    equal(comp.disk.files["Lib/storage.lua.download"], nil)
end
local names = {}
for name in pairs(tests) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do tests[name](); hostPrint("PASS " .. name) end
hostPrint(#names .. " integration tests passed (" .. _VERSION .. ")")
