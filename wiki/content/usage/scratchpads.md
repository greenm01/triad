+++
title = "Scratchpads"
weight = 22
+++

# Scratchpads

A scratchpad is a hidden window pool. Toggle it to bring a window to the
foreground as a floating overlay; toggle again to hide it. Scratchpads are
useful for tools you need briefly and often — a terminal, a calculator, a
notes app.

## Default Scratchpad

The default scratchpad is a single slot. Send the focused window to it:

```bash
triad msg move-to-scratchpad
```

Toggle it visible or hidden:

```bash
triad msg toggle-scratchpad
```

Bind both for quick access:

```kdl
bindings {
  bind "Super+s"       "move-to-scratchpad"
  bind "Super+Alt+s"   "toggle-scratchpad"
  bind "Super+Shift+s" "restore-scratchpad"
}
```

## Named Scratchpads

Named scratchpads let you maintain separate pools for different tools:

```bash
triad msg move-to-named-scratchpad "terminal"
triad msg toggle-named-scratchpad  "terminal"
```

```kdl
bindings {
  bind "Super+Ctrl+e"       "toggle-named-scratchpad terminal"
  bind "Super+Ctrl+Shift+e" "move-to-named-scratchpad terminal"
}
```

Named scratchpads are created on first use. A name can hold multiple windows;
toggling shows or hides the entire pool.

## Workflow

A typical setup keeps a terminal in a named scratchpad:

1. Open a terminal (`Super+Return`).
2. Send it to the scratchpad (`triad msg move-to-named-scratchpad "terminal"`).
3. From any workspace, `Super+Ctrl+e` brings it up as a centered overlay.
4. `Super+Ctrl+e` again hides it.

The window stays running in the background. Its state — shell history, running
processes — persists between toggles.
