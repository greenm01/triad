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
   run them before finishing when feasible.
5. **DRY First Principles**: Minimize duplication of logic. Centralize common patterns.
6. **Data-Oriented Design (DOD)**: Prioritize data layout and transformations (following Yehonathan Sharvit's principles). Keep data separate from logic. Refer to `docs/dod-architecture.md`.
7. **Lean & Mean Source Files**: Keep files small and focused. If a file grows too large, split it by domain.
8. **Manageable Submodules**: Organize code into submodules by domain (e.g., `core`, `layouts`, `config`) to maintain a clean architecture.
9. **Strict Style & Architecture Adherence**: You MUST strictly adhere to `docs/triad-style-guide.md` and `docs/dod-architecture.md`. These are foundational mandates. To maintain perfect consistency, you must re-read these documents upon every context compaction or session initialization.
