+++
title = "Janet Scripting"
weight = 20
+++

# Janet Scripting

Triad embeds Janet so you can write scripts that react to window events and decide placement dynamically.

Place scripts in `~/.config/triad/janet/`. They run inside the manager process with full access to the current session state.

For complete reference and advanced examples, consult the Janet guide in the source tree.

## Quick Start

Enable Janet in your config:

```kdl
janet {
  enabled #true
  automation-dir "~/.config/triad/janet"
}
```

Then add a script like `focus-new-window.janet` that runs on window open events.

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

### Scripts

Triad loads every `*.janet` automation file from `automation-dir` (default
`~/.config/triad/automation`) in lexicographic order. Each file is loaded into
a retained sandbox environment, registers event handlers with `triad/on`, and
is reloaded only when the source file changes. Handler state survives across
events until reload.

Top-level script code runs at load/reload time, not on every event. Put
event-time commands inside `triad/on` handlers; commands emitted while loading a
script are discarded.

Handlers can suspend until a later event with `triad/wait-event`. The current
handler yields back to Triad immediately and resumes with the matching event map:

```janet
(triad/on :window-opened
  (fn [opened]
    (let [ready (triad/wait-event :window-ready)]
      (when (= (opened :window-id) (ready :window-id))
        (triad/command "focus-window" (ready :window-id))))))
```

A single script file can handle any combination of events for a concern —
including window placement on open and any follow-up reactions:

```janet
# ~/.config/triad/automation/firefox.janet
(triad/on :window-ready
  (fn [ev]
    (let [window (ev :window)]
      (when (= (window :app-id) "firefox")
        (let [tag (triad/find-tag-by-name "web")]
          (when tag
            (triad/command "move-window-to-tag" (window :id) (tag :tag-id) true)))))))

(triad/on :window-closed
  (fn [ev]
    (let [window (ev :window)]
      (when (= (window :app-id) "firefox")
        # react to firefox closing
        ))))
```

This replaces the old manifest + hooks split. All per-app placement logic,
reactions, and cross-event state live in one file.

#### The `:window-ready` event

`:window-ready` is the canonical event for initial window placement. It fires
exactly once per window, the first time both conditions hold:

1. The window has a non-placeholder `app-id` (i.e. the app has reported its
   identity to the compositor).
2. The window has been admitted to the model.

This ensures placement scripts always see the real `app-id`, even for apps that
report it asynchronously after the window is created (Telegram, some Electron
apps). Triad tracks which windows have already received `:window-ready` and
never re-fires it.

#### The `:window-opened` event

`:window-opened` fires once at window creation, before the window is fully
admitted. The `app-id` may still be empty at this point. Use it for very
early reactions that do not depend on app identity.

#### Available events

| Event | When it fires | Key fields |
|---|---|---|
| `:window-ready` | First moment window has app-id + is admitted | `:window-id`, `:window` |
| `:window-opened` | Window created (app-id may be empty) | `:window-id`, `:window` |
| `:window-admitted` | Window fully admitted to model | `:window-id`, `:window` |
| `:window-closed` | Window destroyed | `:window-id`, `:window` |
| `:window-title-changed` | Title updated | `:window-id`, `:old-title`, `:new-title`, `:old-window`, `:new-window` |
| `:window-app-id-changed` | App-id updated | `:window-id`, `:old-app-id`, `:new-app-id`, `:old-window`, `:new-window` |
| `:window-focus-changed` | Focus moved | `:old-window-id`, `:new-window-id`, `:old-window`, `:new-window` |
| `:output-added` | Output appears in shell snapshot | `:output-id`, `:output`, `:old-output` (`nil`) |
| `:output-changed` | Output fields visible to scripts changed | `:output-id`, `:output`, `:old-output` |
| `:output-removed` | Output disappears from shell snapshot | `:output-id`, `:output` (`nil`), `:old-output` |
| `:tag-changed` | Active tag changed | `:old-tag-id`, `:new-tag-id` |
| `:layout-changed` | Active layout changed | `:old-layout`, `:new-layout`, `:tag-id` |
| `:session-locked` | Session locked | — |
| `:session-unlocked` | Session unlocked | — |
| `:overview-opened` / `:overview-closed` | Overview visibility changed | `:active`, `:selected-window-id` |
| `:recent-windows-opened` / `:recent-windows-closed` | Recent-windows switcher visibility changed | `:active`, `:selected-window-id`, `:scope`, `:filter`, `:app-id-filter` |
| `:hotkey-overlay-opened` / `:hotkey-overlay-closed` | Hotkey overlay visibility changed | `:active` |
| `:exit-session-confirm-opened` / `:exit-session-confirm-closed` | Exit-session confirmation visibility changed | `:active` |
| `:layout-switch-toast-opened` / `:layout-switch-toast-closed` | Layout-switch toast visibility changed | `:active`, `:layout` |

