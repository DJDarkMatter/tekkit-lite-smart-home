-- Monitor initialisieren
local monitor = peripheral.wrap("top")
local width, height = monitor.getSize()
monitor.setTextScale(1)
local currentScreen = "menu"
local waiting = 0.3
local colorsOn = colors.lime
local colorsOff = colors.red
local textColor = colors.white
local tableLineColor = colors.gray
local menuOptionColor = colors.gray
local menuOptionTextColor = colors.white
local function saveState(state)
    local file = fs.open("redstoneState", "w")
    if file then
        local serializedState = textutils.serialize(state)
        file.write(serializedState)
        file.close()
        print("State saved to redstoneState:", serializedState)
    else
        print("Error: Could not open redstoneState for writing.")
    end
end
local function loadState()
    if fs.exists("redstoneState") then
        local file = fs.open("redstoneState", "r")
        if file then
            local content = file.readAll()
            file.close()
            print("Loaded content from redstoneState:", content)
            if content and content ~= "" then
                return textutils.unserialize(content)
            else
                print("Error: redstoneState file is empty or corrupted.")
            end
        else
            print("Error: Could not open redstoneState for reading.")
        end
    else
        print("redstoneState file does not exist. Using defaults.")
    end
    return nil
end
local tableButtons = {
    back = {
        redstoneSide = "back",
        buttons = {
            {name = "White", color = colors.white},
            {name = "Orange", color = colors.orange},
            {name = "Magenta", color = colors.magenta},
            {name = "Blue", color = colors.lightBlue},
            {name = "Yellow", color = colors.yellow},
            {name = "Lime", color = colors.lime},
            {name = "Pink", color = colors.pink},
            {name = "Gray", color = colors.gray},
            {name = "Light Gray", color = colors.lightGray},
            {name = "Cyan", color = colors.cyan},
            {name = "Purple", color = colors.purple},
            {name = "Blue", color = colors.blue},
            {name = "Brown", color = colors.brown},
            {name = "Green", color = colors.green},
            {name = "Red", color = colors.red},
            {name = "Black", color = colors.black}
        }
    },
    front = {
        redstoneSide = "front",
        buttons = {
            {name = "White", color = colors.white},
            {name = "Orange", color = colors.orange},
            {name = "Magenta", color = colors.magenta},
            {name = "Blue", color = colors.lightBlue},
            {name = "Yellow", color = colors.yellow},
            {name = "Lime", color = colors.lime},
            {name = "Pink", color = colors.pink},
            {name = "Gray", color = colors.gray},
            {name = "Light Gray", color = colors.lightGray},
            {name = "Cyan", color = colors.cyan},
            {name = "Purple", color = colors.purple},
            {name = "Blue", color = colors.blue},
            {name = "Brown", color = colors.brown},
            {name = "Green", color = colors.green},
            {name = "Red", color = colors.red},
            {name = "Black", color = colors.black}
        }
    },
    right = {
        redstoneSide = "right",
        buttons = {
            {name = "White", color = colors.white},
            {name = "Orange", color = colors.orange},
            {name = "Magenta", color = colors.magenta},
            {name = "Blue", color = colors.lightBlue},
            {name = "Yellow", color = colors.yellow},
            {name = "Lime", color = colors.lime},
            {name = "Pink", color = colors.pink},
            {name = "Gray", color = colors.gray},
            {name = "Light Gray", color = colors.lightGray},
            {name = "Cyan", color = colors.cyan},
            {name = "Purple", color = colors.purple},
            {name = "Blue", color = colors.blue},
            {name = "Brown", color = colors.brown},
            {name = "Green", color = colors.green},
            {name = "Red", color = colors.red},
            {name = "Black", color = colors.black}
        }
    },
    left = {
        redstoneSide = "left",
        buttons = {
            {name = "White", color = colors.white},
            {name = "Orange", color = colors.orange},
            {name = "Magenta", color = colors.magenta},
            {name = "Blue", color = colors.lightBlue},
            {name = "Yellow", color = colors.yellow},
            {name = "Lime", color = colors.lime},
            {name = "Pink", color = colors.pink},
            {name = "Gray", color = colors.gray},
            {name = "Light Gray", color = colors.lightGray},
            {name = "Cyan", color = colors.cyan},
            {name = "Purple", color = colors.purple},
            {name = "Blue", color = colors.blue},
            {name = "Brown", color = colors.brown},
            {name = "Green", color = colors.green},
            {name = "Red", color = colors.red},
            {name = "Black", color = colors.black}
        }
    },
    bottom = {
        redstoneSide = "bottom",
        buttons = {
            {name = "White", color = colors.white},
            {name = "Orange", color = colors.orange},
            {name = "Magenta", color = colors.magenta},
            {name = "Blue", color = colors.lightBlue},
            {name = "Yellow", color = colors.yellow},
            {name = "Lime", color = colors.lime},
            {name = "Pink", color = colors.pink},
            {name = "Gray", color = colors.gray},
            {name = "Light Gray", color = colors.lightGray},
            {name = "Cyan", color = colors.cyan},
            {name = "Purple", color = colors.purple},
            {name = "Blue", color = colors.blue},
            {name = "Brown", color = colors.brown},
            {name = "Green", color = colors.green},
            {name = "Red", color = colors.red},
            {name = "Black", color = colors.black}
        }
    }
}
 
 
 
 
local activeColors = loadState() or {
    back = 0,
    front = 0,
    right = 0,
    left = 0,
    bottom = 0
}
saveState(activeColors)
print("Loaded activeColors:", textutils.serialize(activeColors))
local function updateRedstoneOutput()
    if not tableButtons then
        print("Error: tableButtons is nil. Cannot update Redstone output.")
        return
    end
    local sides = {}
    for tableName, data in pairs(tableButtons) do
        local side = data.redstoneSide
        local signal = activeColors[tableName] or 0
        print("Processing Table:", tableName, "Side:", side, "Signal:", signal)
        if side and signal then
            sides[side] = colors.combine(sides[side] or 0, signal)
        else
            print("Warning: Missing side or signal for table:", tableName)
        end
    end
    for side, output in pairs(sides) do
        print("Setting Redstone Output for Side:", side, "with Signal:", output)
        redstone.setBundledOutput(side, output)
        sleep(0.051)
    end
