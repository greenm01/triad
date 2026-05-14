import tcore_support

suite "Core Runtime Logic: window rules policy":
  test "Window rule presentation-mode follows focused window":
    var model = initRuntimeStateFromConfig(
      Config(
        presentationMode: PresentationMode.PresentationVsync,
        windowRules:
          @[
            WindowRule(
              appIdMatch: "game",
              presentationModeSet: true,
              presentationMode: PresentationMode.PresentationAsync,
            ),
            WindowRule(
              appIdMatch: "docs",
              presentationModeSet: true,
              presentationMode: PresentationMode.PresentationDefault,
            ),
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "game", title: "Game")
    )
    var policy = model.effectivePresentationMode()
    check policy.hasPreference
    check policy.mode == PresentationMode.PresentationAsync

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "docs", title: "Docs")
    )
    policy = model.effectivePresentationMode()
    check policy.hasPreference
    check policy.mode == PresentationMode.PresentationVsync

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    policy = model.effectivePresentationMode()
    check policy.hasPreference
    check policy.mode == PresentationMode.PresentationAsync

  test "Window rule presentation-mode has no preference without focused match":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              appIdMatch: "game",
              presentationModeSet: true,
              presentationMode: PresentationMode.PresentationAsync,
            )
          ]
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "plain", title: "Plain")
    )
    var policy = model.effectivePresentationMode()
    check not policy.hasPreference

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "game", title: "Game")
    )
    policy = model.effectivePresentationMode()
    check policy.hasPreference
    check policy.mode == PresentationMode.PresentationAsync

  test "Window rule idle-inhibit focused follows active focus":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              appIdMatch: "video",
              idleInhibitModeSet: true,
              idleInhibitMode: WindowRuleIdleInhibitMode.IdleInhibitFocused,
            )
          ]
      )
    ).model

    var effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "video", title: "Video")
    )
    check effects.hasIdleInhibitEffect(true)
    check model.shellSnapshot().windows[0].idleInhibitMode ==
      WindowRuleIdleInhibitMode.IdleInhibitFocused

    effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "docs", title: "Docs")
    )
    check effects.hasIdleInhibitEffect(false)

    effects = model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    check effects.hasIdleInhibitEffect(true)

    effects = model.updateModel(Msg(kind: MsgKind.WlLayerFocusExclusive))
    check effects.hasIdleInhibitEffect(false)

  test "Window rule idle-inhibit visible tracks output-visible workspaces":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "video",
              idleInhibitModeSet: true,
              idleInhibitMode: WindowRuleIdleInhibitMode.IdleInhibitVisible,
            )
          ],
      )
    ).model

    discard model.updateModel(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    discard model.updateModel(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    discard
      model.updateModel(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    var effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "video", title: "Video")
    )
    check effects.hasIdleInhibitEffect(true)

    let secondOutput = model.outputForExternal(ExternalOutputId(2))
    discard model.setOutputTag(secondOutput, model.tagForSlot(2))
    effects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    check not effects.hasIdleInhibitEffect(false)

    effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowMinimizeRequested, minimizeRequestId: 1)
    )
    check effects.hasIdleInhibitEffect(false)

  test "Window rule border uses global defaults without focused match":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          borderWidth: 3,
          focusedBorderColor: 0x112233ff'u32,
          unfocusedBorderColor: 0x445566ff'u32,
        ),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "other",
              border: WindowRuleBorderConfig(widthSet: true, width: 0),
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "plain", title: "Plain")
    )

    let border = model.effectiveWindowBorder(WindowId(1))
    check border.width == 3
    check border.activeColor == 0x112233ff'u32
    check border.inactiveColor == 0x445566ff'u32

  test "Window rule border merges width and colors independently":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          borderWidth: 2,
          focusedBorderColor: 0x111111ff'u32,
          unfocusedBorderColor: 0x222222ff'u32,
        ),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "app",
              border: WindowRuleBorderConfig(
                activeColorSet: true,
                activeColor: 0xabcdef80'u32,
                inactiveColorSet: true,
                inactiveColor: 0x123456ff'u32,
              ),
            ),
            WindowRule(
              appIdMatch: "app",
              titleMatch: "Dialog",
              border: WindowRuleBorderConfig(widthSet: true, width: 6),
            ),
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Dialog")
    )

    let border = model.effectiveWindowBorder(WindowId(1))
    check border.width == 6
    check border.activeColor == 0xabcdef80'u32
    check border.inactiveColor == 0x123456ff'u32

  test "Window rule border width zero disables and later rule can re-enable":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          borderWidth: 2,
          focusedBorderColor: 0x111111ff'u32,
          unfocusedBorderColor: 0x222222ff'u32,
        ),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "app",
              border: WindowRuleBorderConfig(widthSet: true, width: 0),
            ),
            WindowRule(
              appIdMatch: "app",
              titleMatch: "Main",
              border: WindowRuleBorderConfig(widthSet: true, width: 4),
            ),
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Dialog")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Main")
    )

    check model.effectiveWindowBorder(WindowId(1)).width == 0
    check model.effectiveWindowBorder(WindowId(2)).width == 4

  test "Window rule focus-ring overrides only focused border rendering":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          borderWidth: 2,
          focusedBorderColor: 0x111111ff'u32,
          unfocusedBorderColor: 0x222222ff'u32,
        ),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "app",
              border: WindowRuleBorderConfig(
                widthSet: true,
                width: 3,
                activeColorSet: true,
                activeColor: 0x333333ff'u32,
                inactiveColorSet: true,
                inactiveColor: 0x444444ff'u32,
              ),
              focusRing: WindowRuleFocusRingConfig(
                widthSet: true,
                width: 6,
                activeColorSet: true,
                activeColor: 0xabcdef80'u32,
              ),
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "App")
    )

    let unfocused = model.effectiveWindowBorder(WindowId(1), focused = false)
    check unfocused.width == 3
    check unfocused.activeColor == 0x333333ff'u32
    check unfocused.inactiveColor == 0x444444ff'u32

    let focused = model.effectiveWindowBorder(WindowId(1), focused = true)
    check focused.width == 6
    check focused.activeColor == 0xabcdef80'u32
    check focused.inactiveColor == 0x444444ff'u32

  test "Window rule focus-ring can make active-only borders":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          borderWidth: 2,
          focusedBorderColor: 0x111111ff'u32,
          unfocusedBorderColor: 0x222222ff'u32,
        ),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "app",
              border: WindowRuleBorderConfig(widthSet: true, width: 0),
              focusRing: WindowRuleFocusRingConfig(
                widthSet: true,
                width: 4,
                activeColorSet: true,
                activeColor: 0xff8800ff'u32,
              ),
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "App")
    )

    check model.effectiveWindowBorder(WindowId(1), focused = false).width == 0
    let focused = model.effectiveWindowBorder(WindowId(1), focused = true)
    check focused.width == 4
    check focused.activeColor == 0xff8800ff'u32

  test "Window rule focus-ring fields merge independently":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          borderWidth: 2,
          focusedBorderColor: 0x111111ff'u32,
          unfocusedBorderColor: 0x222222ff'u32,
        ),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "app",
              focusRing: WindowRuleFocusRingConfig(
                activeColorSet: true, activeColor: 0xabcdef80'u32
              ),
            ),
            WindowRule(
              appIdMatch: "app",
              titleMatch: "Dialog",
              focusRing: WindowRuleFocusRingConfig(widthSet: true, width: 8),
            ),
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Dialog")
    )

    let focused = model.effectiveWindowBorder(WindowId(1), focused = true)
    check focused.width == 8
    check focused.activeColor == 0xabcdef80'u32

  test "Window rule clip-to-geometry merges as explicit boolean":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(appIdMatch: "app", clipToGeometrySet: true, clipToGeometry: true),
            WindowRule(
              appIdMatch: "app",
              titleMatch: "Dialog",
              clipToGeometrySet: true,
              clipToGeometry: false,
            ),
            WindowRule(
              appIdMatch: "app",
              titleMatch: "Tool",
              clipToGeometrySet: true,
              clipToGeometry: true,
            ),
          ]
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Main")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Dialog")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "other", title: "Other")
    )

    check model.windowClipToGeometry(WindowId(1))
    check not model.windowClipToGeometry(WindowId(2))
    check not model.windowClipToGeometry(WindowId(3))

    let tool = model.windowRuleFor("app", "Tool")
    check tool.found
    check tool.rule.clipToGeometrySet
    check tool.rule.clipToGeometry
