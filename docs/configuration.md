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
- Prefer action verbs for commands: `toggle-maximized`, `move-window-left`.
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
| `layout { smart-gaps #true }` | `smartgaps=1` |
| `master { count 1; split-ratio 0.55 }` | `nmaster=1`, `mfact=0.55` |
| `window-rule { open-floating #true }` | `isfloating:1` |
| `toggle-maximized` | `togglemaximizescreen` |

## Current Config Surface

The supported KDL nodes are:

- `layout`: gaps, column/window proportions, master settings, borders,
  scroller centering, animation settings, smart gaps, and layout cycle.
- `workspaces`: default workspace floor.
- `tag-rules`: tag names and default layouts.
- `window-rule`: app/title matching, default tag, floating behavior,
  focus behavior, shortcut inhibition, and forced layout.
- `bindings`: keyboard bindings, pointer bindings, HJKL/arrow mirroring,
  binding mode, layout override, and inhibition policy.
- `quickshell`, `terminal`, `screen-lock`, `window-menu-command`,
  `spawn-at-startup`.
- `scratchpad`, `overview`, `floating`, `screenshot`, `cursor`.
- Top-level flags and settings: `presentation-mode`, `allow-exit-session`,
  and `protocol-surfaces`.

For command details, see `docs/ipc.md`. For the Mango/River/Triad comparison
matrix, see `docs/comp/config-command-matrix.md`.

When a config option, binding command, IPC command, or window-management
capability changes, update this guide and
`docs/comp/config-command-matrix.md` in the same change. The configuration
guide states Triad's naming policy; the comparison matrix shows how that policy
maps against Mango and River.

## Window Rules

`window-rule` entries match windows by app id and/or title and apply launch
policy:

```kdl
window-rule {
  match app-id="pinentry"
  open-floating #true
  open-focused #false
}
```

- `open-floating #true|#false`: explicitly opens matching windows floating or
  tiled. Parented dialogs open floating by default unless this rule is set.
- `open-focused #true|#false`: explicitly allows or prevents focusing matching
  windows when they open. Parented dialogs use smart focus by default: they
  focus only when they open on the active workspace.
- `default-tag <n>`: opens matching windows on a tag. For parented dialogs,
  this explicit tag overrides the parent workspace.

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
