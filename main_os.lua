local osConfig = {
    saveFile = "Configs/os_state.txt",
    taskbarHeight = 2,
    tickInterval = 0.5,
}

local state = {
    monitors = {},
    ioClients = {},
    sensorClients = {},
    windows = {},
    apps = {},
    appRegistry = {},
    playerOnline = false,
    gameTime = "?:??",
    nextWindowId = 1,
}

local function loadState()
    if fs.exists(osConfig.saveFile) then
        local file = fs.open(osConfig.saveFile, "r")
        local loaded = textutils.unserialize(file.readAll())
        file.close()
        if loaded then
            state.windows = loaded.windows or {}
            state.appRegistry = loaded.appRegistry or {}
            return true
        end
    end
    return false
end

local function saveState()
    local toSave = {
        windows = state.windows,
        appRegistry = state.appRegistry,
    }
    local file = fs.open(osConfig.saveFile, "w")
    file.write(textutils.serialize(toSave))
    file.close()
end

local function sendToMonitor(monitorId, message)
    local monitor = state.monitors[monitorId]
    if monitor and monitor.channel then
        modem.send(monitor.channel, message)
    end
end

local function broadcastToAll(message)
    for monitorId, monitor in pairs(state.monitors) do
        sendToMonitor(monitorId, message)
    end
end

local function drawTaskbar(monitorId, width, height)
    local lines = {}
    local windowList = ""
    for _, win in pairs(state.windows) do
        if win.monitorId == monitorId then
            windowList = windowList .. "[" .. win.appName .. "] "
        end
    end
    if windowList == "" then
        windowList = "(no windows)"
    end

    local line1 = " SmartHome OS | " .. state.gameTime
    local line2 = "Windows: " .. windowList

    lines[1] = line1
    lines[2] = line2

    return lines, osConfig.taskbarHeight
end

