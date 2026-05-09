local config = {
    networkChannel = 45231,
    clientId = "io_main",
    sides = {
        "top", "bottom", "left", "right", "front", "back"
    }
}

local connected = false
local osChannel = nil

local function announce()
    local capabilities = {}
    for _, side in ipairs(config.sides) do
        local wrapped = peripheral.wrap(side)
        if wrapped then
            if wrapped.setBundledOutput then
                capabilities[side] = "output"
            end
            if wrapped.getBundledOutput then
                capabilities[side] = capabilities[side] or "input"
            end
            if wrapped.getInput then
                capabilities[side] = "input"
            end
        end
    end

    local message = {
        type = "announce",
        clientType = "io",
        clientId = config.clientId,
        capabilities = capabilities
    }
    modem.transmit(config.networkChannel, config.networkChannel, message)
end

local function handleCommand(message)
    local cmd = message.command
    local target = message.target
    local value = message.value

    if cmd == "setOutput" then
        local parts = {}
        for part in string.gmatch(target, "[^:]+") do
            table.insert(parts, part)
        end
        local side = parts[1]
        local color = tonumber(parts[2]) or 0

        if value then
            redstone.setBundledOutput(side, colors.combine(redstone.getBundledOutput(side) or 0, color))
        else
            redstone.setBundledOutput(side, colors.combine(redstone.getBundledOutput(side) or 0, bit.bnot(color)))
        end
    end
end

local function readInputs()
    for _, side in ipairs(config.sides) do
        local success, input = pcall(function()
            return redstone.getBundledInput(side)
        end)
        if success and input then
            modem.transmit(config.networkChannel, config.networkChannel, {
                type = "inputData",
                clientId = config.clientId,
                side = side,
                value = input
            })
        end
    end
end

local function mainLoop()
    local modemSide = nil
    for _, side in ipairs(config.sides) do
        local wrapped = peripheral.wrap(side)
        if wrapped and wrapped.isWireless then
            modemSide = side
            break
        end
    end

    if not modemSide then
        print("No wireless modem found")
        return
    end

    local modem = peripheral.wrap(modemSide)
    modem.open(config.networkChannel)
    print("IO Client " .. config.clientId .. " starting on " .. modemSide)

    announce()

    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")

        if channel == config.networkChannel then
            if message.type == "ioCommand" then
                handleCommand(message)
            end
        end

        sleep(0.5)
    end
end

mainLoop()