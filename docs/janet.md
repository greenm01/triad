# Janet Scripting in the Triad Ecosystem

Triad supports Janet in two roles: external Janet clients over IPC, and an
embedded manifest runtime for in-process window placement policy. This document
specifies the current embedded surface, the sandbox shape, and how future hooks
and layout extensions fit alongside it.

Janet is a small, embeddable Lisp with a clean C API, built-in event loop,
green threads, and a data-oriented character that fits Triad's model naturally.
Triad vendors a pinned Janet `janet.c` / `janet.h` pair under `vendor/janet`
and compiles it through a thin wrapper. The vendored interpreter is marked
`linguist-vendored` so the upstream C source does not dominate GitHub language
statistics.

---

## Two Distinct Roles

Janet operates in two separate modes in this ecosystem. They are independent
and coexist.

### 1. Embedded runtime (inside Triad)

A Janet interpreter hosted inside the Triad process. Scripts receive the
`ShellSnapshot` as a native Janet struct, issue placement commands through the
same `Model.update(msg)` reducer boundary as IPC and keybinds, and pay no
socket or JSON round-trip cost.

This is the primary integration. It currently covers placement manifests; event
hooks and custom layout functions remain future phases.

### 2. External client scripts (zero Triad changes required)

Any Janet program can also connect to Triad's Unix socket and control window
behavior through the existing JSON IPC protocol. No embedding required, works
today. This is the same pattern Hyprland users apply with `hyprctl` and its
event socket — a process subscribes to the event stream, reacts to events, and
sends commands back.

```
River compositor
├── Triad              (layout + window policy daemon, Janet embedded)
├── your.janet         (optional external: subscribes to event-stream)
├── Quickshell         (QML shell, reads Triad/Niri IPC independently)
└── any riverctl script
```

The rest of this document focuses on the embedded runtime. For the external
socket protocol see `docs/ipc.md`.

---

## Why Janet

| Property | Janet | Lua | Python | Wasm |
|---|---|---|---|---|
| Embed size | < 1 MB | ~250 KB | impractical | varies |
| Single-file embed | Yes (`janet.c`) | Yes | No | No |
| Explicit sandbox | Yes (build env from scratch) | Partial | No | Partial |
| Built-in event loop | Yes | No | No | No |
| Green threads / fibers | Yes | Coroutines | No | No |
| C FFI | Yes (abstract types) | Yes | No | Indirect |
| Immutable value types | Yes (struct, tuple) | No | No | N/A |

Lua is the most common embedded scripting choice in compositors. Janet is
smaller in scope, has a stricter sandboxing story (you construct the entire
environment from scratch — nothing is available unless you put it there), and
its immutable structs and tuples map naturally onto Triad's `ShellSnapshot`
model where data flows one way through the reducer.

---

## What Embedded Janet Can Do

### Placement manifests

When a window opens, Triad checks for a Janet manifest file matching the
`app-id`. The manifest receives the current snapshot and the new window's
metadata, evaluates placement logic, and emits `Msg` values that re-enter the
reducer.

```janet
# ~/.config/triad/manifests/firefox.janet
(let [tag (triad/find-tag-by-name "web")]
  (if tag
    (triad/move-to-tag (tag :tag-id))
    (triad/move-to-tag (triad/active-tag-id))))
```

This is the executable successor to ICCCM/EWMH placement hints. KDL window
rules handle the static, unconditional cases well. A manifest handles
conditionality KDL cannot express: open next to an existing terminal if one is
present on this tag, otherwise claim a new tag; check how many windows already
share a tag before deciding whether to float; use a different layout when the
main IDE window is already open.

### Event hooks (future)

Long-running hooks that react to compositor events in real time:

```janet
(triad/on :window-opened
  (fn [ev]
    (when (= (ev :app-id) "pavucontrol")
      (triad/toggle-floating))))

(triad/on :tag-changed
  (fn [ev]
    (when (= (ev :tag-name) "game")
      (triad/set-layout "monocle"))))
```

### Custom layout functions (future)

Pure Janet functions that receive column and window geometry data and return
placement instructions, slotting into the layout projection pipeline alongside
the built-in Nim layouts without recompiling Triad.

---

## What Embedded Janet Cannot Do

- **Render application windows.** Triad does not render client content; River
  does. Janet cannot open Wayland surfaces or draw into client windows.
- **Mutate the model directly.** All Janet output goes through `Model.update(msg)`.
  The model is never passed by reference to Janet — only the immutable snapshot.
- **Access the host filesystem, network, or OS.** `os/*`, `net/*`, file I/O,
  and `ffi` are not loaded into the sandbox environment.
- **Block the main loop.** Manifests run synchronously in the manage phase.
  Long-running work goes in a Janet fiber; the main fiber yields back
  immediately.
- **Replace Quickshell.** Janet has no Qt/QML bindings. Shell UI — bars,
  panels, notifications — remains Quickshell's domain.

---

