# The Triad: Tags, Rules, and IPC

Tags, rules, and IPC allow external programs to control windows in real time.

## Tags
Tags are stable labels. A window can carry more than one. Each tag maintains its own layout state independently.

## Rules
Rules match an app or title to set placement, floating state, and layout hints. They are declarative and hot-reloadable. Rules cover the known, static cases.

## IPC
Two sockets expose the model. One carries Triad’s native snapshot; the other projects a Niri-compatible view. External code receives events and sends commands that the reducer processes as messages.

## Interaction
1.  An event arrives.
2.  The model updates and applies rules.
3.  Triad broadcasts a snapshot.
4.  External logic reacts and issues the next command.

## Why This Works
KDL rules handle the defaults. Scripts handle the rest. Unlike KDL, a script can ask questions before acting: How many windows are on this tag? Is my IDE already open? What time is it?

The IPC event stream and stable IDs make Triad a natural host for scripts in any language that speaks JSON over a Unix socket.

## Flat, Not Hierarchical
Most window managers treat workspaces as containers. To move a window, you lift it out of one container and drop it into another. This is intuitive until you want a window to exist in multiple contexts at once.

Triad’s model is flat. A window is a record in a table. Its relationship to tags is a bitmask, not a pointer to a parent. Tags are not containers; they are membership bits. We re-derive the layout projection from these bits on every render pass.

This makes conditionality cheap. Querying the state is a handful of index lookups, not a tree traversal.

## Embedded Scripting with Janet
Janet brings the scripting model inside the process. It is a small Lisp with a data-oriented character that fits Triad perfectly. A Janet script receives the snapshot as a native table and calls placement functions directly, eliminating socket overhead and JSON parsing.

This allows for app-specific placement policy. A Janet script can encode knowledge that rules cannot: which dialogs should float, which secondary windows belong on a dedicated tag, or whether a specific app works better in scroller or monocle.

The security is simple. Scripts run in a sandboxed Janet environment with no file I/O or network access. They see a snapshot and issue commands through the same reducer boundary used by every other actor. They cannot corrupt internal state.
