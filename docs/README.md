# Triad Documentation

Welcome to the Triad documentation. This directory contains everything from high-level philosophy and user guides to hard technical specifications for the window manager.

## For Users

If you are looking to set up and use Triad, start here:

- **[Configuration Guide](configuration.md)**: The definitive reference for `config.kdl`, including window rules, input settings, and layout tuning.
- **[IPC & Commands](ipc.md)**: A complete list of commands available via `triad msg` and the underlying JSON protocol.

## For Developers & Contributors

These documents detail how Triad is built and how to ensure it stays stable:

### Core Architecture
- **[System Architecture](architecture.md)**: High-level overview of the runtime event loop, module boundaries, and the hybrid layout engine.
- **[Data-Oriented Design (DOD)](dod-architecture.md)**: The technical specification for Triad's state management and entity-component-like storage.
- **[The Triad](the_triad.md)**: The philosophical foundation of Triad: Tags, Rules, and IPC.

### Feature Specifications
- **[Child Window Behavior](child-window-behavior.md)**: Policy and decision trees for floating vs. tiling dialogs and utility windows.
- **[Overview Navigation](triad-overview-navigation.md)**: How spatial navigation and workspace traversal work in overview mode.
- **[Janet Scripting](janet.md)**: Details on the embedded Janet runtime and external scripting capabilities.

### Development Standards
- **[Style Guide](triad-style-guide.md)**: Coding conventions, NEP-1 compliance, and pragmatic DOD patterns for Nim.
- **[Implementation TODO](todo.md)**: Current roadmap, blocked features, and implementation watchlist.

### Verification & Testing
- **[Daily Driver Gates](daily-driver-gates.md)**: The automated and manual checks required before a release is considered stable.
- **[Live Testing Runbook](live-testing.md)**: Procedures for testing Triad inside a real River session.
- **[QEMU VT Smoke Harness](qemu-vt-smoke.md)**: How to use the virtualized TTY harness to test compositor recovery and seat handling.

---

## Internal Trackers

Historical gap analysis and architectural tracking against other window managers can be found in the **[Internal Engineering Trackers](comp/README.md)** directory.