## Architecture

### Data flow

```
Wayland event / IPC command
        │
        ▼
  Model.update(msg)              ← reducer boundary
        │
   [manage phase — WlManageStart]
        │
        ├─ WlWindowCreated? ──► janet/manifest.evalManifest(appId, snap)
        │                              │
        │                         seq[Msg] ──► Model.update(msg)  (each)
        │
        ├─ any event? ─────────► janet/runtime.dispatchHooks(event, snap)
        │                              │
        │                         seq[Msg] ──► Model.update(msg)  (each)
        │
        └─ [render phase continues unchanged]
```

Janet never receives a `var Model` reference. It receives a `ShellSnapshot`
(already computed for the IPC broadcast path) converted to a Janet struct.
Output is a `seq[Msg]` that re-enters the existing reducer. The DOD boundary
is preserved: snapshot is input data, Janet is a transformation, Msg values
are output data.

### Integration point in `app.nim`

The manage-phase message processing loop in `src/daemon/app.nim` already
handles `WlManageStart` and processes the message queue. Janet evaluation slots
in at the `WlWindowCreated` case, before layout projection:

```nim
# processQueuedMessages — WlWindowCreated branch (sketch)
if msg.kind == MsgKind.WlWindowCreated:
  let snap = daemon.readModelSnapshot()
  let janetMsgs = daemon.janetRuntime.evalManifest(msg.appId, snap)
  for jmsg in janetMsgs:
    daemon.enqueue(jmsg)
```

Hook dispatch runs after every event that has registered listeners:

```nim
# after syncRuntimeUpdate returns effects
let snap = daemon.readModelSnapshot()
let hookMsgs = daemon.janetRuntime.dispatchHooks(msg.kind, snap)
for jmsg in hookMsgs:
  daemon.enqueue(jmsg)
```

### Snapshot conversion

`ShellSnapshot` maps cleanly to a Janet struct (immutable key-value table):

```
ShellSnapshot  →  janet struct
  activeTag        :active-tag
  workspaces       :workspaces  (tuple of structs)
  windows          :windows     (tuple of structs)
  outputs          :outputs     (tuple of structs)
  overviewActive   :overview-active
  ...
```

Janet structs are immutable by construction — the sandbox guarantee that Janet
never mutates model data is enforced by the type, not by convention.

### Module layout

```
src/
  janet/
    binding.nim       ← compiles vendored janet.c and the C API wrapper
    runtime.nim       ← JanetRuntime lifecycle, sandboxed eval, manifest cache
    snapshot_api.nim  ← registers triad/snapshot and shorthand query functions
    command_api.nim   ← registers triad/move-to-tag etc., writes to Msg queue
    hooks.nim         ← future triad/on registration, fiber-per-hook dispatch
```

`src/janet/binding.nim` and the adjacent C wrapper are the only Triad-owned
files that touch Janet's C API. All other modules build on it through Nim
types. This keeps the C surface minimal and auditable.

---

## Sandbox Design

Manifests are untrusted code from third-party application packages. The
sandbox is enforced structurally, not by policy documentation.

### Environment construction

The embedded environment removes host-facing APIs and exposes only the Triad
snapshot helpers and command functions. The vendored Janet build is compiled
with dynamic modules, FFI, network, and process support disabled.

Exposed namespaces:

```
triad/snapshot            read-only ShellSnapshot struct
triad/current-window      opening window struct | nil
triad/active-tag-id       shorthand query → uint32
triad/find-tag-by-name    shorthand query → struct | nil
triad/windows-on-tag      shorthand query → tuple of structs
triad/window-by-id        shorthand query → struct | nil
triad/move-to-tag         emit CmdMoveToTag Msg
triad/move-to-workspace   emit CmdMoveToWorkspaceIndex Msg
triad/toggle-floating     emit CmdToggleFloating Msg
triad/move-window-to-tag  emit targeted CmdMoveWindowToTag Msg
triad/move-window-to-workspace emit targeted CmdMoveWindowToWorkspaceIndex Msg
triad/set-window-floating emit targeted CmdSetWindowFloatingById Msg
triad/set-layout-for-workspace emit targeted CmdSetLayout Msg
triad/focus-window        emit CmdFocusWindowById Msg
triad/set-layout          emit CmdSetLayout Msg
triad/focus-tag           emit CmdFocusTag Msg
triad/spawn               emit CmdSpawn Msg
triad/on                  future event hook registration
```

Explicitly absent: host filesystem, network, process, FFI, dynamic native
module loading, and direct model or Wayland handles.

### Fuel limit

Triad stores a configured `fuel-limit` for the embedded runtime. The first
manifest implementation also blocks obvious loop forms before evaluation so a
manifest cannot stall the manage path.

```kdl
janet {
  enabled #true
  manifest-dir "~/.config/triad/manifests"
  system-manifest-dir "/usr/share/triad/manifests"
  fuel-limit 500000
}
```

