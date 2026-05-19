# i3 layout-engine conformance

Scope: **layout engine only** — container model, insertion/removal, split/layout/focus/move/resize
commands against upstream i3 (`~/src/i3`).

Explicit non-goals: i3 IPC wire protocol (13 msg types, 8 events), i3 config DSL
(`bindsym`/`for_window`/`assign`/`mode`/`bar`), marks subsystem, bar protocol, and criteria
operators. These are deliberate omissions; see `docs/comp/config-command-matrix.md` rows 345–378
for the comp-target rationale.

---

## Container model

| Concept | i3 (`include/data.h`) | Triad (`src/types/runtime_values.nim`) | Status |
|---|---|---|---|
| Node kinds | `CT_CON` (leaf or split) | `FrameNodeKind.{Leaf, Split}` | ✓ |
| Split modes | `L_SPLITH`, `L_SPLITV`, `L_STACKED`, `L_TABBED` | `SplitTreeNodeMode.{SplitH, SplitV, Stacking, Tabbed}` (line 71) | ✓ |
| `last_split_layout` | `con->last_split_layout` (`con.c:2135`) | `SplitNodeData.lastSplitMode` tracked per node | ✓ |
| Container types: root, output, workspace, dockarea | `CT_ROOT`, `CT_OUTPUT`, `CT_WORKSPACE`, `CT_DOCKAREA` | Tag model (not tree nodes) | ≈ different abstraction, no gap for layout engine |
| Floating containers (`CT_FLOATING_CON`) | Separate floating list on workspace | Per-window `isFloating` flag; floating windows excluded from split-tree | ✓ effective behavior |
| Weight/percent sizing | Per-child `percent` field (`con.c:1430`) | Per-node `weight` float32, normalized at render; clamped [0.05, 0.95] (`split_tree_ops.nim:863`) | ✓ |
| Empty containers (`open` command) | `cmd_open` creates a `CT_CON` with no window | Not implemented | ✗ |

---

## Commands

Upstream i3 command grammar source: `parser-specs/commands.spec`.

Legend: ✓ conformant · ≈ close with minor divergence · ✗ missing

### `split`

| i3 form | i3 behavior (`tree.c:327`) | Triad command | Triad behavior | Status | Notes |
|---|---|---|---|---|---|
| `split h` / `split horizontal` | Wraps focused con in new `SPLITH` parent (or changes existing split) | `split-tree-split-horizontal` → `CmdSplitTreeSplitHorizontal` → `splitFocusedSplitTree(H)` (`split_tree_ops.nim:371`) | Same semantics; optimizes: if parent has one child, rewrites parent mode rather than creating another wrapper | ≈ | Triad avoids redundant nesting; user-visible result is identical |
| `split v` / `split vertical` | Wraps in new `SPLITV` parent | `split-tree-split-vertical` → `splitFocusedSplitTree(V)` | Same | ≈ | |
| `split t` / `split toggle` | Toggles orientation of focused con's parent (H→V or V→H); `cmd_split` in `commands.c` | `split-tree-split-toggle` → `CmdSplitTreeSplitToggle` (`update_commands.nim:129`) | Peeks at focused leaf's parent mode and inverts (H→V, else→H) | ≈ | Logic matches i3 for leaf case; split-container target behaves identically to `split h/v` |

### `layout`

