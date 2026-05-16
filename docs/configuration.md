# Configuration

Triad is configured with KDL at `$XDG_CONFIG_HOME/triad/config.kdl`, or
`~/.config/triad/config.kdl` when `XDG_CONFIG_HOME` is unset. If no user config
exists, Triad creates one from the embedded fallback config.

Set `TRIAD_CONFIG=/path/to/config.kdl` or start Triad with
`triad --config /path/to/config.kdl` to use a different root config. The short
form `triad -c /path/to/config.kdl` is equivalent.

Validate config without starting the daemon with:

```sh
triad validate-config
triad validate-config --config ~/.config/triad/config.kdl
```

The config is hot-reloaded. `config-reload` reloads the KDL document without
restarting Triad. Shell startup, binding rebuilds, and River side effects happen
after the config has parsed successfully.

Config files can include other KDL files in place. Relative include paths resolve
against the file that contains the include. `~/` expands to the user's home
directory.

```kdl
include "bindings.kdl"
include optional=#true "~/.config/triad/local.kdl"
```

Included files are also watched for hot reload after a successful startup or
config reload. Recursive includes and required missing includes are rejected.

## Naming Policy

Triad config names should read like user intent, not internal implementation.
Use the Niri style as the naming baseline:

- Prefer lowercase kebab-case: `center-focused-column`, `spawn-at-startup`.
- Prefer sections with plain fields over packed strings:
  `master { split-ratio 0.55 }`.
- Prefer complete words over abbreviations: `split-ratio`, not `mfact`.
- Prefer positive names: `open-floating`, not `isfloating`.
- Prefer action verbs for commands: `maximize-column`, `move-window-left`.
- Use KDL flags for simple booleans when omission means disabled:
  `allow-exit-session`.
- Keep config names stable once shipped.

Mango is a feature reference, especially for layouts, scratchpads, tags,
gestures, and pointer workflows. Mango names should not be copied directly when
they are abbreviated, packed, or state-shaped. Translate the capability into
clear Triad KDL and command names.

Examples:

| Prefer | Avoid |
| :--- | :--- |
| `overview { outer-gap 64 }` | `overviewgappo=64` |
| `overview { zoom 0.5 }` | `ov_scale=0.5` |
| `layout { smart-gaps #true }` | `smartgaps=1` |
| `master { count 1; split-ratio 0.55 }` | `nmaster=1`, `mfact=0.55` |
| `window-rule { open-floating #true }` | `isfloating:1` |
| `maximize-window-to-edges` | `togglemaximizescreen` |

## Current Config Surface

The supported KDL nodes are:

- `include`: in-place config composition with optional includes.
- `layout`: gaps, column/window proportions, master settings, borders,
  scroller centering, animation settings, smart gaps, and layout cycle.
- `workspaces`: default workspace floor and fallback default layout.
- `output`: startup focus and workspace affinity by output identity.
- `workspace-rules`: workspace names and explicit default layouts.
- `window-rule`: app/title matching, default workspace/workspaces, floating behavior,
  all-workspace sticky behavior, managed overlay behavior, focus behavior,
  unmanaged-global behavior,
  parented-dialog viewport jump behavior, terminal swallowing policy, size-hint
  policy, shortcut inhibition, presentation mode,
  border/focus-ring/clip policy, and forced layout.
- `bindings`: keyboard bindings, pointer button, wheel, and gesture bindings,
  HJKL/arrow mirroring,
  binding mode, layout override, inhibition policy, and hotkey overlay titles.
- `switch-events`: dormant hardware switch command bindings for lid and tablet
  mode events.
- `config-notification`: optional reload success, failure, and rollback
  notification commands.
- `environment`, `quickshell`, `janet`, `terminal`, `screen-lock`,
  `window-menu-command`, `spawn-at-startup`.
- `scratchpad`, `overview` gaps, zoom, tab mode, `floating`, `screenshot`,
  `input`, `cursor`.
- Top-level flags and settings: `presentation-mode`, `allow-exit-session`,
  `protocol-surfaces`, `hotkey-overlay`, and `config-notification`.

For command details, see `docs/ipc.md`. For the Mango/River/Triad comparison
matrix, see `docs/comp/config-command-matrix.md`.

When a config option, binding command, IPC command, or window-management
capability changes, update this guide and
`docs/comp/config-command-matrix.md` in the same change. The configuration
guide states Triad's naming policy; the comparison matrix shows how that policy
maps against Mango and River.

## Janet Scripting

The `janet` block configures the embedded Janet manifest runtime. It is enabled
by default; external scripts can still use the IPC socket independently.

