import tcore_support

suite "Core Runtime Logic: window rules placement":
  test "Window rule workspace placement is layout agnostic":
    for mode in [
      LayoutMode.Scroller, LayoutMode.VerticalScroller, LayoutMode.MasterStack,
      LayoutMode.Grid, LayoutMode.Monocle, LayoutMode.Deck, LayoutMode.CenterTile,
      LayoutMode.RightTile, LayoutMode.VerticalTile, LayoutMode.VerticalGrid,
      LayoutMode.VerticalDeck, LayoutMode.TGMix,
    ]:
      var model = initRuntimeStateFromConfig(
        Config(
          workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: mode),
          windowRules:
            @[
              WindowRule(
                appIdMatch: "target",
                defaultWorkspace: 2,
                openFocusedSet: true,
                openFocused: false,
              )
            ],
        )
      ).model
      model.applyMsg(
        Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
      )
      model.applyMsg(
        Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
      )
      let effects = model.updateModel(
        Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "target", title: "Two")
      )
      let snapshot = model.shellSnapshot()

      check snapshot.activeTag == 1
      check model.focusedWindowId() == 1
      check model.activeWorkspaceFocusId() == 1
      check snapshot.workspaces[1].focusedWindow == 2
      check not effects.hasFocusEffect(2)

  test "Window rule multi-workspace placement uses tag-mask placements":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 4, defaultLayout: LayoutMode.Scroller),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "target",
              defaultWorkspaces: @[2'u32, 4'u32],
              defaultColumnWidthSet: true,
              defaultColumnWidth: 0.60,
              openMaximizedSet: true,
              openMaximized: true,
              openFocusedSet: true,
              openFocused: false,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "target", title: "Two")
    )
    let winId = model.windowForExternal(ExternalWindowId(2))
    let tag2 = model.tagForSlot(2)
    let tag4 = model.tagForSlot(4)
    let mask = model.windowTags[winId]
    let tag2Column = model.placementForWindowOnTag(tag2, winId).get().columnId
    let tag4Column = model.placementForWindowOnTag(tag4, winId).get().columnId

    check model.snapshotWindow(2).workspaceIdx == 2
    check model.placementForWindowOnTag(tag2, winId).isSome
    check model.placementForWindowOnTag(tag4, winId).isSome
    check mask.contains(model.tagData(tag2).get().bit)
    check mask.contains(model.tagData(tag4).get().bit)
    check model.columnData(tag2Column).get().widthProportion == 0.60'f32
    check model.columnData(tag4Column).get().widthProportion == 0.60'f32
    check model.columnData(tag2Column).get().isFullWidth
    check model.columnData(tag4Column).get().isFullWidth
    check model.tagData(tag2).get().focusedWindow == winId
    check model.tagData(tag4).get().focusedWindow == winId
    check model.activeTag == model.tagForSlot(1)
    check model.focusedWindowId() == 1
    check not effects.hasFocusEffect(2)

  test "Window rule secondary active workspace placement does not steal focus":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "target",
              defaultWorkspaces: @[2'u32, 1'u32],
              openFocusedSet: true,
              openFocused: false,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    let beforeViewport = model.viewport(1)

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "target", title: "Two")
    )
    let winId = model.windowForExternal(ExternalWindowId(2))

    check model.placementForWindowOnTag(model.tagForSlot(2), winId).isSome
    check model.placementForWindowOnTag(model.tagForSlot(1), winId).isSome
    check model.activeTag == model.tagForSlot(1)
    check model.focusedWindowId() == 1
    check model.viewport(1) == beforeViewport
    check not effects.hasFocusEffect(2)

  test "Window rule opening sizing sets initial column and window proportions":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          defaultColumnWidth: 0.5, defaultWindowWidth: 0.5, defaultWindowHeight: 1.0
        ),
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Scroller),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "sized",
              defaultColumnWidthSet: true,
              defaultColumnWidth: 0.65,
              defaultWindowWidthSet: true,
              defaultWindowWidth: 0.75,
              defaultWindowHeightSet: true,
              defaultWindowHeight: 0.85,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "sized", title: "Main")
    )
    let placement =
      model.firstWindowPosition(model.windowForExternal(ExternalWindowId(2)))
    let win = model.snapshotWindow(2)

    check placement.found
    let columnId = model.columnAt(placement.tagId, int(placement.colIdx) - 1)
    check model.columnData(columnId).get().widthProportion == 0.65'f32
    check win.widthProportion == 0.75'f32
    check win.heightProportion == 0.85'f32

  test "Scroller window rule proportion overrides default column width":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          defaultColumnWidth: 0.4, defaultWindowWidth: 0.5, defaultWindowHeight: 1.0
        ),
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Scroller),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "sized",
              defaultColumnWidthSet: true,
              defaultColumnWidth: 0.30,
              scrollerProportionSet: true,
              scrollerProportion: 0.65,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "sized", title: "Main")
    )
    let placement =
      model.firstWindowPosition(model.windowForExternal(ExternalWindowId(2)))
    let columnId = model.columnAt(placement.tagId, int(placement.colIdx) - 1)

    check placement.found
    check model.columnData(columnId).get().widthProportion == 0.65'f32

  test "Scroller single proportion centers only a single horizontal column":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          defaultColumnWidth: 0.4, defaultWindowWidth: 0.5, defaultWindowHeight: 1.0
        ),
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Scroller),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "single",
              scrollerSingleProportionSet: true,
              scrollerSingleProportion: 0.8,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "single", title: "Main")
    )
    let singleGeom = model.instructionGeom(2)
    check singleGeom.x == 100
    check singleGeom.w == 800
    check singleGeom.y == 0
    check singleGeom.h == 700

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "plain", title: "Second")
    )
    let multiGeom = model.instructionGeom(2)
    check multiGeom.x == 0
    check multiGeom.w == 400

  test "Scroller single proportion centers only a single vertical column":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          defaultColumnWidth: 0.4, defaultWindowWidth: 0.5, defaultWindowHeight: 1.0
        ),
        workspaces:
          WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.VerticalScroller),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "single",
              scrollerSingleProportionSet: true,
              scrollerSingleProportion: 0.5,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "single", title: "Main")
    )
    let geom = model.instructionGeom(2)

    check geom.x == 0
    check geom.w == 1000
    check geom.y == 175
    check geom.h == 350

  test "Window rule opening sizing fields merge independently":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          defaultColumnWidth: 0.5, defaultWindowWidth: 0.5, defaultWindowHeight: 1.0
        ),
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Scroller),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "sized",
              defaultColumnWidthSet: true,
              defaultColumnWidth: 0.60,
              defaultWindowWidthSet: true,
              defaultWindowWidth: 0.70,
            ),
            WindowRule(
              appIdMatch: "sized",
              titleMatch: "Tall",
              defaultWindowHeightSet: true,
              defaultWindowHeight: 0.80,
            ),
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "sized", title: "Tall")
    )
    let placement =
      model.firstWindowPosition(model.windowForExternal(ExternalWindowId(2)))
    let win = model.snapshotWindow(2)

    check placement.found
    let columnId = model.columnAt(placement.tagId, int(placement.colIdx) - 1)
    check model.columnData(columnId).get().widthProportion == 0.60'f32
    check win.widthProportion == 0.70'f32
    check win.heightProportion == 0.80'f32

  test "Window rule opening sizing coexists with presentation states":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Scroller),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "video",
              defaultColumnWidthSet: true,
              defaultColumnWidth: 0.40,
              defaultWindowWidthSet: true,
              defaultWindowWidth: 0.70,
              defaultWindowHeightSet: true,
              defaultWindowHeight: 0.60,
              openFullscreenSet: true,
              openFullscreen: true,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "video", title: "Main")
    )
    let win = model.snapshotWindow(2)

    check win.isFullscreen
    check win.widthProportion == 0.70'f32
    check win.heightProportion == 0.60'f32

  test "Window rule size bounds apply on create and merge with client hints":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "bounded",
              minWidthSet: true,
              minWidth: 640,
              maxHeightSet: true,
              maxHeight: 600,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "bounded", title: "Main")
    )
    var win = model.windowData(model.windowForExternal(ExternalWindowId(2))).get()
    check win.clientMinWidth == 0
    check win.minWidth == 640
    check win.maxHeight == 600

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 2,
        minWidth: 300,
        minHeight: 200,
        maxWidth: 900,
        maxHeight: 500,
      )
    )
    win = model.windowData(model.windowForExternal(ExternalWindowId(2))).get()

    check win.clientMinWidth == 300
    check win.clientMinHeight == 200
    check win.clientMaxWidth == 900
    check win.clientMaxHeight == 500
    check win.minWidth == 640
    check win.minHeight == 200
    check win.maxWidth == 900
    check win.maxHeight == 600

  test "Window rule size bounds re-evaluate on title changes":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(appIdMatch: "bounded", minWidthSet: true, minWidth: 500),
            WindowRule(
              appIdMatch: "bounded",
              titleMatch: "Small",
              minWidthSet: true,
              minWidth: 0,
              maxWidthSet: true,
              maxWidth: 900,
            ),
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "bounded", title: "Main")
    )
    var win = model.windowData(model.windowForExternal(ExternalWindowId(2))).get()
    check win.minWidth == 500
    check win.maxWidth == 0

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowTitle, titleWindowId: 2, updatedTitle: "Small Dialog")
    )
    win = model.windowData(model.windowForExternal(ExternalWindowId(2))).get()
    check win.minWidth == 0
    check win.maxWidth == 900

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowTitle, titleWindowId: 2, updatedTitle: "Main")
    )
    win = model.windowData(model.windowForExternal(ExternalWindowId(2))).get()
    check win.minWidth == 500
    check win.maxWidth == 0

  test "Window rule size bounds re-evaluate on app id changes":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[WindowRule(appIdMatch: "bounded", minHeightSet: true, minHeight: 400)],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "plain", title: "Main")
    )
    check model.windowData(model.windowForExternal(ExternalWindowId(2))).get().minHeight ==
      0

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowAppId, appIdWindowId: 2, updatedAppId: "bounded")
    )
    check model.windowData(model.windowForExternal(ExternalWindowId(2))).get().minHeight ==
      400

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowAppId, appIdWindowId: 2, updatedAppId: "plain")
    )
    check model.windowData(model.windowForExternal(ExternalWindowId(2))).get().minHeight ==
      0

  test "Config reload re-evaluates window rule size bounds":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[WindowRule(appIdMatch: "bounded", minWidthSet: true, minWidth: 500)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "bounded", title: "Main")
    )
    check model.windowData(model.windowForExternal(ExternalWindowId(2))).get().minWidth ==
      500

    model.applyConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[WindowRule(appIdMatch: "bounded", maxWidthSet: true, maxWidth: 700)],
      )
    )
    let win = model.windowData(model.windowForExternal(ExternalWindowId(2))).get()
    check win.minWidth == 0
    check win.maxWidth == 700

  test "Window rule fixed size bounds do not force floating":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "fixed-rule",
              minWidthSet: true,
              minWidth: 260,
              minHeightSet: true,
              minHeight: 140,
              maxWidthSet: true,
              maxWidth: 260,
              maxHeightSet: true,
              maxHeight: 140,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 2, appId: "fixed-rule", title: "Main"
      )
    )

    let win = model.windowData(model.windowForExternal(ExternalWindowId(2))).get()
    check win.minWidth == 260
    check not win.isFloating

  test "Client fixed size hints still force floating with rule bounds":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[WindowRule(appIdMatch: "fixed-client", maxWidthSet: true, maxWidth: 500)],
      )
    ).model
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 2, appId: "fixed-client", title: "Main"
      )
    )

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 2,
        minWidth: 260,
        minHeight: 140,
        maxWidth: 260,
        maxHeight: 140,
      )
    )
    let win = model.windowData(model.windowForExternal(ExternalWindowId(2))).get()
    check win.isFloating
    check win.maxWidth == 500

  test "Window rule open-on-output targets the visible workspace on that output":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              openOnOutput: "hdmi-a-1",
              openFocusedSet: true,
              openFocused: false,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(2)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    check model.snapshotWindow(3).workspaceIdx == 2
    check model.activeTag == model.tagForSlot(1)
    check model.focusedWindowId() == 0
    check not effects.hasFocusEffect(3)
