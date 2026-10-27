-- Download once: install server|io|monitor [branch-or-commit] [--startup]
-- Configs are preserved. --startup backs up and replaces the boot script.
local args = {...}
local role = args[1]
local ref = (args[2] ~= "--startup" and args[2]) or "main"
local autorun = args[2] == "--startup" or args[3] == "--startup"
local entry = {server = "main_os", io = "Clients/io_client", monitor = "Clients/monitor_client"}
if not entry[role] then
    print("Usage: install server|io|monitor [ref] [--startup]")
    return
end
assert(ref:match("^[%w_./-]+$"), "Invalid branch or commit")
assert(not args[4] and (not args[3] or args[3] == "--startup"), "Unexpected install argument")
assert(http and http.get, "HTTP is disabled; ask the Minecraft server admin or copy files manually")
assert(shell.dir() == "", "Run cd / first")
local files = {"Lib/storage.lua", "Lib/network.lua"}
if role == "server" then
    files[#files + 1] = "Lib/server.lua"
elseif role == "io" then files[#files + 1] = "Lib/io.lua"
else files[#files + 1] = "Lib/monitor.lua" end
files[#files + 1] = entry[role] .. ".lua"
local base = "https://raw.githubusercontent.com/DJDarkMatter/tekkit-lite-smart-home/" .. ref .. "/"
local downloaded, flatLayout = {}, false
local function fetch(path)
    local response = http.get(base .. path)
    if not response then return nil end
    local code = response.getResponseCode and response.getResponseCode() or 200
    local contents = response.readAll()
    response.close()
    if code == 200 and type(contents) == "string" and #contents > 0 then return contents end
end
-- A missing ref or a failed HTTP download cannot partially replace the install.
for index, path in ipairs(files) do
    print("Downloading " .. path)
    local source = flatLayout and path:match("[^/]+$") or path
    local contents = fetch(source)
    -- Browser uploads sometimes flatten directories. Detect that once using a
    -- library, then use the same layout for all files, including client scripts.
    if not contents and index == 1 then
        contents = fetch(path:match("[^/]+$"))
        if contents then flatLayout = true; print("Using files from repository root") end
    end
    assert(contents, "Cannot download " .. path .. " from " .. ref)
    if path == "Lib/storage.lua" then
        -- Also accept the earlier upload which used a post-1.5 filesystem API.
        -- Adapt its path helper locally so a second GitHub file update is unnecessary.
        contents = contents:gsub("fs%.getDir%(path%)", '(path:match("^(.*)/[^/]+$") or "")')
    end
    local chunk, err = loadstring(contents, path)
    assert(chunk, "Invalid Lua download: " .. path .. ": " .. tostring(err))
    downloaded[path] = contents
end
if autorun then
    downloaded.startup = 'shell.setDir("/")\nshell.run("' .. entry[role] .. '.lua")\n'
    files[#files + 1] = "startup"
end
for _, path in ipairs(files) do
    local dir = path:match("^(.*)/[^/]+$") or ""
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local file = assert(fs.open(path .. ".download", "w"), "Cannot stage " .. path)
    file.write(downloaded[path])
    file.close()
end
for _, path in ipairs(files) do
    if fs.exists(path) then
        if fs.exists(path .. ".pre_update") then fs.delete(path .. ".pre_update") end
        fs.move(path, path .. ".pre_update")
    end
    fs.move(path .. ".download", path)
end
print("Installed " .. role .. " from " .. ref)
print("Start with: " .. entry[role] .. ".lua")
if autorun then print("Autorun enabled (previous startup kept as startup.pre_update)")
else print("Autorun unchanged; add --startup to enable it") end
print("First connection settings: Configs/network.txt (created on first run)")
