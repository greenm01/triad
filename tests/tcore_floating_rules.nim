import tcore_support

suite "Core Runtime Logic: floating rules":
  test "Parented tool role stays visible outside popup focus tree":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "gimp-tool",
              parentedRole: ParentedRole.Tool,
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
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "gimp", title: "Image")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "gimp-tool",
        title: "Toolbox",
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "terminal", title: "Shell")
    )

    let childId = model.windowForExternal(ExternalWindowId(2))
    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check model.windowData(childId).get().isFloating
    check model.popupRoot(childId) == childId
    check order.contains(2'u32)
    check model.focusedWindowId() == 3

  test "Parented tool role uses rule geometry and preserves manual moves":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "gimp-tool",
              parentedRole: ParentedRole.Tool,
              floating: WindowRuleFloatingConfig(
                xRatioSet: true,
                xRatio: 0.02,
                yRatioSet: true,
                yRatio: 0.08,
                widthRatioSet: true,
                widthRatio: 0.22,
                heightRatioSet: true,
                heightRatio: 0.84,
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "gimp", title: "Image")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "gimp-tool",
        title: "Toolbox",
      )
    )

    let childId = model.windowForExternal(ExternalWindowId(2))
    let initial = model.windowData(childId).get().floatingGeom
    check initial == runtime_values.Rect(x: 20, y: 56, w: 220, h: 588)
    check model.instructionGeom(2) == initial
    check not model.windowData(childId).get().parentAutoFloating
    check model.focusedWindowId() == 2

    model.applyMsg(Msg(kind: MsgKind.CmdMoveFloating, moveDX: 10, moveDY: 20))
    let moved = model.windowData(childId).get().floatingGeom
    check moved.x == initial.x + 10
    check moved.y == initial.y + 20
    check model.instructionGeom(2) == moved

  test "Floating anchor positions unparented float from screen edge":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "pip",
              openFloatingSet: true,
              openFloating: true,
              floating: WindowRuleFloatingConfig(
                widthRatioSet: true,
                widthRatio: 0.20,
                heightRatioSet: true,
                heightRatio: 0.25,
              ),
              defaultFloatingPosition: WindowRuleFloatingPositionConfig(
                set: true, relativeTo: FloatingPositionAnchor.BottomLeft, x: 32, y: 48
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 800)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "pip", title: "PiP")
    )

    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.windowData(winId).get().floatingGeom ==
      runtime_values.Rect(x: 32, y: 552, w: 200, h: 200)

  test "Center floating rule centers unparented generated geometry":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "picker",
              openFloatingSet: true,
              openFloating: true,
              centerFloatingSet: true,
              centerFloating: true,
              floating: WindowRuleFloatingConfig(
                widthSet: true, width: 400, heightSet: true, height: 200
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 800)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "picker", title: "Pick")
    )

    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.windowData(winId).get().floatingGeom ==
      runtime_values.Rect(x: 300, y: 300, w: 400, h: 200)

  test "Floating anchor overrides center floating rule":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "anchored",
              openFloatingSet: true,
              openFloating: true,
              centerFloatingSet: true,
              centerFloating: true,
              floating: WindowRuleFloatingConfig(
                widthSet: true, width: 200, heightSet: true, height: 200
              ),
              defaultFloatingPosition: WindowRuleFloatingPositionConfig(
                set: true, relativeTo: FloatingPositionAnchor.BottomLeft, x: 32, y: 48
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 800)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "anchored", title: "Pick")
    )

    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.windowData(winId).get().floatingGeom ==
      runtime_values.Rect(x: 32, y: 552, w: 200, h: 200)

  test "Respect size hints false disables fixed-size auto floating":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "utility", respectSizeHintsSet: true, respectSizeHints: false
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "utility", title: "Tool")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 1,
        minWidth: 260,
        minHeight: 140,
        maxWidth: 260,
        maxHeight: 140,
      )
    )

    let win = model.windowData(model.windowForExternal(ExternalWindowId(1))).get()
    check not win.isFloating
    check win.clientMinWidth == 260
    check win.minWidth == 0
    check win.maxWidth == 0

  test "Respect size hints false still honors explicit rule bounds":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "bounded-tool",
              openFloatingSet: true,
              openFloating: true,
              respectSizeHintsSet: true,
              respectSizeHints: false,
              minWidthSet: true,
              minWidth: 500,
              maxHeightSet: true,
              maxHeight: 300,
              floating: WindowRuleFloatingConfig(
                widthSet: true, width: 300, heightSet: true, height: 500
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 1, appId: "bounded-tool", title: "Tool"
      )
    )

    let win = model.windowData(model.windowForExternal(ExternalWindowId(1))).get()
    check win.isFloating
    check win.floatingGeom.w == 500
    check win.floatingGeom.h == 300

  test "Single-edge floating anchor centers on the other axis":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "dropdown",
              openFloatingSet: true,
              openFloating: true,
              floating: WindowRuleFloatingConfig(
                widthRatioSet: true,
                widthRatio: 0.50,
                heightRatioSet: true,
                heightRatio: 0.25,
              ),
              defaultFloatingPosition: WindowRuleFloatingPositionConfig(
                set: true, relativeTo: FloatingPositionAnchor.Top, x: 10, y: 20
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 800)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "dropdown", title: "Drop")
    )

    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.windowData(winId).get().floatingGeom ==
      runtime_values.Rect(x: 260, y: 20, w: 500, h: 200)

  test "Dialog parent anchoring ignores default floating position":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "pinentry",
              defaultFloatingPosition: WindowRuleFloatingPositionConfig(
                set: true, relativeTo: FloatingPositionAnchor.BottomRight, x: 0, y: 0
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "editor", title: "Doc")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Dialog",
      )
    )

    let parentGeom = model.instructionGeom(1)
    let childId = model.windowForExternal(ExternalWindowId(2))
    let childGeom = model.windowData(childId).get().floatingGeom
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Toggle floating uses matching rule anchor":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "scratch",
              floating: WindowRuleFloatingConfig(
                widthRatioSet: true,
                widthRatio: 0.25,
                heightRatioSet: true,
                heightRatio: 0.50,
              ),
              defaultFloatingPosition: WindowRuleFloatingPositionConfig(
                set: true, relativeTo: FloatingPositionAnchor.TopRight, x: 25, y: 30
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 800)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 1, appId: "scratch", title: "Scratch"
      )
    )
    model.applyMsg(Msg(kind: MsgKind.CmdToggleFloating))

    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.windowData(winId).get().floatingGeom ==
      runtime_values.Rect(x: 725, y: 30, w: 250, h: 400)

  test "Lead floating startup window anchors same-app main window":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.5),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "gimp",
              titleMatch: "Welcome",
              openFloatingSet: true,
              openFloating: true,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "browser", title: "Docs")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "gimp", title: "Welcome")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        appId: "gimp",
        title: "GNU Image Manipulation Program",
      )
    )

    let workspace = model.shellSnapshot().workspaces[0]
    let leadGeom = model.instructionGeom(2)
    let mainGeom = model.instructionGeom(3)
    check workspace.columns.len == 2
    check workspace.columns[1].windows == @[runtime_values.WindowId(3)]
    check model.focusedWindowId() == 2
    check abs(leadGeom.rectCenter().x - mainGeom.rectCenter().x) <= 1
    check abs(leadGeom.rectCenter().y - mainGeom.rectCenter().y) <= 1

    model.applyMsg(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 2))
    check model.focusedWindowId() == 3

  test "Specific startup floating rule inherits broad app workspace":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.5),
        workspaces: WorkspaceConfig(defaultCount: 4),
        windowRules:
          @[
            WindowRule(appIdMatch: "gimp", defaultWorkspace: 4),
            WindowRule(
              appIdMatch: "gimp",
              titleMatch: "Welcome",
              openFloatingSet: true,
              openFloating: true,
              openFocusedSet: true,
              openFocused: false,
            ),
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "browser", title: "Docs")
    )

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "gimp", title: "Welcome")
    )
    let win = model.snapshotWindow(2)

    check win.isFloating
    check win.workspaceIdx == 4
    check model.focusedWindowId() == 1
    check not effects.hasFocusEffect(2)

  test "Parented tool rule inherits broad app workspace and specific geometry":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
        workspaces: WorkspaceConfig(defaultCount: 4),
        windowRules:
          @[
            WindowRule(appIdMatch: "gimp-tool", defaultWorkspace: 4),
            WindowRule(
              appIdMatch: "gimp-tool",
              titleMatch: "Toolbox",
              parentedRole: ParentedRole.Tool,
              floating: WindowRuleFloatingConfig(
                xRatioSet: true,
                xRatio: 0.02,
                yRatioSet: true,
                yRatio: 0.08,
                widthRatioSet: true,
                widthRatio: 0.22,
                heightRatioSet: true,
                heightRatio: 0.84,
              ),
            ),
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "gimp", title: "Image")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "gimp-tool",
        title: "Toolbox",
      )
    )

    let childId = model.windowForExternal(ExternalWindowId(2))
    let child = model.snapshotWindow(2)
    check child.isFloating
    check child.workspaceIdx == 4
    check model.windowData(childId).get().floatingGeom ==
      runtime_values.Rect(x: 20, y: 56, w: 220, h: 588)

  test "Lead floating startup anchor ignores other apps and existing main windows":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.5),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "gimp",
              titleMatch: "Welcome",
              openFloatingSet: true,
              openFloating: true,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "browser", title: "Docs")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "gimp", title: "Welcome")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "krita", title: "Main")
    )
    check model.shellSnapshot().workspaces[0].columns.len == 2
    check model.shellSnapshot().workspaces[0].columns[1].windows ==
      @[runtime_values.WindowId(3)]

    model.applyMsg(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 3))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        appId: "gimp",
        title: "GNU Image Manipulation Program",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 5,
        appId: "gimp",
        title: "GNU Image Manipulation Program 2",
      )
    )

    let workspace = model.shellSnapshot().workspaces[0]
    check workspace.columns.len == 3
    check workspace.columns[1].windows == @[runtime_values.WindowId(4)]
    check workspace.columns[2].windows == @[runtime_values.WindowId(5)]

  test "Plain parented float ignores parent workspace and anchoring":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[WindowRule(appIdMatch: "utility", parentedRole: ParentedRole.Plain)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 1))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "utility",
        title: "Detached",
      )
    )

    let childId = model.windowForExternal(ExternalWindowId(2))
    let child = model.snapshotWindow(2)
    check child.isFloating
    check child.tagId.isSome and child.tagId.get() == 1
    check child.workspaceIdx == 1
    check model.popupRoot(childId) == childId
    check model.instructionGeom(2) == model.windowData(childId).get().floatingGeom

  test "Open-floating false overrides parented tool role":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "gimp-tool",
              parentedRole: ParentedRole.Tool,
              openFloatingSet: true,
              openFloating: false,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "gimp", title: "Image")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "gimp-tool",
        title: "Toolbox",
      )
    )

    check not model.snapshotWindow(2).isFloating

  test "Dialog rule size preserves parent centered anchoring":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "pinentry",
              floating: WindowRuleFloatingConfig(
                widthRatioSet: true,
                widthRatio: 0.2,
                heightRatioSet: true,
                heightRatio: 0.2,
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Passphrase",
      )
    )

    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(2)
    check childGeom.w == 200
    check childGeom.h == 140
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Explicit default-workspace can override parent workspace":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules: @[WindowRule(appIdMatch: "pinentry", defaultWorkspace: 2)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )

    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    let child = model.snapshotWindow(2)

    check child.tagId.isSome and child.tagId.get() == 2
    check child.workspaceIdx == 2

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowParent, childWindowId: 2, parentWindowId: 1)
    )
    let afterParentEvent = model.snapshotWindow(2)
    check afterParentEvent.tagId.isSome and afterParentEvent.tagId.get() == 2
    check afterParentEvent.workspaceIdx == 2

  test "Fixed-size hint opens normal window as floating":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "dialog", title: "Tool")
    )

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 1,
        minWidth: 260,
        minHeight: 140,
        maxWidth: 260,
        maxHeight: 140,
      )
    )
    discard model.layoutInstructions()

    let winId = model.windowForExternal(ExternalWindowId(1))
    let win = model.windowData(winId).get()
    check win.isFloating
    check win.floatingGeom.w == 260
    check win.floatingGeom.h == 140
    check not model.viewportRetargetRequested(model.activeTag)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastTriadJson and it.triadEventName == "layout"
    )