### Output is data

Every `triad/*` command function appends to an internal `seq[Msg]` owned by
the `JanetRuntime`. Nothing is applied during Janet execution. After `eval`
returns, `collectMsgs()` drains that queue into the daemon's message queue.
Janet cannot observe the model change as a result of its own output — it
receives only the snapshot that existed when evaluation began.

Targeted window commands take the compositor-facing window id exposed in
`triad/current-window` or `triad/snapshot :windows`. This lets manifests place
or float a newly opened window without relying on the currently focused window.
The optional final boolean on `triad/move-window-to-tag` and
`triad/move-window-to-workspace` controls whether Triad follows focus to the
moved window.

---

## Manifest Discovery and Caching

Triad looks for manifests in order:

1. `{manifest-dir}/{app-id}.janet` (config-specified directory)
2. `{system-manifest-dir}/{app-id}.janet` (system-installed)

Manifest source is read on first match and cached with the file modification
time. Editing a manifest takes effect on the next matching window open, no
Triad restart required.

If no manifest exists for an `app-id`, evaluation is skipped with zero
overhead — a simple table lookup against the cache.

---

## Comparison to Hyprland Plugins

Hyprland offers a C++ plugin API that loads `.so` files into the compositor
process. Plugins hook into internal rendering, input dispatch, and Wayland
protocol handlers.

| | Hyprland plugins | Triad embedded Janet | External Janet client |
|---|---|---|---|
| In-process | Yes | Yes | No |
| Compiled binary | Yes (C++) | No (script) | No (script) |
| Access to internals | Full (compositor) | Snapshot + Msg only | Snapshot via JSON |
| Can affect rendering | Yes | No | No |
| Security boundary | None | Sandboxed env + fuel limit | OS process isolation |
| Breaks on WM update | Often (ABI) | On snapshot schema change only | On IPC schema change only |
| Effort to write | High | Low | Low |

Triad's narrower surface is intentional. Placement policy does not need
compositor rendering internals. Sandboxed manifests that express policy against
a stable snapshot are more maintainable and more secure than compiled plugins
that reach into compositor state.

---

## Parallel River Clients

Independent of the embedded runtime, any number of external processes can run
alongside Triad against River directly. River is designed for this.

```
River compositor
├── Triad              (window policy, layouts, IPC daemon, Janet embedded)
├── janet-daemon.janet (external: talks to Triad IPC over Unix socket)
├── custom-layout      (speaks river-layout-v3 directly — no Triad involvement)
├── Quickshell         (QML shell, Niri/Triad IPC)
└── waybar             (status bar, riverctl)
```

A custom layout daemon speaking `river-layout-v3` coexists peacefully with
Triad. An external Janet script using the IPC socket coexists with the embedded
Janet runtime. River's architecture enables this; Triad's IPC is designed to
support it.

---

## Relationship to `docs/the_triad.md`

`docs/the_triad.md` establishes that KDL rules handle defaults and scripts
handle the long tail. This document specifies what that scripting surface looks
like in practice:

- **KDL window rules** — static, unconditional placement. Fast lookup, no
  conditionality. Defined in `config.kdl`.
- **Embedded Janet manifests** — conditional placement at window-open time.
  Receives the live snapshot. Emits `Msg` values through the reducer.
- **Embedded Janet hooks** — persistent event-driven logic. Runs in a fiber
  per hook, yields back to the main loop immediately.
- **External Janet (or any language) via IPC** — out-of-process scripts.
  Socket latency, full OS isolation. Suitable for long-running automations.
- **Parallel `river-layout-v3` clients** — custom layout generators that
  speak the River protocol directly, independent of Triad.

The five levels compose. All can run simultaneously without conflict.

---

## Implementation Phases

### Phase 1 — Embedded manifest runtime

- Vendored Janet source, wrapper, runtime lifecycle, snapshot conversion,
  command emission, manifest lookup/cache, KDL config, and daemon integration.
- Covered by `nimble testJanet`.

### Phase 2 — Hardening

- Replace the first loop guard with a true Janet VM fuel/interruption mechanism
  when the C API integration is ready.
- Expand sandbox tests for every host-facing symbol Triad promises not to
  expose.

### Phase 3 — Event hooks

- Add `src/janet/hooks.nim`: `triad/on` registration, per-hook fiber dispatch,
  hook drain after each `syncRuntimeUpdate` call.
- Support hook events: `:window-opened`, `:window-closed`,
  `:window-focus-changed`, `:tag-changed`, `:layout-changed`.

### Phase 4 — Custom layouts (speculative)

- Define a layout contract: a Janet function that receives column/window
  geometry data and returns a sequence of placement instructions.
- Slot into the layout projection pipeline in `src/layouts/`.
- Benchmark at realistic window counts (20+ windows, 60 FPS) before
  committing. If pure-Janet layout is too slow, consider a compiled-image
  cache or a hybrid where Janet computes ratios and Nim applies them.