Output structs include `:id`, `:name`, `:x`, `:y`, `:w`, `:h`,
`:refresh-rate`, and `:primary`.

#### Recursion behaviour

Commands emitted by scripts carry a `JanetHook` origin marker. The dispatcher
does not re-evaluate scripts for messages with that origin, preventing infinite
cascades. If a `:window-ready` handler emits `move-window-to-tag`, the
resulting tag change will not re-trigger the `:tag-changed` handler in other
scripts.

#### Example: tag-based reactions

```janet
(triad/on :window-opened
  (fn [ev]
    (when (= (ev :app-id) "pavucontrol")
      (triad/command "toggle-floating"))))

(triad/on :tag-changed
  (fn [ev]
    (when (= (ev :new-tag-id) 5)
      (triad/command "layout-monocle"))))
```

See `examples/janet/` for full per-app examples (gimp, telegram, vesktop).

This is the executable successor to ICCCM/EWMH placement hints. KDL window
rules handle the static, unconditional cases well. Scripts handle
conditionality KDL cannot express: open next to an existing terminal if one is
present on this tag, otherwise claim a new tag; check how many windows already
share a tag before deciding whether to float; use a different layout when the
main IDE window is already open.

### Custom layout functions

Pure Janet functions that receive column and window geometry data and return
placement instructions, slotting into the layout projection pipeline alongside
the built-in Nim layouts without recompiling Triad.

A script may register a pure geometry function:

```janet
(triad/def-layout :halves
  (fn [ctx]
    [{:window-id 10 :x 0 :y 0 :w 960 :h 1080}
     {:window-id 11 :x 960 :y 0 :w 960 :h 1080}]))
```

Triad validates that the result contains exactly one positive-sized rectangle
for every tiled projected window. Layout functions cannot emit
`triad/command`; doing so fails evaluation and falls back.

A user layout may optionally register movement behavior for commands such as
`move-window-up` and `move-window-down`. Core and bundled layouts mirror
directional focus and swap with the selected target without using Janet
movement hooks:

```janet
(triad/def-layout-movement :halves
  (fn [ctx direction]
    (if (= direction :up)
      {:op :move-order :delta -1}
      {:op :noop})))
```

The direction argument is one of `:left`, `:right`, `:up`, or `:down`. V1 hooks
support only `{:op :noop}` and `{:op :move-order :delta -1|1}`. Movement hooks
override the core mirrored-navigation movement for that layout. They share the
layout purity rule: they cannot emit `triad/command`.

Frame-aware layouts use a native `frame-tree` fallback:

```kdl
janet {
  enabled #true
  layout-dir "~/.config/triad/layouts"
  layout "janet-frame-tree" fallback="frame-tree"
}
```

When native frame data is active, `ctx` includes top-level `:frames`, mirrors
the same data at `((ctx :tag) :frames)`, and sets `:substrate :frames`. Leaf
frames include `:windows`, `:active-window`, `:focused`, `:rect-set`, and
`:rect`. A layout may either keep returning active tab window instructions or
return frame instructions:

```janet
{:frame-id 7 :x 0 :y 0 :w 960 :h 1080}
```

Frame instructions target leaf frames only. Triad maps each frame rectangle to
that frame's active visible tab; empty frames validate but do not render a
window. A single result must not mix `:window-id` and `:frame-id`.

Native `i3` layouts expose immutable i3/Sway-style split nodes:

```kdl
janet {
  enabled #true
  layout-dir "~/.config/triad/layouts"
  layout "janet-split-tree" fallback="i3"
}
```

When split-tree data is active, `ctx` includes top-level `:split-nodes`,
mirrors the same data at `((ctx :tag) :split-nodes)`, and sets
`:substrate :split-tree`. Leaf split nodes include `:window`, `:focused`,
`:rect-set`, and `:rect`; container nodes include `:children`, `:mode`,
`:last-split-mode`, and `:weight`. A layout may return `:split-node-id`
geometry for leaf nodes. Triad maps each split leaf rectangle to that node's
tiled window. Janet cannot mutate the split tree; split h/v, i3
stacking/tabbed modes, insertion, movement, resize, flattening, and restore
remain native reducer behavior.

---

## What Embedded Janet Cannot Do

- **Render application windows.** Triad does not render client content; River
  does. Janet cannot open Wayland surfaces or draw into client windows.
