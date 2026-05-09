-- Monitor initialisieren
local monitor = peripheral.wrap("top")
monitor.setTextScale(1) -- Gleiche Skalierung wie im Hauptmenü
local screenWidth, screenHeight = 50, 24 -- Bildschirmgröße wie im Hauptmenü
 
-- Funktion: Landschaft zeichnen
local function drawLandscape(offset)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
 
    -- Himmel
    monitor.setBackgroundColor(colors.lightBlue)
    for y = 1, 8 do
        monitor.setCursorPos(1, y)
        monitor.write(string.rep(" ", screenWidth))
    end
 
    -- Hügeliger Horizont (Bewegung synchron mit Gebäuden und Blumen)
    local horizon = {2,3,5,6,7,6,5,4,2,1,3,5,6,7,5,4,2,2,3,4,5,4,3,4,6,5,4,3} -- Höhenverlauf der Hügel
    local horizonLength = #horizon
 
    for x = 1, screenWidth do
        local hillHeight = horizon[(x + offset) % horizonLength + 1]
        for y = 9, 14 + hillHeight do
            monitor.setCursorPos(x, y)
            monitor.setBackgroundColor(colors.green)
            monitor.write(" ")
        end
    end
 
    -- Blumen (Bewegung synchron, langsamer Wechsel)
    local flowers = {
        {color = colors.red, symbol = "*"},
        {color = colors.yellow, symbol = "+"},
        {color = colors.purple, symbol = "@"},
        {color = colors.orange, symbol = "#"}
    }
 
    for i = 1, 15 do
        local flowerX = ((i * 5) + math.floor(offset / 2)) % screenWidth + 1 -- Langsame Bewegung
        local flowerY = math.random(9, screenHeight)
        local flower = flowers[math.random(1, #flowers)]
 
        monitor.setCursorPos(flowerX, flowerY)
        monitor.setTextColor(flower.color)
        monitor.write(flower.symbol)
    end
 
    -- Gebäude
    local buildings = {
        {x = 5, y = 7, width = 5, height = 4, color = colors.red}, -- Kleines Gebäude
        {x = 15, y = 6, width = 7, height = 5, color = colors.gray}, -- Größeres Gebäude
        {x = 28, y = 8, width = 6, height = 4, color = colors.orange}, -- Mittelgroßes Gebäude
    }
 
    for _, building in ipairs(buildings) do
        local adjustedX = (building.x + offset) % (screenWidth + building.width) - building.width
        if adjustedX < 0 then adjustedX = adjustedX + screenWidth end -- Negative Werte korrigieren
 
        for x = 0, building.width - 1 do
            for y = 0, building.height - 1 do
                if adjustedX + x >= 1 and adjustedX + x <= screenWidth then
                    monitor.setBackgroundColor(building.color)
                    monitor.setCursorPos(adjustedX + x, building.y + y)
                    monitor.write(" ")
                end
            end
        end
    end
 
    -- Wolken
    local clouds = {
        {x = 10, y = 3, width = 10, height = 2},
        {x = 25, y = 2, width = 7, height = 2},
    }
 
    for _, cloud in ipairs(clouds) do
        local adjustedX = (cloud.x + math.floor(offset / 2)) % (screenWidth + cloud.width) - cloud.width
        if adjustedX < 0 then adjustedX = adjustedX + screenWidth end -- Negative Werte korrigieren
 
        for x = 0, cloud.width - 1 do
            for y = 0, cloud.height - 1 do
                if adjustedX + x >= 1 and adjustedX + x <= screenWidth then
                    monitor.setBackgroundColor(colors.white)
                    monitor.setCursorPos(adjustedX + x, cloud.y + y)
                    monitor.write(" ")
                end
            end
        end
    end
end
 
-- Funktion: Animation starten
local function startScreensaver()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
 
    local offset = 0
    local animationRunning = true
 
    parallel.waitForAny(
        function()
            -- Animation
            while animationRunning do
                drawLandscape(offset)
                offset = offset + 1
                sleep(0.1)
            end
        end,
        function()
            -- Touch-Ereignis abwarten
            os.pullEvent("monitor_touch")
            animationRunning = false
        end
    )
 
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
end
 
-- Starte Bildschirmschoner
startScreensaver()
