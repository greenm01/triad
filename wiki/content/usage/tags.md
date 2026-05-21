+++
title = "Tags"
weight = 5
+++

# Tags

Tags are Triad's model for workspaces. Understanding them explains why Triad
behaves differently from most window managers.

## What a Tag Is

A tag is a stable label. A window carries one or more tags. Each tag has its
own layout state. Tag IDs are logical identifiers that Triad owns — they never
change for the lifetime of the tag, regardless of what the compositor or shell
is doing.

Most window managers give you workspaces as containers: a window lives inside
one, and moving it means lifting it out and dropping it in another. Triad's
model is flat. A window is a record. Its relationship to tags is a bitmask —
membership bits, not a pointer to a parent container. The layout projection
re-derives everything from those bits on every render pass.

## Why It Matters

**Conditionality becomes cheap.** A script asking "how many windows share tag 3,
and what layout is running, and is my IDE already open?" is a handful of index
lookups against a flat snapshot. The same question against a
workspace-as-container model requires traversing a nested object graph.

**A window can exist in more than one context at once.** Set
`open-on-all-workspaces #true` in a window rule and that window appears on
every tag simultaneously. No duplication — the same record, multiple membership
bits.

**Scripts stay stable across restarts.** Because tag IDs are Triad-owned and
never change, a Janet script or external program written today reads the same
snapshot shape tomorrow.

## How Tags Map to Workspaces

The sidebar and shells display tags as workspaces. Each connected output shows
one active tag. The mapping is:

- Tags are stable logical IDs.
- Workspaces are the user-facing presentation of those tags.
- Each output maintains at least one visible workspace.
- Dynamic workspaces (created with `new-workspace`) are pruned when empty.

Name your tags in config:

```kdl
workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web"
  workspace 3 name="code"
  workspace 4 name="chat"
}
```

Pin them to monitors:

```kdl
workspace-rules {
  workspace 4 name="chat" open-on-output="DP-2"
}
```

## Rules and Scripts

KDL window rules handle static placement — "always send Firefox to tag 2."
Janet scripts handle conditionality — "send this window to tag 2 if it's
already running, otherwise tag 3."

```kdl
window-rule {
  match app-id="^firefox$"
  default-workspace 2
}
```

For dynamic placement, see [Janet Scripting](@/usage/janet-scripting.md).
For workspace configuration (naming, pinning, counts), see
[Workspaces](@/configuration/workspaces.md).