```kdl
janet {
  enabled #true
  manifest-dir "~/.config/triad/manifests"
  system-manifest-dir "/usr/share/triad/manifests"
  fuel-limit 500000
  manifest-alias "org.telegram.desktop" "telegram"
}
```

When enabled, Triad evaluates `{manifest-dir}/{app-id}.janet` when a matching
window opens. `manifest-alias` maps an app id to a canonical manifest basename,
so `org.telegram.desktop` can load `telegram.janet` without duplicating files.
Exact app-id manifests are tried before aliases. A manifest receives a read-only
`triad/snapshot` value plus
`triad/current-window` for the opening window, and can emit normal Triad
commands through `triad/command`, which mirrors the command names accepted by
`triad msg` and config bindings. Manifest output re-enters the normal reducer
message path; scripts do not receive direct model or compositor handles. See
`docs/janet.md`.

## Session Environment

`environment` sets literal environment variables for future user-facing
processes that Triad starts:

```kdl
environment {
  GTK_THEME "Adwaita:dark"
  SSH_AUTH_SOCK #null
}
```

- Child node names are environment variable names. Names must start with a
  letter or `_` and may contain letters, digits, and `_`.
- String values are used literally. Triad does not expand `~`, `$VAR`, command
  substitutions, or shell quoting.
- `#null` removes the variable from the spawned process environment.
- Later entries for the same variable win.
- The block applies to future `spawn-at-startup`, `spawn`, `spawn-terminal`,
  `screen-lock`, `window-menu-command`, screenshot helper commands, and the
  configured shell profile process. It does not change Triad's own environment,
  systemd/dbus activation environments, externally started processes, or an
  already-running shell profile after `config-reload`.

## Shell Profiles

`shells` defines named shell or bar profiles. Profile names are user-defined;
Triad only stores the argv-style launch/stop commands and optional Niri
compatibility environment.

```kdl
shells {
  enabled #true
  active "noctalia"
  cycle "noctalia" "dank" "waybar"

  profile "noctalia" {
    launch "qs" "-c" "noctalia-shell"
    stop "qs" "kill" "-c" "noctalia-shell" "--any-display"
    niri-compat #true
  }

  profile "dank" {
    launch "dms" "run" "--session"
    stop "dms" "kill"
    niri-compat #true
  }

  profile "waybar" {
    launch "waybar"
    stop "pkill" "-x" "waybar"
    niri-compat #true
  }
}
```

`switch-shell <name>` stops the active profile before launching the named
profile. `cycle-shell` rotates through `cycle`, falling back to profile order
when `cycle` is empty. Missing launch or stop executables are logged as shell
profile failures. The legacy `quickshell` block is still accepted and is
translated into a single generated shell profile when `shells` is absent.

## Layout

`layout { scroller-proportion-presets <n>... }` sets the ascending proportions
used by `switch-proportion-preset`. Values are clamped to `0.05..1.0`; empty
lists fall back to `0.33 0.5 0.67 1.0`. Triad does not bind
`switch-proportion-preset` by default.

`layout { enable-animations #true; animation-speed 0.15; animation-snap-threshold 0.5 }`
controls viewport camera animation. `animation-speed` is clamped to `0.0..1.0`;
`0.0` snaps immediately. `animation-snap-threshold` is a pixel distance clamped
to `0.01..64.0`; once the camera is within that distance of the target, Triad
snaps to the exact target coordinate.

## Window Rules

`window-rule` entries match windows by app id and/or title regex and apply
launch policy. Multiple `match` children are OR-ed, fields within one `match`
are AND-ed, and any matching `exclude` child skips the rule. Matchers can also
use boolean state properties: `is-focused`, `is-active`,
`is-active-in-column`, `is-floating`, and `at-startup`. All matching rules are
merged in file order: broad app rules can set defaults, and later specific
title or state rules can override individual fields.

