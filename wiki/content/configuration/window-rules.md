+++
title = "Window Rules"
weight = 40
+++

# Window Rules

Window rules tell Triad how to handle a window the moment it opens. Rules are
declarative and reload on save — no restart needed.

Every rule begins with a `window-rule` block containing at least one `match`
or `exclude` clause, followed by the properties to apply.

## Matching

Rules match on `app-id` and `title` using regular expressions. You can combine
matchers; all must match for the rule to apply.

| Matcher | Type | Description |
|---|---|---|
| `app-id` | Regex | Match the application ID (Wayland class). |
| `title` | Regex | Match the window title. |
| `is-focused` | Bool | Match only when the window has focus. |
| `is-floating` | Bool | Match only floating windows. |

To find a window's `app-id`, run:

```bash
triad msg state | grep app-id
```

Use `exclude` to carve out exceptions from a broader rule:

```kdl
window-rule {
  match app-id="^org\."
  exclude title=".*—Private Browsing.*"
  open-workspace 2
}
```

## Placement & Behavior

| Property | Values | Description |
|---|---|---|
| `open-floating` | Bool | Open the window floating instead of tiled. |
| `open-focused` | Bool | Give focus to the window when it opens. |
| `open-fullscreen` | Bool | Open in fullscreen mode. |
| `open-maximized` | Bool | Open as a full-width column in scroller layouts. |
| `maximize-policy` | `"edge"`, `"column"`, `"ignore"` | How the maximize command behaves for this window. |
| `default-workspace` | Int | Send the window to a specific workspace number. |
| `open-on-output` | String | Pin the window to a specific monitor by connector name. |
| `open-on-all-workspaces` | Bool | Make the window sticky — visible on every workspace. |
| `idle-inhibit` | `"none"`, `"focused"`, `"visible"` | Prevent the screen from sleeping while this window is visible or focused. |
| `presentation-mode` | `"default"`, `"vsync"`, `"async"` | Output presentation policy. |

## Sizing

| Property | Values | Description |
|---|---|---|
| `min-width` / `max-width` | Pixels | Hard size boundaries. |
| `scroller-proportion` | 0.05..1.0 | Initial column width in scroller layouts. |
| `center-floating` | Bool | Center the window on screen when floating. |

## Examples

Send KeePassXC to workspace 2, floating and centered:

```kdl
window-rule {
  match app-id="^org\.keepassxc\.KeePassXC$"
  open-floating #true
  center-floating #true
  default-workspace 2
}
```

Fullscreen Steam games and inhibit idle:

```kdl
window-rule {
  match app-id="^steam_app_"
  open-fullscreen #true
  idle-inhibit "visible"
}
```

Pin a browser to the web workspace and monitor:

```kdl
window-rule {
  match app-id="^firefox$"
  default-workspace 2
  open-on-output "DP-1"
}
```

Float all dialog windows:

```kdl
window-rule {
  match title=".*— Open File$"
  open-floating #true
  center-floating #true
}
```

Sticky a chat app across all workspaces:

```kdl
window-rule {
  match app-id="^vesktop$"
  open-on-all-workspaces #true
}
```

For event-driven placement that KDL rules cannot express — "open next to an
existing terminal if one is present, otherwise claim a new tag" — see
[Janet Scripting](@/usage/janet-scripting.md).
