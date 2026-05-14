import tcore_support

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

  test "Workspace focus broadcasts activation and window snapshot":
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
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspaceActivated")
    )
    check not effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspacesChanged")
    )
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

  test "Scratchpad restore returns window to active tag":
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
    check focused[0].workspaceIdx == 2
    model.requireTagShellSemantics("scratchpad restored scenario")

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

    model.applyMsg(Msg(kind: MsgKind.CmdToggleNamedScratchpad, scratchpadName: "files"))

    check model.scratchpadVisible()
    check model.activeScratchpadWindow() == winId
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
    check native.get().windows[10].appId == "term"
    check native.get().windows[10].manualFloatingPosition
    check not native.get().windows[11].manualFloatingPosition

    let invalid = parseLiveRestoreJson("""{"workspaces":[{"id":1}]}""")
    check invalid.isNone

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