| i3 form | i3 behavior (`con.c:2109`) | Triad command | Triad behavior | Status |
|---|---|---|---|---|
| `layout splith` | Sets focused container to `L_SPLITH`, clears stacking/tabbed | `split-tree-layout-split-horizontal` → `setFocusedSplitTreeLayoutMode(SplitH)` (`split_tree_ops.nim:413`) | Same | ✓ |
| `layout splitv` | Sets to `L_SPLITV` | `split-tree-layout-split-vertical` → `setFocusedSplitTreeLayoutMode(SplitV)` | Same | ✓ |
| `layout stacking` | Sets to `L_STACKED`, saves split in `last_split_layout` | `split-tree-layout-stacking` → `setFocusedSplitTreeLayoutMode(Stacking)` | Saves prior split mode in `lastSplitMode` | ✓ |
| `layout tabbed` | Sets to `L_TABBED`, saves split | `split-tree-layout-tabbed` → `setFocusedSplitTreeLayoutMode(Tabbed)` | Same | ✓ |
| `layout default` | Sets to `L_DEFAULT` (= splith, `commands.c`) | Not implemented | — | ✗ P1-trivial: dispatch to `setFocusedSplitTreeLayoutMode(SplitH)` |
| `layout toggle split` | Flips H↔V; if currently stacked/tabbed restores `last_split_layout` (`con.c:2154`) | `split-tree-layout-toggle-split` → `toggleFocusedSplitTreeSplitLayout()` (`split_tree_ops.nim:440`) | Flips SplitH↔SplitV; from Stacking/Tabbed restores `lastSplitMode` | ✓ |
| `layout toggle` (bare) | Cycles stacked→tabbed→last_split (`con.c:2173`) | Not implemented | — | ✗ P1: needs new command or extend `CidSplitTreeLayoutToggleSplit` |
| `layout toggle all` | Cycles splith→splitv→stacked→tabbed→splith (`con.c:2173`) | Not implemented | — | ✗ P1 |
| `layout toggle <a> <b> ...` | Cycles explicit list (`con.c:2129`) | Not implemented | — | ✗ P1 |

### `focus` (directional)

| i3 form | i3 algorithm (`tree.c:503`) | Triad behavior (`focus.nim:474`) | Status |
|---|---|---|---|
| `focus left/right/up/down` | **Parent-walk**: ascend tree until a split node's orientation matches direction; step to sibling on that side; descend back to focused/edgemost child of sibling subtree | `splitTreeStructuralNeighbor` in `split_tree_ops.nim` implements the parent-walk; `lastFocusedWindowInSubtree` descends to most-recently-focused leaf; geometric fallback preserved | ✓ |
| `focus next sibling` | Move to next sibling in parent's children list | Not implemented | ✗ P1 |
| `focus prev sibling` | Move to prev sibling | Not implemented | ✗ P1 |
| `focus parent` | `level_up` (`tree.c:386`): move focus to parent split container | Not implemented | ✗ P0 — common i3 workflow (promote window out of tabbed container) |
| `focus child` | `level_down` (`tree.c:409`): descend back into last-focused child | Not implemented | ✗ P0 |
| `focus tiling` / `focus floating` / `focus mode_toggle` | Toggle between tiling and floating focus | Not implemented in split-tree context | ✗ P3 (out of layout-engine scope) |
| Tab cycling (next/prev tab in tabbed/stacking) | i3: `focus next` in tabbed context; also controlled by scrolling | `frame-tab-next`/`frame-tab-prev` → `focusSplitTreeTab(±1)` (`split_tree_ops.nim:196`, `update_commands.nim:108`) | ✓ |

### `move`

| i3 form | i3 algorithm (`move.c:259`) | Triad behavior (`placement_ops.nim:316`) | Status |
|---|---|---|---|
| `move left/right/up/down` | **Structural re-parent**: ascend until matching-orientation ancestor; insert into sibling branch; if none, `ws_force_orientation` wraps workspace root; at workspace boundary calls `move_to_output_directed` | `moveWindowInSplitTree` in `split_tree_ops.nim` implements the parent-walk re-parent; `flattenSplitTreeFrom` collapses single-child containers after detach; cross-tag fallback preserved | ✓ |
| `move <dir> [Npx]` | Move with pixel distance hint (used for floating; tiling ignores distance) | Distance arg accepted by parser but tiling move is atomic | ≈ |
| `move to workspace <name>` | Detach container, attach to named workspace | `move-window-to-tag` / `move-to-workspace` | ✓ different naming |
| `move to output <name>` | Move to named output | `move-window-to-output` | ✓ |
| `move to scratchpad` / `scratchpad show` | i3 scratchpad | Triad has independent scratchpad impl; different from i3 | ≈ |
| `move to mark <m>` | Move container adjacent to marked container | Not implemented (depends on marks) | ✗ P3 |
| `move workspace to output` | Move entire workspace to another output | `move-workspace-to-output` / `move-tag-to-output` | ✓ |
| `move position center/mouse` | Move floating window | Floating geometry ops, not split-tree scope | — |

### `swap`

