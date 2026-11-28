# ext-workspace-v1

## Triad Wayland proxy

Triad ships an optional proxy for Wayland clients that use `ext-workspace-v1`.
It adds the workspace protocol on a separate Wayland socket and forwards the
client's other Wayland traffic to River. The proxy uses River's native workspace
global when the compositor already advertises one. Noctalia, Waybar's
`ext/workspaces` module, and other workspace clients use the same socket and
protocol. Waybar's module uses `"on-click": "activate"` for click-to-switch.

Build the helper with Rust 1.89 or later from the Triad checkout. The usual Nim
build works independently of the helper.

```sh
cargo build --release --locked --manifest-path wayland-proxy/Cargo.toml
install -Dm755 wayland-proxy/target/release/triad-wayland-proxy ~/.local/bin/triad-wayland-proxy
```

When the helper is installed, Triad checks River at each managed shell launch.
On builds without `ext-workspace-v1`, Triad starts or reuses the proxy and gives
the shell its display. When River advertises the protocol, Triad launches the
shell on River's display. Existing shell profiles work as written. A running
shell picks up the new display on its next launch. Set `TRIAD_WORKSPACE_PROXY=0`
in Triad's environment to opt out.

The native session installer and `nimble liveReload` build and install the
helper when Cargo is available. The Nix `triadSession` package includes it.
Any other Wayland client can use the running proxy with
`triad-wayland-proxy run -- COMMAND ARGUMENTS`. For manual sessions, start it
first with `triad-wayland-proxy serve`.

The default socket is `$XDG_RUNTIME_DIR/triad-workspaces-$WAYLAND_DISPLAY`
using the basename of River's display. Both commands accept `--socket PATH`
to select a different listener. `serve` uses the session's Triad sockets by
default. For a custom session, `TRIAD_SOCKET` overrides the state and workspace
action endpoint, and `TRIAD_NIRI_SOCKET` overrides the activation fallback for
older daemons. The helper exits when its River session ends.

The proxy lists workspaces and accepts create, activate, assign, deactivate,
and remove requests. Each Wayland commit applies one batch in Triad. Creation
keeps an empty workspace available without taking focus. Assignment preserves
focus on the current output and replaces a moved workspace if one was visible
there. Deactivation selects another workspace on the same output when available.
Removal is available for empty, inactive dynamic workspaces.

Protocol versions it forwards are bounded by the bundled proxy library.
Upstream Wayland peer credentials identify the proxy process, which can affect
PID-based window rules. The session display continues to accept direct
connections.

With both binaries built, the isolated smoke test is available through
`python3 wayland-proxy/tests/smoke.py`. Add `--wlr-randr /path/to/wlr-randr` to
exercise output removal and `--wtype /path/to/wtype` to send a workspace
shortcut through River.

## Protocol and compositor support

Triad already has native IPC. It also has a Niri-compatible path for shells that
expect Niri's workspace stream. `ext-workspace-v1` is the better path for
workspace buttons.

The protocol gives shells the workspace list, state, and grouping. Clients can
request activation, deactivation, assignment to a group, creation, and removal
according to the capabilities advertised on each object.

The shape:

```
Triad workspace state
  -> ext-workspace-v1 server
       -> shell or bar
```

The shell does not need to speak Triad IPC. Triad does not need a private
adapter for every shell.

River is moving the same way. In issue 1402, the plan is to expose a
`river-workspace-v1` protocol that proxies `ext-workspace-v1` through to the
window manager. The useful lesson is not the River-specific wrapper. It is the
direction: stop inventing one workspace IPC per shell, and use the protocol
Waybar already understands.

## Shells and Bars

This table starts from the shell list in `README.md`. The last column records
what matters for an `ext-workspace-v1` integration.

| Shell or bar | Current README path | ext-workspace-v1 status | Triad note |
| :--- | :--- | :--- | :--- |
| [Noctalia v5](https://github.com/noctalia-dev/noctalia) | Native IPC in the [Triad fork](https://github.com/greenm01/noctalia-shell/tree/triad-native-ipc-v5). Upstream 5.6 detects the Niri socket. | Upstream 5.6 has an `ext-workspace-v1` backend. | Triad uses the installed proxy for managed shell launches on River builds that lack native workspace support. |
| [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) | Niri IPC; native IPC fork/PR pending | Documented for workspace integration | Good target for the standard workspace path. |
| [Waybar](https://github.com/Alexays/Waybar) | Niri IPC; native IPC fork/PR pending | Documented through `ext/workspaces` | Best first bar target. It may require an experimental Waybar build. |
| [Wayle](https://github.com/wayle-rs/wayle) | Niri IPC; native IPC fork/PR pending | Not confirmed in public docs | Track as a later shell target. Current public docs describe compositor-specific workspace modules. |
| [Ironbar](https://github.com/JakeStanger/ironbar) | Niri IPC; native IPC fork/PR pending | Not confirmed in current docs | Track as a later bar target. Prior discussion asked for the standard workspace protocol, but current support needs verification. |

## Triad Mapping

Triad tags map naturally to workspaces:

| Triad | ext-workspace-v1 |
| :--- | :--- |
| configured workspace slot | optional workspace `id` |
| tag name or slot label | workspace `name` |
| workspace shown on its output | `active` state |
| pruned workspace | `removed` event |
| focus workspace command | client `activate` request |

Triad IPC also handles layout control, diagnostics, and scripting.

## References

- `README.md`, Shell Support table
- <https://wayland.app/protocols/ext-workspace-v1>
- <https://codeberg.org/river/river/issues/1402#issuecomment-11282755>
- <https://codeberg.org/river/river/issues/1402#issuecomment-15930749>
- <https://github.com/Alexays/Waybar/wiki/Module:-Workspaces>
- <https://pkg.go.dev/github.com/AvengeMedia/DankMaterialShell/core>
- <https://isaacfreund.com/docs/wayland/river-window-management-v1/>
