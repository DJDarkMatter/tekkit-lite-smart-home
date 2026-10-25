-- Start from / with: main_os.lua
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
