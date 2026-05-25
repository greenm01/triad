# Triad

https://github.com/user-attachments/assets/27e4bde8-95fc-40cf-9830-5373ac0bcc74

Triad is a programmable Wayland window manager for River. River handles Wayland; Triad manages placement, policy, IPC, and scripting.

[Installation Guide](https://triadwm.org/getting-started/installation/)

[Documentation](https://triadwm.org/)

Triad treats your session as data. Windows carry tags rather than living in a fixed tree, allowing rules and scripts to make placement decisions from the current state. If Triad restarts, your windows stay in place.

Need a screen lock? See [LockMe](https://github.com/greenm01/lockme).

### Multi-Paradigm Layouts

Triad includes `scroller`, `dwindle`, `bsp`, `i3`, `notion`, `tile`, `grid`, `monocle`, `deck`, `spiral`, `tgmix`, and [many other built-in layouts](docs/tiling_wm_categories.md#layout-index). Each workspace can use a different layout.

The layout model supports algorithmic tiling, scrollable strips, BSP trees, and floating placement. You can also set layout-specific key bindings.

### Features

* **Crash resilience:** Layout errors do not affect the compositor session.
* **Shell ready:** Native IPC plus an optional compatibility facade work with popular shell bars.
* **Dynamic workspaces:** Triad spawns workspaces when needed and prunes them when empty.
* **Smooth motion:** Configurable frame pacing and exponential easing for window movement.
* **Scratchpad:** Utility windows manage as centered overlays.
* **Stable identity:** Stable tag and window IDs for long-running scripts.

### Tags, Rules, and IPC

Triad relies on tags, rules, and IPC.

Tags are stable labels for windows. Rules, written in KDL, provide declarative defaults. IPC exposes the session state over a Unix socket, letting scripts query the number of windows on a tag or the current layout before placing a new application.

### Scripting with Janet

Static rules cover the predictable; [Janet](https://janet-lang.org/) handles the rest.

Triad embeds Janet so you can write custom logic directly. Use it to send specific apps to dedicated workspaces, float dialogs based on parent state, or switch layouts dynamically. Janet scripts live in `~/.config/triad/janet/` and react to session events.

You can also use Janet to create custom layouts. See [docs/tiling_wm_categories.md](docs/tiling_wm_categories.md) for the taxonomy.

### Shell Support

Triad exposes its own state socket for native integrations and can also launch shell profiles with a compatibility socket for shells that consume Niri's workspace IPC.

| Shell | Native IPC | Niri IPC |
| :--- | :--- | :--- |
| [Noctalia v5](https://github.com/noctalia-dev/noctalia-shell/tree/v5) | Yes | Yes |
| [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) | No, fork/PR pending | Yes |
| [Waybar](https://github.com/Alexays/Waybar) | No, fork/PR pending | Yes |
| [Wayle](https://github.com/wayle-rs/wayle) | No, fork/PR pending | Yes |
| [Ironbar](https://github.com/JakeStanger/ironbar) | No, fork/PR pending | Yes |

Set `niri-compat #true` only for profiles using the Niri IPC path. For native IPC profiles, leave `niri-compat #false` so Triad does not start the compatibility socket for that shell.

### Installation

Use the [installation guide](https://triadwm.org/getting-started/installation/).
It covers River, distro packages, Nim, first-run setup, and the default config.

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

`verify` runs tests and builds while ensuring a clean tree. Run `nimble liveReload` from within a live session to test runtime changes.

### IPC & Navigation

Interact with Triad's IPC socket via the CLI:

```bash
triad msg focus-next
triad msg toggle-overview
triad msg tile
```

See `docs/ipc.md` for the full command guide.

### License

Triad is released under the MIT License.
