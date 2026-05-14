# Janet Scripting in the Triad Ecosystem

Janet is embedded in Triad from the start. This document specifies the
architecture, integration points, sandbox design, and module layout for the
embedded runtime, and describes how external Janet clients fit alongside it.

Janet is a small, embeddable Lisp with a clean C API, built-in event loop,
green threads, and a data-oriented character that fits Triad's model naturally.
It embeds via a single `janet.c` / `janet.h` pair — integrated into the Nim
build via `{.compile.}` pragmas and a thin C wrapper, with no additional
runtime dependency.

---

## Two Distinct Roles

Janet operates in two separate modes in this ecosystem. They are independent
and coexist.

### 1. Embedded runtime (inside Triad)

A Janet interpreter hosted inside the Triad process. Scripts receive the
`ShellSnapshot` as a native Janet struct, issue placement commands through the
same `Model.update(msg)` reducer boundary as IPC and keybinds, and pay no
socket or JSON round-trip cost.

This is the primary integration. It covers placement manifests, event hooks,
and eventually custom layout functions.

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
    (triad/move-to-tag (tag :id))
    (triad/move-to-tag (triad/active-tag-id))))
```

This is the executable successor to ICCCM/EWMH placement hints. KDL window
rules handle the static, unconditional cases well. A manifest handles
conditionality KDL cannot express: open next to an existing terminal if one is
present on this tag, otherwise claim a new tag; check how many windows already
share a tag before deciding whether to float; use a different layout when the
main IDE window is already open.

### Event hooks

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

### Custom layout functions (phase 3)

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
    binding.nim       ← {.compile: "janet.c".} pragma, raw C API types/procs
    runtime.nim       ← JanetRuntime lifecycle, sandboxed eval, hook registry
    snapshot_api.nim  ← registers triad/snapshot and shorthand query functions
    command_api.nim   ← registers triad/move-to-tag etc., writes to Msg queue
    manifest.nim      ← discovery (~/.config/triad/manifests/<app-id>.janet),
                         caching (fsnotify invalidation), evaluation entry point
    hooks.nim         ← triad/on registration, fiber-per-hook dispatch
```

`src/janet/binding.nim` is the only file that touches C. All other modules
build on it through Nim types. This keeps the C surface minimal and auditable.

---

## Sandbox Design

Manifests are untrusted code from third-party application packages. The
sandbox is enforced structurally, not by policy documentation.

### Environment construction

Janet's `janet_core_env()` is **not used**. The embedded environment is built
from scratch using `janet_table(0)` and populated with only what is explicitly
registered. No standard library module is reachable unless deliberately added.

Exposed namespaces:

```
triad/snapshot            read-only ShellSnapshot struct
triad/active-tag-id       shorthand query → uint32
triad/find-tag-by-name    shorthand query → struct | nil
triad/windows-on-tag      shorthand query → tuple of structs
triad/window-by-id        shorthand query → struct | nil
triad/move-to-tag         emit CmdMoveToTag Msg
triad/move-to-workspace   emit CmdMoveToWorkspaceIndex Msg
triad/toggle-floating     emit CmdToggleFloating Msg
triad/set-layout          emit CmdSetLayout Msg
triad/focus-tag           emit CmdFocusTag Msg
triad/spawn               emit CmdSpawn Msg
triad/on                  register an event hook fiber
```

Explicitly absent: `os/*`, `net/*`, `io/*`, `ffi`, `native/load`, `require`,
`math/*` beyond basic arithmetic, `string/format` with `%p` (pointer leak).

### Fuel limit

Janet supports an instruction-count fuel limit (`janet_vm_set_fuel`). Every
manifest evaluation and hook dispatch runs with a configured ceiling (default:
500 000 instructions). Scripts that loop infinitely are killed before they
stall the manage phase. The limit is configurable in `config.kdl`:

```kdl
janet {
  fuel-limit 500000
  manifest-dir "~/.config/triad/manifests"
}
```

### Output is data

Every `triad/*` command function appends to an internal `seq[Msg]` owned by
the `JanetRuntime`. Nothing is applied during Janet execution. After `eval`
returns, `collectMsgs()` drains that queue into the daemon's message queue.
Janet cannot observe the model change as a result of its own output — it
receives only the snapshot that existed when evaluation began.

---

## Manifest Discovery and Caching

Triad looks for manifests in order:

1. `{manifest-dir}/{app-id}.janet` (config-specified directory)
2. `~/.config/triad/manifests/{app-id}.janet` (default)
3. `/usr/share/triad/manifests/{app-id}.janet` (system-installed)

Manifests are compiled to Janet images on first load and cached. `fsnotify`
(already in the dependency tree) watches the manifest directory and invalidates
the cache on file change. Hot-reload: editing a manifest takes effect on the
next matching window open, no Triad restart required.

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

### Phase 1 — Embedded runtime skeleton

- Add `src/janet/binding.nim` with `{.compile: "janet.c".}` and the raw C API
  surface.
- Add `src/janet/runtime.nim` with `JanetRuntime` init/deinit and sandboxed
  `eval(src: string): seq[Msg]`.
- Add `src/janet/snapshot_api.nim` and `src/janet/command_api.nim` to
  register the `triad/*` C functions.
- Write a unit test: feed a minimal Janet string, assert it produces the
  expected `Msg` values.
- Wire `JanetRuntime` into `TriadDaemon` state (constructed in `daemon/state.nim`,
  passed to `processQueuedMessages`).

### Phase 2 — Manifest loading

- Add `src/janet/manifest.nim`: discovery logic, `fsnotify`-backed cache,
  per-`app-id` compiled image storage.
- Hook `WlWindowCreated` in `processQueuedMessages` to call
  `evalManifest(appId, snap)`.
- Add the `janet { }` config block to the KDL parser (`src/config/parser.nim`)
  for `fuel-limit` and `manifest-dir`.
- Add `nimble task testJanet` and a test suite covering manifest eval, cache
  invalidation, and fuel-limit enforcement.

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