```kdl
window-rule {
  match app-id="pinentry"
  open-floating #true
  open-focused #false
  center-floating #true
}

window-rule {
  match app-id="keepassxc"
  dialog-viewport-jump #true
}

window-rule {
  match app-id="gimp"
  exclude title="Private"
  default-workspace 4
  open-maximized #true
  maximize-policy "column"
  tiled-state #true
  respect-size-hints #true
  default-column-width { proportion 0.65 }
  scroller-proportion { proportion 0.70 }
  scroller-single-proportion { proportion 0.80 }
  default-window-height { proportion 0.90 }
  min-width 640
  max-height 1200
}

window-rule {
  match app-id="gimp" title="Toolbox"
  parented-role "tool"
  open-focused #false
  open-on-output "HDMI-A-1"
  default-floating-position x=32 y=48 relative-to="bottom-left"
  floating {
    x-ratio 0.02
    y-ratio 0.08
    width-ratio 0.22
    height-ratio 0.84
  }
}

window-rule {
  match app-id="qemu" is-focused=#true
  keyboard-shortcuts-inhibit #true
}

window-rule {
  match app-id="^st-yazi$"
  open-named-scratchpad "files"
}

window-rule {
  match app-id="^org\\.keepassxc\\.KeePassXC$" at-startup=#true
  default-workspace 2
}

window-rule {
  match app-id="obsidian"
  default-workspaces 2 4
  open-focused #false
}

window-rule {
  match app-id="waybar|quickshell"
  open-on-all-workspaces #true
  open-focused #false
}

window-rule {
  match app-id="cheese|camera"
  open-unmanaged-global #true
  default-floating-position x=24 y=24 relative-to="bottom-right"
}

window-rule {
  match app-id="kitty|Alacritty|foot"
  terminal #true
}

window-rule {
  match app-id="keepassxc"
  allow-swallow #false
}

window-rule {
  match app-id="^steam_app_"
  presentation-mode "async"
  border {
    width 4
    active-color "#7fc8ff"
    inactive-color "#505050"
  }
  focus-ring {
    width 6
    active-color "#ffbf7f"
  }
  clip-to-geometry #true
}
```

- `match` and `exclude`: support `app-id="<regex>"`, `title="<regex>"`,
  `is-focused=#true|#false`, `is-active=#true|#false`,
  `is-active-in-column=#true|#false`, `is-floating=#true|#false`, and
  `at-startup=#true|#false`.
  `is-active` matches the focused window of any workspace the window belongs
  to. `is-active-in-column` uses the last focused tiled window in that column,
  falling back to the first visible tiled window when history is missing or
  stale. Initial opening evaluation treats windows as unfocused, inactive,
  non-floating, and active in column, matching Niri's cycle-avoidance behavior
  for `open-floating`. `at-startup` is true during the first 60 seconds of a
  Triad daemon process, then existing dynamic rule effects are recomputed.
- `open-floating #true|#false`: explicitly opens matching windows floating or
  tiled. Parented dialogs open floating by default unless this rule is set.
- `open-focused #true|#false`: explicitly allows or prevents focusing matching
  windows when they open. Parented dialogs use smart focus by default: they
  focus only when they open on the active workspace.
- `open-fullscreen #true|#false`: opens matching windows fullscreen. This
  forces tiled placement if it conflicts with `open-floating`.
- `open-maximized #true|#false`: opens matching tiled windows as a full-width
  column in scroller layouts. It does not set the client-visible maximized
  state.
- `open-maximized-to-edges #true|#false`: opens matching windows in Triad's
  client-visible edge-maximized state. This forces tiled placement if it
  conflicts with `open-floating`.
- `maximize-policy "edge"|"column"|"ignore"`: controls later maximize actions
  for matching windows. `edge` is the default client-visible maximize behavior.
  `column` maps maximize actions to a full-width scroller column without
  setting client-visible maximize state. `ignore` refuses maximize-on actions;
  unmaximize and toggle-off still clear existing maximize state.
- `respect-size-hints #true|#false`: controls whether matching windows use
  client-provided min, max, and fixed-size hints. The default is `#true`.
  `#false` ignores client hints for effective geometry and disables fixed-size
  auto-floating for that rule, but explicit Triad `min-*` and `max-*` rule
  bounds still apply.
- `center-floating #true|#false`: centers generated floating geometry on the
  active screen after rule/global floating size is resolved. The default is
  `#false`, preserving the normal floating ratios. `default-floating-position`
  takes precedence when both match.
- `parented-role "dialog"|"tool"|"plain"`: controls how a matching parented
  floating window participates in child-window policy. `dialog` is the default:
  it joins the popup tree, adopts the parent workspace unless `default-workspace`
  overrides it, anchors to the parent, and may defer focus while the parent is
  hidden. `tool` adopts the parent workspace but behaves as a persistent normal
  float instead of a transient popup. `plain` treats the window as an ordinary
  float even when it has a parent; it does not adopt the parent workspace,
  anchor to the parent, or join popup focus hiding. `open-floating #false`
  still tiles the window regardless of role.
- `dialog-viewport-jump #true|#false`: when set on a parent app rule, its
  child dialogs may immediately retarget/snap the viewport instead of waiting
  until the parent is visible. The default is `#false`.
- `tiled-state #true|#false`: overrides the client-visible tiled hint sent via
  River `set_tiled`. This does not move the window between Triad tiled and
  floating placement; use `open-floating` for placement.
