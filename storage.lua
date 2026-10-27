-- Lua 5.1 / ComputerCraft 1.5. Only plain, serializable data belongs here.
local storage = {}

local function readTable(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    local ok, value = pcall(textutils.unserialize, contents)
    if ok and type(value) == "table" then return value end
end

function storage.load(path, validate)
    for _, candidate in ipairs({path, path .. ".tmp", path .. ".bak"}) do
        local value = readTable(candidate)
        if value and (not validate or validate(value)) then return value, candidate end
    end
end

function storage.save(path, value)
    local ok, err = pcall(function()
        local contents = textutils.serialize(value)
        -- fs.getDir was only added in CC 1.63; Tekkit Lite uses older CC.
        local dir = path:match("^(.*)/[^/]+$") or ""
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local file = assert(fs.open(path .. ".tmp", "w"), "Cannot write " .. path)
        file.write(contents)
        file.close()
        if fs.exists(path) then
            if readTable(path) then
                if fs.exists(path .. ".bak") then fs.delete(path .. ".bak") end
                fs.move(path, path .. ".bak")
            else
                -- A corrupt primary must not replace a good backup.
                fs.delete(path)
            end
        end
        fs.move(path .. ".tmp", path)
    end)
    return ok, err
end

function storage.config(path, defaults)
    local value = storage.load(path)
    if value then
        for key, default in pairs(defaults) do
            if value[key] == nil then value[key] = default end
        end
        return value
    end
    for _, suffix in ipairs({"", ".tmp", ".bak"}) do
        assert(not fs.exists(path .. suffix), "Unreadable config: " .. path .. suffix)
    end
    local ok, err = storage.save(path, defaults)
    assert(ok, err)
    return defaults
end

return storage
