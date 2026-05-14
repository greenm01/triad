# Niri Recent Windows Compliance

Reference: <https://niri-wm.github.io/niri/Configuration%3A-Recent-Windows.html>

| Area | Niri Behavior | Triad Status | Notes |
| --- | --- | --- | --- |
| Enable/disable | `recent-windows { on/off }` | Compliant | Triad defaults on and supports `off`; `enabled #true/#false` is also accepted. |
| Debounce | Focus timestamp commits after `debounce-ms`; new windows commit immediately. | Compliant | Triad keeps this separate from `focus-last` history. |
| Open delay | Overlay appears after `open-delay-ms`. | Compliant | Quick taps can confirm before the visual overlay appears. |
| Default binds | Alt/Super Tab and grave. | Partial | Triad intentionally defaults to Alt-only to preserve existing `Super+Tab` focus behavior. |
| Nested binds | Recent-window-specific keybind block. | Compliant | `recent-windows { binds { bind ... } }` replaces the recent default binds. |
| Scopes | All, workspace, output. | Compliant | Scope can be set or cycled while the switcher is open. |
| App filter | Same app-id filtering. | Compliant | Uses the active/selected app id when opening or changing filter. |
| Modifier release | Releasing all modifiers confirms. | Compliant | Uses watched modifier state from `river_xkb_bindings_v1`. |
| Preview overlay | Live previews, title, selected highlight, scope panel. | Compliant | Rendered with Triad protocol surfaces and live River window nodes. |
| Pointer hover | Hovering a preview selects it. | Compliant | Pointer motion is ignored until the overlay is visible. |
| Close selected | Close the selected MRU window. | Compliant | Exposed as `recent-window-close-current`. |
| Urgency highlight | Separate urgent color. | Partial | Config is parsed; Triad currently has no urgency signal. |
