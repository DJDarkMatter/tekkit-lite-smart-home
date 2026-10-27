"""Build the one-paste installer using only the repository's current Lua sources."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PATHS = [
    "Lib/storage.lua", "Lib/network.lua", "Lib/server.lua", "Lib/io.lua", "Lib/monitor.lua",
    "main_os.lua", "Clients/io_client.lua", "Clients/monitor_client.lua",
]

def lua_string(value):
    equals = "="
    while "]" + equals + "]" in value:
        equals += "="
    return "[" + equals + "[" + value + "]" + equals + "]"

header = '''-- SmartHome OS installer: bundled-v2
-- Upload this ONE file to Pastebin. All role files are included below.
-- Usage: inst server|io|monitor [--startup]
-- User apps: inst app NAME PASTE_ID   or   inst app NAME --file PATH
-- OS/client installation is offline. Apps are fetched only on request.
local sources = {
'''
entries = [f'    ["{path}"] = {lua_string((ROOT / path).read_text())},\n' for path in PATHS]
runner = r'''}
local args = {...}
local role, autorun = args[1], false
local entry = {server = "main_os.lua", io = "Clients/io_client.lua", monitor = "Clients/monitor_client.lua"}
print("SmartHome installer: bundled-v2")
if not entry[role] and role ~= "app" then
    print("Usage: inst server|io|monitor [--startup]")
    print("       inst app NAME PASTE_ID | inst app NAME --file PATH")
    return
end
assert(shell.dir() == "", "Run cd / first")
local files
if role == "app" then
    local name, source = args[2], args[3]
    assert(type(name) == "string" and name:match("^[%w_-]+$"), "Specify a simple app name without .lua")
    assert(source and (source == "--file" and args[4] and not args[5]
        or source:match("^%w+$") and not args[4]), "Usage: inst app NAME PASTE_ID | inst app NAME --file PATH")
    assert(fs.exists("main_os.lua") and fs.exists("Lib/server.lua"), "Install apps on the central OS computer")
    local path = "Apps/" .. name .. ".lua"
    local contents
    if source == "--file" then
        local file = assert(fs.open(args[4], "r"), "Cannot read app source: " .. args[4])
        contents = file.readAll(); file.close()
    else
        if not fs.exists("Apps") then fs.makeDir("Apps") end
        local temporary = path .. ".download"
        if fs.exists(temporary) then fs.delete(temporary) end
        assert(shell.run("pastebin", "get", source, temporary) and fs.exists(temporary), "Pastebin app download failed")
        local file = assert(fs.open(temporary, "r"), "Cannot read downloaded app")
        contents = file.readAll(); file.close()
        fs.delete(temporary)
    end
    assert(type(contents) == "string" and #contents > 0, "Empty app source")
    local chunk, err = loadstring(contents, path)
    assert(chunk, "Invalid app Lua: " .. tostring(err))
    -- Read settings without resetting them or executing the app at install time.
    local storageChunk = assert(loadstring(sources["Lib/storage.lua"], "Lib/storage.lua"))
    setfenv(storageChunk, getfenv(1))
    local storage = storageChunk()
    local configPath = "Configs/os.txt"
    local settings = storage.load(configPath)
    if not settings then
        for _, suffix in ipairs({"", ".tmp", ".bak"}) do
            assert(not fs.exists(configPath .. suffix), "Unreadable OS settings")
        end
        settings = {}
    end
    if settings.enabledApps == nil then settings.enabledApps = {} end
    assert(type(settings.enabledApps) == "table", "Invalid enabledApps setting")
    settings.enabledApps[name] = true -- Explicit app installation opts this app in.
    sources[path], sources[configPath] = contents, textutils.serialize(settings)
    files = {path, configPath}
else
    for index = 2, #args do
        assert(args[index] == "--startup", "Usage: inst server|io|monitor [--startup]")
        autorun = true
    end
    files = {"Lib/storage.lua", "Lib/network.lua"}
    if role == "server" then files[#files + 1] = "Lib/server.lua"
    elseif role == "io" then files[#files + 1] = "Lib/io.lua"
    else files[#files + 1] = "Lib/monitor.lua" end
    files[#files + 1] = entry[role]
    if autorun then
        sources.startup = 'shell.setDir("/")\nshell.run("' .. entry[role] .. '")\n'
        files[#files + 1] = "startup"
    end
end
-- Check every file before replacing any installed program.
for _, path in ipairs(files) do
    local contents = assert(sources[path], "Missing bundled file: " .. path)
    if path:match("%.lua$") or path == "startup" then
        local chunk, err = loadstring(contents, path)
        assert(chunk, "Invalid Lua: " .. path .. ": " .. tostring(err))
    else assert(type(textutils.unserialize(contents)) == "table", "Invalid settings: " .. path) end
end
for _, path in ipairs(files) do
    local dir = path:match("^(.*)/[^/]+$") or ""
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local file = assert(fs.open(path .. ".download", "w"), "Cannot stage " .. path)
    file.write(sources[path])
    file.close()
end
for _, path in ipairs(files) do
    if fs.exists(path) then
        if fs.exists(path .. ".pre_update") then fs.delete(path .. ".pre_update") end
        fs.move(path, path .. ".pre_update")
    end
    fs.move(path .. ".download", path)
    print("Installed " .. path)
end
if role == "app" then
    print("Installed and enabled user app: " .. args[2])
    print("Restart the central OS to load it")
    return
end
print("Installed " .. role .. " from the bundled files")
if autorun then
    print("Autorun enabled; an existing startup is kept as startup.pre_update")
    print("Run reboot to start automatically")
else print("Autorun unchanged; add --startup to enable it") end
print("Start with: " .. entry[role])
'''
contents = header + "".join(entries) + runner
path = ROOT / "install.lua"
if "--check" in sys.argv:
    if not path.exists() or path.read_text() != contents:
        raise SystemExit("install.lua is stale; run python3 tools/build_installer.py")
    print("Bundled installer matches all current source files")
else:
    path.write_text(contents)
    print(f"Built {path.name}: {len(contents.encode())} bytes, {len(PATHS)} bundled source files")