- `presentation-mode "default"|"vsync"|"async"`: controls output presentation
  mode while the matching window is focused. Focused matching windows win over
  the top-level `presentation-mode`; `default` clears a broader matching rule
  and falls back to the top-level setting or backend default. River exposes
  this as output-level policy, so background matching windows do not change the
  output mode.
- `border { width <px>; active-color "<rgba>"; inactive-color "<rgba>" }`:
  overrides compositor-drawn border policy for matching windows. Fields merge
  independently in rule order and fall back to the top-level `layout.border`
  config. `width` is clamped to `0..64`; `width 0` disables borders for
  matching windows. Colors use the same `#rrggbb` or `#rrggbbaa` syntax as
  global border colors.
- `focus-ring { width <px>; active-color "<rgba>" }`: overrides the rendered
  border only while the matching window is focused or highlighted in overview.
  It uses River's same border primitive, so unfocused rendering keeps the
  normal `border` or top-level `layout.border` policy. To get active-only
  rings, combine `border { width 0 }` with a nonzero `focus-ring` width.
- `clip-to-geometry #true|#false`: forces matching windows to use River clip
  boxes around Triad's rendered geometry. This is a render policy only; it
  does not change placement, sizing, focus, or layout. Explicit `#false`
  clears a broader matching rule but cannot disable safety clipping for
  oversized or offscreen cells.
- `default-workspace <n>`: opens matching windows on a workspace. For parented
  dialogs, this explicit workspace overrides the parent workspace.
- `default-workspaces <n>...`: opens matching windows on multiple workspaces.
  The first valid workspace is the primary target for focus, output placement,
  and shell snapshots; additional workspaces get normal tag placements without
  switching focus or moving the camera. Later matching rules replace the whole
  workspace list. Duplicate workspace numbers are ignored.
- `open-on-all-workspaces #true|#false`: makes matching top-level windows
  sticky across every materialized workspace. Later rules can clear a broader
  sticky rule with `#false`. Parented `dialog` and `tool` windows ignore this
  rule so transient popups stay attached to their parent; use
  `parented-role "plain"` when a parented window should behave like a normal
  sticky window. Sticky-only occupancy does not keep dynamic workspaces alive,
  and moving a sticky window to scratchpad clears sticky state.
- `open-overlay #true|#false`: keeps matching managed windows above normal
  managed windows without making them floating, sticky, scratchpad, or
  unmanaged. Later matching rules can clear a broader overlay rule with
  `#false`. Focused overlay windows preserve the fullscreen or maximized
  presentation of the backing workspace the same way focused floating popups
  do.
- `open-unmanaged-global #true|#false`: opens matching windows as
  unmanaged-like global floats. They are visible on every workspace, render
  above normal managed windows, and are excluded from workspace layout, focus
  traversal, overview previews, and dynamic workspace occupancy. This is
  distinct from sticky, overlay, scratchpad, and layer-shell behavior.
- `open-on-output "<name>"`: opens matching windows on the workspace currently
  visible on the named output. Targets match connector names such as
  `HDMI-A-1`, shell fallback names such as `river-2`, niri-style
  `make model serial` strings with `Unknown` for unavailable serials, and the
  raw Wayland output description when present. When combined with
  `default-workspace` or `default-workspaces`, Triad may move the primary
  target workspace's non-primary output mapping to the named output, but it
  never switches the active workspace just because a window opened. Unknown
  outputs fall back to the normal active-workspace behavior.
- `open-named-scratchpad "<name>"`: opens matching new windows as hidden named
  scratchpads. The window is untagged until `toggle-named-scratchpad <name>` is
  run. Empty names are ignored; live restore takes precedence; config reloads
  do not move existing windows into or out of scratchpads.
- `terminal #true|#false`: marks matching windows as terminal hosts for
  swallowing. Triad does not infer terminal status from desktop metadata in v1.
  A terminal can swallow only a new top-level child whose reported PID descends
  from the terminal PID.
- `allow-swallow #true|#false`: controls whether matching child windows may be
  swallowed by an eligible terminal host. The default is `#true`; use `#false`
  for apps that should always open as normal tiled/floating windows. Missing
  PID data disables swallowing rather than guessing.
- `default-column-width { proportion <n> }`: sets the initial width of a newly
  created tiled column for matching windows. Values are clamped to `0.05..1.0`.
- `scroller-proportion { proportion <n> }`: sets the initial primary-axis size
  of a newly created scroller column and overrides `default-column-width` when
  both match. Horizontal scrollers use width; vertical scrollers use height.
