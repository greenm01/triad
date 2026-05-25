+++
title = "Triad Window Manager"
insert_anchor_links = "right"
template = "index.html"
+++

# Triad Window Manager

Triad is a window manager for River. River handles the compositor; Triad handles placement, policy, IPC, and scripting.

Windows use stable tags—membership bits, not containers. A window can belong to multiple tags at once. Rules dictate placement. Janet scripts handle the rest. If you restart Triad, your windows stay exactly where you left them.

## Layouts

Triad includes scroller, BSP, i3, Notion-style frame-trees, master-stack, and more. Every workspace runs its own layout independently. You can change one without disturbing the others.

If you need something custom, you can write it in Janet. See the [layout reference](@/configuration/layouts.md).

## Janet, Not Lua

Most window managers embed Lua or nothing. Triad embeds [Janet](https://janet-lang.org/), a small Lisp with a strict sandbox and no dependencies beyond a single C file. Scripts run inside the process. They see the session as a native table and drive placement without socket round-trips or JSON parsing.

A script can check how many windows share a tag or if your IDE is already open, then act on it. KDL rules can't do that. Janet can. See [Janet Scripting](@/usage/janet-scripting.md).

## Flat, Not Hierarchical

Window managers usually treat workspaces as containers. To move a window, you lift it out of one and drop it in another. Triad's model is flat. A window is a record; its relationship to tags is a bitmask. We re-derive the layout projection from that bitmask on every render pass.

This keeps conditional logic cheap. A placement decision is a handful of index lookups, not a tree traversal.

## Built on River

River separates the Wayland compositor from the window manager. River owns rendering and input; Triad owns policy.

This has a practical benefit: a Triad crash doesn't kill your session. River keeps your windows visible while Triad restarts and resumes. Frame synchronization happens in the compositor, so layout changes are atomic—no torn frames or gaps while windows resize.

Isaac Freund explains the design in [Separating the Wayland Compositor and Window Manager](https://isaacfreund.com/blog/river-window-management/).

## Built to Last

*   **Crash-resilient.** Layout errors never reach the compositor. Long-running scripts survive reloads without losing context.
*   **Fast.** Written in Nim. No object graph to walk.
*   **Shell-ready.** Triad-native IPC is our primary integration, but we also provide a compatibility socket for Waybar, Noctalia, and Waylee.
