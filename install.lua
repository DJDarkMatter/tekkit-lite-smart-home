-- Download this file once, then: install server|io|monitor [branch-or-commit]
-- Programs/configuration are separate. Existing Configs and startup are untouched.
local args = {...}
local role, ref = args[1], args[2] or "main"
local entry = {server = "main_os", io = "Clients/io_client", monitor = "Clients/monitor_client"}
if not entry[role] then
    print("Usage: install server|io|monitor [branch-or-commit]")
    return
end
assert(ref:match("^[%w_./-]+$"), "Invalid branch or commit")
assert(http and http.get, "HTTP is disabled; ask the Minecraft server admin or copy files manually")
assert(shell.dir() == "", "Run cd / first")
local files = {"Lib/storage.lua", "Lib/network.lua"}
if role == "server" then
    files[#files + 1] = "Lib/server.lua"
    files[#files + 1] = "Apps/switchboard.lua"
elseif role == "io" then files[#files + 1] = "Lib/io.lua"
else files[#files + 1] = "Lib/monitor.lua" end
files[#files + 1] = entry[role] .. ".lua"
local base = "https://raw.githubusercontent.com/DJDarkMatter/tekkit-lite-smart-home/" .. ref .. "/"
local downloaded = {}
-- A missing ref or a failed HTTP download cannot partially replace the install.
for _, path in ipairs(files) do
    print("Downloading " .. path)
    local response = assert(http.get(base .. path), "Cannot download " .. path .. " from " .. ref)
    local code = response.getResponseCode and response.getResponseCode() or 200
    local contents = response.readAll()
    response.close()
    assert(code == 200 and type(contents) == "string" and #contents > 0, "Bad response for " .. path)
    local chunk, err = loadstring(contents, path)
    assert(chunk, "Invalid Lua download: " .. path .. ": " .. tostring(err))
    downloaded[path] = contents
end
for _, path in ipairs(files) do
    local dir = fs.getDir(path)
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
print("First connection settings: Configs/network.txt (created on first run)")