- `scroller-single-proportion { proportion <n> }`: when the matching window is
  the only tiled scroller column, centers that column on the scroller primary
  axis at the requested proportion. Multi-column scrollers ignore this field
  and keep normal per-column scroller sizing.
- `default-window-width { proportion <n> }` and
  `default-window-height { proportion <n> }`: set the matching window's initial
  stored width and height proportions. Values are clamped to `0.05..1.0`.
- `min-width <px>`, `min-height <px>`, `max-width <px>`, and
  `max-height <px>`: override the effective size bounds used for matching
  windows. Values are clamped to `0..65535`; `0` clears a broader matching
  rule's bound. Bounds constrain geometry but do not make a window floating by
  themselves. They still apply when `respect-size-hints #false` ignores client
  hints.
- `match` and `exclude` use regex search semantics. Simple strings such as
  `gimp` match as before; exact matches should be anchored, for example
  `^org\\.gimp\\.GIMP$`.
- `floating { x-ratio; y-ratio; width-ratio; height-ratio; width; height }`: overrides the
  global floating defaults for this window rule. `x-ratio` and `y-ratio` place
  tool, plain, and unparented floats when `default-floating-position` is not
  set. Dialogs still center on the parent, but `width-ratio`, `height-ratio`,
  `width`, and `height` can set their desired size before clamping. Missing
  fields fall back to the top-level `floating` defaults. Fixed pixel `width`
  and `height` are clamped to `1..65535` and override ratio size on the same
  axis.
- `default-floating-position x=<px> y=<px> relative-to="<anchor>"`: sets the
  initial position for tool, plain, and unparented floats. Anchors are
  `top-left`, `top-right`, `bottom-left`, `bottom-right`, `top`, `bottom`,
  `left`, and `right`; single-edge anchors center on the other axis. `x` and
  `y` are logical pixel offsets from that edge or corner and are clamped to
  `-65535..65535`. Parented dialogs still use parent anchoring for position,
  while rule/global floating size still applies.
- Rule-level `floating` fields merge independently by axis. A later matching
  rule can override only `width` while keeping `x-ratio` and `y-ratio` from an
  earlier broad rule. Fixed pixel size and ratio size are mutually exclusive
  on the same axis; the later field wins.
- Rule-level `default-floating-position` merges atomically. A later matching
  rule replaces the earlier anchor and both offsets.
- Rule-level `respect-size-hints` and `center-floating` merge as ordinary
  explicit booleans. A later matching rule can override `#true` with `#false`.
- Rule-level opening sizing fields merge independently. A later matching rule
  can override only `default-window-height` while keeping an earlier
  `default-column-width`.
- Rule-level size bounds merge independently and are re-evaluated when app id,
  title, client dimension hints, or config change. Client-provided fixed-size
  hints still drive fixed-size floating policy; rule bounds only constrain
  geometry.
- When multiple opening states are true, fullscreen wins over edge maximize,
  and edge maximize wins over full-width column.
- `maximize-policy` applies after a window exists. It does not change
  `open-fullscreen`, `open-maximized`, or `open-maximized-to-edges`.

## Input Devices

Triad can apply keyboard and libinput device settings through River's input,
XKB, and libinput configuration protocols. Omitted fields preserve compositor
and device defaults.

```kdl
input {
  keyboard {
    repeat-rate 40
    repeat-delay 300
    numlock
    capslock #false
    xkb {
      rules "evdev"
      model "pc105"
      layout "us"
      variant ""
      options "ctrl:nocaps"
    }
  }

  mouse {
    natural-scroll #false
    accel-profile "flat"
    accel-speed 0.0
    scroll-factor 1.0
  }

  touchpad {
    tap
    natural-scroll
    click-method "clickfinger"
    scroll-method "two-finger"
    disabled-on-external-mouse
  }

  trackpoint {
    scroll-method "on-button-down"
    middle-emulation
  }

  trackball {
    accel-profile "none"
    scroll-factor 0.75
  }
}
```

- `keyboard.repeat-rate <hz>` and `keyboard.repeat-delay <ms>` configure key
  repeat for keyboards exposed by River input management.
- `keyboard.numlock #true|#false` and `keyboard.capslock #true|#false`
  request initial lock state.
- `keyboard.xkb` supports `rules`, `model`, `layout`, `variant`, and
  `options`. Triad builds the keymap with libxkbcommon and sends it to River;
  binding-level `layout=<index>` still controls per-binding layout overrides.
- Pointer sections are `mouse`, `touchpad`, `trackpoint`, and `trackball`.
  Triad applies the matching section to devices by River/libinput capabilities;
  trackpoint and trackball selection also uses common device-name matching.
