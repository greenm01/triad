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

### [Tags](@/usage/tags.md)

What tags are, how they differ from container-based workspaces, stable IDs,
and why the flat model makes scripting cheap.

### [IPC & Commands](@/usage/ipc-commands.md)

The complete `triad msg` reference: navigation, layout switching, window
manipulation, system commands, and the event stream.

### [Overview](@/usage/overview.md)

Overview mode, spatial arrow-key navigation, workspace jumping with PgUp/PgDn,
and how each layout renders in the thumbnail strip.

### [Scratchpads](@/usage/scratchpads.md)

Hidden window pools you toggle as floating overlays. Default and named
scratchpad pools.

### [Janet Scripting](@/usage/janet-scripting.md)

Write scripts that react to window events and drive placement from inside the
process, without a socket round-trip or JSON parse.

### [Troubleshooting](@/usage/troubleshooting.md)

Session logs, config validation, IPC checks, display manager issues, and
enabling diagnostic mode.
