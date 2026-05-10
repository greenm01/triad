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
   step after automated tests/build checks pass.
5. **DRY First Principles**: Minimize duplication of logic. Centralize common patterns.
6. **Data-Oriented Design (DOD)**: Prioritize data layout and transformations (following Yehonathan Sharvit's principles). Keep data separate from logic. Refer to `docs/dod-architecture.md`.
7. **Lean & Mean Source Files**: Keep files small and focused. If a file grows too large, split it by domain.
8. **Manageable Submodules**: Organize code into submodules by domain (e.g., `core`, `layouts`, `config`) to maintain a clean architecture.
9. **Strict Style & Architecture Adherence**: You MUST strictly adhere to `docs/triad-style-guide.md`, `docs/dod-architecture.md`, and `docs/configuration.md` when touching config or command surfaces. Keep `docs/comp/config-command-matrix.md` updated alongside config or command changes. These are foundational mandates. To maintain perfect consistency, you must re-read the style and DOD documents upon every context compaction or session initialization.

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