| i3 form | i3 behavior (`con.c:2580`) | Triad behavior | Status |
|---|---|---|---|
| `swap container with id <xid>` | Exchange two containers' positions in-place (full subtrees swapped, not just leaves) | `swapWindowsInSplitTree`: swaps window pointers only in leaves — subtrees cannot be swapped | ≈ leaf-only |
| `swap container with con_id <id>` | Same by i3 con id | Not implemented | ✗ P3 |
| `swap container with mark <m>` | Same by mark | Not implemented (needs marks) | ✗ P3 |

### `resize`

| i3 form | i3 behavior (`commands.c`) | Triad behavior | Status |
|---|---|---|---|
| `resize grow/shrink <dir> [Npx [or Mppt]]` | Adjust container size by walking to matching-orientation ancestor, scaling neighbor weights | `adjustFocusedSplitTreeSplit(orientation, delta)` (`split_tree_ops.nim:830`): same parent-walk, adjusts `weight` on focused + sibling | ✓ algorithm matches |
| `resize set [width W] [height H]` | Set explicit width/height in px or ppt | Not implemented | ✗ P2 |

### Other layout-engine-relevant commands

| i3 command | i3 behavior | Triad | Status |
|---|---|---|---|
| `kill window` / `kill client` | Close focused window | `close-window` | ✓ different name |
| `fullscreen enable/toggle` | Output-scoped fullscreen | `fullscreen-window` / `toggle-fullscreen` | ✓ |
| `fullscreen toggle global` | Global (all-output) fullscreen | Not implemented | ✗ P3 |
| `floating enable/disable/toggle` | Move window to/from floating layer | `toggle-floating` | ✓ |
| `sticky enable/disable/toggle` | Window visible on all workspaces | Declarative config only (`window-rule`), no runtime command | ✗ P3 |
| `rename workspace [<old>] to <new>` | Rename workspace | `rename-tag` / `rename-workspace` | ✓ |

---

## Algorithm divergences

### Directional focus

**i3 (`tree.c:503–591`):** Pure tree traversal.
1. Start at the focused leaf (`con`).
2. Walk `con->parent` until you find a split container whose `orientation` matches
   the requested direction (`H` for left/right, `V` for up/down).
3. Within that container, step to the adjacent child (next or prev sibling).
4. Descend into that subtree via `con_descend_focused` (always into the last-focused
   child) to arrive at a leaf.
5. If the workspace root is reached with no match, cross to the adjacent output via
   `get_tree_next_workspace` (`tree.c:469`).

**Triad (`focus.nim:splitTreeNeighborWindow`):** ✓ Fixed. `splitTreeStructuralNeighbor` (added to
`split_tree_ops.nim`) implements the parent-walk: ascend ancestors, find matching-orientation
split, step to adjacent sibling, descend via `lastFocusedWindowInSubtree` (focus-history-aware).
`bspNeighborCandidate` is retained as geometric fallback when the walk returns `NullWindowId`.

**Remaining limitation:** Empty containers (split node with no leaves) — i3 can focus these as
focus level holders; triad's split-tree has no empty-container focus path.

---

### Move

**i3 (`move.c:259`):** Structural re-parenting.
1. Walk ancestors for a split whose `orientation` matches the move direction.
2. If found: detach `con` from its current parent; `insert_con_into` the matching ancestor's
   sibling branch on the target side. Parent is collapsed if it becomes empty (`tree_flatten`).
3. If not found (at workspace root): call `ws_force_orientation(workspace, o)` to wrap the
   workspace root in a new split with the requested orientation, then insert.
4. At workspace boundary: `move_to_output_directed` (`move.c:206`).

**Triad (`update_commands.nim:CmdMoveWindowLeft/Right/Up/Down`):** ✓ Fixed.
`moveWindowInSplitTree` (added to `split_tree_ops.nim`) implements the parent-walk re-parent:
ascend ancestors, find matching-orientation split with sibling in target direction, detach leaf,
`flattenSplitTreeFrom` collapses the vacated parent, insert adjacent to sibling.
Cross-tag/cross-output fallback to `moveFocusedWindowByDirection` is preserved.

**Remaining limitation:** `ws_force_orientation` (auto-wrapping workspace root on
cross-orientation boundary move) is not implemented; boundary moves fall through to the
cross-tag path instead of restructuring the workspace root.

---

## Non-goals (recorded for completeness)

