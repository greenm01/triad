# The Triad

Tags, rules, and IPC together let external programs control windows precisely and in real time.

## Tags
Tags are stable labels. A window can carry more than one at once. Each tag keeps its own layout state.

## Rules
Rules match an app or title and set initial placement, floating state, and layout hints. They remain declarative and reloadable. Rules are a lookup table: they cover the known, static cases well.

## IPC
Two sockets expose the model. One carries Triad's native snapshot. The other projects a Niri-compatible view. External code receives events and sends commands that become messages to the reducer.

## How They Work Together
1. An event arrives.
2. The model updates and applies rules.
3. A snapshot is broadcast.
4. External logic reacts and issues the next command.

## Why This Matters
- External code becomes a first-class policy layer.
- One window can exist in multiple contexts simultaneously.
- Behavior can evolve without restarting the window manager.

## Implications
KDL rules handle defaults. Scripts handle the long tail. The key difference is conditionality: a script can ask how many windows are already on a tag, what else is open, or what time it is before deciding where to place a new window. KDL cannot. The IPC event stream, stable IDs, and clean command surface make Triad a natural host for external scripts in any language that can open a Unix socket and speak JSON.

## Minimal Example
```json
{"triad":{"version":1,"request":"event-stream","events":["state"]}}
```
On `WindowOpened` for `firefox`, the script can immediately send:
```json
{"triad":{"version":1,"request":"move-to-tag","tag":3}}
```
or inspect current tag state and choose the layout conditionally.

## Why Triad Is Different

Most window managers treat workspaces as containers. A window lives inside one workspace, and moving it means lifting it out of one container and dropping it into another. The script author thinks in terms of object graphs: workspace owns windows, windows have parents, layouts are properties of containers. Hyprland and Niri both work this way. The model is intuitive for simple cases and becomes awkward fast when you want a window to participate in more than one context at once.
Triad's model is flat. A window is a record in a table. Its relationship to tags is a bitmask, not a pointer to a parent. Tags are not containers; they are membership bits, and the layout projection re-derives everything from those bits on every render pass. There is no object graph to traverse, no hierarchy to navigate, and no ownership to transfer. When a script queries state, it receives a flat snapshot of that data. When it issues a command, the reducer applies it as a direct transformation on the model.

This matters because conditionality becomes cheap. A script asking "how many windows share tag 3, and what layout is it running, and is my IDE already open somewhere" is just a handful of index lookups against a flat snapshot. The same question against a workspace-as-container model requires traversing nested structures and reasoning about ownership. The Triad version maps naturally onto a simple decision table, a short script, or eventually a classifier trained on the same feature vector the snapshot already provides.

The stability of IDs reinforces this. Tag IDs and window IDs are Triad-owned logical identifiers that never change for the lifetime of the entity. A script written today will read the same snapshot shape tomorrow regardless of what the compositor or shell layer is doing. That stability is what makes long-running daemons and persistent scripting surfaces practical.

## Practical Application: Embedded Scripting with Janet

The logical extension of the IPC scripting model is to bring the script inside the process entirely. Janet is a small, embeddable Lisp with a clean C API and a data-oriented character that fits Triad's model naturally. Rather than a script opening a socket and speaking JSON, a Janet script receives the snapshot as a native table and calls placement functions directly. The socket overhead and JSON round-trip disappear.

The more interesting possibility is app-specific placement policy. A user keeps
a small Janet script in Triad's `script-dir`; when matching events fire, Triad
evaluates that script against the current snapshot. The script can encode
knowledge generic rules do not have: which dialogs should float, which
secondary windows belong on a dedicated tag, whether the main canvas works
better in scroller or monocle. A script can express conditionality that KDL
cannot — open next to an existing terminal if one is present, otherwise claim a
new tag.

This is a modern, executable successor to the static ICCCM and EWMH hints that X11 apps used to self-describe their placement preferences. Instead of rigid binary properties, a script is live policy that reads context and responds to it.

The security boundary is straightforward. A script runs in a sandboxed Janet environment that exposes only the snapshot as input and a constrained set of placement commands as output. No file I/O, no network access, no system calls. Janet's environment is controllable enough to enforce this: you expose exactly the functions you want the script to call and nothing else. The script cannot corrupt internal state because it never touches the model directly — it only sees a snapshot and issues commands through the same reducer boundary that every other external actor uses.
