# ext-workspace-v1

Triad already has native IPC. It also has a Niri-compatible path for shells that
expect Niri's workspace stream. `ext-workspace-v1` is the better path for
workspace buttons.

The protocol is narrow. It gives shells a list of workspaces, their state, their
grouping, and a few requests: activate, remove, maybe rename. That is the slice
of Triad a bar needs. It is not a replacement for Triad IPC, Janet, layout
control, diagnostics, or scripting.

The shape:

```
Triad workspace state
  -> ext-workspace-v1 server
       -> shell or bar
```

The shell does not need to speak Triad IPC. Triad does not need a private
adapter for every shell.

## Shells and Bars

This table starts from the shell list in `README.md`. The last column records
what matters for an `ext-workspace-v1` integration.

| Shell or bar | Current README path | ext-workspace-v1 status | Triad note |
| :--- | :--- | :--- | :--- |
| [Noctalia v5](https://github.com/noctalia-dev/noctalia-shell/tree/v5) | Native IPC and Niri IPC | Not confirmed in public docs | Keep the current path until Noctalia exposes or documents an `ext-workspace-v1` workspace source. |
| [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) | Niri IPC; native IPC fork/PR pending | Documented for workspace integration | Good target for the standard workspace path. |
| [Waybar](https://github.com/Alexays/Waybar) | Niri IPC; native IPC fork/PR pending | Documented through `ext/workspaces` | Best first bar target. It may require an experimental Waybar build. |
| [Wayle](https://github.com/wayle-rs/wayle) | Niri IPC; native IPC fork/PR pending | Not confirmed in public docs | Track as a later shell target. Current public docs describe compositor-specific workspace modules. |
| [Ironbar](https://github.com/JakeStanger/ironbar) | Niri IPC; native IPC fork/PR pending | Not confirmed in current docs | Track as a later bar target. Prior discussion asked for the standard workspace protocol, but current support needs verification. |

## Triad Mapping

Triad tags map naturally to workspaces:

| Triad | ext-workspace-v1 |
| :--- | :--- |
| tag ID | workspace `id` |
| tag name or slot label | workspace `name` |
| active tag | `active` state |
| attention request | `urgent` state |
| pruned or hidden tag | `hidden` state, or remove the workspace |
| focus workspace command | client `activate` request |

Triad should keep using its own IPC for full control. `ext-workspace-v1` should
only carry the workspace state shells already know how to consume.

## References

- `README.md`, Shell Support table
- <https://wayland.app/protocols/ext-workspace-v1>
- <https://github.com/Alexays/Waybar/wiki/Module:-Workspaces>
- <https://pkg.go.dev/github.com/AvengeMedia/DankMaterialShell/core>
- <https://isaacfreund.com/docs/wayland/river-window-management-v1/>
