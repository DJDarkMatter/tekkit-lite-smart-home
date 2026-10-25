# SmartHome OS for Tekkit Lite

A central ComputerCraft computer owns apps, saved state and output decisions. Remote computers are reusable IO or monitor bridges. See [the target design](DOCUMENTATION/DESIGN.md), [the review](DOCUMENTATION/REVIEW.md) and [the app/protocol reference](DOCUMENTATION/API.md).

This repair targets Lua 5.1 and the channel-based modem API available in ComputerCraft 1.5. It uses serialized **strings** on the wire and no CC:Tweaked-only APIs. It has been tested with simulated ComputerCraft APIs, **not inside the Minecraft server**.

## First working IO connection

Use two computers with wireless modems, initially near each other in loaded chunks in the same dimension. The OS modem can be on any side. The IO modem can also be on any side, but that side cannot be used for a cable.

### Install

**If you received this repair as a ZIP:** the changes have not necessarily been published to GitHub yet. Extract it and upload the contents of its inner `tekkit-lite-smart-home` folder to the repository root (GitHub: **Add file → Upload files**, then commit). Once the repaired files are on `main`, the download commands below work. Alternatively copy the files directly to each ComputerCraft computer, preserving paths:

| Role | Required files |
| --- | --- |
| All roles | `Lib/network.lua`, `Lib/storage.lua` |
| Central OS | Also `main_os.lua`, `Lib/server.lua`, `Apps/switchboard.lua` |
| IO client | Also `Clients/io_client.lua`, `Lib/io.lua` |
| Monitor client | Also `Clients/monitor_client.lua`, `Lib/monitor.lua` |

On each computer, run `cd /`, then download `install.lua`. If your CraftOS has no downloader, enter `lua` and paste this as one line:

```lua
local h=assert(http.get("https://raw.githubusercontent.com/DJDarkMatter/tekkit-lite-smart-home/main/install.lua"),"Download failed"); local f=assert(fs.open("install","w")); f.write(h.readAll()); f.close(); h.close()
```

Exit the Lua prompt with `exit()`. On the central computer:

```text
install server
main_os.lua
```

On the IO computer:

```text
install io
Clients/io_client.lua
```

For files published on another branch, replace `main` in the bootstrap URL with that branch and pass it as the installer's second argument: `install server BRANCH_OR_COMMIT` or `install io BRANCH_OR_COMMIT`. A local branch or patch must be published before it can be downloaded this way.

If HTTP/HTTPS is disabled or blocked by the public server, copy the role's files manually into the same paths. The installer lists all dependencies at its top. Do not copy only the entry point: the `Lib` files are required. Update both ends to the same revision.

The installer downloads and checks all Lua files before replacing programs, keeps `.pre_update` backups, and preserves `Configs` and `startup`.

### Confirm connection and test a wire

The IO computer prints its ID, e.g. `io_11`, then `Connected to OS computer 10`. The OS prints `io connected: io_11`. Either computer may start first; retries happen every five seconds.

On the **OS console**, substitute the IO computer's actual client ID:

```text
clients
inputs io_11
map test io_11 left white
set test on
outputs
set test off
```

Connect a bundled cable on the IO computer's **left** side, and observe its white channel. `outputs` should show `confirmed` after the IO client acknowledges each state. `inputs io_11` displays bundled masks and ordinary redstone, including zero/false readings. For ordinary redstone, use `map lamp io_11 front digital`.

The OS owns the complete output mask of every mapped cable side: unmapped colours on that side are OFF. Do not drive the same side with a second program. Mapping a logical output to a new side/client clears its previous wires and retains its desired state. A logical output is independent of the IO computer's identity and physical wire address.

For autorun, put `shell.run("main_os.lua")` in the OS computer's `startup` file, or `shell.run("Clients/io_client.lua")` in the IO computer's. Add the line to an existing startup deliberately; the installer does not replace it.

### Connection settings

The first run creates `Configs/network.txt`:

```lua
{
  networkId = "home",
  channel = 45231
}
```

Choose your own `networkId` and use the same value and channel on all your computers. On clients, add `serverId = 10` with your central computer's actual ID if you want to pin them to it. Restart the program after editing settings.

