import tcore_support

suite "Core Runtime Logic: window rules matchers":
  test "Window rules match regex entries with OR and exclude semantics":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^org\\.gimp\\.",
                    titleSet: true,
                    title: "Welcome",
                  ),
                  WindowRuleMatcher(appIdSet: true, appId: "^gimp-tool$"),
                ],
              excludes: @[WindowRuleMatcher(titleSet: true, title: "Private")],
              defaultWorkspace: 4,
              openFloatingSet: true,
              openFloating: true,
            )
          ]
      )
    ).model

    let welcome = model.windowRuleFor("org.gimp.GIMP", "Welcome to GIMP")
    let tool = model.windowRuleFor("gimp-tool", "Toolbox")
    let privateWelcome = model.windowRuleFor("org.gimp.GIMP", "Private Welcome")
    let titleMiss = model.windowRuleFor("org.gimp.GIMP", "Toolbox")

    check welcome.found
    check welcome.rule.defaultSlot == 4
    check welcome.rule.openFloating
    check tool.found
    check tool.rule.defaultSlot == 4
    check not privateWelcome.found
    check not titleMiss.found

  test "Window rule at-startup matcher follows startup phase":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true, appId: "^app$", atStartupSet: true, atStartup: true
                  )
                ],
              defaultWorkspace: 2,
            ),
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true, appId: "^app$", atStartupSet: true, atStartup: false
                  )
                ],
              defaultWorkspace: 3,
            ),
          ],
      )
    ).model

    check model.startupWindowRulesActive
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Early")
    )
    check model.snapshotWindow(1).workspaceIdx == 2

    model.applyMsg(Msg(kind: MsgKind.CmdExpireStartupWindowRules))
    check not model.startupWindowRulesActive
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Late")
    )
    check model.snapshotWindow(2).workspaceIdx == 3

  test "Window rule at-startup matcher refreshes derived state on expiry":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true, appId: "^app$", atStartupSet: true, atStartup: true
                  )
                ],
              keyboardShortcutsInhibitSet: true,
              keyboardShortcutsInhibit: true,
            )
          ]
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Early")
    )
    check model.windowData(WindowId(1)).get().keyboardShortcutsInhibit

    model.applyMsg(Msg(kind: MsgKind.CmdExpireStartupWindowRules))

    check not model.startupWindowRulesActive
    check not model.windowData(WindowId(1)).get().keyboardShortcutsInhibit

  test "Duplicate title and app-id updates are not dirty":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 1))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Same")
    )

    let titleEffects = model.updateModel(
      Msg(kind: MsgKind.WlWindowTitle, titleWindowId: 1, updatedTitle: "Same")
    )
    check titleEffects.len == 0

    let appIdEffects = model.updateModel(
      Msg(kind: MsgKind.WlWindowAppId, appIdWindowId: 1, updatedAppId: "app")
    )
    check appIdEffects.len == 0

  test "Title text changes broadcast without manage dirty by default":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 1))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "A")
    )

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowTitle, titleWindowId: 1, updatedTitle: "B")
    )

    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastWindowChanged and it.broadcastWindowId == 1
    )
    check not effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Title text changes do not force frame-tree manage":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 1))
    ).model
    discard model.updateModel(
      Msg(
        kind: MsgKind.CmdSetNativeLayout,
        nativeLayout: nativeLayoutId(FrameTreeLayoutId),
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "A")
    )

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowTitle, titleWindowId: 1, updatedTitle: "B")
    )

    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastWindowChanged and it.broadcastWindowId == 1
    )
    check not effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Window dimensions update render state without manage dirty":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 1))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "A")
    )

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: 1,
        actualWidth: 800,
        actualHeight: 600,
      )
    )

    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastWindowChanged and it.broadcastWindowId == 1
    )
    check effects.anyIt(it.kind == EffectKind.EffRenderDirty)
    check not effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check not effects.anyIt(it.kind == EffectKind.EffBroadcastTriadJson)
    check not effects.anyIt(it.kind == EffectKind.EffBroadcastJson)

  test "Window rule state matchers use focused and active window state":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              matches: @[WindowRuleMatcher(appIdSet: true, appId: "^two$")],
              defaultWorkspace: 2,
              openFocusedSet: true,
              openFocused: false,
            ),
            WindowRule(
              matches: @[WindowRuleMatcher(isActiveSet: true, isActive: true)],
              minWidthSet: true,
              minWidth: 500,
            ),
            WindowRule(
              matches: @[WindowRuleMatcher(isFocusedSet: true, isFocused: true)],
              minHeightSet: true,
              minHeight: 600,
            ),
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "one", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "two", title: "Two")
    )

    let one = model.windowData(WindowId(1)).get()
    let two = model.windowData(WindowId(2)).get()
    let oneRule = model.windowRuleFor(one)
    let twoRule = model.windowRuleFor(two)

    check oneRule.rule.minWidthSet
    check oneRule.rule.minWidth == 500
    check oneRule.rule.minHeightSet
    check oneRule.rule.minHeight == 600
    check twoRule.rule.minWidthSet
    check twoRule.rule.minWidth == 500
    check not twoRule.rule.minHeightSet
    check one.minWidth == 500
    check one.minHeight == 600
    check two.minWidth == 500
    check two.minHeight == 0

  test "Window rule focused matcher refreshes keyboard inhibition":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true, appId: "^app$", isFocusedSet: true, isFocused: true
                  )
                ],
              keyboardShortcutsInhibitSet: true,
              keyboardShortcutsInhibit: true,
            )
          ]
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    check not model.windowData(WindowId(1)).get().keyboardShortcutsInhibit
    check model.windowData(WindowId(2)).get().keyboardShortcutsInhibit

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))

    check model.windowData(WindowId(1)).get().keyboardShortcutsInhibit
    check not model.windowData(WindowId(2)).get().keyboardShortcutsInhibit

  test "Window rule state matcher can control tiled-state":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^app$",
                    isFloatingSet: true,
                    isFloating: false,
                  )
                ],
              tiledStateSet: true,
              tiledState: true,
            ),
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^app$",
                    isFloatingSet: true,
                    isFloating: true,
                  )
                ],
              tiledStateSet: true,
              tiledState: false,
            ),
          ]
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    let tiled = model.windowData(WindowId(1)).get()
    let tiledRule = model.windowRuleFor(tiled)
    check tiledRule.rule.tiledStateSet
    check tiledRule.rule.tiledState

    discard model.setWindowFloating(WindowId(1), true, model.defaultFloatingGeom())
    let floating = model.windowData(WindowId(1)).get()
    let floatingRule = model.windowRuleFor(floating)
    check floatingRule.rule.tiledStateSet
    check not floatingRule.rule.tiledState

  test "Window rule floating matcher applies dynamic bounds after open":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              matches: @[WindowRuleMatcher(appIdSet: true, appId: "^floaty$")],
              openFloatingSet: true,
              openFloating: true,
            ),
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^floaty$",
                    isFloatingSet: true,
                    isFloating: true,
                  )
                ],
              minWidthSet: true,
              minWidth: 700,
            ),
          ]
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "floaty", title: "Floaty")
    )

    let win = model.windowData(WindowId(1)).get()
    check win.isFloating
    check win.minWidth == 700

  test "Window rule active-in-column matcher distinguishes stacked windows":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^app$",
                    isActiveInColumnSet: true,
                    isActiveInColumn: true,
                  )
                ],
              minWidthSet: true,
              minWidth: 111,
            ),
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^app$",
                    isActiveInColumnSet: true,
                    isActiveInColumn: false,
                  )
                ],
              maxWidthSet: true,
              maxWidth: 222,
            ),
          ]
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdConsumeWindow))

    let active = model.windowData(WindowId(1)).get()
    let stacked = model.windowData(WindowId(2)).get()
    check active.minWidth == 111
    check active.maxWidth == 0
    check stacked.minWidth == 0
    check stacked.maxWidth == 222

  test "Window rule active-in-column remembers focus after leaving column":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^app$",
                    isActiveInColumnSet: true,
                    isActiveInColumn: true,
                  )
                ],
              minWidthSet: true,
              minWidth: 111,
            ),
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^app$",
                    isActiveInColumnSet: true,
                    isActiveInColumn: false,
                  )
                ],
              maxWidthSet: true,
              maxWidth: 222,
            ),
          ]
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three")
    )
    let tagId = model.activeTag
    let firstColumn = model.columnAt(tagId, 0)
    discard model.moveWindowToColumn(tagId, WindowId(2), firstColumn, 1)
    model.focusExternal(2)
    model.focusExternal(3)
    discard model.refreshWindowRuleDerivedState()

    let first = model.windowData(WindowId(1)).get()
    let remembered = model.windowData(WindowId(2)).get()
    let current = model.windowData(WindowId(3)).get()
    check first.minWidth == 0
    check first.maxWidth == 222
    check remembered.minWidth == 111
    check remembered.maxWidth == 0
    check current.minWidth == 111
    check current.maxWidth == 0

  test "Window rule active-in-column falls back from stale column focus":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^app$",
                    isActiveInColumnSet: true,
                    isActiveInColumn: true,
                  )
                ],
              minWidthSet: true,
              minWidth: 111,
            ),
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^app$",
                    isActiveInColumnSet: true,
                    isActiveInColumn: false,
                  )
                ],
              maxWidthSet: true,
              maxWidth: 222,
            ),
          ]
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    let tagId = model.activeTag
    let firstColumn = model.columnAt(tagId, 0)
    discard model.moveWindowToColumn(tagId, WindowId(2), firstColumn, 1)
    model.focusExternal(2)
    discard model.setWindowFloating(WindowId(2), true, model.defaultFloatingGeom())
    discard model.refreshWindowRuleDerivedState()

    var first = model.windowData(WindowId(1)).get()
    var stale = model.windowData(WindowId(2)).get()
    check first.minWidth == 111
    check first.maxWidth == 0
    check stale.minWidth == 0
    check stale.maxWidth == 222

    discard model.setWindowFloating(WindowId(2), false)
    model.focusExternal(2)
    discard model.setWindowMinimized(WindowId(2), true)
    discard model.refreshWindowRuleDerivedState()

    first = model.windowData(WindowId(1)).get()
    stale = model.windowData(WindowId(2)).get()
    check first.minWidth == 111
    check first.maxWidth == 0
    check stale.minWidth == 0
    check stale.maxWidth == 222

    discard model.setWindowMinimized(WindowId(2), false)
    model.focusExternal(2)
    let targetColumn = model.addColumn(tagId)
    discard model.moveWindowToColumn(tagId, WindowId(2), targetColumn, 0)
    discard model.refreshWindowRuleDerivedState()

    first = model.windowData(WindowId(1)).get()
    let moved = model.windowData(WindowId(2)).get()
    check first.minWidth == 111
    check first.maxWidth == 0
    check moved.minWidth == 111
    check moved.maxWidth == 0