| i3 surface | Reason omitted |
|---|---|
| i3 IPC (13 msg types, 8 events) | Triad exposes native JSON IPC + Niri-compat socket; no i3-msg shim |
| Config DSL (`bindsym`, `for_window`, `assign`, `mode`, `bar`) | Triad uses KDL config; window rules serve `for_window`/`assign` semantics at admission time |
| Marks (`mark`/`unmark`/`show_marks`) | Marks subsystem doesn't exist; needed before `move to mark` / `swap with mark` |
| Criteria operators (`class`, `instance`, `con_id`, `con_mark`, …) | Triad `window-rule` uses `app-id` / `title` matchers (Niri-style); full i3 criteria are a separate project |
| Bar protocol (`GET_BAR_CONFIG`, `barconfig_update` event) | Bars are external shells reading Niri-compat/native sockets |
| `append_layout` | Requires parsing i3's JSON layout format |
| `open` (empty container) | Rarely used outside scripts; not in declared compat scope |

---

## Gap remediation

### P0 — Behavioral conformance

1. ~~**Structural directional focus**~~ ✓ — `splitTreeStructuralNeighbor` (parent-walk) +
   `lastFocusedWindowInSubtree` (history-aware descent) added to `split_tree_ops.nim`;
   wired as primary path in `focus.nim:splitTreeNeighborWindow` with geometric fallback.

2. ~~**Structural move**~~ ✓ — `moveWindowInSplitTree` added to `split_tree_ops.nim`;
   wired before column/tag-swap path in `update_commands.nim:CmdMoveWindowLeft/Right/Up/Down`.
   Single-child collapse via `flattenSplitTreeFrom`; cross-tag fallback preserved.

3. **`focus parent` / `focus child` commands** — add `CidSplitTreeFocusParent` /
   `CidSplitTreeFocusChild` to `src/types/ipc_commands.nim:41` and
   `src/ipc/commands.nim:351`. Implement `focusSplitTreeParent` / `focusSplitTreeChild`
   in `src/entities/split_tree_ops.nim` (walk ancestors / descend to last-focused child).
   Document in `docs/configuration.md:126` and update `docs/comp/config-command-matrix.md`.

### P1 — Command completeness

4. **`layout toggle all` cycle** — add `CidSplitTreeLayoutCycleAll` to command registry.
   Implement `cycleFocusedSplitTreeLayoutAll` cycling `SplitH→SplitV→Stacking→Tabbed→SplitH`
   in `src/entities/split_tree_ops.nim`.

5. **`layout toggle <list>` cycle** — add `CidSplitTreeLayoutCycle` with a mode list argument.
   Parser extension in `src/ipc/commands.nim`.

6. **`layout default` alias** — trivial: add `CidSplitTreeLayoutDefault` dispatching to
   `setFocusedSplitTreeLayoutMode(SplitH)` in `src/systems/update_commands.nim`.

7. **`focus next/prev sibling`** — add `CidSplitTreeFocusNextSibling` / `CidSplitTreeFocusPrevSibling`
   stepping through `parent.children` around the focused leaf.

### P2 — Config surface

8. **`default-split-orientation horizontal|vertical|auto`** — KDL option under `layout "i3"`
   block. When `auto`, orient by output aspect ratio at workspace creation
   (`src/systems/workspaces.nim:55–64`). Affects initial wrap in `splitFocusedSplitTree`
   (`split_tree_ops.nim:391–411`) and `wrapSplitLeaf` (`split_tree_ops.nim:322`).

9. **`workspace_layout` equivalent** — new KDL option `default-container-layout stacking|tabbed`
   under `layout "i3"`. Apply at tag creation in `src/systems/workspaces.nim:63`.

10. **`resize set <W> <H>`** — add explicit-size form to `adjustFocusedSplitTreeSplit` or a new
    `setFocusedSplitTreeSize` proc in `src/entities/split_tree_ops.nim`. Wire via new command ID.

### P3 — Deferred (separate features, not layout-engine bugs)

- Marks subsystem (`mark`/`unmark`/`show_marks`/`swap with mark`/`move to mark`)
- `swap container with con_id <id>`
- `fullscreen toggle global`
- `sticky` runtime command
- `open` (empty container creation)
- `for_window` runtime evaluation (current admission-time `window-rule` is functionally equivalent)

All P0–P3 command/config additions require updating `docs/comp/config-command-matrix.md`
alongside the implementation (AGENTS.md rule 10).
