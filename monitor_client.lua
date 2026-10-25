local storage = dofile("Lib/storage.lua")
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
