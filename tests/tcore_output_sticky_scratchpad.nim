import tcore_support

suite "Core Runtime Logic: output sticky scratchpad":
  test "Output identity events store make model and description":
    var model = initRuntimeStateFromConfig(Config()).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputIdentity,
        identityOutputId: 2,
        outputMake: "Dell Inc.",
        outputModel: "DELL U2720Q",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputDescription,
        descriptionOutputId: 2,
        outputDescription: "Dell Inc. 27 inch",
      )
    )

    let output = model.outputData(model.outputForExternal(ExternalOutputId(2))).get()
    check output.make == "Dell Inc."
    check output.model == "DELL U2720Q"
    check output.description == "Dell Inc. 27 inch"

  test "Workspace rules pin workspace home output after output appears":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        tagRules: @[TagRule(tagId: 2, openOnOutput: "HDMI-A-1")],
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

    let tagId = model.tagForSlot(2)
    let outputId = model.outputForExternal(ExternalOutputId(2))
    check model.workspaceOutput(tagId) == outputId
    check model.tagHomeOutputTargets[tagId] == "HDMI-A-1"

  test "Output rules pin workspace home output after output appears":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules: @[OutputRule(target: "HDMI-A-1", workspaceSlots: @[2'u32])],
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

    let tagId = model.tagForSlot(2)
    let outputId = model.outputForExternal(ExternalOutputId(2))
    check model.workspaceOutput(tagId) == outputId
    check model.tagHomeOutputTargets[tagId] == "HDMI-A-1"

  test "Workspace rules override output rule workspace affinity":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules: @[OutputRule(target: "HDMI-A-1", workspaceSlots: @[2'u32])],
        tagRules: @[TagRule(tagId: 2, openOnOutput: "DP-1")],
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
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 900, height: 600)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-1"))

    let tagId = model.tagForSlot(2)
    let outputId = model.outputForExternal(ExternalOutputId(3))
    check model.workspaceOutput(tagId) == outputId
    check model.tagHomeOutputTargets[tagId] == "DP-1"

  test "Output focus-at-startup focuses configured output once":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules:
          @[
            OutputRule(
              target: "HDMI-A-1", focusAtStartup: true, workspaceSlots: @[2'u32]
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

    let outputId = model.outputForExternal(ExternalOutputId(2))
    check model.outputStartupFocusResolved
    check model.activeOutput == outputId
    check model.activeSlot == 2

  test "Output focus-at-startup does not run on config reload":
    var state =
      initRuntimeStateFromConfig(Config(workspaces: WorkspaceConfig(defaultCount: 3)))
    state.model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    state.model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "eDP-1")
    )
    state.model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    state.model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    let originalOutput = state.model.activeOutput

    discard state.applyRuntimeConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules: @[OutputRule(target: "HDMI-A-1", focusAtStartup: true)],
      )
    )

    check state.model.outputStartupFocusResolved
    check state.model.activeOutput == originalOutput

  test "Output commands focus and move active workspace by target":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputPosition, positionOutputId: 1, outputX: 0, outputY: 0)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "HDMI-A-1")
    )

    let outputId = model.outputForExternal(ExternalOutputId(2))
    check model.activeOutput == outputId
    check model.workspaceOutput(model.tagForSlot(2)) == outputId
    check model.outputTags[outputId] == model.tagForSlot(2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusOutput, outputTarget: "left"))
    check model.activeOutput == model.outputForExternal(ExternalOutputId(1))

  test "Moved workspace restores to reconnected output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
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
    model.applyMsg(
      Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "HDMI-A-1")
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: 2))

    check model.workspaceOutput(model.tagForSlot(2)) == model.primaryOutput

    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )

    let outputId = model.outputForExternal(ExternalOutputId(2))
    check model.workspaceOutput(model.tagForSlot(2)) == outputId
    check model.outputTags[outputId] == model.tagForSlot(2)

  test "Window rule open-on-output matches stable output identity":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              openOnOutput: "Dell Inc. DELL U2720Q Unknown",
              openFocusedSet: true,
              openFocused: false,
            ),
            WindowRule(
              appIdMatch: "docs",
              openOnOutput: "benq pd3220u",
              openFocusedSet: true,
              openFocused: false,
            ),
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
      Msg(
        kind: MsgKind.WlOutputIdentity,
        identityOutputId: 2,
        outputMake: "Dell Inc.",
        outputModel: "DELL U2720Q",
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 900, height: 700)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputDescription,
        descriptionOutputId: 3,
        outputDescription: "BenQ PD3220U",
      )
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(2)
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(3)), model.tagForSlot(3)
    )

    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 4, appId: "chat"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 5, appId: "docs"))

    check model.snapshotWindow(4).workspaceIdx == 2
    check model.snapshotWindow(5).workspaceIdx == 3

  test "Window rule open-on-output ignores unknown-only identity":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              openOnOutput: "Unknown Unknown Unknown",
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
      Msg(
        kind: MsgKind.WlOutputIdentity,
        identityOutputId: 2,
        outputMake: "Unknown",
        outputModel: "Unknown",
      )
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(2)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    check model.snapshotWindow(3).workspaceIdx == 1

  test "Window rule open-on-output falls back when output is unknown":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules: @[WindowRule(appIdMatch: "chat", openOnOutput: "missing")],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    check model.snapshotWindow(3).workspaceIdx == 1

  test "Window rule default workspace remaps safe open-on-output":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              defaultWorkspace: 3,
              openOnOutput: "HDMI-A-1",
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

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    check model.snapshotWindow(3).workspaceIdx == 3
    check model.workspaceOutput(model.tagForSlot(3)) ==
      model.outputForExternal(ExternalOutputId(2))
    check model.activeTag == model.tagForSlot(1)

  test "Window rule output remap moves workspace between non-primary outputs":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 4),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              defaultWorkspace: 3,
              openOnOutput: "DP-2",
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
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-2"))
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(3)
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(3)), model.tagForSlot(2)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    let hdmi = model.outputForExternal(ExternalOutputId(2))
    let dp = model.outputForExternal(ExternalOutputId(3))
    check model.snapshotWindow(3).workspaceIdx == 3
    check model.workspaceOutput(model.tagForSlot(3)) == dp
    check model.outputTags[dp] == model.tagForSlot(3)
    check model.outputTags.getOrDefault(hdmi, NullTagId) != model.tagForSlot(3)

  test "Window rule output remap does not change active primary workspace":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              defaultWorkspace: 2,
              openOnOutput: "eDP-1",
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
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "eDP-1")
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    check model.snapshotWindow(3).workspaceIdx == 2
    check model.activeTag == model.tagForSlot(1)
    check model.outputTags[model.primaryOutput] == model.tagForSlot(1)

  test "Parented windows do not remap outputs for workspace rules":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "dialog",
              defaultWorkspace: 3,
              openOnOutput: "HDMI-A-1",
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
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(2)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "parent", title: "Main")
    )

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 11,
        createdParentWindowId: 10,
        appId: "dialog",
        title: "Dialog",
      )
    )

    check model.snapshotWindow(11).workspaceIdx == 3
    check model.outputTags[model.outputForExternal(ExternalOutputId(2))] ==
      model.tagForSlot(2)

  test "Live restore state wins over opening sizing and output rules":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "generic-app",
              defaultWorkspaces: @[2'u32, 3'u32],
              openOnOutput: "HDMI-A-1",
              defaultColumnWidthSet: true,
              defaultColumnWidth: 0.30,
              defaultWindowWidthSet: true,
              defaultWindowWidth: 0.40,
              defaultWindowHeightSet: true,
              defaultWindowHeight: 0.50,
              openNamedScratchpad: "files",
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
    var restore = PendingRestoreState(activeSlot: 1)
    restore.addRestoredWindow(ExternalWindowId(50), 1, "generic-app", "Old title")
    model.applyLiveRestore(restore)

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 50,
        appId: "generic-app",
        title: "Old title",
      )
    )
    let placement =
      model.firstWindowPosition(model.windowForExternal(ExternalWindowId(50)))
    let win = model.snapshotWindow(50)

    check win.workspaceIdx == 1
    check win.widthProportion == 0.8'f32
    check win.heightProportion == 0.6'f32
    check model.scratchpadWindowCount() == 0
    check model.namedScratchpadWindow("files") == NullWindowId
    check placement.found
    check model.placementForWindowOnTag(
      model.tagForSlot(3), model.windowForExternal(ExternalWindowId(50))
    ).isNone
    let columnId = model.columnAt(placement.tagId, int(placement.colIdx) - 1)
    check model.columnData(columnId).get().widthProportion == 0.7'f32

  test "Window rule open-on-all-workspaces places sticky windows everywhere":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "status",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 20, appId: "status", title: "bar")
    )
    let winId = model.windowForExternal(ExternalWindowId(20))

    check model.windowData(winId).get().isSticky
    for slot in 1'u32 .. 3'u32:
      check model.placementForWindowOnTag(model.tagForSlot(slot), winId).isSome
    for workspace in model.shellSnapshot().workspaces:
      check not workspace.occupied

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    check model.activeWorkspaceFocusId() == 20
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 21, appId: "local", title: "main")
    )
    check model.activeWorkspaceFocusId() == 21

  test "Window rule open-on-all-workspaces obeys later explicit false":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "app", openOnAllWorkspacesSet: true, openOnAllWorkspaces: true
            ),
            WindowRule(
              appIdMatch: "app",
              titleMatch: "single",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: false,
            ),
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 22, appId: "app", title: "single")
    )
    let winId = model.windowForExternal(ExternalWindowId(22))

    check not model.windowData(winId).get().isSticky
    check model.placementForWindowOnTag(model.tagForSlot(1), winId).isSome
    check model.placementForWindowOnTag(model.tagForSlot(2), winId).isNone

  test "Window rule open-overlay creates managed overlay without floating":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules: @[WindowRule(appIdMatch: "hud", openOverlay: true)],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 30, appId: "hud", title: "HUD")
    )
    let winId = model.windowForExternal(ExternalWindowId(30))
    let win = model.windowData(winId).get()
    let snapshot = model.shellSnapshot()
    let shellWin = snapshotWindow(model, 30)
    let stateJson = triadStateJson(snapshot)

    check win.isOverlay
    check not win.isFloating
    check shellWin.isOverlay
    check stateJson["windows"][0]["is_overlay"].getBool()

  test "Window rule open-overlay refreshes on dynamic rule changes":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 1))
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 31, appId: "panel", title: "Main")
    )
    let winId = model.windowForExternal(ExternalWindowId(31))
    check not model.windowData(winId).get().isOverlay

    model.applyConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 1),
        windowRules: @[WindowRule(appIdMatch: "panel", openOverlay: true)],
      )
    )
    check model.windowData(winId).get().isOverlay

    model.applyConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 1),
        windowRules:
          @[
            WindowRule(appIdMatch: "panel", openOverlay: true),
            WindowRule(
              appIdMatch: "panel",
              titleMatch: "Main",
              openOverlaySet: true,
              openOverlay: false,
            ),
          ],
      )
    )
    check not model.windowData(winId).get().isOverlay

  test "Overlay render order is above normal managed windows":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 1),
        windowRules: @[WindowRule(appIdMatch: "hud", openOverlay: true)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 32, appId: "term", title: "A")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 33, appId: "hud", title: "HUD")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 34, appId: "term", title: "B")
    )

    var daemon = initTriadDaemon()
    daemon.runtimeState.model = model
    daemon.recordDesiredPlacement(
      RenderInstruction(windowId: 32, geom: Rect(x: 0, y: 0, w: 100, h: 100))
    )
    daemon.recordDesiredPlacement(
      RenderInstruction(windowId: 33, geom: Rect(x: 0, y: 0, w: 100, h: 100))
    )
    daemon.recordDesiredPlacement(
      RenderInstruction(windowId: 34, geom: Rect(x: 0, y: 0, w: 100, h: 100))
    )
    let order = daemon.orderedDesiredInstructions().mapIt(uint32(it.windowId))

    check order[^1] == 33'u32

  test "Sticky windows sync to dynamic workspaces without pinning them occupied":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 1),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "status",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 23, appId: "status", title: "bar")
    )
    let winId = model.windowForExternal(ExternalWindowId(23))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 4))

    check model.tagForSlot(4) != NullTagId
    check model.placementForWindowOnTag(model.tagForSlot(4), winId).isSome
    check model.activeWorkspaceFocusId() == 23

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 1))
    discard model.pruneDynamicWorkspaces()
    check model.tagForSlot(4) == NullTagId

  test "Parented dialog sticky rules require plain parented role":
    var dialogModel = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "child",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model
    dialogModel.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 24, appId: "parent", title: "main")
    )
    dialogModel.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 25,
        createdParentWindowId: 24,
        appId: "child",
        title: "dialog",
      )
    )
    let dialogId = dialogModel.windowForExternal(ExternalWindowId(25))
    check not dialogModel.windowData(dialogId).get().isSticky
    check dialogModel.placementForWindowOnTag(dialogModel.tagForSlot(2), dialogId).isNone

    var plainModel = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "child",
              parentedRoleSet: true,
              parentedRole: ParentedRole.Plain,
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model
    plainModel.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 26, appId: "parent", title: "main")
    )
    plainModel.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 27,
        createdParentWindowId: 26,
        appId: "child",
        title: "plain",
      )
    )
    let plainId = plainModel.windowForExternal(ExternalWindowId(27))
    check plainModel.windowData(plainId).get().isSticky
    check plainModel.placementForWindowOnTag(plainModel.tagForSlot(2), plainId).isSome

  test "Scratchpad clears sticky state and restores previous tag set":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "status",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 28, appId: "status", title: "bar")
    )
    let winId = model.windowForExternal(ExternalWindowId(28))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))

    check not model.windowData(winId).get().isSticky
    check model.placementForWindowOnTag(model.tagForSlot(1), winId).isNone
    check model.placementForWindowOnTag(model.tagForSlot(2), winId).isNone

    model.applyMsg(Msg(kind: MsgKind.CmdRestoreScratchpad))
    check not model.windowData(winId).get().isSticky
    check model.placementForWindowOnTag(model.tagForSlot(1), winId).isSome
    check model.placementForWindowOnTag(model.tagForSlot(2), winId).isSome

  test "Live restore preserves scratchpad restore workspace":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 29, appId: "term", title: "home")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))

    let restore = parseLiveRestoreJson(model.liveRestoreJson()).get()
    var restoredModel = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    restoredModel.applyLiveRestore(restore.pendingRestoreState())
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 29, appId: "term", title: "home")
    )
    restoredModel.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    restoredModel.applyMsg(Msg(kind: MsgKind.CmdRestoreScratchpad))

    let restoredId = restoredModel.windowForExternal(ExternalWindowId(29))
    check restoredModel.activeWorkspaceSlot() == 1
    check restoredModel.placementForWindowOnTag(restoredModel.tagForSlot(1), restoredId).isSome
    check restoredModel.placementForWindowOnTag(restoredModel.tagForSlot(2), restoredId).isNone

  test "Live restore preserves sticky window state":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "status",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 29, appId: "status", title: "bar")
    )
    check model.restoreWindowJson(29)["is_sticky"].getBool()
    let restore = parseLiveRestoreJson(model.liveRestoreJson()).get()

    var restoredModel = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    restoredModel.applyLiveRestore(restore.pendingRestoreState())
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 29, appId: "status", title: "bar")
    )
    let restoredId = restoredModel.windowForExternal(ExternalWindowId(29))

    check restoredModel.windowData(restoredId).get().isSticky
    check restoredModel.placementForWindowOnTag(restoredModel.tagForSlot(1), restoredId).isSome
    check restoredModel.placementForWindowOnTag(restoredModel.tagForSlot(2), restoredId).isSome