- Common pointer fields are `off`, `natural-scroll`, `accel-profile`
  (`"none"`, `"flat"`, `"adaptive"`), `accel-speed -1.0..1.0`,
  `scroll-method` (`"no-scroll"`, `"two-finger"`, `"edge"`,
  `"on-button-down"`), `scroll-button <button-code>`,
  `scroll-button-lock`, `left-handed`, `middle-emulation`, and
  `scroll-factor 0.0..100.0`.
- Touchpad-only fields are `tap`, `tap-button-map`
  (`"left-right-middle"` or `"left-middle-right"`), `drag`, `drag-lock`,
  `dwt`, `dwtp`, `click-method` (`"button-areas"` or `"clickfinger"`), and
  `disabled-on-external-mouse`.

## Cursor

```kdl
cursor {
  theme "default"
  size 24
  shake-to-find #true
  hide-when-typing #true
  hide-after-inactive-ms 1000
}
```

- `theme "<name>"`: sets the compositor cursor theme through River.
- `size <px>`: sets the base compositor cursor size.
- `shake-to-find #true|#false`: when enabled, rapid back-and-forth pointer
  motion temporarily enlarges the compositor cursor and restores it after idle.
  The default is `#false`.
- `hide-when-typing #true|#false`: hides the compositor cursor on key binding
  input and shows it again on pointer motion. The default is `#false`.
- `hide-after-inactive-ms <ms>`: hides the compositor cursor after this many
  milliseconds without pointer motion. `0` disables inactivity hiding, which is
  the default.

## Workspaces

Workspace config uses user-facing workspace language. Internally Triad still
stores workspace membership as DOD tags and masks, but config should describe
the workflow rather than the storage model.

```kdl
workspaces {
  default-count 3
  default-layout "scroller"
}

output "HDMI-A-1" {
  focus-at-startup
  workspaces 2 4
}

workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web"
  workspace 3 name="files"
  workspace 4 name="chat" default-layout="deck" open-on-output="HDMI-A-1"
}
```

- `default-count <n>`: sets the minimum workspace floor. Values are normalized
  to the runtime workspace limits.
- `default-layout "<layout>"`: sets the fallback layout for default workspaces
  and dynamic workspaces without an explicit workspace rule layout.
- `workspace <n> name="..."`: names a workspace slot without forcing a layout.
- `workspace <n> default-layout="..."`: gives that workspace slot an explicit
  layout default. Explicit workspace-rule layouts override
  `workspaces.default-layout`.
- `workspace <n> open-on-output="..."`: pins the workspace's home output.
  Targets use the same connector, shell fallback, make/model identity, or
  description matching as window-rule `open-on-output`. Dynamic output
  reconnects restore the workspace to that output when the target reappears.
- Workspace rules beyond `default-count` are valid dynamic workspace templates.

## Output Rules

Output rules use Niri-style top-level output blocks for output-centered startup
and workspace placement policy:

```kdl
output "HDMI-A-1" {
  focus-at-startup
  workspaces 2 4
}
```

- `output "<target>"`: matches the same connector, shell fallback,
  make/model/unknown-serial identity, or description strings used by
  `open-on-output`.
- `focus-at-startup`: focuses the first connected matching output during the
  initial Triad startup only. Config reloads and later reconnects do not steal
  focus.
- `workspaces <n>...`: pins the listed workspace slots to this output target.
  Later output blocks win for the same slot, and explicit
  `workspace-rules` `open-on-output` entries override output-rule affinity.
- Monitor mode, scale, transform, position, and power fields are not supported
  until Triad has an output-management protocol path for those compositor
  settings.

## Bindings

`bindings` stores keyboard, pointer button, wheel-axis, and dormant gesture
command bindings:

```kdl
bindings {
  bind "Super+Return" "spawn-terminal"
  pointer-bind "Super+left" "move"
  pointer-bind "Super+right" "resize"
  axis-bind "Super+wheel-up" "focus-left"
  axis-bind "Super+wheel-down" "focus-right" mode="overview" allow-inhibiting=#false
  gesture-bind "Super+swipe-left" "focus-left" fingers=3
  gesture-bind "Super+swipe-up" "toggle-overview" fingers=4
}
```

- `bind "<modifiers+key>" "<command>"`: binds a keyboard command. Keyboard
  binds also support `layout=<index>`, `on-release=#true`,
  `while-locked=#true`, and `hotkey-overlay-title`.
- `pointer-bind "<modifiers+button>" "<command>"`: binds mouse buttons. `move`
  and `resize` start River pointer operations; other commands are parsed as
  normal Triad commands and target the window under the pointer when the
  command is window-specific.
