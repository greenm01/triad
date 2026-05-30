# Contributing

Triad is still young, but it is not a dumping ground. Keep patches small. Make the change easy to review. If a change touches policy, layout, IPC, or startup, say what behavior changed and why.

Prefer boring fixes over clever ones. Triad sits between the compositor and the user's session; a cute abstraction is not worth a broken desktop.

## Before a Patch

Run the checks that match the work:

```bash
nimble test
nimble build
nimble verify
```

`verify` is the slow pass. Use it before sending anything broad. For live-session work, use `nimble liveReload` from inside Triad so the doctor checks run before the binaries are swapped.

## Code

Write Nim that can be read under pressure. Keep state changes explicit. Keep protocol boundaries plain. Avoid helper layers that only rename the thing underneath them.

When fixing a bug, add a focused test unless the bug only appears in a live River session. If it does, document the manual check in the commit or PR.

## Docs

Docs should tell the truth without ceremony. Use active verbs. Cut filler. If a feature is unfinished, say so. If a trade-off is ugly, name it.

Put user-facing docs in `docs/`. Keep filenames lowercase with hyphens. The root README should stay short enough for a first-time reader.

## Commits

Use direct commit messages:

```text
Fix focus restore after tag switch
Document monitor matching rules
Add IPC snapshot test
```

No slogans. No process notes. The commit should describe the tree after the change.
