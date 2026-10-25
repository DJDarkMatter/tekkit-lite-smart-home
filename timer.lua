-- Configuration variables
local countdownTime = 14400 -- Initial countdown time in seconds
local redstoneTime = 60    -- Redstone activation time in seconds
 
-- File for saving the countdown state
local saveFile = "countdown_state.txt"
 
-- Load or initialize the timer state
local function loadState()
    if fs.exists(saveFile) then
        local file = fs.open(saveFile, "r")
        local state = textutils.unserialize(file.readAll())
        file.close()
        return state
    end
    -- Default state if no file exists
    return {remainingTime = countdownTime, redstoneActive = false, redstoneEndTime = 0}
end
 
local function saveState(state)
    local file = fs.open(saveFile, "w")
    file.write(textutils.serialize(state))
    file.close()
end
 
-- Initialize peripherals
local monitor = peripheral.wrap("back")
if monitor then
    monitor.setTextScale(1)
    monitor.clear()
    monitor.setCursorPos(1, 1)
else
    print("Monitor not detected on top. Check your setup.")
end
 
-- Load initial state
local state = loadState()
local lastUpdateTime = os.clock()
 
-- Display the initial time on the monitor
if monitor then
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Coffee:")
    monitor.setCursorPos(1, 2)
    monitor.write(math.floor(state.remainingTime) .. "s")
end
 
-- Main program loop
while true do
    -- Check for redstone input from the left (proximity sensor)
    if redstone.getInput("left") then
        local currentTime = os.clock()
        local elapsed = currentTime - lastUpdateTime
 
        if state.redstoneActive then
            -- Countdown for redstone activation time
            state.redstoneEndTime = state.redstoneEndTime - elapsed
            if state.redstoneEndTime <= 0 then
                redstone.setOutput("right", false)
                state.redstoneActive = false
                state.remainingTime = countdownTime  -- Reset countdown
                saveState(state)
            else
                -- Update the monitor with the remaining redstone time
                if monitor then
                    monitor.clear()
                    monitor.setCursorPos(1, 1)
                    monitor.write("Coffee:")
                    monitor.setCursorPos(1, 2)
                    monitor.write(math.floor(state.redstoneEndTime) .. "s")
                end
            end
        else
            -- Countdown for main timer
            state.remainingTime = state.remainingTime - elapsed
            if state.remainingTime <= 0 then
                redstone.setOutput("right", true)
                state.redstoneActive = true
                state.redstoneEndTime = redstoneTime  -- Set time for redstone activation
                saveState(state)
            else
                -- Update the monitor with the new remaining countdown time
                if monitor then
                    monitor.clear()
                    monitor.setCursorPos(1, 1)
                    monitor.write("Coffee:")
                    monitor.setCursorPos(1, 2)
                    monitor.write(math.floor(state.remainingTime) .. "s")
                end
            end
        end
        saveState(state)
        lastUpdateTime = os.clock()
    else
        -- If no player is detected, keep the monitor showing the remaining time
        if state.redstoneActive then
            -- Show remaining time for redstone activation on the monitor
            if monitor then
                monitor.clear()
                monitor.setCursorPos(1, 1)
                monitor.write("Coffee:")
                monitor.setCursorPos(1, 2)
                monitor.write(math.floor(state.redstoneEndTime) .. "s")
            end
        else
            -- Show the remaining time for the main countdown when no redstone signal
            if monitor then
                monitor.clear()
                monitor.setCursorPos(1, 1)
                monitor.write("Coffee:")
                monitor.setCursorPos(1, 2)
                monitor.write(math.floor(state.remainingTime) .. "s")
            end
        end
        lastUpdateTime = os.clock() -- Reset lastUpdateTime to avoid decrementing
    end
    sleep(1)  -- Update every second
end
