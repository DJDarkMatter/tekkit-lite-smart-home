-- Run from the computer root. Configs survive program updates.
local storage = dofile("Lib/storage.lua")
local Network = dofile("Lib/network.lua")
local IO = dofile("Lib/io.lua")
local networkConfig = storage.config("Configs/network.txt", {networkId = "home", channel = 45231})
local config = storage.config("Configs/io.txt", {
    clientId = "io_" .. os.getComputerID(), sides = Network.sides,
    announceInterval = 5, timeout = 15, safeOff = true, outputInterval = 0.6,
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
local timer = os.startTimer(0.1)
while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
        local message = net.receive(p1, p2, p3, p4)
        if message then client.handle(message, os.clock()) end
    elseif event == "redstone" then
        client.readInputs(false)
    elseif event == "timer" and p1 == timer then
        client.tick(os.clock())
        timer = os.startTimer(0.1)
    elseif event == "peripheral" or event == "peripheral_detach" then
        net.peripheralChanged(p1)
        if not net.modem then client.disconnect() end
        client.lastAnnounce = -math.huge
        client.tick(os.clock())
    end
end
