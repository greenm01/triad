import tcore_support

suite "Core Runtime Logic: window rules merge":
  test "Window rules merge broad app and specific title rules in order":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              appIdMatch: "gimp",
              defaultWorkspace: 4,
              floating: WindowRuleFloatingConfig(
                xRatioSet: true, xRatio: 0.10, yRatioSet: true, yRatio: 0.20
              ),
            ),
            WindowRule(
              appIdMatch: "gimp",
              titleMatch: "Welcome",
              openFloatingSet: true,
              openFloating: true,
              floating: WindowRuleFloatingConfig(widthRatioSet: true, widthRatio: 0.40),
            ),
          ]
      )
    ).model

    let rule = model.windowRuleFor("gimp", "Welcome to GIMP")
    check rule.found
    check rule.rule.defaultSlot == 4
    check rule.rule.defaultSlots == @[4'u32]
    check rule.rule.openFloatingSet
    check rule.rule.openFloating
    check rule.rule.floating.xRatioSet
    check rule.rule.floating.xRatio == 0.10'f32
    check rule.rule.floating.yRatioSet
    check rule.rule.floating.yRatio == 0.20'f32
    check rule.rule.floating.widthRatioSet
    check rule.rule.floating.widthRatio == 0.40'f32
    check not rule.rule.floating.heightRatioSet

  test "Window rule terminal swallowing replaces host until child closes":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(appIdMatch: "term", terminalSet: true, terminal: true),
            WindowRule(appIdMatch: "app"),
          ],
      )
    ).model
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 1,
        appId: "term",
        title: "Shell",
        createdPid: 100,
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        appId: "app",
        title: "Editor",
        createdSwallowHostWindowId: 1,
        createdPid: 101,
      )
    )

    let host = model.windowForExternal(ExternalWindowId(1))
    let child = model.windowForExternal(ExternalWindowId(2))
    check model.windowData(host).get().isTerminal
    check model.windowData(child).get().allowSwallow
    check model.swallowingWindow(host) == child
    check model.swallowedByWindow(child) == host
    check model.columnHeads(1) == @[2'u32]
    check not model.shellSnapshot().windows.anyIt(uint32(it.id) == 1)
    check model.snapshotWindow(2).swallowedBy == uint32(1)

    model.applyMsg(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 2))

    check model.swallowingWindow(host) == NullWindowId
    check model.columnHeads(1) == @[1'u32]
    check model.focusedWindowId() == 1

  test "Window rule allow-swallow false keeps child tiled beside terminal":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(appIdMatch: "term", terminalSet: true, terminal: true),
            WindowRule(appIdMatch: "app", allowSwallowSet: true, allowSwallow: false),
          ],
      )
    ).model
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 1,
        appId: "term",
        title: "Shell",
        createdPid: 100,
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        appId: "app",
        title: "Editor",
        createdSwallowHostWindowId: 1,
        createdPid: 101,
      )
    )

    let host = model.windowForExternal(ExternalWindowId(1))
    let child = model.windowForExternal(ExternalWindowId(2))
    check not model.windowData(child).get().allowSwallow
    check model.swallowingWindow(host) == NullWindowId
    check model.swallowedByWindow(child) == NullWindowId
    check model.columnHeads(1) == @[1'u32, 2]

  test "Live restore preserves swallowed terminal relation":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(appIdMatch: "term", terminalSet: true, terminal: true),
            WindowRule(appIdMatch: "app"),
          ],
      )
    ).model
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 1,
        appId: "term",
        title: "Shell",
        createdPid: 100,
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        appId: "app",
        title: "Editor",
        createdSwallowHostWindowId: 1,
        createdPid: 101,
      )
    )

    let hostJson = model.restoreWindowJson(1)
    check hostJson["is_terminal"].getBool()
    check hostJson["pid"].getInt() == 100
    check hostJson["swallowing"].getInt() == 2

    var restored = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(appIdMatch: "term", terminalSet: true, terminal: true),
            WindowRule(appIdMatch: "app"),
          ],
      )
    ).model
    let state = parseLiveRestoreJson(model.liveRestoreJson()).get()
    restored.applyLiveRestore(state.pendingRestoreState())
    restored.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 1,
        appId: "term",
        title: "Shell",
        createdPid: 100,
      )
    )
    restored.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        appId: "app",
        title: "Editor",
        createdPid: 101,
      )
    )

    let restoredHost = restored.windowForExternal(ExternalWindowId(1))
    let restoredChild = restored.windowForExternal(ExternalWindowId(2))
    check restored.swallowingWindow(restoredHost) == restoredChild
    check restored.swallowedByWindow(restoredChild) == restoredHost
    check restored.columnHeads(1) == @[2'u32]

  test "Window rules let later workspace target lists override earlier lists":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(appIdMatch: "app", defaultWorkspaces: @[2'u32, 4'u32]),
            WindowRule(appIdMatch: "app", titleMatch: "Single", defaultWorkspace: 3),
            WindowRule(
              appIdMatch: "app", titleMatch: "Multi", defaultWorkspaces: @[5'u32, 2'u32]
            ),
          ]
      )
    ).model

    let broad = model.windowRuleFor("app", "Other")
    let single = model.windowRuleFor("app", "Single")
    let multi = model.windowRuleFor("app", "Multi")

    check broad.found
    check broad.rule.defaultSlot == 2
    check broad.rule.defaultSlots == @[2'u32, 4'u32]
    check single.found
    check single.rule.defaultSlot == 3
    check single.rule.defaultSlots == @[3'u32]
    check multi.found
    check multi.rule.defaultSlot == 5
    check multi.rule.defaultSlots == @[5'u32, 2'u32]

  test "Window rules merge broad floating size and specific anchor":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              appIdMatch: "dropdown",
              floating: WindowRuleFloatingConfig(widthRatioSet: true, widthRatio: 0.80),
            ),
            WindowRule(
              appIdMatch: "dropdown",
              titleMatch: "Top",
              defaultFloatingPosition: WindowRuleFloatingPositionConfig(
                set: true, relativeTo: FloatingPositionAnchor.Top, x: 10, y: 20
              ),
            ),
          ]
      )
    ).model

    let rule = model.windowRuleFor("dropdown", "Top Terminal")
    check rule.found
    check rule.rule.floating.widthRatioSet
    check rule.rule.floating.widthRatio == 0.80'f32
    check rule.rule.defaultFloatingPosition.set
    check rule.rule.defaultFloatingPosition.relativeTo == FloatingPositionAnchor.Top
    check rule.rule.defaultFloatingPosition.x == 10
    check rule.rule.defaultFloatingPosition.y == 20

  test "Window rules let later explicit fields override earlier matches":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              appIdMatch: "pinentry",
              openFloating: true,
              openFullscreen: true,
              openMaximized: true,
              openMaximizedToEdges: true,
              openOverlay: true,
              maximizePolicySet: true,
              maximizePolicy: WindowRuleMaximizePolicy.Ignore,
              respectSizeHintsSet: true,
              respectSizeHints: false,
              centerFloatingSet: true,
              centerFloating: true,
              parentedRole: ParentedRole.Tool,
              dialogViewportJump: true,
              keyboardShortcutsInhibit: true,
              presentationModeSet: true,
              presentationMode: PresentationMode.PresentationAsync,
              border: WindowRuleBorderConfig(
                widthSet: true,
                width: 7,
                activeColorSet: true,
                activeColor: 0xff0000ff'u32,
              ),
              focusRing: WindowRuleFocusRingConfig(
                widthSet: true,
                width: 8,
                activeColorSet: true,
                activeColor: 0x0000ffff'u32,
              ),
              clipToGeometrySet: true,
              clipToGeometry: true,
              tiledState: true,
            ),
            WindowRule(
              appIdMatch: "pinentry",
              titleMatch: "Passphrase",
              openFloatingSet: true,
              openFloating: false,
              openFullscreenSet: true,
              openFullscreen: false,
              openMaximizedSet: true,
              openMaximized: false,
              openMaximizedToEdgesSet: true,
              openMaximizedToEdges: false,
              openOverlaySet: true,
              openOverlay: false,
              maximizePolicySet: true,
              maximizePolicy: WindowRuleMaximizePolicy.Edge,
              respectSizeHintsSet: true,
              respectSizeHints: true,
              centerFloatingSet: true,
              centerFloating: false,
              parentedRoleSet: true,
              parentedRole: ParentedRole.Dialog,
              dialogViewportJumpSet: true,
              dialogViewportJump: false,
              keyboardShortcutsInhibitSet: true,
              keyboardShortcutsInhibit: false,
              idleInhibitModeSet: true,
              idleInhibitMode: WindowRuleIdleInhibitMode.IdleInhibitNone,
              presentationModeSet: true,
              presentationMode: PresentationMode.PresentationDefault,
              border: WindowRuleBorderConfig(
                widthSet: true,
                width: 0,
                inactiveColorSet: true,
                inactiveColor: 0x00ff00ff'u32,
              ),
              focusRing: WindowRuleFocusRingConfig(widthSet: true, width: 9),
              clipToGeometrySet: true,
              clipToGeometry: false,
              tiledStateSet: true,
              tiledState: false,
            ),
          ]
      )
    ).model

    let rule = model.windowRuleFor("pinentry", "Passphrase")
    check rule.found
    check rule.rule.openFloatingSet
    check not rule.rule.openFloating
    check rule.rule.openFullscreenSet
    check not rule.rule.openFullscreen
    check rule.rule.openMaximizedSet
    check not rule.rule.openMaximized
    check rule.rule.openMaximizedToEdgesSet
    check not rule.rule.openMaximizedToEdges
    check rule.rule.openOverlaySet
    check not rule.rule.openOverlay
    check rule.rule.maximizePolicySet
    check rule.rule.maximizePolicy == WindowRuleMaximizePolicy.Edge
    check rule.rule.respectSizeHintsSet
    check rule.rule.respectSizeHints
    check rule.rule.centerFloatingSet
    check not rule.rule.centerFloating
    check rule.rule.parentedRole == ParentedRole.Dialog
    check not rule.rule.dialogViewportJump
    check not rule.rule.keyboardShortcutsInhibit
    check rule.rule.idleInhibitMode == WindowRuleIdleInhibitMode.IdleInhibitNone
    check rule.rule.presentationModeSet
    check rule.rule.presentationMode == PresentationMode.PresentationDefault
    check rule.rule.border.widthSet
    check rule.rule.border.width == 0
    check rule.rule.border.activeColorSet
    check rule.rule.border.activeColor == 0xff0000ff'u32
    check rule.rule.border.inactiveColorSet
    check rule.rule.border.inactiveColor == 0x00ff00ff'u32
    check rule.rule.focusRing.widthSet
    check rule.rule.focusRing.width == 9
    check rule.rule.focusRing.activeColorSet
    check rule.rule.focusRing.activeColor == 0x0000ffff'u32
    check rule.rule.clipToGeometrySet
    check not rule.rule.clipToGeometry
    check rule.rule.tiledStateSet
    check not rule.rule.tiledState