end
updateRedstoneOutput()
local function toggleBundledOutput(tableName, color)
    if bit.band(activeColors[tableName], color) == color then
        activeColors[tableName] = bit.band(activeColors[tableName], bit.bnot(color))
    else
        activeColors[tableName] = colors.combine(activeColors[tableName], color)
    end
    saveState(activeColors) -- Zustand speichern
    sleep(0.1)
    updateRedstoneOutput()
end
local function isColorOn(tableName, color)
    return bit.band(activeColors[tableName], color) == color
end
local menuOptions = {
    {label = "Back  ", action = "back"},
    {label = "Front ", action = "front"},
    {label = "Right ", action = "right"},
    {label = "Left  ", action = "left"},
    {label = "Bottom", action = "bottom"}
}
local function initializeDefaults()
    for tableName, data in pairs(tableButtons) do
        activeColors[tableName] = 0 -- Initialisieren
        for _, button in ipairs(data.buttons) do
            if button.defaultOn then
                activeColors[tableName] = colors.combine(activeColors[tableName], button.color)
            end
        end
    end
    updateRedstoneOutput()
end
 
local function writeCentered(y, text)
    local x = math.floor((width - #text) / 2) + 1 -- Berechnung der X-Position
    monitor.setCursorPos(x, y) -- Cursor positionieren
    monitor.write(text) -- Text schreiben
end
 
local function drawMenu()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    monitor.setTextColor(colors.gray)
    writeCentered(2, " Redstone Controllpanel ")
    monitor.setTextColor(colors.lightGray)
    monitor.setCursorPos(1, 4)
    monitor.write(string.rep("=", width))
    for i, option in ipairs(menuOptions) do
        local y = 3 + (i * 3)
        local data = tableButtons[option.action]
        local isActive = false
        for _, button in ipairs(data.buttons) do
            if isColorOn(option.action, button.color) then
                isActive = true
                break
            end
        end
        monitor.setCursorPos(1, y)
        monitor.setBackgroundColor(isActive and colorsOn or colorsOff)
        monitor.write(" ")
        monitor.setBackgroundColor(menuOptionColor)
        monitor.setTextColor(menuOptionTextColor)
        monitor.setCursorPos((width/2)-10, y)
        monitor.write("    " .. option.label .. "    ")
    end
    monitor.setCursorPos(1, 21)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.lightGray)
    monitor.write(string.rep("=", width))
end
local function drawHeader(title)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    monitor.setTextColor(colors.gray)
    monitor.setCursorPos(1, 2)
    monitor.write(title)
 
    local data = tableButtons[currentScreen]
    if data and data.redstoneSide then
        monitor.setCursorPos(20, 2)
        monitor.setTextColor(colors.green)
        monitor.write(" -> " .. data.redstoneSide)
    else
        monitor.setCursorPos(20, 2)
        monitor.setTextColor(colors.red)
        monitor.write(" [Keine Seite]")
    end
 
    monitor.setCursorPos(width-4, 2)
    monitor.setBackgroundColor(colors.gray)
    monitor.setTextColor(colors.white)
    monitor.write("<--")
    monitor.setBackgroundColor(colors.gray)
    monitor.setCursorPos(1, 4)
    monitor.setTextColor(colors.white)
    monitor.write(string.rep("-", width))
end
local function drawTable()
    monitor.setBackgroundColor(tableLineColor) 
    monitor.setTextColor(textColor)
    monitor.setCursorPos(1, 5)
    monitor.clearLine()
    monitor.write("| Funktion")
    monitor.setCursorPos(width/2,5)
    monitor.write("|")
    monitor.setCursorPos(width-7,5)
    monitor.write("Status |")
    monitor.setCursorPos(1, 6)
    monitor.write(string.rep("-", width))
 
    local data = tableButtons[currentScreen]
    local buttons = data.buttons
    for i, button in ipairs(buttons) do
        local y = 6 + i
        local bgColor = isColorOn(currentScreen, button.color) and colorsOn or colorsOff
        monitor.setBackgroundColor(bgColor)
        monitor.setCursorPos(1, y)
        monitor.clearLine()
        monitor.setTextColor(textColor)
        monitor.write("| " .. button.name)
        monitor.setCursorPos(width/2, y)
        monitor.write("|")
        monitor.setCursorPos(width-5, y)
        monitor.write(isColorOn(currentScreen, button.color) and "ON " or "OFF")
        monitor.setCursorPos(width, y)
        monitor.write("|")
    end
 
    monitor.setBackgroundColor(tableLineColor)
    monitor.setCursorPos(1, 6 + #buttons + 1)
    monitor.write(string.rep("-", width))
end
 
local function toggleButton(x, y)
    
    if x >= width-4 and x <= width and y == 2 then
        currentScreen = "menu"
        drawMenu()
        return
    end
 
    
    local buttonIndex = y - 6
    local data = tableButtons[currentScreen]
    local buttons = data.buttons
    if buttonIndex > 0 and buttonIndex <= #buttons then
        toggleBundledOutput(currentScreen, buttons[buttonIndex].color)
        drawTable()
    end
end
 
local function handleMenuClick(x, y)
    for i, option in ipairs(menuOptions) do
        local expectedY = 3 + (i * 3) -- Start bei Zeile 3
        if y >= expectedY and y <= expectedY + 1 then
            currentScreen = option.action
            if tableButtons[currentScreen] then
                drawHeader(option.label)
                drawTable()
            end
            return
        end
    end
end
 
 
local function startScreensaver()
    shell.run("screensaver")
    drawMenu()
end
 
local function handleHeaderClick(x, y)
    if y == 2 and x >= 1 and x <= width then
        startScreensaver()
    end
end
local function initializeProgram()
    updateRedstoneOutput()
    drawMenu()
end
 
initializeProgram()
 
 
while true do
    local event, side, x, y = os.pullEvent("monitor_touch")
    if currentScreen == "menu" then
        handleHeaderClick(x, y)
        handleMenuClick(x, y)
    elseif tableButtons[currentScreen] then
        toggleButton(x, y)
    end
end
