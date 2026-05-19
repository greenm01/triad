import tcore_support
import ../src/core/native_layout_codec

suite "Core Runtime Logic: shell snapshot ipc":
  test "Shell snapshot exposes active workspace focus globally":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "browser", title: "Two")
    )

    var snapshot = model.shellSnapshot()
    let focused = snapshot.windows.filterIt(it.isFocused)
    check snapshot.activeWorkspaceIdx == 2
    check focused.len == 1
    check focused[0].id == 2
    check focused[0].workspaceIdx == 2
    check snapshot.workspaces[0].focusedWindow == 1
    check snapshot.workspaces[1].focusedWindow == 2

    let tag2 = model.tagForSlot(2)
    let col2 = model.columnAt(tag2, 0)
    model.placeWindow(tag2, col2, WindowId(1))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))

    snapshot = model.shellSnapshot()
    let activeFocused = snapshot.windows.filterIt(it.isFocused)
    check activeFocused.len == 1
    check activeFocused[0].id == 1
    check activeFocused[0].workspaceIdx == 2
    check activeFocused[0].tagId.isSome
    check activeFocused[0].tagId.get() == 2
    model.requireTagShellSemantics("active workspace focus scenario")

  test "Window focus broadcasts active window change":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "term", title: "Two")
    )

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    let activeWindowEvent = effects.filterIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspaceActiveWindowChanged")
    )
    check activeWindowEvent.len == 1
    let payload = parseJson(activeWindowEvent[0].jsonPayload)
    check payload["WorkspaceActiveWindowChanged"]["workspace_id"].getInt() == 1
    check payload["WorkspaceActiveWindowChanged"]["active_window_id"].getInt() == 1
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowFocusChanged")
    )
    check not effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspacesChanged")
    )

  test "Shell snapshot exposes output refresh rate":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1920, height: 1080)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputRefreshRate, refreshOutputId: 1, outputRefreshRate: 144000
      )
    )

    let snapshot = model.shellSnapshot()
    check snapshot.outputs.len == 1
    check snapshot.outputs[0].refreshRate == 144000

  test "Workspace focus broadcasts activation with workspace snapshot":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "browser", title: "Two")
    )

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    let activationEvents = effects.filterIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspaceActivated")
    )
    check activationEvents.len == 1
    let activation = parseJson(activationEvents[0].jsonPayload)["WorkspaceActivated"]
    check activation["id"].getInt() == 1
    check activation["focused"].getBool()
    let workspaceEvents = effects.filterIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspacesChanged")
    )
    check workspaceEvents.len == 1
    let workspaces =
      parseJson(workspaceEvents[0].jsonPayload)["WorkspacesChanged"]["workspaces"]
    check workspaces[0]["id"].getInt() == 1
    check workspaces[0]["is_active"].getBool()
    check workspaces[0]["is_focused"].getBool()
    check workspaces[1]["id"].getInt() == 2
    check not workspaces[1]["is_active"].getBool()
    check not workspaces[1]["is_focused"].getBool()
    check not effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowsChanged")
    )
    model.requireTagShellSemantics("workspace focus broadcast scenario")

  test "Empty dynamic workspaces prune after focus leaves":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))

    var snapshot = model.shellSnapshot()
    check snapshot.activeTag == 4
    check snapshot.workspaces.anyIt(it.tagId == 4)
    model.requireTagShellSemantics("empty dynamic active scenario")

    let pruneEffects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    snapshot = model.shellSnapshot()
    check snapshot.activeTag == 2
    check not snapshot.workspaces.anyIt(it.tagId == 4)
    check pruneEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspacesChanged")
    )
    model.requireTagShellSemantics("empty dynamic pruned scenario")

  test "Scratchpad restore returns window to previous workspace":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))
    model.requireTagShellSemantics("scratchpad hidden scenario")

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdRestoreScratchpad))

    let snapshot = model.shellSnapshot()
    let focused = snapshot.windows.filterIt(it.isFocused)
    check focused.len == 1
    check focused[0].id == 1
    check focused[0].workspaceIdx == 1
    check snapshot.activeWorkspaceIdx == 1
    check model.placementForWindowOnTag(model.tagForSlot(1), WindowId(1)).isSome
    check model.placementForWindowOnTag(model.tagForSlot(2), WindowId(1)).isNone
    model.requireTagShellSemantics("scratchpad restored scenario")

  test "Scratchpad toggle cycles standard windows in send order":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "term", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "term", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))

    var effects = model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))
    check model.scratchpadVisible()
    check model.focusedWindowId() == 2
    check effects.hasFocusEffect(2)

    effects = model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))
    check not model.scratchpadVisible()
    check model.focusedWindowId() == 1
    check effects.hasFocusEffect(1)

    effects = model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))
    check model.scratchpadVisible()
    check model.focusedWindowId() == 3
    check effects.hasFocusEffect(3)

    discard model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))
    effects = model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))
    check model.scratchpadVisible()
    check model.focusedWindowId() == 2
    check effects.hasFocusEffect(2)
    model.requireTagShellSemantics("scratchpad cycle scenario")

  test "Scratchpad toggle focuses shown window and restores workspace focus":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "term", title: "Two")
    )

    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToScratchpad))
    check model.activeWorkspaceFocusId() == 1

    var effects = model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))
    check model.scratchpadVisible()
    check model.focusedWindowId() == 2
    check effects.hasFocusEffect(2)

    effects = model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))
    check not model.scratchpadVisible()
    check model.focusedWindowId() == 1
    check effects.hasFocusEffect(1)

  test "Move to scratchpad focuses last workspace-local focus":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "term", title: "Two")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "term", title: "Three")
    )
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdMoveToScratchpad))

    check not model.scratchpadVisible()
    check model.focusedWindowId() == 2
    check model.activeWorkspaceFocusId() == 2
    check effects.hasFocusEffect(2)
    check model.placementForWindowOnTag(model.tagForSlot(2), WindowId(3)).isNone
    model.requireTagShellSemantics("scratchpad move fallback focus scenario")

  test "Standard scratchpad toggle skips hidden named scratchpads":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "term", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "files", title: "Files")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToNamedScratchpad, scratchpadName: "files"))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))
    check model.scratchpadVisible()
    check model.focusedWindowId() == 2
    check effects.hasFocusEffect(2)
    model.requireTagShellSemantics("hidden named scratchpad skipped scenario")

  test "Standard scratchpad toggle hides visible named scratchpad first":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "term", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "files", title: "Files")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToNamedScratchpad, scratchpadName: "files"))
    model.applyMsg(Msg(kind: MsgKind.CmdToggleNamedScratchpad, scratchpadName: "files"))
    check model.scratchpadVisible()
    check model.focusedWindowId() == 3

    let effects = model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))
    check model.scratchpadVisible()
    check model.focusedWindowId() == 2
    check effects.hasFocusEffect(2)
    model.requireTagShellSemantics("visible named scratchpad hidden scenario")

  test "Scratchpad restore with no visible window restores next standard candidate":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "term", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "term", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdRestoreScratchpad))
    check not model.scratchpadVisible()
    check model.focusedWindowId() == 2
    check model.scratchpadWindowCount() == 1
    check model.placementForWindowOnTag(model.tagForSlot(1), WindowId(2)).isSome
    check model.placementForWindowOnTag(model.tagForSlot(1), WindowId(3)).isNone
    check effects.hasFocusEffect(2)
    model.requireTagShellSemantics("hidden scratchpad restore candidate scenario")

  test "Manage start keeps compositor focus on visible scratchpad":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "term", title: "Two")
    )

    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToScratchpad))
    discard model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))

    let effects = model.updateModel(Msg(kind: MsgKind.WlManageStart))
    check model.scratchpadVisible()
    check model.focusedWindowId() == 2
    check effects.hasFocusEffect(2)
    check not effects.hasFocusEffect(1)
    model.requireTagShellSemantics("scratchpad manage focus scenario")

  test "Clicking visible scratchpad reasserts compositor focus":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "term", title: "Two")
    )

    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToScratchpad))
    discard model.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    check model.scratchpadVisible()
    check model.focusedWindowId() == 2
    check effects.hasFocusEffect(2)
    model.requireTagShellSemantics("scratchpad click focus scenario")

  test "Window rule opens named scratchpad hidden until toggled":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "st-yazi",
              defaultWorkspaces: @[2'u32, 3'u32],
              openNamedScratchpad: "files",
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "st-yazi", title: "Files")
    )

    let winId = model.windowForExternal(ExternalWindowId(10))
    check winId != NullWindowId
    check model.scratchpadWindowCount() == 1
    check model.namedScratchpadWindow("files") == winId
    check not model.scratchpadVisible()
    check not model.firstWindowPosition(winId).found
    check model.placementForWindowOnTag(model.tagForSlot(2), winId).isNone
    check model.placementForWindowOnTag(model.tagForSlot(3), winId).isNone
    check model.shellSnapshot().windows.anyIt(uint32(it.id) == 10 and it.tagId.isNone)

    let effects = model.updateModel(
      Msg(kind: MsgKind.CmdToggleNamedScratchpad, scratchpadName: "files")
    )

    check model.scratchpadVisible()
    check model.activeScratchpadWindow() == winId
    check effects.hasFocusEffect(10)
    check model.instructionGeom(10).w > 0
    model.requireTagShellSemantics("named scratchpad rule scenario")

  test "Closing transient window keeps focus on active workspace":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "brave", title: "Browser")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 2, appId: "thunar", title: "Pictures"
      )
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 3, appId: "kitty", title: "Terminal A"
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 4, appId: "kitty", title: "Terminal B"
      )
    )

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 5,
        appId: "image-viewer",
        title: "Screenshot",
      )
    )

    let effects =
      model.updateModel(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 5))

    check model.shellSnapshot().activeTag == 1
    check model.activeWorkspaceFocusId() == 2
    check model.focusedWindowId() == 2
    check effects.hasFocusEffect(2)
    check not effects.hasFocusEffect(3)
    check not effects.hasFocusEffect(4)
    model.requireTagShellSemantics("transient close local focus scenario")

  test "Closing last dynamic workspace window still collapses workspace":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "term", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "term", title: "Dynamic")
    )

    let effects =
      model.updateModel(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 2))
    let snapshot = model.shellSnapshot()

    check snapshot.activeTag == 3
    check not snapshot.workspaces.anyIt(it.tagId == 4)
    check not effects.hasFocusEffect(1)
    model.requireTagShellSemantics("dynamic close collapse scenario")

  test "Overview order deduplicates multi-tag windows":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    let tag2 = model.tagForSlot(2)
    let col2 = model.addColumn(tag2)
    model.placeWindow(tag2, col2, WindowId(1))

    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    check model.overviewWindowIds() == @[WindowId(1)]
    check model.selectedOverviewWindow() == WindowId(1)

  test "Configured defaults place floating windows":
    var model = configuredModel()
    let (nextModel, _) = model.update(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 130, appId: "float-me", title: "Tool"
      )
    )
    let snapshot = nextModel.shellSnapshot()

    check snapshot.windows.len == 1
    check snapshot.windows[0].widthProportion == 0.8'f32
    check snapshot.windows[0].heightProportion == 0.6'f32
    check snapshot.windows[0].isFloating
    check snapshot.workspaces[0].masterCount == 2
    check snapshot.workspaces[0].masterSplitRatio == 0.65'f32
    check snapshot.workspaces[0].columns.len == 0

  test "Window rule fixed floating size overrides ratio size":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "fixed-float",
              openFloating: true,
              floating: WindowRuleFloatingConfig(
                widthRatioSet: true,
                widthRatio: 0.25,
                widthSet: true,
                width: 900,
                heightRatioSet: true,
                heightRatio: 0.5,
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 131,
        appId: "fixed-float",
        title: "Tool",
      )
    )
    let win = model.windowData(model.windowForExternal(ExternalWindowId(131))).get()

    check win.isFloating
    check win.floatingGeom.w == 900
    check win.floatingGeom.h == 350

  test "Window rule fixed floating size respects rule bounds":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "bounded-float",
              openFloating: true,
              maxWidthSet: true,
              maxWidth: 700,
              minHeightSet: true,
              minHeight: 500,
              floating: WindowRuleFloatingConfig(
                widthSet: true, width: 900, heightSet: true, height: 420
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 132,
        appId: "bounded-float",
        title: "Tool",
      )
    )
    let win = model.windowData(model.windowForExternal(ExternalWindowId(132))).get()

    check win.isFloating
    check win.floatingGeom.w == 700
    check win.floatingGeom.h == 500

  test "Window rule marks matching windows as shortcut-inhibiting":
    var model = configuredModel()
    let (nextModel, _) = model.update(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 140,
        appId: "qemu-system-x86_64",
        title: "Void",
      )
    )
    let snapshot = nextModel.shellSnapshot()

    check snapshot.windows.len == 1
    check snapshot.windows[0].keyboardShortcutsInhibit

  test "Live restore parser accepts native schema only":
    let native = parseLiveRestoreJson(
      """
{
  "schema": "triad-live-restore-v2",
  "active_tag": 2,
  "focused_window": 10,
  "tags": [
    {"id": 2, "layout_mode": "Deck", "columns": [
      {"windows": [10], "width_proportion": 0.6, "scroller_single_proportion": 0.7, "is_full_width": true}
    ], "split_nodes": [
      {"id": 1, "kind": 1, "parent": 0, "children": [2, 3], "mode": "split-v", "last_split_mode": "split-v", "weight": 1.0, "window": 0},
      {"id": 2, "kind": 0, "parent": 1, "children": [], "mode": 0, "last_split_mode": 0, "weight": 0.5, "window": 10}
    ]}
  ],
  "windows": [
    {"id": 10, "tag_id": 2, "app_id": "term", "manual_floating_position": true},
    {"id": 11, "tag_id": 2, "app_id": "old-term"}
  ]
}
"""
    )
    check native.isSome
    check native.get().activeTag == 2
    check native.get().tags[2].layoutMode == LayoutMode.Deck
    check native.get().tags[2].columns[0].isFullWidth
    check native.get().tags[2].columns[0].scrollerSingleProportion == 0.7'f32
    check native.get().tags[2].splitNodes.len == 2
    check native.get().tags[2].splitNodes[0].mode == SplitTreeNodeMode.SplitV
    check native.get().tags[2].splitNodes[0].children == @[2'u32, 3'u32]
    check native.get().windows[10].appId == "term"
    check native.get().windows[10].manualFloatingPosition
    check not native.get().windows[11].manualFloatingPosition

    let invalid = parseLiveRestoreJson("""{"workspaces":[{"id":1}]}""")
    check invalid.isNone

  test "Live restore JSON preserves split-tree nodes":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("i3"))
    )
    model.applyMsg(Msg(kind: MsgKind.CmdSplitTreeSplitVertical))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))

    let parsed = parseLiveRestoreJson(model.liveRestoreJson())
    check parsed.isSome
    check parsed.get().tags[1].splitNodes.len == 3
    check parsed.get().tags[1].splitNodes.anyIt(it.mode == SplitTreeNodeMode.SplitV)

    let layout = triadLayoutStateJson(model.shellSnapshot())
    let workspace = layout["workspaces"][0]
    check workspace["split_nodes"].len == 3
    check workspace["split_nodes"].getElems().anyIt(it["mode"].getStr() == "split-v")

  test "Niri window event includes focused workspace state":
    var model = configuredModel()
    let (_, effects) = model.update(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 120,
        appId: "alacritty",
        title: "Alacritty",
      )
    )
    let event = effects.filterIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowOpenedOrChanged")
    )[0]
    let win = parseJson(event.jsonPayload)["WindowOpenedOrChanged"]["window"]

    check win["id"].getInt() == 120
    check win["workspace_id"].getInt() == 1
    check win["is_focused"].getBool()

  test "Niri window title update stays incremental":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 120, appId: "alacritty", title: "A")
    )

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowTitle, titleWindowId: 120, updatedTitle: "B")
    )

    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowOpenedOrChanged")
    )
    check not effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowsChanged")
    )
