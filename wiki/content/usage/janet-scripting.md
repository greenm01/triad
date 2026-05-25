+++
title = "Janet Scripting"
weight = 20
+++

# Janet: Scripting the Manager

Triad embeds Janet. You write scripts; we react to events. Decide window placement on the fly. 

Put your scripts in `~/.config/triad/janet/`. They run inside the manager. They see everything Triad sees.

## Quick Start

Enable Janet in your `config.kdl`:

```kdl
janet {
  enabled #true
  automation-dir "~/.config/triad/janet"
}
```

Add a script, like `focus-new-window.janet`, to handle your events.

## Why Janet?

Lua is common, but Janet fits Triad better. It’s tiny. Its sandbox is a wall. It uses immutable values, just like our state snapshots. Data flows one way.

## What It Does

### Automation
Triad loads every `*.janet` file from your `automation-dir`. It puts them in a sandbox. Register your handlers with `triad/on`. These handlers live until you change the file.

Write your logic in handlers. Top-level code runs once at load time. If you try to command the manager while loading, we ignore it.

Handlers can wait. `triad/wait-event` yields to Triad and resumes when the event hits. You can coordinate complex moves in a single file.

### Key Events
- `:window-ready`: The big one. Fires when a window is admitted and identified. Use this for placement.
- `:window-opened`: Early warning. The window exists, but identity might be missing.
- `:window-closed`: The window is gone.
- `:tag-changed`: You switched workspaces.

### Custom Layouts
Janet can define your screen’s shape. Write a pure function that takes window data and returns coordinates. It slots in next to our native layouts.

Layout functions must be pure. They do math; they don't issue commands. We validate every result.

## The Sandbox

The environment is lean. We give you `triad/snapshot`, `triad/command`, and queries like `triad/find-tag-by-name`. We remove the host. No filesystem. No network. No OS calls.

We use fuel limits. If your script loops forever, we kill it.

## Architecture

Data flows one way. An event hits the model. We take a snapshot. We pass it to Janet. Janet returns messages. We feed those back into the model. The boundary stays intact.
