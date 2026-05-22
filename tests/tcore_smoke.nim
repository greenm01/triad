import tcore_support

suite "Core Runtime Logic: smoke":
  test "Triad reload command emits restart effect":
    var model = Model()
    let (_, effects) = model.update(Msg(kind: MsgKind.CmdTriadReload))
    check effects.len == 1
    check effects[0].kind == EffectKind.EffTriadReload

  test "Session unlock clears stale layer focus and restores active focus":
    var model = configuredModel()
    model.seedCameraWindows(2)
    check model.focusedWindowId() == 2

    discard model.updateModel(Msg(kind: MsgKind.WlLayerFocusExclusive))
    discard model.updateModel(Msg(kind: MsgKind.WlSessionLocked))
    check model.sessionLocked
    check model.layerFocusExclusive

    let lockedEffects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    check model.focusedWindowId() == 2
    check lockedEffects.len == 0

    let unlockEffects = model.updateModel(Msg(kind: MsgKind.WlSessionUnlocked))
    check not model.sessionLocked
    check not model.layerFocusExclusive
    check model.focusedWindowId() == 2
    check unlockEffects.hasFocusEffect(2)

  test "Screenshot command emits explicit capture effect":
    var model = Model()
    let (_, effects) = model.update(
      Msg(
        kind: MsgKind.CmdScreenshot,
        screenshotKind: ScreenshotKind.ShotWindow,
        screenshotPath: "/tmp/window.png",
        screenshotPointerMode: ScreenshotPointerMode.PointerShow,
        screenshotWriteToDisk: true,
        screenshotCopyToClipboard: false,
      )
    )

    check effects.len == 1
    check effects[0].kind == EffectKind.EffScreenshot
    check effects[0].screenshotKind == ScreenshotKind.ShotWindow
    check effects[0].screenshotPath == "/tmp/window.png"
    check effects[0].screenshotPointerMode == ScreenshotPointerMode.PointerShow
    check effects[0].screenshotWriteToDisk
    check not effects[0].screenshotCopyToClipboard

  test "Monitor power commands emit explicit output-management effects":
    var model = Model()

    let powerOffEffects = model.updateModel(Msg(kind: MsgKind.CmdPowerOffMonitors))
    check powerOffEffects.len == 1
    check powerOffEffects[0].kind == EffectKind.EffSetMonitorPower
    check not powerOffEffects[0].monitorPowerEnabled

    let powerOnEffects = model.updateModel(Msg(kind: MsgKind.CmdPowerOnMonitors))
    check powerOnEffects.len == 1
    check powerOnEffects[0].kind == EffectKind.EffSetMonitorPower
    check powerOnEffects[0].monitorPowerEnabled

    let targetOffEffects =
      model.updateModel(Msg(kind: MsgKind.CmdPowerOffMonitor, outputTarget: "DP-3"))
    check targetOffEffects.len == 1
    check targetOffEffects[0].kind == EffectKind.EffSetMonitorPower
    check not targetOffEffects[0].monitorPowerEnabled
    check targetOffEffects[0].monitorPowerTarget == "DP-3"

    let targetOnEffects =
      model.updateModel(Msg(kind: MsgKind.CmdPowerOnMonitor, outputTarget: "DP-3"))
    check targetOnEffects.len == 1
    check targetOnEffects[0].kind == EffectKind.EffSetMonitorPower
    check targetOnEffects[0].monitorPowerEnabled
    check targetOnEffects[0].monitorPowerTarget == "DP-3"

  test "Workspace reorder changes visible workspace order":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    check model.shellSnapshot().workspaces.mapIt(it.tagId) == @[1'u32, 2, 3]

    model.applyMsg(
      Msg(
        kind: MsgKind.CmdReorderWorkspaceIndex,
        reorderWorkspaceIndex: 1,
        reorderTargetIndex: 3,
      )
    )

    check model.shellSnapshot().workspaces.mapIt(it.tagId) == @[2'u32, 3, 1]
    model.refreshVisibleWorkspaceSlots()
    check model.shellSnapshot().workspaces.mapIt(it.tagId) == @[2'u32, 3, 1]

  test "Keyboard layout switch updates snapshot and emits layout effect":
    var model = initRuntimeStateFromConfig(
      Config(
        input: InputConfig(
          keyboard:
            InputKeyboardConfig(xkb: InputXkbConfig(layoutSet: true, layout: "us,de"))
        )
      )
    ).model
    var snapshot = model.shellSnapshot()
    check snapshot.keyboardLayoutNames == @["us", "de"]
    check snapshot.keyboardLayoutIndex == 0

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.CmdSwitchKeyboardLayout,
        keyboardLayoutDelta: 1,
        keyboardLayoutIndex: -1,
      )
    )
    snapshot = model.shellSnapshot()

    check snapshot.keyboardLayoutIndex == 1
    check effects.anyIt(
      it.kind == EffectKind.EffSetKeyboardLayout and it.keyboardLayoutIndex == 1
    )
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("KeyboardLayoutSwitched")
    )

  test "Screenshot command builder preserves shell snippets and quotes data":
    let config = ScreenshotConfig(
      captureCommand: "grim -t png",
      regionSelectorCommand: "slurp -d",
      clipboardCommand: "wl-copy --type image/png",
    )
    let screen = Rect(x: 0, y: 0, w: 1920, h: 1080)
    let win = Rect(x: 40, y: 50, w: 800, h: 600)

    check screenshotCaptureCommand(
      ScreenshotKind.ShotRegion, "/tmp/region shot.png", config, screen, win,
      ScreenshotPointerMode.PointerDefault,
    ) == "grim -t png -g \"$(slurp -d)\" '/tmp/region shot.png'"
    check screenshotCaptureCommand(
      ScreenshotKind.ShotScreen, "/tmp/screen.png", config, screen, win,
      ScreenshotPointerMode.PointerShow,
    ) == "grim -t png -c -g '0,0 1920x1080' '/tmp/screen.png'"
    check screenshotCaptureCommand(
      ScreenshotKind.ShotWindow, "/tmp/window.png", config, screen, win,
      ScreenshotPointerMode.PointerHide,
    ) == "grim -t png -g '40,50 800x600' '/tmp/window.png'"
    check screenshotClipboardCommand("/tmp/window.png", config) ==
      "wl-copy --type image/png < '/tmp/window.png'"

  test "Screenshot paths expand home directory absolutely":
    let home = getHomeDir().strip(leading = false, trailing = true, chars = {'/'})
    let config = ScreenshotConfig(
      directory: "~/Pictures/Screenshots", filenamePrefix: "screenshot"
    )
    let path = screenshotPathOrDefault("", config)

    check expandUserPath("~") == home
    check expandUserPath("~/") == home
    check expandUserPath("~/Pictures/Screenshots") == home / "Pictures" / "Screenshots"
    check expandUserPath("/tmp/shot.png") == "/tmp/shot.png"
    check path.startsWith(home / "Pictures" / "Screenshots" / "screenshot-")
    check not path.startsWith("home/")

  test "Process tree descendant check follows parent chain":
    proc parentPid(pid: int32): int32 {.gcsafe.} =
      case pid
      of 20'i32: 10'i32
      of 30'i32: 20'i32
      else: 0'i32

    check isDescendantProcess(10, 30, parentPid)
    check not isDescendantProcess(30, 10, parentPid)
    check not isDescendantProcess(0, 30, parentPid)

  test "Async shell command runner yields while process runs":
    var ticked = false

    proc markTick() {.async.} =
      await sleepAsync(20)
      ticked = true

    proc runSlow(): Future[int] {.async.} =
      asyncCheck markTick()
      result = await runShellCommandAsync("sleep 0.1", pollMs = 10)

    check waitFor(runSlow()) == 0
    check ticked
    check waitFor(runShellCommandAsync("exit 7", pollMs = 10)) == 7

  test "Targeted layout command updates requested slot only":
    var model = configuredModel()
    let (nextModel, effects) = model.update(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Deck, layoutTargetTag: 2)
    )
    let snapshot = nextModel.shellSnapshot()

    check snapshot.activeTag == 1
    check snapshot.workspaces[0].layoutMode == LayoutMode.Scroller
    check snapshot.workspaces[1].layoutMode == LayoutMode.Scroller
    check snapshot.workspaces[1].layoutId == "deck"
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastTriadJson and
        it.jsonPayload.contains("layout-state-changed")
    )

  test "Hotkey overlay commands update runtime state":
    var model = initRuntimeStateFromConfig(
      Config(
        hotkeyOverlay: HotkeyOverlayConfig(skipAtStartup: true),
        workspaces: WorkspaceConfig(defaultCount: 3),
      )
    ).model

    var effects = model.updateModel(Msg(kind: MsgKind.CmdShowHotkeyOverlay))
    check model.hotkeyOverlayOpen
    check model.hotkeyOverlayShownOnce
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

    effects = model.updateModel(Msg(kind: MsgKind.CmdShowHotkeyOverlay))
    check model.hotkeyOverlayOpen
    check not effects.anyIt(it.kind == EffectKind.EffManageDirty)

    effects = model.updateModel(Msg(kind: MsgKind.CmdToggleHotkeyOverlay))
    check not model.hotkeyOverlayOpen
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

    effects = model.updateModel(Msg(kind: MsgKind.CmdHideHotkeyOverlay))
    check not model.hotkeyOverlayOpen
    check not effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Exit session command opens confirmation before exiting":
    var model = Model(allowExitSession: true)

    var effects = model.updateModel(Msg(kind: MsgKind.CmdExitSession))
    check model.exitSessionConfirmOpen
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check not effects.anyIt(it.kind == EffectKind.EffExitSession)

    effects = model.updateModel(Msg(kind: MsgKind.CmdConfirmExitSession))
    check not model.exitSessionConfirmOpen
    check effects.anyIt(it.kind == EffectKind.EffExitSession)

  test "Immediate exit session command bypasses confirmation with config guard":
    var model = Model(allowExitSession: true)

    var effects = model.updateModel(Msg(kind: MsgKind.CmdExitSessionImmediate))
    check not model.exitSessionConfirmOpen
    check effects.anyIt(it.kind == EffectKind.EffExitSession)

    model.allowExitSession = false
    effects = model.updateModel(Msg(kind: MsgKind.CmdExitSessionImmediate))
    check not effects.anyIt(it.kind == EffectKind.EffExitSession)
    check effects.anyIt(it.kind == EffectKind.EffLog)

  test "Exit session confirmation can dismiss and respects config guard":
    var model = Model(allowExitSession: true)

    discard model.updateModel(Msg(kind: MsgKind.CmdExitSession))
    let dismissed = model.updateModel(Msg(kind: MsgKind.CmdDismissExitSessionConfirm))
    check not model.exitSessionConfirmOpen
    check not dismissed.anyIt(it.kind == EffectKind.EffExitSession)

    let closedConfirm = model.updateModel(Msg(kind: MsgKind.CmdConfirmExitSession))
    check not closedConfirm.anyIt(it.kind == EffectKind.EffExitSession)

    model.allowExitSession = false
    let disabled = model.updateModel(Msg(kind: MsgKind.CmdExitSession))
    check not model.exitSessionConfirmOpen
    check disabled.anyIt(it.kind == EffectKind.EffLog)

  test "Hotkey overlay rows honor custom and hidden binding titles":
    var model = initRuntimeStateFromConfig(
      Config(
        hotkeyOverlay: HotkeyOverlayConfig(hideNotBound: true),
        keyBindings:
          @[
            KeyBindingConfig(
              key: "Slash",
              modifiers: 65'u32,
              command: "toggle-hotkey-overlay",
              hotkeyOverlayTitleKind: HotkeyOverlayTitleKind.HotkeyTitleCustom,
              hotkeyOverlayTitle: "Show Important Hotkeys",
            ),
            KeyBindingConfig(
              key: "q",
              modifiers: 64'u32,
              command: "close-window",
              hotkeyOverlayTitleKind: HotkeyOverlayTitleKind.HotkeyTitleHidden,
            ),
            KeyBindingConfig(
              key: "Return", modifiers: 64'u32, command: "spawn-terminal"
            ),
          ],
      )
    ).model
    let rows = model.hotkeyOverlayRows()

    check rows.anyIt(
      it.key == "Super + Shift + /" and it.label == "Show Important Hotkeys"
    )
    check not rows.anyIt(it.label == "Close Focused Window")
    check rows.anyIt(it.key == "Super + Enter" and it.label == "Open Terminal")
    check not rows.anyIt(it.key == "(not bound)")