- **Mutate the model directly.** All Janet output goes through `Model.update(msg)`.
  The model is never passed by reference to Janet — only the immutable snapshot.
- **Access the host filesystem, network, or OS.** `os/*`, `net/*`, file I/O,
  and `ffi` are not loaded into the sandbox environment.
- **Block the main loop.** Scripts run synchronously in the event loop.
  `triad/wait-event` yields back to Triad, but there is no sleep, timer, thread,
  or Janet event-loop integration yet.
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
        ├─ any dispatchable event? ──► janet_script_runtime.collectJanetScriptMessages(event, snap)
        ├─ UI hook state changed? ───► janet_script_runtime.collectJanetUiScriptMessages(before, after, snap)
        │                                     │
        │                               seq[Msg] ──► Model.update(msg)  (each)
        │
        └─ [render phase continues unchanged]
```

Janet never receives a `var Model` reference. It receives a `ShellSnapshot`
(already computed for the IPC broadcast path) converted to a Janet struct.
Output is a `seq[Msg]` that re-enters the existing reducer. The DOD boundary
is preserved: snapshot is input data, Janet is a transformation, Msg values
are output data.

### Integration point in `app.nim`

The manage-phase message processing loop evaluates scripts after the model
update for dispatchable compositor/runtime events and for model-owned UI state
transitions:

```nim
if beforeSnapshot.isSome:
  let afterSnapshot = daemon.readModelSnapshot()
  nextQueuedMessages.add(
    daemon.collectJanetScriptMessages(msg, beforeSnapshot.get(), afterSnapshot)
  )
if beforeUiState != afterUiState:
  nextQueuedMessages.add(
    daemon.collectJanetUiScriptMessages(beforeUiState, afterUiState, afterSnapshot)
  )
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
    binding.nim            ← compiles vendored janet.c and the C API wrapper
    runtime.nim            ← JanetRuntime lifecycle, sandboxed eval, source caches
    snapshot_api.nim       ← registers triad/snapshot and shorthand query functions
    command_api.nim        ← translates triad/command actions into Msg values
  daemon/
    janet_script_runtime.nim ← event shaping, triad/on dispatch, behavior logs