local function drawFrame(win, content, monitorWidth, monitorHeight)
    local lines = {}

    local title = win.appName or "Window"
    if win.width < #title + 4 then
        title = string.sub(title, 1, win.width - 4)
    end

    table.insert(lines, "=" .. title .. string.rep(" ", win.width - #title - 1) .. "X")

    for i, line in ipairs(content) do
        table.insert(lines, line)
    end

    return lines
end

local function fullRender(monitorId, width, height)
    local output = {}

    local taskbarLines, taskbarH = drawTaskbar(monitorId, width, height)
    for i = 1, taskbarH do
        output[i] = taskbarLines[i] or ""
    end

    local sortedWindows = {}
    for _, win in pairs(state.windows) do
        if win.monitorId == monitorId then
            table.insert(sortedWindows, win)
        end
    end
    table.sort(sortedWindows, function(a, b) return a.y < b.y end)

    local yOffset = taskbarH + 1
    for _, win in ipairs(sortedWindows) do
        local app = state.apps[win.appName]
        if app then
            local contentHeight = win.height
            local renderData = app.render(win.width, contentHeight, win.appState)
            local framed = drawFrame(win, renderData, width, height)
            for i, line in ipairs(framed) do
                output[yOffset + i - 1] = line
            end
            yOffset = yOffset + #framed
        end
    end

    return output
end

local function refreshMonitor(monitorId)
    local monitor = state.monitors[monitorId]
    if not monitor then return end

    local width, height = monitor.width or 50, monitor.height or 20
    local render = fullRender(monitorId, width, height)

    sendToMonitor(monitorId, {
        type = "render",
        lines = render,
        width = width,
        height = height
    })
end

local function refreshAllMonitors()
    for monitorId, _ in pairs(state.monitors) do
        refreshMonitor(monitorId)
    end
end

local function openApp(appName, monitorId, x, y, width, height)
    local app = state.apps[appName]
    if not app then return nil end

    local winId = state.nextWindowId
    state.nextWindowId = state.nextWindowId + 1

    local win = {
        id = winId,
        appName = appName,
        monitorId = monitorId,
        x = x,
        y = y,
        width = width,
        height = height,
        appState = {}
    }

    state.windows[winId] = win

    if app.init then
        app.init(win.appState)
    end

    refreshMonitor(monitorId)
    saveState()

    return winId
end

local function closeWindow(winId)
    local win = state.windows[winId]
    if not win then return end

    state.windows[winId] = nil
    refreshMonitor(win.monitorId)
    saveState()
end

local function registerApp(name, app)
    state.apps[name] = app
end

local function loadApps()
    if not fs.exists("Apps") then return end

    local files = fs.list("Apps")
    for _, file in ipairs(files) do
        if string.match(file, "%.lua$") then
            local appName = string.gsub(file, "%.lua$", "")
            local func, err = loadfile("Apps/" .. file)
            if func then
                local success, app = pcall(func)
                if success and app then
                    registerApp(appName, app)
                    print("Loaded app: " .. appName)
                else
                    print("App failed to initialize: " .. appName)
                end
            else
                print("Failed to load app: " .. file .. " - " .. tostring(err))
            end
        end
    end
end

local function handleNetworkMessage(event, side, channel, replyChannel, message, distance)
    if channel ~= 100 then return end

    if message.type == "announce" then
        local clientId = message.clientId or side
        local clientType = message.clientType or "monitor"

        if clientType == "monitor" then
            state.monitors[clientId] = {
                channel = replyChannel,
                width = message.width or 50,
                height = message.height or 20,
                side = side
            }
            print("Monitor connected: " .. clientId .. " (" .. message.width .. "x" .. message.height .. ")")
            refreshMonitor(clientId)

        elseif clientType == "io" then
            state.ioClients[clientId] = {
                channel = replyChannel,
                side = side,
                capabilities = message.capabilities or {}
            }
            print("IO client connected: " .. clientId)

        elseif clientType == "sensor" then
            state.sensorClients[clientId] = {
                channel = replyChannel,
                side = side,
                sensors = message.sensors or {}
            }
            print("Sensor client connected: " .. clientId)
        end

    elseif message.type == "sensorData" then
        local clientId = message.clientId
        if state.sensorClients[clientId] then
            state[message.varName] = message.value
        end

    elseif message.type == "touch" then
        local monitorId = message.monitorId
        local x, y = message.x, message.y
        local winId = message.winId

        if winId then
            local win = state.windows[winId]
            if win then
                local app = state.apps[win.appName]
                if app and app.handleTouch then
                    local handled, newState = app.handleTouch(x - win.x, y - win.y - osConfig.taskbarHeight, win.width, win.height, win.appState)
                    if newState then
                        win.appState = newState
                    end
                    if handled then
                        refreshMonitor(monitorId)
                    end
                end
            end
        else
            if y <= osConfig.taskbarHeight then
                handleTaskbarTouch(x, y, monitorId)
            end
        end

    elseif message.type == "resize" then
        local monitorId = message.monitorId
        if state.monitors[monitorId] then
            state.monitors[monitorId].width = message.width
            state.monitors[monitorId].height = message.height
            refreshMonitor(monitorId)
        end
    end
end

local function handleTaskbarTouch(x, y, monitorId)
end

local function runBackgroundTasks()
    for appName, app in pairs(state.apps) do
        if app.background then
            local results = app.background()
            if results then
                if results.stateUpdate then
                    for _, win in pairs(state.windows) do
                        if win.appName == appName then
                            win.appState = results.stateUpdate
                        end
                    end
                end
                if results.ioCommand then
                    sendToIO(results.ioCommand)
                end
            end
        end
    end
end

local function sendToIO(command)
    local targetClient = command.target
    local ioClient = state.ioClients[targetClient]
    if ioClient and ioClient.channel then
        modem.send(ioClient.channel, {
            type = "ioCommand",
            command = command.action,
            target = command.target,
            value = command.value
        })
    end
end

local function mainLoop()
    local modem = peripheral.wrap("back")
    if not modem then
        print("No modem found on back")
        return
    end
    modem.open(100)

    loadState()
    loadApps()

    print("SmartHome OS starting...")

    local saveCounter = 0
    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()

        if event == "modem_message" then
            handleNetworkMessage(event, p1, p2, p3, p4, p5)
        elseif event == "peripheral" then
        elseif event == "peripheral_detach" then
        end

        runBackgroundTasks()

        saveCounter = saveCounter + 1
        if saveCounter >= 60 then
            saveState()
            saveCounter = 0
        end

        sleep(osConfig.tickInterval)
    end
end

mainLoop()