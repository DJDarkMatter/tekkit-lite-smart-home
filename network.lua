-- All wire packets are serialized strings, including on old CC modems.
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