- `axis-bind "<modifiers+wheel-direction>" "<command>"`: binds wheel detents.
  Supported directions are `wheel-up`, `wheel-down`, `wheel-left`, and
  `wheel-right`. Large scroll events run once per accumulated 120-unit wheel
  detent.
- `gesture-bind "<modifiers+swipe-direction>" "<command>" fingers=<3|4>`:
  binds touchpad swipe gestures when the compositor advertises
  `zwp_pointer_gestures_v1`. Supported directions are `swipe-left`,
  `swipe-right`, `swipe-up`, and `swipe-down`.
- `mode="normal"|"overview"|"recent"` limits a binding to that mode. Omitted
  mode means always active.
- `allow-inhibiting=#false` lets a binding bypass a focused client's keyboard
  shortcuts inhibition.
- `on-release=#true` runs the command on key release after an accepted press
  instead of on press.
- `while-locked=#true` keeps the keyboard binding active while the River
  session is locked. This does not bypass command-specific behavior; commands
  that need an unlocked session may still be no-ops.

## Switch Events

`switch-events` stores dormant hardware switch command bindings:

```kdl
switch-events {
  lid-close "lock-session"
  lid-open "spawn notify-send lid-open"
  tablet-mode-on "spawn onboard"
  tablet-mode-off "spawn pkill onboard"
}
```

Supported events are `lid-close`, `lid-open`, `tablet-mode-on`, and
`tablet-mode-off`. Switch events are dispatched independently of binding mode,
shortcut inhibition, and session lock. On Linux, Triad reads readable
`/dev/input/event*` devices for lid and tablet-mode switch events; if the
session cannot read those devices, Triad logs the issue and continues without
live switch delivery. Compositor-native switch delivery is not available yet.

## Recent Windows

Triad includes a niri-style MRU switcher with debounced focus history and a
native preview overlay:

```kdl
recent-windows {
  debounce-ms 750
  open-delay-ms 150
  highlight {
    active-color "#999999"
    urgent-color "#ff9999"
    padding 30
    corner-radius 0
  }
  previews {
    max-height 480
    max-scale 0.5
  }
  binds {
    bind "Alt+Tab" "recent-window-next"
    bind "Alt+Shift+Tab" "recent-window-prev"
    bind "Alt+grave" "recent-window-next --filter app-id"
    bind "Alt+Shift+grave" "recent-window-prev --filter app-id"
  }
}
```

- `off`: disables the feature and prevents default recent-window binds.
- `debounce-ms <ms>`: waits before committing a focused window to the MRU list.
  Newly seen windows are recorded immediately. The default is `750`.
- `open-delay-ms <ms>`: delays drawing the switcher so a quick tap can switch
  without flashing the overlay. The default is `150`.
- `highlight`: configures the selected preview border. `urgent-color` is parsed
  for compatibility, but Triad does not expose urgency state yet.
- `previews`: limits preview size by maximum height and scale.
- `binds`: replaces the default Alt-only recent-window binds. Recent binds are
  added only when the physical key slot is not already used by normal bindings.

While open, releasing all modifiers confirms the selected window. `Escape`
cancels, `Return` confirms, Left/Right move selection, Home/End jump to the
edges, `a`/`w`/`o` select all/workspace/output scope, `s` cycles scope, and `q`
closes the selected window. Triad also derives switcher navigation from normal
direction bindings: for example, a configured `Super+h` `focus-left` binding
adds `Alt+h` previous-window behavior while the switcher is open.

## Hotkey Overlay

Triad can render a native keyboard helper popup from the active config:

```kdl
hotkey-overlay {
  skip-at-startup #false
  hide-not-bound
  position "center"
  columns 2
}

bindings {
  bind "Super+?" "toggle-hotkey-overlay" hotkey-overlay-title="Show Important Hotkeys"
  bind "Super+Shift+Q" "close-window" hotkey-overlay-title=#null
}
```

- `skip-at-startup`: when true, prevents the helper from appearing on startup.
  Omitted configs default to true; the generated default config sets this false.
- `hide-not-bound`: omits built-in helper rows that have no configured key.
- `position "top"|"center"|"bottom"`: places the helper popup on screen.
  Omitted configs default to `"top"`; the generated default config uses
  `"center"`.
- `columns <1..4>`: wraps helper rows into multiple columns. The default is
  `2`.
- `hotkey-overlay-title="..."`: shows a binding in the helper with the
  supplied label.
- `hotkey-overlay-title=#null`: hides that binding from the helper.

Triad adds `Super+?` as a fallback `toggle-hotkey-overlay` binding when no
overlay binding is configured and that key slot is free. Shifted punctuation
aliases such as `Super+Shift+/` normalize to their shifted key symbol, so
`Super+?` and `Super+Shift+/` target the same binding.

