# Configuration

Triad is configured with KDL at `$XDG_CONFIG_HOME/triad/config.kdl`, or
`~/.config/triad/config.kdl` when `XDG_CONFIG_HOME` is unset. If no user config
exists, Triad creates one from the embedded fallback config.

The config is hot-reloaded. `config-reload` reloads the KDL document without
restarting Triad. Shell startup, binding rebuilds, and River side effects happen
after the config has parsed successfully.

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

- `layout`: gaps, column/window proportions, master settings, borders,
  scroller centering, animation settings, smart gaps, and layout cycle.
- `workspaces`: default workspace floor and fallback default layout.
- `workspace-rules`: workspace names and explicit default layouts.
- `window-rule`: app/title matching, default workspace, floating behavior,
  focus behavior, parented-dialog viewport jump behavior, shortcut
  inhibition, and forced layout.
- `bindings`: keyboard bindings, pointer bindings, HJKL/arrow mirroring,
  binding mode, layout override, inhibition policy, and hotkey overlay titles.
- `quickshell`, `terminal`, `screen-lock`, `window-menu-command`,
  `spawn-at-startup`.
- `scratchpad`, `overview` gaps and zoom, `floating`, `screenshot`, `cursor`.
- Top-level flags and settings: `presentation-mode`, `allow-exit-session`,
  `protocol-surfaces`, and `hotkey-overlay`.

For command details, see `docs/ipc.md`. For the Mango/River/Triad comparison
matrix, see `docs/comp/config-command-matrix.md`.

When a config option, binding command, IPC command, or window-management
capability changes, update this guide and
`docs/comp/config-command-matrix.md` in the same change. The configuration
guide states Triad's naming policy; the comparison matrix shows how that policy
maps against Mango and River.

## Window Rules

`window-rule` entries match windows by app id and/or title and apply launch
policy. All matching rules are merged in file order: broad app rules can set
defaults, and later specific title rules can override individual fields.

```kdl
window-rule {
  match app-id="pinentry"
  open-floating #true
  open-focused #false
}

window-rule {
  match app-id="keepassxc"
  dialog-viewport-jump #true
}

window-rule {
  match app-id="gimp"
  default-workspace 4
}

window-rule {
  match app-id="gimp" title="Toolbox"
  parented-role "tool"
  open-focused #false
  floating {
    x-ratio 0.02
    y-ratio 0.08
    width-ratio 0.22
    height-ratio 0.84
  }
}
```

- `open-floating #true|#false`: explicitly opens matching windows floating or
  tiled. Parented dialogs open floating by default unless this rule is set.
- `open-focused #true|#false`: explicitly allows or prevents focusing matching
  windows when they open. Parented dialogs use smart focus by default: they
  focus only when they open on the active workspace.
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
- `default-workspace <n>`: opens matching windows on a workspace. For parented
  dialogs, this explicit workspace overrides the parent workspace.
- `floating { x-ratio; y-ratio; width-ratio; height-ratio }`: overrides the
  global floating defaults for this window rule. `x-ratio` and `y-ratio` place
  tool, plain, and unparented floats. Dialogs still center on the parent, but
  `width-ratio` and `height-ratio` can set their desired size before clamping.
  Missing fields fall back to the top-level `floating` defaults.
- Rule-level `floating` fields merge independently. A later matching rule can
  override only `width-ratio` while keeping `x-ratio` and `y-ratio` from an
  earlier broad rule.

## Cursor

```kdl
cursor {
  theme "default"
  size 24
  shake-to-find #true
}
```

- `theme "<name>"`: sets the compositor cursor theme through River.
- `size <px>`: sets the base compositor cursor size.
- `shake-to-find #true|#false`: when enabled, rapid back-and-forth pointer
  motion temporarily enlarges the compositor cursor and restores it after idle.
  The default is `#false`.

## Workspaces

Workspace config uses user-facing workspace language. Internally Triad still
stores workspace membership as DOD tags and masks, but config should describe
the workflow rather than the storage model.

```kdl
workspaces {
  default-count 3
  default-layout "scroller"
}

workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web"
  workspace 3 name="files"
  workspace 4 name="chat" default-layout="deck"
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
- Workspace rules beyond `default-count` are valid dynamic workspace templates.

## Hotkey Overlay

Triad can render a native keyboard helper popup from the active config:

```kdl
hotkey-overlay {
  skip-at-startup
  hide-not-bound
}

bindings {
  bind "Super+Shift+Slash" "toggle-hotkey-overlay" hotkey-overlay-title="Show Important Hotkeys"
  bind "Super+Shift+Q" "close-window" hotkey-overlay-title=#null
}
```

- `skip-at-startup`: prevents the helper from appearing on startup.
  This is the default, so reloads never show the helper unless the user opens
  it explicitly.
- `hide-not-bound`: omits built-in helper rows that have no configured key.
- `hotkey-overlay-title="..."`: shows a binding in the helper with the
  supplied label.
- `hotkey-overlay-title=#null`: hides that binding from the helper.

Triad adds `Super+Shift+Slash` as a fallback `toggle-hotkey-overlay` binding
when no overlay binding is configured and that key slot is free. `Slash`, `/`,
`Question`, and `?` are accepted key names for slash/question bindings.

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
