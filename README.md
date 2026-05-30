# Triad

https://github.com/user-attachments/assets/27e4bde8-95fc-40cf-9830-5373ac0bcc74

Triad is a programmable Wayland window manager for River. River handles Wayland; Triad manages placement, policy, IPC, and scripting.

[Installation Guide](https://triadwm.org/getting-started/installation/)

[Documentation](https://triadwm.org/)

Triad treats your session as data. Windows carry tags; they don't live in a fixed tree. Rules and scripts make placement decisions based on the current state. If Triad restarts, your windows stay put.

Need a screen lock? See [LockMe](https://github.com/greenm01/lockme).

### Layouts

Triad includes `scroller`, `dwindle`, `bsp`, `i3`, `notion`, `tile`, `grid`, `monocle`, `deck`, `spiral`, `tgmix`, and [many others](docs/tiling_wm_categories.md#layout-index). Every workspace runs its own layout independently.

The layout model supports algorithmic tiling, scrollable strips, BSP trees, and floating placement. You can also bind keys specific to a layout.

### Features

* **Crash-resilient:** Layout errors never reach the compositor.
* **Shell-ready:** We provide native IPC and a compatibility facade for popular shell bars.
* **Dynamic Workspaces:** Triad spawns workspaces when you need them and prunes them when you don't.
* **Smooth Motion:** Configurable frame pacing and exponential easing for window movement.
* **Scratchpads:** Utility windows manage as centered overlays.
* **Stable IDs:** Tag and window IDs stay the same, allowing scripts to survive reloads.

### Tags, Rules, and IPC

Triad relies on tags, rules, and IPC.

Tags are stable labels. Rules provide declarative defaults in KDL. IPC exposes the session state over a Unix socket. This lets scripts ask questions—like how many windows are on a tag—before deciding where to put a new application.

### Scripting with Janet

Static rules cover the predictable; [Janet](https://janet-lang.org/) handles the rest.

Triad embeds Janet so you can write custom logic directly. Use it to send specific apps to dedicated workspaces, float dialogs based on parent state, or switch layouts dynamically. Janet scripts live in `~/.config/triad/janet/` and react to session events.

You can also use Janet to write custom layouts. See [docs/tiling_wm_categories.md](docs/tiling_wm_categories.md) for the taxonomy.

### Shell Support

Triad exposes its own state socket for native integrations. It can also launch shell profiles with a compatibility socket for shells that consume Niri's workspace IPC.

| Shell | Native IPC | Niri IPC |
| :--- | :--- | :--- |
| [Noctalia v5](https://github.com/noctalia-dev/noctalia-shell/tree/v5) | Yes | Yes |
| [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) | No, fork/PR pending | Yes |
| [Waybar](https://github.com/Alexays/Waybar) | No, fork/PR pending | Yes |
| [Wayle](https://github.com/wayle-rs/wayle) | No, fork/PR pending | Yes |
| [Ironbar](https://github.com/JakeStanger/ironbar) | No, fork/PR pending | Yes |

Set `niri-compat #true` only for profiles using the Niri IPC path. For native IPC profiles, leave `niri-compat #false` so Triad does not start the compatibility socket.

### Installation

Follow the [installation guide](https://triadwm.org/getting-started/installation/). It covers River, distro packages, Nim, first-run setup, and the default config.

For the best River protocol coverage, build upstream River from source:

```bash
git clone https://codeberg.org/river/river.git
cd river
zig build -Doptimize=ReleaseSafe -Dcpu=baseline -Dstrip -Dpie \
  -Dxwayland --prefix "$HOME/.local" install
river -version
```

Triad supports River 0.4+, while upstream `main` may report a development version such as `0.5.0-dev`.

### Toolchain

For development, Triad tracks stable Nim via `choosenim`:

```bash
choosenim update self
choosenim update stable
```

The compiler must report Nim 2.2.4 or newer.

### Development

Use these tasks while iterating:

```bash
nimble test
nimble build
nimble verify
nimble liveReload
```

`verify` runs tests and builds while ensuring a clean tree. Run
`nimble liveReload` from within a live session to test runtime changes; it runs
the live-session doctor checks before replacing binaries.

See [CONTRIBUTING.md](CONTRIBUTING.md) before sending patches.

### IPC & Navigation

Interact with Triad's IPC socket via the CLI:

```bash
triad msg focus-next
triad msg toggle-overview
triad msg tile
```

See `docs/ipc.md` for the full command list.

### License

Triad is released under the MIT License.
