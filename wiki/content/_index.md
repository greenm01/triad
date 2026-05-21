+++
title = "Triad Window Manager"
insert_anchor_links = "right"
template = "index.html"
+++

# Triad Window Manager

Triad is a programmable Wayland window manager for River. River owns the
compositor; Triad owns placement, policy, IPC, and scripting.

Windows carry stable tags. Tags are membership bits, not containers — a window
can belong to more than one at once. Rules decide placement declaratively. Janet
scripts handle everything rules cannot. Restart Triad and your windows stay put.

## Layouts

Triad ships scroller, BSP, i3, frame-tree (Notion), master-stack, grid, monocle,
deck, spiral, dwindle, tgmix, and more. Every workspace picks its own layout
independently. Switch one without touching the others.

Can't find what you need? Write it in Janet. See the full [layout reference](@/configuration/layouts.md).

## Janet, Not Lua

Most window managers embed Lua or nothing. Triad embeds [Janet](https://janet-lang.org/) — a small Lisp
with a strict sandbox, an immutable data model, and no dependencies beyond a
single C file. Scripts run inside the process, see the session as a native
table, and drive placement without a socket round-trip or JSON parse.

A script can ask how many windows share a tag, what layout is running, and
whether your IDE is already open — then act on the answer. KDL rules cannot do
that. Janet can. See [Janet Scripting](@/usage/janet-scripting.md).

## Flat, Not Hierarchical

Most window managers treat workspaces as containers: a window lives inside one,
moving it means lifting it out and dropping it in another, and scripting against
it means walking an object graph. Triad's model is flat. A window is a record.
Its relationship to tags is a bitmask. The layout projection re-derives
everything from that on every render pass.

Conditional logic stays cheap. A placement decision is a handful of index
lookups against a flat snapshot, not a tree traversal.

## Built on River

River separates the Wayland compositor from the window manager at the protocol
level. River owns rendering, input routing, and the Wayland session. Triad runs
as a separate process — owning placement and policy, nothing more.

The consequence is practical: a Triad crash or reload doesn't drop your
session. River keeps your windows visible. Triad restarts, reconnects, and
resumes. Frame synchronization happens at the compositor level, so layout
changes are atomic — no torn frames, no gaps while windows resize into place.
Input latency stays compositor-level regardless of what Triad does.

Isaac Freund explains the design in [Separating the Wayland Compositor and
Window Manager](https://isaacfreund.com/blog/river-window-management/).

## Built to Last

**Crash-resilient.** Layout errors don't reach the compositor. Stable tag and
window IDs let long-running scripts survive reloads without losing context.
See [IPC & Commands](@/usage/ipc-commands.md).

**Fast and lean.** Written in Nim. No object graph to walk on every render pass.

**Shell-ready.** Niri-compatible IPC means Waybar, Quickshell, Noctalia, and
DankMaterialShell work without modification.
