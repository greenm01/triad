# Triad Documentation

Triad is a window manager client for River. This directory contains everything you need to configure, build, and hack on it.

## For Users

- **[Configuration Guide](configuration.md)**: The reference for `config.kdl`. Covers window rules, input settings, and layout tuning.
- **[Monitors and Workspaces](monitors.md)**: Multi-monitor setup, workspace placement, and shell bars.
- **[IPC & Commands](ipc.md)**: How to control Triad via `triad msg` and the JSON protocol.

## For Developers

- **[System Architecture](architecture.md)**: The runtime event loop and the hybrid layout engine.
- **[Data-Oriented Design (DOD)](dod-architecture.md)**: Technical specs for state management and entity storage.
- **[The Triad](the_triad.md)**: The philosophy behind Tags, Rules, and IPC.
- **[Janet Scripting](janet.md)**: Using the embedded Janet runtime.
- **[Janet Layouts](janet-layouts.md)**: How to write custom layouts in Janet.
- **[Style Guide](triad-style-guide.md)**: Coding conventions and pragmatic Nim patterns.

### Quality & Testing
- **[Implementation TODO](todo.md)**: Roadmap, blocked features, and the watchlist.
- **[Daily Driver Gates](daily-driver-gates.md)**: Manual and automated checks required for a release.
- **[Live Testing](live-testing.md)**: Procedures for testing inside a live River session.
- **[QEMU VT Smoke Harness](qemu-vt-smoke.md)**: A virtualized TTY harness for seat and recovery testing.
- **[Engineering Trackers](comp/README.md)**: Architectural gap analysis against other window managers.
