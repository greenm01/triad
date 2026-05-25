# Janet: The Triad Engine

Janet plays two roles in Triad. It works outside as an IPC client and inside as an embedded script engine. It handles window placement and events without breaking a sweat.

Janet is small. It’s a Lisp with a clean API and an event loop. It fits Triad because it loves data as much as we do. We vendor the source. We compile it in. It’s always there.

## Two Paths

You can use Janet in two ways. They are independent. They coexist.

### Inside: The Embedded Runtime
We host a Janet interpreter inside the Triad process. Scripts get a snapshot of the world. They issue commands through the same gates as IPC. No sockets. No JSON. Zero latency. This is where your custom layouts and event handlers live.

### Outside: The External Client
Any Janet program can talk to Triad over its Unix socket. It works today. No changes required. It’s the same pattern you’d use with `hyprctl`. Subscribe to events, react, and send commands back.

## Why Janet?

Lua is common, but Janet is better for us. It’s smaller. Its sandbox is tighter—you build the world from scratch. Its immutable values map perfectly to Triad’s snapshots. Data flows one way.

## What It Does

### Automation
Triad loads every `*.janet` file from your `automation-dir`. It puts them in a sandbox. Scripts register handlers with `triad/on`. These handlers survive until you change the file.

Top-level code runs once at load time. Put your logic in handlers. If you emit a command while loading, we drop it.

Handlers can wait. `triad/wait-event` yields to the manager and resumes when the event hits. You can coordinate complex moves across multiple events in a single file.

### Key Events
- `:window-ready`: The big one. Fires when a window has its identity and is admitted. Use this for placement.
- `:window-opened`: Fires early. The window exists, but it might not have an ID yet.
- `:window-closed`: The window is gone.
- `:tag-changed`: You switched workspaces.
- `:layout-changed`: The shape of the world shifted.

### No Infinite Loops
Commands from scripts carry a marker. We don't re-trigger scripts for their own actions. If you move a window, we won't bark at you for moving it.

### Custom Layouts
Janet can define the shape of your screen. You write a pure function that takes window data and returns coordinates. It slots in next to our native layouts.

Layout functions must be pure. They can't emit commands. They just do math. We validate the result—every window needs a rectangle.

## What It Can't Do

- **Render Windows.** Triad doesn't draw. River does. Janet can't touch pixels.
- **Mutate State Directly.** All changes go through `Model.update`. Janet sees an immutable snapshot, never the live model.
- **Touch the Host.** No filesystem. No network. No OS calls. The sandbox is a wall.
- **Block the Loop.** Scripts run in the main event loop. Don't write slow code. We have a fuel limit; if you exceed it, your script dies.

## Architecture

Data flows one way. A Wayland event hits the model. We take a snapshot. We pass it to Janet. Janet returns a list of messages. We feed those messages back into the model. The DOD boundary stays intact.

We use `binding.nim` to talk to Janet's C API. It's the only place we touch it. The rest of Triad stays clean.

## The Sandbox

The environment is a desert. We give you what you need: `triad/snapshot`, `triad/command`, and shorthand queries like `triad/find-tag-by-name`. We explicitly remove `os/*`, `net/*`, and `ffi`. 

Fuel limits keep you honest. If your script loops forever, we kill it.

## Comparison

Hyprland uses C++ plugins. They are fast but fragile. One update and your ABI breaks. Triad uses Janet. It’s sandboxed. It’s stable. It’s easier to write.
