+++
title = "Usage"
sort_by = "weight"
insert_anchor_links = "right"
render = true
+++

# Usage

Triad responds to key bindings, `triad msg` commands over a Unix socket, and
embedded Janet scripts. All three routes reach the same reducer — they're
interchangeable.

---

### [IPC & Commands](@/usage/ipc-commands.md)

The complete `triad msg` reference: navigation, layout switching, window
manipulation, system commands, and the event stream.

### [Janet Scripting](@/usage/janet-scripting.md)

Write scripts that react to window events and drive placement from inside the
process, without a socket round-trip or JSON parse.
