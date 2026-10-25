# App and network reference

## Single-file apps

Place a Lua file returning an app table in `Apps/` on the OS computer and restart the OS. Files are discovered automatically; the saved `appRegistry` records enabled apps. An entry set to `false` disables loading it. The example `Apps/switchboard.lua` uses no modem, redstone or filesystem APIs.

```lua
local app = {minWidth = 18, minHeight = 4, maxWidth = 40, maxHeight = 12}

function app.init(state, api)
    -- init runs after restoring state: set defaults, do not erase saved values.
    if state.seconds == nil then state.seconds = 0 end
end

function app.background(dt, state, api)
    state.seconds = state.seconds + dt
end

function app.render(width, height, state, api)
    return {"Running: " .. math.floor(state.seconds) .. "s"}
end

function app.handleTouch(x, y, width, height, state, api)
    -- All coordinates here are 1-based within the content, excluding the frame.
    state.seconds = 0
    api.save()
    return true
end

return app
```

Size limits describe **content** character dimensions. The OS adds a one-character frame and reserves two top taskbar rows. A background-only app can omit `render`. App state is shared across the app's windows and background hook and is persisted separately from window geometry. `handleTouch` may optionally return `handled, replacementState`.

Hooks must return promptly and must not call `sleep`, `read`, `os.pullEvent`, HTTP, or other yielding functions. Lua 5.1 hooks run under `pcall` for fault isolation. Apps are trusted code, not sandboxed plugins.

| API | Result |
| --- | --- |
| `api.mapOutput(name, clientId, side, color)` | `ok, error`; nil colour means ordinary/digital redstone; otherwise one CC colour bit |
| `api.setOutput(name, boolean)` | `ok, error`; saves desired state before sending it |
| `api.getOutput(name)` | Desired boolean; false if unknown |
| `api.getOutputs()` | Sorted array of `{name, clientId, side, color, value, online, confirmed}` |
| `api.getInput(clientId, side)` | `{value = bundledMask, digital = boolean}`, or nil if unknown/offline |
| `api.getSensor(clientId, name)` | Raw scalar reading, or nil if unknown/offline |
| `api.getSystem()` | `{gameTime, playerOnline}` |
| `api.getClients()` | Sorted array of `{id, type, online, computerId}` |
| `api.openApp(name, monitorId, x, y, width, height)` | `windowId, error`; geometry optional, outer dimensions |
| `api.closeWindow(windowId)` | `ok, error` |
| `api.placeWindow(windowId, x, y, width, height)` | `ok, error`; nil fields retain the old values |
| `api.save()` | `ok, error`; checkpoints central state |

Physical sides use computer-relative names. Mappings are independent of apps and persisted centrally. All mapped sides are fully owned by the OS. Input/sensor values are live observations, not restored stale values. Losing a sensor client clears its supplied system indicators.

`dt` is elapsed ComputerCraft `os.clock()` time between OS ticks. It is not reconstructed across program/server downtime. A real coffee app must define its own online/pause/harvest state transitions and explicitly save important counters.

## Transport

`Lib/network.lua` handles modem detection, string encoding and envelope checks. Configuration is a serialized Lua table in `Configs/network.txt`.

- Server listens on `channel` (default `45231`).
- Client listens on `1000 + (computerId % 40000)`, substituting `41001` if that equals the server channel.
- Clients announce to the server channel with their own channel as `replyChannel`.
- Server replies to that channel with its server channel as `replyChannel`.
- Every message is `textutils.serialize(packet)`; receivers use protected `textutils.unserialize`.

Every envelope has these fields:

```lua
{
  protocol = "SmartHomeOS/1",
  networkId = "home",
  sender = 11,           -- claimed ComputerCraft ID; not authentication
  recipient = 10,        -- may be absent for discovery to an unpinned server
  type = "announce",
  clientId = "io_11"     -- stable logical endpoint, distinct from computer ID
}
```

Multiple logical monitor endpoints can share a computer/reply channel. The recipient computer ID and the logical client ID are checked separately. Packets for another household, computer, channel, modem side, pinned OS ID or protocol are discarded. Packets are limited to 65536 encoded characters; monitor resolutions are bounded to 256x128 characters.

## Handshake and output state

1. Client sends `announce` with `clientType` (`io`, `monitor`, `sensor`), an increasing `nonce`, and capabilities/resolution.
2. OS registers the logical endpoint and returns `welcome`, echoing `nonce` and including its persisted per-boot `serverSession`.
3. Client accepts a welcome only for its current nonce. IO reports all inputs, including zero values.
4. OS sends the IO client `ioCommand`, with `command = "syncOutputs"`, `serverSession`, integer `revision`, and `outputs` indexed by physical side.
5. Client validates the complete snapshot before applying it, ignores earlier revisions/sessions, then sends `ioAck` with the applied revision and session.
6. OS retries unacknowledged state every two seconds. Announcements/full resynchronization also repeat every five seconds, recovering lost welcomes/acks/frames and OS/client restarts.

An IO snapshot looks like:

```lua
{
  type = "ioCommand", clientId = "io_11", command = "syncOutputs",
  serverSession = "10:3", revision = 7,
  outputs = {
    left = {bundled = 16385, digital = false},
    front = {bundled = 0, digital = true}
  }
}
```

It sets a complete desired state instead of sending toggle commands, so a duplicate/retry cannot toggle twice. Boot sessions and increasing revisions prevent delayed commands from restoring obsolete outputs. This is convergence/acknowledgement, not an exactly-once guarantee for external machinery.

Input updates use `inputData` with `side`, `value` (bundled mask), `digital`, and `serverSession`. Monitor touches use `touch` with `x`, `y` and `serverSession`; the OS decides the window. Frames use `render` with `lines`, `width`, `height`, `monitorId` and `serverSession`.

A future sensor adapter must implement the same announce/welcome/heartbeat process. Once welcomed, send `sensorData` with `varName`, scalar `value`, and `serverSession`. `playerOnline` must be boolean and `gameTime` must be a string; other names remain raw readings under that sensor client. There is no sensor peripheral driver included yet.
