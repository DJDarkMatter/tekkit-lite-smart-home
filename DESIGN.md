# SmartHome OS Design

Minecraft 1.4.7, ComputerCraft, Tekkit Lite, server environment (crashes, restarts require full state persistence).

## 1. Overall Architecture

One central OS computer holds all logic, state, and coordinates the system.

All IO and sensors happen through dedicated client computers connected via wireless modems. Clients are modular - any monitor can be swapped with another, any sensor unit can be swapped with another.

Communication between OS and all clients uses ComputerCraft's wireless network.

Apps are stored as files on the main OS computer's storage. The OS loads app files and manages their execution and display.

## 2. Client Types

### Monitor Clients
Each monitor client computer:
- Drives one or more physical monitors attached to it
- Classified by monitor dimensions (e.g. "5x4", "10x7") - allows same client code for identical monitor sizes
- Communicates resolution and capabilities to the OS
- Receives drawing instructions from the OS and renders to monitor
- Forwards touch events to OS with coordinates
- No IO or automation logic - pure display/input forwarding

### IO Clients
Physical IO computers placed throughout the base. Each:
- Has bundled cables on multiple sides for redstone input and output
- Receives high-level commands from the OS (e.g. "set pump1 to ON") and translates to physical redstone
- Sends raw sensor readings and state changes back to the OS
- No business logic, no persistent state beyond reconnection

Multiple IO clients exist: central ones for main base IO, plus optional distributed ones at specific locations.

### Sensor Clients
Computers with sensor cards (or other sensor peripherals) that read specific data:
- Player online detection
- Game time from time-exposing blocks
- Other environmental sensors

Sensor clients forward raw readings to the OS, which converts them to system state (e.g. "playerOnline" boolean, "gameTime" string).

## 3. Component Roles

### Central OS Computer
- Holds all game logic (timers, automation, production calculations)
- Owns all persistent state
- Coordinates all IO decisions by sending commands to IO clients
- Manages desktop and window layouts for all monitor clients
- Loads and runs apps, handles background logic and rendering
- Can optionally have its own monitor showing system status (connected clients, active IO, sensor values)
- Does NOT directly read/write redstone - commands go through IO clients
- Does NOT directly read sensors - data comes via sensor clients

## 4. Monitor Desktops and Window System

Every monitor has its own desktop managed centrally by the OS:
- OS stores each monitor's dimensions and type
- OS tracks which windows are open on each monitor and positions/sizes

### Window Properties
- Resizable within app-defined min/max limits
- Closed via X button in window frame (sends event to OS)
- Positioned by OS based on available space

### App Size Categories
- **Small apps**: Designed for small monitors. Can run on any monitor.
- **Large apps**: Require more screen space. Can only open on monitors that fit them.

### Size Calculation
The OS calculates window sizing:
1. Converts monitor block size to character capacity (based on text scale)
2. Checks if app's min size fits within monitor dimensions
3. Calculates max window size from app's declared maxWidth/maxHeight
4. Determines if multi-window layout is possible (windows side by side or stacked)
5. Rejects apps that don't fit

### Monitor Classification
Monitors are classified by their actual block dimensions (e.g. "5x4", "10x7"). This allows multiple clients with identical monitor sizes to use the same client code.

### Window Layout
- OS decides window positioning
- Windows can be arranged side-by-side or stacked on large monitors
- Small monitors typically show one app at a time

## 5. Taskbar

Every monitor desktop has a taskbar:
- Shows list of open windows on that monitor
- Touch to switch focus, minimize, or close windows
- Always visible, reserves screen space (bottom or top)
- Displays game time from sensor data

## 6. Apps

Apps are single files stored on the OS computer.

The OS installer includes no apps and enables none by default. Apps are user-specific, installed separately and explicitly enabled in `Configs/os.txt`. An app file's presence or an older saved registry entry must not cause it to run automatically. App implementation is deferred until the OS/IO connection works reliably.

### App Structure
Each app has two parts:

**UI Layer**:
- Knows how to draw itself within window bounds
- Handles touch/click events (buttons, toggles, sliders)

**Logic/Background Layer**:
- Runs on OS, not monitor client
- Maintains app state and sends IO commands through OS

### Background Services
Some apps run continuously even when no window is open (e.g. coffee automation runs regardless of UI visibility).

### Adding Apps
1. Create/edit one app file in Apps folder on OS
2. Explicitly enable its name in `enabledApps` in `Configs/os.txt` so it appears on compatible desktops
3. No changes to core OS or other apps

## 7. Coffee Automation

Long-duration timer that runs when player is online (detected via sensor client input).

**Features**:
- Long countdown timer that pauses while the player is offline, preserving remaining time like the original standalone timer
- Harvest output activated for fixed duration when timer completes (via IO client)
- "Force harvest now" - manually trigger harvest and reset timer
- "Pause timer" - suspend countdown without losing remaining time
- Total harvest counter (never reset)
- Trip counter (resettable by user)

**User clarification, 2026-10-27 — requirements only; no app implementation yet**:
- When enabled, the coffee logic runs continuously on the central OS, even if its window is minimized, closed, covered, or absent from every monitor. Window visibility is never the timer's clock or on/off control.
- Preserve the original `OLDFILES/CofeeTimer/timer.lua` restart protection: persist the remaining countdown, whether harvest is active, and remaining harvest duration, and restore them instead of reinitializing them at boot. Preserve future counters and explicit pause state as well.
- The original checkpoints every second and at phase transitions. Future implementation must provide comparable progress protection, rather than relying only on the OS's default 30-second periodic checkpoint. Restarting the OS/client, unloading a chunk, or restarting the Minecraft server must not reset a saved countdown or restart a saved harvest from its full duration.
- The original pauses while no player is detected; this supersedes the earlier generated text saying to reset on player logout. Offline time and window visibility must not silently reset progress. No elapsed-time catch-up during computer downtime is implied.

**UI Modes**:
- Minimal view (small monitors): remaining time, harvest active/inactive
- Detailed view (large windows): all stats plus control buttons

## 8. Switchboard

All switchboard IO goes through IO clients:
- OS maintains logical output names (e.g. "pump1", "massfab_feed")
- Maps logical names to physical IO client + side + color
- Apps send "set output X to ON/OFF" to OS
- OS routes command to appropriate IO client

This abstraction allows adding IO clients or moving cables without changing apps.

## 9. Mass Fabricators and Solar

Sensors wired to IO clients feed data to OS:
- UU-matter production rates per mass fabricator
- Solar generation per panel
- Long-term and short-term production averages

OS maintains averages, apps display the data. Manual reset via UI after upgrades.

## 10. Persistence

System handles crashes/restarts gracefully:
- OS periodically saves state to Configs/os_state.txt
- Saved: window layouts, app registry, production totals, switch states, coffee timers/counters
- On restart, OS restores state and recalculates all outputs
- All clients reconnect and re-announce themselves

## 11. Future Expansion

New subsystems (ME integration, new farms, etc.) added by:
1. Adding new sensor client or IO client
2. Creating a new app file that uses OS IO/state APIs
3. Registering the app

No core changes needed for new features.
## Implementation Status

This document is the target architecture, not a claim that every feature is implemented. The repaired runtime, installation steps, current limitations and remaining apps are described in [README.md](../README.md). The original-code review and explicit design decisions are in [REVIEW.md](REVIEW.md); app hooks and wire messages are in [API.md](API.md).