While the helper is open, Triad asks River to eat the next non-modifier key and
uses that key only to dismiss the helper. Bound Triad keys also dismiss without
running their normal command.

## Scratchpad

The `scratchpad` block controls the size used when showing the standard
scratchpad:

```kdl
scratchpad {
  width-ratio 0.8
  height-ratio 0.9
}
```

Default scratchpad bindings mirror Mango's standard scratchpad workflow:

- `Super+I`: `move-to-scratchpad`
- `Alt+Z`: `toggle-scratchpad`
- `Super+Shift+I`: `restore-scratchpad`

`toggle-scratchpad` shows, hides, or cycles windows that are already in the
scratchpad pool. Use `move-to-scratchpad` first to send the focused window
there. Showing a scratchpad gives that window keyboard focus; hiding it returns
keyboard focus to the active workspace's focused window. `restore-scratchpad`
removes the window from scratchpad and returns it to the workspace it occupied
before entering scratchpad.

## Config Notifications

`config-notification` runs optional user commands when `config-reload` succeeds,
fails before applying, or rolls back because the reload would disturb live
window state:

```kdl
config-notification {
  reload-succeeded "notify-send" "Triad" "Config reloaded"
  reload-failed "notify-send" "Triad" "Config reload failed"
  reload-rolled-back "notify-send" "Triad" "Config reload rolled back"
}
```

- Commands are argv-style KDL strings. The first value is the executable and
  later values are arguments.
- `reload-failed` uses the currently active config because a failed reload does
  not produce a new config.
- `reload-rolled-back` uses the previously active config after Triad restores
  the model.
- `reload-succeeded` uses the newly applied config.
- Omitted commands do nothing.

## Overview

Overview supports opt-in tab mode for Mango-style hold navigation:

```kdl
overview {
  tab-mode
}

bindings {
  bind "Super+o" "toggle-overview"
}
```

- `tab-mode`: enables overview tab mode. The default is off. When enabled,
  keyboard bindings for `toggle-overview` and `open-overview` that include
  modifiers start a hold session instead of acting as a normal toggle. For
  example, `Super+o` opens overview, tapping `o` again while still holding
  `Super` cycles to the next overview window, and releasing `Super` closes
  overview around the selected window.
- Overview tab mode uses the configured opener binding's modifiers as the hold
  latch. It does not affect IPC commands, pointer opens, hot corners, or
  modifierless overview bindings.

## Overview Hot Corners

Overview hot corners are opt-in and open the overview when the pointer enters a
configured corner square:

```kdl
overview {
  hot-corners {
    size 10
    top-left
    bottom-right
  }
}
```

- `size <px>`: sets the square trigger size in pixels. The default is `10`;
  values are clamped to `1..1000`.

Overview also derives modal navigation keys from configured direction bindings.
For example, a configured `Super+h` `focus-left` binding adds bare `h`
navigation while overview is open, as long as that overview key slot is free.
- `top-left`, `top-right`, `bottom-left`, `bottom-right`: enable individual
  corners. Corners can also be set to `#false`.
- Hot corners open overview only. They do not close an already open overview.
- Hot corners are disabled unless at least one corner is configured.

## Screenshots

The `screenshot` block configures still-image capture:

```kdl
screenshot {
  directory "~/Pictures/Screenshots"
  filename-prefix "triad-screenshot"
  capture-command "grim"
  region-selector-command "slurp"
  clipboard-command "wl-copy --type image/png"
  show-pointer #false
}
```

Default bindings are:

- `Print`: `screenshot`
- `Ctrl+Print`: `screenshot-screen`
- `Alt+Print`: `screenshot-window`
- `Super+Print`: `screenshot --clipboard-only`
- `Super+F`: `maximize-window-to-edges`
- `Super+Shift+F`: `fullscreen-window`
- `Super+M`: `maximize-column`
- `Super+Shift+B`: `minimize`

Screenshot commands save to disk and copy to the clipboard by default. Use
`--no-clipboard` for disk-only capture or `--clipboard-only` for clipboard-only
capture.

## Change Rules

New config should follow the data model rather than compositor object shapes.
The parser may translate KDL into runtime structs, but production behavior
should still flow through the model and state systems.

When adding a config option:

1. Choose a name using the policy above.
2. Add it to the parsed config type and default config.
3. Apply it through the model config path.
4. Add focused parser and runtime tests.
5. Document the setting here or in a dedicated config subsection.
6. Update `docs/comp/config-command-matrix.md` with the new capability,
   naming comparison, and Triad implementation mark.
