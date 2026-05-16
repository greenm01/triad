# Triad

https://github.com/user-attachments/assets/27e4bde8-95fc-40cf-9830-5373ac0bcc74

Triad is a dynamic window manager for Wayland, built as a dedicated client for the River compositor. It operates on a clarifying principle: separate the display from the policy. River handles the Wayland protocol and keeps your screens running. Triad decides where your windows go. The result is a desktop of extraordinary resilience. If Triad restarts or updates, your display does not flinch; your windows remain exactly where they were.

But Triad's true distinction lies in its architecture. Most window managers treat workspaces as containers—moving a window means lifting it out of one box and dropping it into another. Triad treats your session as flat data. A window carries tags; there is no rigid hierarchy to traverse. This shift makes conditional logic remarkably cheap, transforming window management from static configuration into a live, scriptable engine.

Need a good screen lock? See [LockMe](https://github.com/greenm01/lockme).

### The Triad

Triad's namesake is its foundation of control: **Tags**, **Rules**, and **IPC**.

Tags provide stable, concurrent labels for your windows. Rules, written in robust KDL, provide declarative defaults. IPC exposes a clean, flat snapshot of the entire model over a Unix socket. Together, they elevate external code into a first-class policy layer. A script can easily ask, "How many windows are currently on this tag, and what is the layout?" before deciding where to place a newly opened application.

### Scriptable Policy with Janet

Configuration handles the predictable. Code handles the exceptions.

To support true conditional logic, Triad embeds Janet—a small, elegant, and data-oriented Lisp. Rather than suffering the overhead of socket communication and JSON parsing, Janet scripts receive Triad's state as native tables and execute placement functions directly.

This unlocks **App Manifests**. Applications can ship with small, sandboxed Janet scripts that evaluate the current desktop context and dictate their preferred layout. It is a modern, executable successor to rigid X11 window hints. Your environment adapts live, making intelligent decisions based on what is actually on your screen.

### First-Class Scrolling (And 11 Other Layouts)

Triad is built around a premier, first-class scrolling layout—giving you an infinite, fluid canvas for your workflow. 

However, it does not force you into a single paradigm. Much like Mango WM, Triad natively supports 11 other layout modes, including Master-Stack, Grid, and Monocle. You can toggle between them instantly and independently for every workspace.

### The Shell Ecosystem

A window manager is defined by its ecosystem, and the Wayland tiling community is largely split between Waybar and Quickshell. Triad supports both, flawlessly. 

While it emits its own native JSON stream, it also natively projects its state as Niri-shaped JSON. This means you can drop in existing, highly polished Waybar configurations or rich Quickshell themes—such as **Noctalia-shell** or **DankMaterialShell**—and they will work immediately. No forks, no shims, no compromises.

### Features at a Glance

* **Crash Resilience:** Because policy is decoupled from the Wayland compositor, layout errors cannot destroy your session or your open work.
* **Waybar & Quickshell Ready:** Native projection of Niri-shaped JSON ensures immediate compatibility with the two most popular shell ecosystems.
* **Dynamic Workspaces:** Spawns workspaces when needed; prunes them when empty.
* **Flawless Motion:** Driven by an internal 60FPS clock and exponential easing for exceptionally smooth window movements.
* **The Scratchpad:** Banishes utility windows, summoning them instantly as centered overlays.
* **Stable Identity:** Ensures tag and window IDs remain constant, providing a solid foundation for long-running scripts.

### Installation

For complete installation and session setup instructions, refer to [INSTALL.md](INSTALL.md).
The fastest path for Nix users is:

```bash
git clone https://github.com/greenm01/triad.git
cd triad
nix develop
nix build .#triad
nix run .#install-session
```

Log out and select **River (Triad)** from your display manager's session menu.

### Toolchain

Triad tracks stable Nim via `choosenim`.

```bash
choosenim update self
choosenim update stable
nim --version
```

The compiler must report Nim 2.2.4 or newer before running the full preflight.

### Development Checks

Use the standard tasks while iterating:

```bash
nimble test
nimble build
nimble tidy
```

Before publishing changes, run the full local preflight:

```bash
nimble verify
nimble liveReload
```

`verify` requires a clean working tree, runs tests and builds, tidies generated artifacts, and ensures no executable binaries are left behind. For runtime-facing work, execute `nimble liveReload` from inside a live session.

**Additional Resources:**
* **Live Testing:** `docs/live-testing.md`
* **Configuration Guide:** `docs/configuration.md`
* **VT Switching & Recovery:** `docs/qemu-vt-smoke.md`
* **Daily-Driver Gates:** `docs/daily-driver-gates.md`

### IPC & Navigation

You can interact with Triad's IPC socket directly using the CLI:

```bash
triad msg focus-next
triad msg toggle-overview
triad msg layout-tile
```

For a comprehensive guide to commands and the JSON state protocol, see `docs/ipc.md`.

### License

Triad is released under the MIT License.