```

`src/janet/binding.nim` and the adjacent C wrapper are the only Triad-owned
files that touch Janet's C API. All other modules build on it through Nim
types. This keeps the C surface minimal and auditable.

---

## Sandbox Design

The sandbox is enforced structurally, not by policy documentation.

### Environment construction

The embedded environment removes host-facing APIs and exposes only the Triad
snapshot helpers and `triad/command`. The vendored Janet build is compiled
with dynamic modules, FFI, network, and process support disabled.

Exposed namespaces:

```
triad/snapshot            read-only ShellSnapshot struct
triad/current-window      event window struct | nil
triad/current-event       current event struct | nil
triad/active-tag-id       shorthand query → uint32
triad/find-tag-by-name    shorthand query → struct | nil
triad/workspace-by-tag    shorthand query → struct | nil
triad/workspace-by-index  shorthand query → struct | nil
triad/current-workspace   shorthand query → struct | nil
triad/output-by-name      shorthand query → struct | nil
triad/windows-on-tag      shorthand query → tuple of structs
triad/windows-by-app-id   shorthand query → tuple of structs
triad/window-by-id        shorthand query → struct | nil
triad/workspace-empty?    shorthand query → bool
triad/first-empty-workspace shorthand query → struct | nil
triad/command             emit any registered user command by name + args
triad/spawn               emit spawn command with argv-style args
triad/spawn-sh            emit spawn command as sh -lc
triad/volume-*            wpctl volume and mute helpers
triad/media-*             playerctl playback helpers
triad/screenshot-*        Triad screenshot command helpers
triad/record-*            wf-recorder recipe helpers
triad/on                  persistent event handler registration
triad/wait-event          yield until a future event keyword
```

`triad/workspace-empty?` and `triad/first-empty-workspace` take an
`ignored-window-id` argument. Pass `0` when no window should be ignored, or
the current window id while deciding where to place that same window.

Explicitly absent: host filesystem, network, process, FFI, dynamic native
module loading, and direct model or Wayland handles.

### Fuel limit

Triad stores a configured `fuel-limit` for user script evaluation. Finite loops
are allowed when they complete within the budget; scripts that exceed the
budget fail without applying emitted commands, so a script cannot stall the
event path indefinitely.

```kdl
janet {
  enabled #true
  automation-dir "~/.config/triad/automation"
  layout-dir "~/.config/triad/layouts"
  fuel-limit 500000
}
```

### Output is data

Every `triad/*` command function appends to an internal `seq[Msg]` owned by
the `JanetRuntime`. Nothing is applied during Janet execution. After `eval`
returns, `collectMsgs()` drains that queue into the daemon's message queue.
Janet cannot observe the model change as a result of its own output — it
receives only the snapshot that existed when evaluation began.

`triad/command` is the complete command surface. It accepts the same canonical
command names and aliases used by `triad msg` and config bindings:

```janet
(triad/command "focus-workspace" 8)
(triad/command "layout-grid")
(triad/command "maximize-window-to-edges")
(triad/command "move-window-to-tag" (triad/current-window :id) 8 true)
(triad/command "set-window-maximized" (triad/current-window :id) true)
(triad/command "recent-window-next" "--scope" "output" "--filter" "app-id")
(triad/command "spawn" "foot" "--working-directory" "/tmp")
```

Arguments are argv-style values, not shell strings. Use one Janet argument per
command argument; names that contain spaces can be passed as one string.

Targeted window commands take the compositor-facing window id exposed in
`triad/current-window` or `triad/snapshot :windows`. This lets scripts place
or change state on a specific window without relying on the currently focused
window. The optional final boolean on `move-window-to-tag` and
`move-window-to-workspace` controls whether Triad follows focus to the moved
window.

### Media and capture helpers

The Janet prelude adds small convenience helpers for common media and capture
workflows. These helpers still emit ordinary Triad commands; they do not grant
Janet direct process, filesystem, network, PipeWire, or MPRIS access.

Audio helpers use `wpctl`:

```janet
(triad/volume-up)        # wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
(triad/volume-up "10%")  # wpctl set-volume @DEFAULT_AUDIO_SINK@ 10%+
(triad/volume-down)
(triad/volume-toggle-mute)
(triad/mic-toggle-mute)
```

Playback helpers use `playerctl`:

```janet
(triad/media-play-pause)
(triad/media-next)
(triad/media-prev)
(triad/media-stop)
(triad/media-seek "+5")
```

Capture helpers reuse Triad's configured screenshot commands or launch
`wf-recorder`:

```janet
(triad/screenshot "--clipboard-only")
(triad/screenshot-screen "--path" "/tmp/screen.png")
(triad/screenshot-window "--show-pointer")
(triad/record-screen "/tmp/triad-screen.mp4")
(triad/record-region "/tmp/triad-region.mp4")
(triad/record-stop)
```

Portal-based screen sharing remains app-initiated through the XDG ScreenCast
portal. Triad can launch helper commands or apps, but it does not own a native
portal session API.

---

## Script Discovery and Caching

Triad loads all automation `*.janet` files from `automation-dir` in
lexicographic order. The default is `~/.config/triad/automation`. Change it in
`config.kdl`:

```kdl
janet {
  automation-dir "~/.config/triad/automation"
}
```

Declared custom layouts load from `layout-dir/<name>.janet`; `script-dir`
remains accepted as a deprecated alias for `automation-dir`.

Script source is read on first load and cached with the file modification time.
Editing a script takes effect on the next matching event — no Triad restart
required. A config reload also clears the cache.

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
compositor rendering internals. Sandboxed scripts that express policy against
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
- **Embedded Janet scripts** — conditional placement and event-driven logic.
  All `*.janet` files in `automation-dir` load into retained sandbox
  environments. Scripts register event handlers with `triad/on` and emit `Msg`
  values through the reducer during handler dispatch.
- **External Janet (or any language) via IPC** — out-of-process scripts.
  Socket latency, full OS isolation. Suitable for long-running automations.
- **Parallel `river-layout-v3` clients** — custom layout generators that
  speak the River protocol directly, independent of Triad.

The four levels compose. All can run simultaneously without conflict.

---

## Implementation Phases

### Phase 1 — Embedded script runtime

- Vendored Janet source, wrapper, runtime lifecycle, snapshot conversion,
  command emission, script lookup/cache, KDL config, and daemon integration.
- Persistent event dispatch with `triad/on`, including `:window-ready` for
  placement.
- Covered by `nimble testJanet`.

### Phase 2 — Hardening

- Keep expanding sandbox tests for host-facing symbols Triad promises not to
  expose.
- Validate the fuel budget against realistic user scripts as the embedded
  surface grows.

### Phase 3 — Custom layouts (speculative)

- Define a layout contract: a Janet function that receives column/window
  geometry data and returns a sequence of placement instructions.
- Slot into the layout projection pipeline in `src/layouts/`.
- Benchmark at realistic window counts (20+ windows, 60 FPS) before
  committing. If pure-Janet layout is too slow, consider a compiled-image
  cache or a hybrid where Janet computes ratios and Nim applies them.
