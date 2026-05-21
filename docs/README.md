# Triad Documentation

This directory contains the documentation for the Triad window manager.

## For Users

- **[Configuration Guide](configuration.md)**: The definitive reference for `config.kdl`, covering window rules, input settings, and layout tuning.
- **[Monitors and Workspaces](monitors.md)**: A guide to multi-monitor output setup, workspace placement, launchers, and shell bars.
- **[IPC & Commands](ipc.md)**: The complete list of commands available via `triad msg` and the JSON protocol.

## For Developers & Contributors

- **[System Architecture](architecture.md)**: The runtime event loop, module boundaries, and the hybrid layout engine.
- **[Data-Oriented Design (DOD)](dod-architecture.md)**: The technical specification for Triad's state management and entity-component storage.
- **[The Triad](the_triad.md)**: The philosophical foundation of Triad: Tags, Rules, and IPC.
- **[Child Window Behavior](child-window-behavior.md)**: Policy and decision trees for floating vs. tiling dialogs and utility windows.
- **[Overview Navigation](triad-overview-navigation.md)**: Spatial navigation and workspace traversal in overview mode.
- **[Janet Scripting](janet.md)**: The embedded Janet runtime and external scripting capabilities.
- **[Janet Layouts](janet-layouts.md)**: The design plan for user-defined Janet layouts.
- **[Style Guide](triad-style-guide.md)**: Coding conventions, NEP-1 compliance, and pragmatic DOD patterns for Nim.
- **[Implementation TODO](todo.md)**: The current roadmap, blocked features, and implementation watchlist.
- **[Daily Driver Gates](daily-driver-gates.md)**: The automated and manual checks required before a release.
- **[Live Testing Runbook](live-testing.md)**: Procedures for testing Triad inside a real River session.
- **[QEMU VT Smoke Harness](qemu-vt-smoke.md)**: The virtualized TTY harness to test compositor recovery and seat handling.
- **[Internal Engineering Trackers](comp/README.md)**: Historical gap analysis and architectural tracking against other window managers.
