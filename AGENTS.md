# AGENTS.md — guide for AI coding agents

This file documents project conventions, hot zones, build mechanics, and
gotchas for agents working on `triad`. Humans should read `README.md` first;
this file adds the operational details an agent needs to act safely.

## Working rules

1. Think before coding. State assumptions, surface tradeoffs, and ask when
   intent is genuinely ambiguous.
2. Keep changes simple. Do not add speculative features, abstractions, or
   configurability.
3. Make surgical edits. Touch only files needed for the request and clean up
   only the mess your change creates.
4. Define verification. Turn every bugfix or feature into concrete checks and
   run them before finishing when feasible. For runtime, compositor, reload, or
   session-behavior changes, run `nimble liveReload` as the final verification
   step after automated tests/build checks pass. If the current session has had
   a recent keyboard lock, reload hang, missing-manager incident, or manual
   recovery after `nimble liveReload`, do not run `nimble liveReload` again
   without explicit human approval.
5. Format Nim-family files with `nph`. Run `nph` on touched `.nim`,
   `.nims`, and `.nimble` files before verification, and use `nph --check`
   when validating formatting without writing changes.
6. **DRY First Principles**: Minimize duplication of logic. Centralize common patterns.
7. **Data-Oriented Design (DOD)**: Prioritize data layout and transformations (following Yehonathan Sharvit's principles). Keep data separate from logic. Refer to `docs/dod-architecture.md`.
8. **Lean & Mean Source Files**: Keep files small and focused. If a file grows too large, split it by domain.
9. **Manageable Submodules**: Organize code into submodules by domain (e.g., `core`, `layouts`, `config`) to maintain a clean architecture.
10. **Strict Style & Architecture Adherence**: You MUST strictly adhere to `docs/triad-style-guide.md`, `docs/dod-architecture.md`, and `docs/configuration.md` when touching config or command surfaces. Keep `docs/comp/config-command-matrix.md` updated alongside config or command changes. These are foundational mandates. To maintain perfect consistency, you must re-read the style and DOD documents upon every context compaction or session initialization.

## DOD runtime direction

The runtime model is the source of truth. Production code should not rebuild
compositor-shaped object graphs or bypass the state/query layer.

When changing runtime, state, or systems code:

1. Prefer indexed queries and iterators over allocation-returning helpers in hot
   production paths.
2. Keep mutation centralized in `src/state` and `src/entities`; systems should
   use the `src/state/engine.nim` facade instead of reaching into entity tables
   or relationship indexes directly.
3. Keep daemon and protocol code as thin adapters: translate compositor events
   into model messages, and translate effects or projections back to compositor
   actions.
4. Treat `Model.update(msg)` as the reducer boundary. If profiling shows event
   copying is expensive, prefer an in-place reducer design over adding side
   mutation paths.

## Live debugging evidence

For live reload, compositor, focus, session restore, or window-placement bugs:

1. Do not delete `$XDG_RUNTIME_DIR/triad-live-restore.json` as cleanup. Live
   restore preserves this handoff file and marks it with
   `restore_status: "applied"` after a successful restore so stale state is not
   replayed.
2. Inspect the retained restore snapshot before and after `nimble liveReload`
   when debugging reload behavior. It records active tag, focused window,
   per-tag focus, window geometry, maximized/fullscreen state, and focus
   history.
3. Use the behavior JSONL logs for cross-session live debugging. The dev
   default path is
   `${XDG_STATE_HOME:-$HOME/.local/state}/triad/behavior/triad-behavior-YYYY-MM-DD.jsonl`.
   These logs are outside the repo, roll daily, cap each day at 5 MiB, and keep
   seven days by default.
4. Relevant live-restore behavior events include `live_restore_loaded`,
   `live_restore_applied`, `live_restore_committed`, and
   `live_restore_snapshot_dumped`. Quickshell/Noctalia reload events include
   `quickshell_startup_decision`, `quickshell_config_reload_decision`,
   `quickshell_spawned`, `quickshell_released`, and
   `quickshell_configured_stop_*`. Niri-compatible shell stream events include
   `niri_compat_ipc_server_starting`,
   `niri_compat_event_stream_subscribed`, and
   `niri_compat_event_stream_disconnected`. Prefer citing these JSON events
   when explaining a live reload, focus, or shell disappearance bug.
5. Behavior JSONL logs are off by default in normal sessions. Enable the
   development bundle with `triad --dev-mode` or `TRIAD_DEV_MODE=1`, or force
   only behavior logging with `TRIAD_BEHAVIOR_LOG=1`. `TRIAD_BEHAVIOR_LOG=0`
   overrides startup dev mode and keeps behavior logs off. In a running
   session, use `triad msg dev-mode on|off|toggle|status` to change or inspect
   the live diagnostics mode. To redirect or tune logs, use
   `TRIAD_BEHAVIOR_LOG_DIR`, `TRIAD_BEHAVIOR_LOG_MAX_BYTES`, and
   `TRIAD_BEHAVIOR_LOG_KEEP_DAYS`. Keep generated logs out of git.
6. If `nimble liveReload` reports that the running daemon does not expose a
   `perf-status` PID, first verify whether `triad msg perf-status` returns a
   valid `perf-status` reply outside the agent sandbox. A one-version-old
   hardened daemon may answer `perf-status` without `pid`; `tools/live_reload.sh`
   treats that as a bootstrap-compatible daemon only when the live process
   executable matches the installed `$TRIAD_LIVE_BIN_DIR/triad`.