IO settings are in `Configs/io.txt`: `clientId`, enabled `sides`, `announceInterval`, `timeout`, and `safeOff`. By default the client clears outputs at startup and switches them OFF if it loses the OS for 15 seconds. When it reconnects, the OS restores the saved desired state. `safeOff = false` keeps the last commanded outputs during a network timeout instead; startup still clears them. An enabled side is a side the client may read and drive.

For a replacement computer, give it the old logical `clientId` to reuse mappings. Shut down the old computer first; a duplicate active ID is rejected until the old connection times out.

This is a public-server wireless protocol, **not authentication or encryption**. Network names, IDs and channels prevent accidental cross-talk, but another player can sniff/spoof them. There is no password transmitted as a pretend security feature. Use server protections where necessary.

If no acknowledgement arrives, check: matching program versions and network settings; the pinned server ID; modem presence; wireless range/dimension; both chunks loaded. The programs keep retrying and accept late modem attachment.

## Monitors

Install a third computer with a wireless modem and one or more attached monitors:

```text
install monitor
Clients/monitor_client.lua
```

Use a published ref argument if installing from another branch, as above. For touch input, use advanced monitors. All attached monitors become independent desktops, e.g. `monitor_13:top` and `monitor_13:left`. A replacement monitor on the same side keeps that desktop's identity. Adjust `textScale` in `Configs/monitor.txt` if needed.

Touch `[+]` on taskbar row 2, then `switchboard`. Its output rows toggle the OS's logical outputs. There is no wiring or app logic on the display computer. The example displays as many outputs as fit its content height; it is a connection test/basic switchboard, not a replacement for every old switchboard screen.

Touch a window's taskbar entry to minimize it; touch again to restore it. Touch its title's `X` to close it. The OS resolves touches from coordinates and stacking order. Clients do not invent window IDs. From the OS console you can also use:

```text
apps
open switchboard monitor_13:top
resize 1 24 8
move 1 1 3
close 1
save
quit
```

Window sizes in these commands include the frame. `move` and `resize` clamp to the monitor and app limits. The taskbar reserves the first two rows. Window layouts and app state restore after restarting; window IDs are recovered without overwriting restored windows.

## What is implemented

- Acknowledged, addressed OS/IO connections; retries, reconnects and client timeouts.
- Full desired output snapshots, acknowledgements and periodic resynchronization; late/duplicate commands are idempotent.
- Bundled/ordinary output mappings and input reporting; the central OS never accesses redstone.
- Multiple generic monitor desktops; rendering, touch routing, launcher, focus, minimize/restore/close, console positioning/resizing, and app size checks.
- Single-file apps, shared persistent app state and background ticks independent of windows or network activity.
- Checkpoints in `Configs/os_state.txt` with temporary/backup recovery. Logical output changes and mappings save before hardware commands; app background state checkpoints every 30 seconds by default.
- A basic switchboard, role installer and Lua 5.1 integration tests.

## Still to build from the design

Coffee automation, production measurement/averages, real sensor peripheral adapters, richer switchboard screens, and touch-based window move/resize controls are not implemented. The old coffee/switchboard programs remain archived under `OLDFILES`; the OS does not load them. Character resolution is measured from the monitor API; physical block dimensions are not guessed from that resolution.

Periodic checkpoints can lose app changes since the last checkpoint on a crash. Important app transitions can call `api.save()`. Network confirmations report that the IO computer applied an output, not that an external machine physically responded. Wireless disconnection/unloaded chunks cannot be repaired by software running on another unloaded computer.

## Tests

From the repository root:

```sh
lua5.1 tests/run.lua
```

The tests run the actual entry points as separate computers with independent disks and event queues, using string-only virtual modems. They cover startup order, two clients sharing a reply channel, dropped commands/handshakes/acks/frames, stale commands, OS and client restarts, safe-off, modem relocation, remapping, zero inputs, monitor touches/layout restoration, corrupt/interrupted checkpoints, failed saves, malformed packets, sensor isolation and background timing. GitHub Actions runs the suite and syntax checks.
