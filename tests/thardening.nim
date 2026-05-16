import std/[json, options, os, sequtils, strtabs, tables, unittest]
import ../src/config/parser
import ../src/core/[effects, msg, restore_state]
import
  ../src/daemon/[
    bindings_runtime, cursor_shake, effects_runtime, input_device_classification,
    message_queue, process_runner, reload_runtime, switch_event_runtime,
  ]
from ../src/daemon/state import consumeMaximizedAck, expectMaximizedAck, initTriadDaemon
import ../src/ipc/[commands, niri_compat, socket]
import ../src/layouts/[scroller, tiling]
import ../src/state/[invariants, snapshot]
import ../src/systems/[daemon_view, runtime, runtime_facade, update]
from ../src/types/model import Model
import ../src/types/[projection_values, runtime_values, shell_snapshot]
import ../src/utils/session_env

var observedConfigNotificationEvent: ConfigNotificationEvent
var observedConfigNotificationCommand: seq[string]

proc recordConfigNotification(
    daemon: pointer, event: ConfigNotificationEvent, command: seq[string]
) {.nimcall.} =
  discard daemon
  observedConfigNotificationEvent = event
  observedConfigNotificationCommand = command

proc baseSnapshot(): ShellSnapshot =
  ShellSnapshot(
    version: 1,
    activeTag: 1,
    activeWorkspaceIdx: 1,
    layoutCycle: @[LayoutMode.Scroller, LayoutMode.Grid],
    workspaces:
      @[
        ShellWorkspace(
          tagId: 1,
          workspaceIdx: 1,
          layoutMode: LayoutMode.Scroller,
          isActive: true,
          outputName: "triad-0",
          masterCount: 1,
          masterSplitRatio: 0.5,
        )
      ],
    outputs: @[ShellOutput(name: "triad-0", w: 1920, h: 1080)],
  )

suite "Crash hardening":
  test "daemon startup rejects missing Wayland session environment":
    check waylandSessionProblem("", "wayland-1") == "XDG_RUNTIME_DIR is not set"
    check waylandSessionProblem("/run/user/1000", "") == "WAYLAND_DISPLAY is not set"
    check waylandSessionProblem("/run/user/1000", "wayland-1") == ""

  test "daemon consumes only matching self-generated maximize acknowledgements":
    var daemon = initTriadDaemon()

    daemon.expectMaximizedAck(42, false)
    check not daemon.consumeMaximizedAck(42, true)
    check daemon.consumeMaximizedAck(42, false)
    check not daemon.consumeMaximizedAck(42, false)

  test "configured process environment applies literal set and unset entries":
    let base = newStringTable(modeCaseSensitive)
    base["KEEP"] = "base"
    base["DROP"] = "remove"
    base["OVERRIDE"] = "old"

    let model = Model(
      environment:
        @[
          EnvironmentEntryConfig(name: "OVERRIDE", value: "new"),
          EnvironmentEntryConfig(name: "EMPTY", value: ""),
          EnvironmentEntryConfig(name: "DROP", unset: true),
          EnvironmentEntryConfig(name: "OVERRIDE", value: "last"),
        ]
    )

    let env = model.configuredProcessEnv(base)
    check env["KEEP"] == "base"
    check env["OVERRIDE"] == "last"
    check env["EMPTY"] == ""
    check not env.hasKey("DROP")
    check base["DROP"] == "remove"
    check base["OVERRIDE"] == "old"

  test "axis bindings dispatch matching wheel detents":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        axisBindings:
          @[
            AxisBindingConfig(
              direction: AxisBindingDirection.AxisUp,
              modifiers: 64'u32,
              command: "focus-left",
            ),
            AxisBindingConfig(
              direction: AxisBindingDirection.AxisRight,
              modifiers: 64'u32,
              command: "focus-right",
              mode: BindingMode.BindOverview,
            ),
          ]
      )
    )
    daemon.runtimeState.model.activeModifiers = 64'u32

    check axisDirectionForWheelTicks(horizontalAxis = false, ticks = -1) ==
      AxisBindingDirection.AxisUp
    check daemon.dispatchAxisBindingTicks(1'u32, -2, horizontalAxis = false)
    check daemon.hasQueuedMessages()
    check daemon.popQueuedMessage().direction == Direction.DirLeft
    check daemon.popQueuedMessage().direction == Direction.DirLeft
    check not daemon.hasQueuedMessages()

    check not daemon.dispatchAxisBindingTicks(1'u32, 1, horizontalAxis = true)
    daemon.runtimeState.model.overviewActive = true
    check daemon.dispatchAxisBindingTicks(1'u32, 1, horizontalAxis = true)
    check daemon.popQueuedMessage().direction == Direction.DirRight

  test "gesture bindings dispatch matching synthetic swipes":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        gestureBindings:
          @[
            GestureBindingConfig(
              direction: GestureBindingDirection.GestureSwipeLeft,
              fingers: 3,
              modifiers: 64'u32,
              command: "focus-left",
            ),
            GestureBindingConfig(
              direction: GestureBindingDirection.GestureSwipeUp,
              fingers: 4,
              modifiers: 64'u32,
              command: "toggle-overview",
              mode: BindingMode.BindOverview,
            ),
          ]
      )
    )
    daemon.runtimeState.model.activeModifiers = 64'u32

    check not daemon.dispatchGestureBinding(
      1'u32, GestureBindingDirection.GestureSwipeLeft, 4
    )
    check daemon.dispatchGestureBinding(
      1'u32, GestureBindingDirection.GestureSwipeLeft, 3
    )
    check daemon.popQueuedMessage().direction == Direction.DirLeft
    check not daemon.dispatchGestureBinding(
      1'u32, GestureBindingDirection.GestureSwipeUp, 4
    )
    daemon.runtimeState.model.overviewActive = true
    check daemon.dispatchGestureBinding(
      1'u32, GestureBindingDirection.GestureSwipeUp, 4
    )
    check daemon.popQueuedMessage().kind == MsgKind.CmdToggleOverview

  test "touchpad swipe direction uses threshold and major axis":
    check gestureDirectionForSwipe(-15.0, 0.0, cancelled = false) ==
      GestureBindingDirection.GestureNone
    check gestureDirectionForSwipe(-20.0, 2.0, cancelled = false) ==
      GestureBindingDirection.GestureSwipeLeft
    check gestureDirectionForSwipe(20.0, 2.0, cancelled = false) ==
      GestureBindingDirection.GestureSwipeRight
    check gestureDirectionForSwipe(2.0, -20.0, cancelled = false) ==
      GestureBindingDirection.GestureSwipeUp
    check gestureDirectionForSwipe(2.0, 20.0, cancelled = false) ==
      GestureBindingDirection.GestureSwipeDown
    check gestureDirectionForSwipe(20.0, -20.0, cancelled = false) ==
      GestureBindingDirection.GestureSwipeUp
    check gestureDirectionForSwipe(-40.0, 0.0, cancelled = true) ==
      GestureBindingDirection.GestureNone

  test "live touchpad swipe dispatches configured command on end":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        gestureBindings:
          @[
            GestureBindingConfig(
              direction: GestureBindingDirection.GestureSwipeLeft,
              fingers: 3,
              modifiers: 64'u32,
              command: "focus-left",
            )
          ]
      )
    )
    daemon.runtimeState.model.activeModifiers = 64'u32
    daemon.wlPointerRiverSeats[77'u32] = 1'u32

    daemon.beginSwipeGesture(77'u32, 3'u32)
    daemon.updateSwipeGesture(77'u32, -12.0, 0.0)
    check not daemon.endSwipeGesture(77'u32, cancelled = false)
    check not daemon.hasQueuedMessages()

    daemon.beginSwipeGesture(77'u32, 3'u32)
    daemon.updateSwipeGesture(77'u32, -20.0, 2.0)
    check daemon.endSwipeGesture(77'u32, cancelled = false)
    check not daemon.wlSwipeStates.getOrDefault(77'u32).active
    check daemon.popQueuedMessage().direction == Direction.DirLeft
    check not daemon.endSwipeGesture(77'u32, cancelled = false)
    check not daemon.hasQueuedMessages()

  test "live touchpad swipe ignores cancelled or unmapped gestures":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        gestureBindings:
          @[
            GestureBindingConfig(
              direction: GestureBindingDirection.GestureSwipeLeft,
              fingers: 3,
              command: "focus-left",
            )
          ]
      )
    )

    daemon.wlPointerRiverSeats[77'u32] = 1'u32
    daemon.beginSwipeGesture(77'u32, 3'u32)
    daemon.updateSwipeGesture(77'u32, -20.0, 0.0)
    check not daemon.endSwipeGesture(77'u32, cancelled = true)
    check not daemon.hasQueuedMessages()

    daemon.beginSwipeGesture(78'u32, 3'u32)
    daemon.updateSwipeGesture(78'u32, -20.0, 0.0)
    check not daemon.endSwipeGesture(78'u32, cancelled = false)
    check not daemon.hasQueuedMessages()

  test "switch events dispatch configured commands while session is locked":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        switchEvents:
          @[
            SwitchEventConfig(
              kind: SwitchEventKind.SwitchLidOpen, command: "focus-right"
            )
          ]
      )
    )
    daemon.runtimeState.model.sessionLocked = true

    check not daemon.dispatchSwitchEvent(SwitchEventKind.SwitchLidClose)
    check daemon.dispatchSwitchEvent(SwitchEventKind.SwitchLidOpen)
    check daemon.popQueuedMessage().direction == Direction.DirRight

  test "evdev switch events map to switch event kinds":
    check switchEventKindForEvdev(0x05'u16, 0x00'u16, 1) ==
      SwitchEventKind.SwitchLidClose
    check switchEventKindForEvdev(0x05'u16, 0x00'u16, 0) == SwitchEventKind.SwitchLidOpen
    check switchEventKindForEvdev(0x05'u16, 0x01'u16, 1) ==
      SwitchEventKind.SwitchTabletModeOn
    check switchEventKindForEvdev(0x05'u16, 0x01'u16, 0) ==
      SwitchEventKind.SwitchTabletModeOff
    check switchEventKindForEvdev(0x05'u16, 0x02'u16, 1) == SwitchEventKind.SwitchNone
    check switchEventKindForEvdev(0x01'u16, 0x00'u16, 1) == SwitchEventKind.SwitchNone

  test "parsed evdev switch event dispatches configured command":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        switchEvents:
          @[
            SwitchEventConfig(
              kind: SwitchEventKind.SwitchLidClose, command: "lock-session"
            )
          ]
      )
    )

    check daemon.dispatchEvdevSwitchEvent(0x05'u16, 0x00'u16, 1)
    check daemon.popQueuedMessage().kind == MsgKind.CmdLockSession
    check not daemon.dispatchEvdevSwitchEvent(0x05'u16, 0x01'u16, 1)
    check not daemon.hasQueuedMessages()

  test "daemon overview hot corner opens once and rearms after leave":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        overview:
          OverviewConfig(hotCorners: OverviewHotCornersConfig(size: 10, topLeft: true))
      )
    )
    daemon.runtimeState.model.screenWidth = 100
    daemon.runtimeState.model.screenHeight = 100

    check daemon.updateOverviewHotCornerState(1, 0, 0)
    check not daemon.updateOverviewHotCornerState(1, 5, 5)
    check not daemon.updateOverviewHotCornerState(1, 50, 50)
    check daemon.updateOverviewHotCornerState(1, 0, 0)

  test "daemon overview hot corner is open-only":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        overview:
          OverviewConfig(hotCorners: OverviewHotCornersConfig(size: 10, topLeft: true))
      )
    )
    daemon.runtimeState.model.screenWidth = 100
    daemon.runtimeState.model.screenHeight = 100
    daemon.runtimeState.model.overviewActive = true

    check not daemon.updateOverviewHotCornerState(1, 0, 0)

  test "cursor shake ignores normal movement":
    var state = CursorShakeState()
    let config = CursorConfig(theme: "default", size: 24, shakeToFind: true)

    check state.observeCursorMotion(config, 0, 0, 0) == CursorShakeAction.None
    check state.observeCursorMotion(config, 30, 0, 40) == CursorShakeAction.None
    check state.observeCursorMotion(config, 60, 0, 80) == CursorShakeAction.None
    check not state.enlarged

  test "cursor shake enlarges on rapid alternating motion":
    var state = CursorShakeState()
    let config = CursorConfig(theme: "default", size: 24, shakeToFind: true)

    check state.observeCursorMotion(config, 0, 0, 0) == CursorShakeAction.None
    check state.observeCursorMotion(config, 30, 0, 40) == CursorShakeAction.None
    check state.observeCursorMotion(config, -30, 0, 80) == CursorShakeAction.None
    check state.observeCursorMotion(config, 30, 0, 120) == CursorShakeAction.None
    check state.observeCursorMotion(config, -30, 0, 160) == CursorShakeAction.Enlarge
    check state.enlarged
    check config.cursorShakeSize() == 48'u32

  test "cursor shake restores after idle":
    var state = CursorShakeState(enlarged: true, restoreDueMs: 1000)
    let config = CursorConfig(theme: "default", size: 24, shakeToFind: true)

    check state.tickCursorShake(config, 999) == CursorShakeAction.None
    check state.tickCursorShake(config, 1000) == CursorShakeAction.Restore
    check not state.enlarged

  test "cursor shake respects disabled config and size clamp":
    var state = CursorShakeState(enlarged: true, restoreDueMs: 1000)
    let disabled = CursorConfig(theme: "default", size: 24)
    let large = CursorConfig(theme: "default", size: 500, shakeToFind: true)

    check state.observeCursorMotion(disabled, 20, 0, 10) == CursorShakeAction.Restore
    check not state.enlarged
    check large.cursorShakeSize() == 512'u32

  test "cursor hide inactivity config is opt-in":
    check not CursorConfig().cursorHideInactiveEnabled()
    check not CursorConfig(hideAfterInactiveMs: 0).cursorHideInactiveEnabled()
    check CursorConfig(hideAfterInactiveMs: 1).cursorHideInactiveEnabled()

  test "input pointer classification prefers explicit names and touchpad support":
    check pointerClassFor("Kensington Expert Trackball", 0, false, false) ==
      PointerDeviceClass.Trackball
    check pointerClassFor("TPPS/2 IBM TrackPoint", 0, false, false) ==
      PointerDeviceClass.Trackpoint
    check pointerClassFor("ELAN Touchpad", 0, false, false) ==
      PointerDeviceClass.Touchpad
    check pointerClassFor("Generic pointer", 2, false, false) ==
      PointerDeviceClass.Touchpad
    check pointerClassFor("Logitech USB Receiver", 0, false, false) ==
      PointerDeviceClass.Mouse

  test "XKB release bindings arm on accepted press and dispatch once":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(hotkeyOverlay: HotkeyOverlayConfig(skipAtStartup: true))
    )
    daemon.xkbBindings[1'u32] = Msg(kind: MsgKind.CmdFocusNext)
    daemon.xkbBindingModes[1'u32] = BindingMode.BindAlways
    daemon.xkbBindingModifiers[1'u32] = 64'u32
    daemon.xkbBindingOnRelease[1'u32] = true

    daemon.handleXkbBindingPressed(1'u32)
    check daemon.xkbBindingReleaseArmed.getOrDefault(1'u32, false)
    check not daemon.hasQueuedMessages()

    daemon.handleXkbBindingReleased(1'u32)
    check not daemon.xkbBindingReleaseArmed.getOrDefault(1'u32, false)
    check daemon.hasQueuedMessages()
    let releasedMsg = daemon.popQueuedMessage()
    check releasedMsg.kind == MsgKind.CmdFocusNext
    while daemon.hasQueuedMessages():
      discard daemon.popQueuedMessage()

    daemon.handleXkbBindingReleased(1'u32)
    check not daemon.hasQueuedMessages()

  test "XKB bindings honor locked-session opt-in":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(hotkeyOverlay: HotkeyOverlayConfig(skipAtStartup: true))
    )
    daemon.runtimeState.model.sessionLocked = true
    daemon.xkbBindings[1'u32] = Msg(kind: MsgKind.CmdFocusNext)
    daemon.xkbBindingModes[1'u32] = BindingMode.BindAlways
    daemon.xkbBindingModifiers[1'u32] = 64'u32

    daemon.handleXkbBindingPressed(1'u32)
    check not daemon.hasQueuedMessages()

    daemon.xkbBindingWhileLocked[1'u32] = true
    daemon.handleXkbBindingPressed(1'u32)
    check daemon.hasQueuedMessages()
    let lockedMsg = daemon.popQueuedMessage()
    check lockedMsg.kind == MsgKind.CmdFocusNext

  test "Hotkey overlay consumes bound XKB bindings as dismissal":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(Config())
    daemon.runtimeState.model.hotkeyOverlayOpen = true
    daemon.hotkeyOverlayKeyEatArmed = true
    daemon.xkbBindings[1'u32] = Msg(kind: MsgKind.CmdFocusNext)
    daemon.xkbBindingModes[1'u32] = BindingMode.BindAlways
    daemon.xkbBindingModifiers[1'u32] = 64'u32

    daemon.handleXkbBindingPressed(1'u32)

    check daemon.hotkeyOverlayKeyEatArmed
    check daemon.hasQueuedMessages()
    let dismissMsg = daemon.popQueuedMessage()
    check dismissMsg.kind == MsgKind.CmdHideHotkeyOverlay
    check not daemon.hasQueuedMessages()

  test "Hotkey overlay consumes on-release bindings on press":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(Config())
    daemon.runtimeState.model.hotkeyOverlayOpen = true
    daemon.xkbBindings[1'u32] = Msg(kind: MsgKind.CmdFocusNext)
    daemon.xkbBindingModes[1'u32] = BindingMode.BindAlways
    daemon.xkbBindingModifiers[1'u32] = 64'u32
    daemon.xkbBindingOnRelease[1'u32] = true

    daemon.handleXkbBindingPressed(1'u32)

    check not daemon.xkbBindingReleaseArmed.getOrDefault(1'u32, false)
    check daemon.hasQueuedMessages()
    let dismissMsg = daemon.popQueuedMessage()
    check dismissMsg.kind == MsgKind.CmdHideHotkeyOverlay

  test "Hotkey overlay hides after River eats an unbound key":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(Config())
    daemon.runtimeState.model.hotkeyOverlayOpen = true
    daemon.hotkeyOverlayKeyEatArmed = true

    daemon.handleXkbSeatAteUnboundKey(7'u32)

    check daemon.xkbSeatAteUnbound.getOrDefault(7'u32, 0'u32) == 1'u32
    check daemon.hotkeyOverlayKeyEatArmed
    check daemon.hasQueuedMessages()
    let dismissMsg = daemon.popQueuedMessage()
    check dismissMsg.kind == MsgKind.CmdHideHotkeyOverlay

  test "Exit-session confirmation routes Enter to confirm":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(hotkeyOverlay: HotkeyOverlayConfig(skipAtStartup: true))
    )
    daemon.runtimeState.model.exitSessionConfirmOpen = true
    daemon.xkbBindings[1'u32] = Msg(kind: MsgKind.CmdConfirmExitSession)

    daemon.handleXkbBindingPressed(1'u32)

    check daemon.hasQueuedMessages()
    let confirmMsg = daemon.popQueuedMessage()
    check confirmMsg.kind == MsgKind.CmdConfirmExitSession
    check not daemon.hasQueuedMessages()

  test "Exit-session confirmation dismisses other bound and unbound keys":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(hotkeyOverlay: HotkeyOverlayConfig(skipAtStartup: true))
    )
    daemon.runtimeState.model.exitSessionConfirmOpen = true
    daemon.xkbBindings[1'u32] = Msg(kind: MsgKind.CmdFocusNext)

    daemon.handleXkbBindingPressed(1'u32)

    check daemon.hasQueuedMessages()
    var dismissMsg = daemon.popQueuedMessage()
    check dismissMsg.kind == MsgKind.CmdDismissExitSessionConfirm
    check not daemon.hasQueuedMessages()

    daemon.runtimeState.model.exitSessionConfirmOpen = true
    daemon.handleXkbSeatAteUnboundKey(7'u32)

    check daemon.hasQueuedMessages()
    dismissMsg = daemon.popQueuedMessage()
    check dismissMsg.kind == MsgKind.CmdDismissExitSessionConfirm

  test "Exit-session confirmation arms key capture":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(hotkeyOverlay: HotkeyOverlayConfig(skipAtStartup: true))
    )
    daemon.runtimeState.model.exitSessionConfirmOpen = true

    daemon.syncHotkeyOverlayKeyCapture()
    check daemon.hotkeyOverlayKeyEatArmed

    daemon.runtimeState.model.exitSessionConfirmOpen = false
    daemon.syncHotkeyOverlayKeyCapture()
    check not daemon.hotkeyOverlayKeyEatArmed

  test "eat-next-key effects defer to manage phase":
    var daemon = initTriadDaemon()

    daemon.executeEffect(Effect(kind: EffectKind.EffEnsureNextKeyEaten))

    check daemon.pendingManageEffects.len == 1
    check daemon.pendingManageEffects[0].kind == EffectKind.EffEnsureNextKeyEaten

  test "config reload defers binding reconfigure to manage":
    let base = getTempDir() / "triad-config-reload-" & $getCurrentProcessId()
    let configPath = base & ".kdl"
    let restorePath = base & ".json"
    writeFile(
      configPath,
      """
workspaces {
  default-count 3
}
""",
    )

    var daemon = initTriadDaemon()
    daemon.pendingLiveRestorePath = restorePath
    daemon.runtimeState =
      initRuntimeStateFromConfig(Config(workspaces: WorkspaceConfig(defaultCount: 3)))
    discard daemon.runtimeState.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    daemon.bindingsConfigured = true

    check daemon.applyConfigReload(configPath, "")
    check daemon.bindingsConfigured
    check daemon.bindingsReconfigurePending
    check daemon.liveRestoreCommitPending
    check fileExists(restorePath)
    check not liveRestoreStateApplied(restorePath)

    if fileExists(configPath):
      removeFile(configPath)
    if fileExists(restorePath):
      removeFile(restorePath)

  test "config reload notifications use success and failure commands":
    let base = getTempDir() / "triad-config-notify-" & $getCurrentProcessId()
    let configPath = base & ".kdl"
    let restorePath = base & ".json"
    writeFile(
      configPath,
      """
config-notification {
  reload-succeeded "notify-send" "Triad" "reloaded"
  reload-failed "notify-send" "Triad" "failed"
}
""",
    )

    var daemon = initTriadDaemon()
    daemon.pendingLiveRestorePath = restorePath
    daemon.configNotificationHook = recordConfigNotification
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        configNotification:
          ConfigNotificationConfig(reloadFailed: @["notify-send", "old-failed"])
      )
    )

    observedConfigNotificationEvent = ConfigNotificationEvent.ConfigNotifyNone
    observedConfigNotificationCommand = @[]
    check daemon.applyConfigReload(configPath, "")
    check observedConfigNotificationEvent ==
      ConfigNotificationEvent.ConfigReloadSucceeded
    check observedConfigNotificationCommand == @["notify-send", "Triad", "reloaded"]

    writeFile(configPath, "layout { gaps ")
    observedConfigNotificationEvent = ConfigNotificationEvent.ConfigNotifyNone
    observedConfigNotificationCommand = @[]
    check not daemon.applyConfigReload(configPath, "")
    check observedConfigNotificationEvent == ConfigNotificationEvent.ConfigReloadFailed
    check observedConfigNotificationCommand == @["notify-send", "Triad", "failed"]

    if fileExists(configPath):
      removeFile(configPath)
    if fileExists(restorePath):
      removeFile(restorePath)

  test "Niri overview fallback keys preserve user overview bindings":
    var model = initRuntimeStateFromConfig(Config()).model
    model.keyBindings =
      @[
        KeyBindingConfig(
          key: "Enter",
          modifiers: 0'u32,
          command: "custom-enter",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "Left",
          modifiers: 0'u32,
          command: "custom-left",
          mode: BindingMode.BindOverview,
        ),
        KeyBindingConfig(
          key: "Right",
          modifiers: 0'u32,
          command: "normal-right",
          mode: BindingMode.BindNormal,
        ),
      ]

    let fallbacks = model.overviewFallbackKeyBindings()

    check overviewKeyBindingFallbacks().len == 8
    check not fallbacks.anyIt(it.key == "Return")
    check not fallbacks.anyIt(it.key == "Left")
    check fallbacks.anyIt(it.key == "Right" and it.command == "focus-right")
    check fallbacks.anyIt(it.key == "Escape")
    check fallbacks.anyIt(it.key == "Page_Up" and it.command == "focus-tag-left")
    check fallbacks.anyIt(it.key == "Page_Down" and it.command == "focus-tag-right")

  test "Niri overview fallback keys derive user direction keys":
    var model = initRuntimeStateFromConfig(Config()).model
    model.keyBindings =
      @[
        KeyBindingConfig(
          key: "h",
          modifiers: 64'u32,
          command: "focus-left",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "l",
          modifiers: 64'u32,
          command: "focus-right",
          mode: BindingMode.BindNormal,
        ),
        KeyBindingConfig(
          key: "j",
          modifiers: 64'u32,
          command: "focus-window-or-workspace-down",
          mode: BindingMode.BindNormal,
        ),
        KeyBindingConfig(
          key: "k",
          modifiers: 64'u32,
          command: "focus-window-or-workspace-up",
          mode: BindingMode.BindOverview,
        ),
      ]

    let fallbacks = model.overviewFallbackKeyBindings()

    check fallbacks.anyIt(
      it.key == "h" and it.modifiers == 0'u32 and it.command == "focus-left"
    )
    check fallbacks.anyIt(
      it.key == "l" and it.modifiers == 0'u32 and it.command == "focus-right"
    )
    check fallbacks.anyIt(
      it.key == "j" and it.modifiers == 0'u32 and
        it.command == "focus-window-or-workspace-down"
    )
    check fallbacks.anyIt(
      it.key == "k" and it.modifiers == 0'u32 and
        it.command == "focus-window-or-workspace-up"
    )

  test "Niri recent fallback keys use held switcher modifiers":
    var model = initRuntimeStateFromConfig(Config()).model
    discard model.setActiveModifiers(8'u32)

    let fallbacks = model.recentOpenFallbackKeyBindings()

    check fallbacks.anyIt(
      it.key == "Left" and it.modifiers == 8'u32 and it.command == "recent-window-prev"
    )
    check fallbacks.anyIt(
      it.key == "Right" and it.modifiers == 8'u32 and it.command == "recent-window-next"
    )
    check fallbacks.anyIt(
      it.key == "Home" and it.modifiers == 8'u32 and it.command == "recent-window-first"
    )
    check fallbacks.anyIt(
      it.key == "End" and it.modifiers == 8'u32 and it.command == "recent-window-last"
    )
    check not fallbacks.anyIt(it.key == "Up")
    check not fallbacks.anyIt(it.key == "Down")

  test "Niri recent fallback keys preserve user recent bindings":
    var model = initRuntimeStateFromConfig(Config()).model
    discard model.setActiveModifiers(8'u32)
    model.keyBindings.add(
      KeyBindingConfig(
        key: "Left",
        modifiers: 8'u32,
        command: "custom-recent-left",
        mode: BindingMode.BindRecent,
      )
    )

    let fallbacks = model.recentOpenFallbackKeyBindings()

    check not fallbacks.anyIt(
      it.key == "Left" and it.modifiers == 8'u32 and it.command == "recent-window-prev"
    )
    check fallbacks.anyIt(
      it.key == "Right" and it.modifiers == 8'u32 and it.command == "recent-window-next"
    )

  test "Niri recent fallback keys derive user direction keys":
    var model = initRuntimeStateFromConfig(Config()).model
    discard model.setActiveModifiers(8'u32)
    model.keyBindings =
      @[
        KeyBindingConfig(
          key: "h",
          modifiers: 64'u32,
          command: "focus-left",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "l",
          modifiers: 64'u32,
          command: "focus-right",
          mode: BindingMode.BindNormal,
        ),
        KeyBindingConfig(
          key: "j",
          modifiers: 64'u32,
          command: "focus-down",
          mode: BindingMode.BindAlways,
        ),
        KeyBindingConfig(
          key: "k", modifiers: 64'u32, command: "focus-up", mode: BindingMode.BindAlways
        ),
        KeyBindingConfig(
          key: "Left",
          modifiers: 8'u32,
          command: "focus-left",
          mode: BindingMode.BindAlways,
        ),
      ]

    let fallbacks = model.recentOpenFallbackKeyBindings()

    check fallbacks.anyIt(
      it.key == "h" and it.modifiers == 8'u32 and it.command == "recent-window-prev"
    )
    check fallbacks.anyIt(
      it.key == "l" and it.modifiers == 8'u32 and it.command == "recent-window-next"
    )
    check fallbacks.anyIt(
      it.key == "Left" and it.modifiers == 8'u32 and it.command == "recent-window-prev"
    )
    check not fallbacks.anyIt(it.key == "j")
    check not fallbacks.anyIt(it.key == "k")

  test "duplicate window create keeps a single shell window":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    for title in ["old", "new"]:
      let (next, _) = model.update(
        Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "app", title: title)
      )
      model = next

    let snapshot = model.shellSnapshot()
    check model.validateInvariants().ok
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 10
    check snapshot.windows[0].title == "new"

  test "stale focus command paths are no-ops, not crashes":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model

    for msg in [
      Msg(kind: MsgKind.CmdMoveToScratchpad),
      Msg(kind: MsgKind.CmdConsumeWindow),
      Msg(kind: MsgKind.CmdExpelWindow),
      Msg(kind: MsgKind.CmdZoom),
      Msg(kind: MsgKind.CmdMoveWindowLeft),
      Msg(kind: MsgKind.CmdMoveWindowRight),
      Msg(kind: MsgKind.CmdToggleFloating),
      Msg(kind: MsgKind.CmdToggleFullscreen),
    ]:
      let (next, _) = model.update(msg)
      model = next
      check model.validateInvariants().ok
      check model.shellSnapshot().windows.len == 0

  test "river output and fullscreen events tolerate removal":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 42, width: 1280, height: 720),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 7, appId: "app", title: "title"),
      Msg(
        kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: 7,
        fullscreenOutputId: 0,
      ),
    ]:
      let (next, _) = model.update(msg)
      model = next

    var effects: seq[Effect]
    (model, effects) =
      model.update(Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: 42))
    check model.validateInvariants().ok
    check effects.anyIt(
      it.kind == EffectKind.EffSetFullscreen and it.fsWinId == 7 and not it.isFullscreen
    )

  test "dimension hints are normalized for daemon bounds":
    var model = initRuntimeStateFromConfig(Config()).model
    let (next, _) = model.update(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 7, appId: "app", title: "title")
    )
    model = next
    let (hinted, _) = model.update(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 7,
        minWidth: -10,
        minHeight: 200,
        maxWidth: 100,
        maxHeight: 50,
      )
    )
    let win = hinted.windowDataForRiverId(7).get()

    check win.minWidth == 0
    check win.minHeight == 200
    check win.maxWidth == 100
    check win.maxHeight == 200
    check win.boundedDimensions(50, 50) == (w: 50'i32, h: 200'i32)
    check win.boundedDimensions(500, 500) == (w: 100'i32, h: 200'i32)
    check win.proposalDimensions(50, 50, honorMinimums = false) == (
      w: 50'i32, h: 50'i32
    )
    check win.proposalDimensions(500, 500, honorMinimums = false) ==
      (w: 100'i32, h: 200'i32)
    check win.needsCellClip(100, 100)
    check not win.needsCellClip(100, 220)

  test "window rule tiled-state controls River tiled edges":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(
              matches: @[WindowRuleMatcher(appIdSet: true, appId: "^float-default$")],
              openFloatingSet: true,
              openFloating: true,
            ),
            WindowRule(
              matches: @[WindowRuleMatcher(appIdSet: true, appId: "^force-tiled$")],
              openFloatingSet: true,
              openFloating: true,
              tiledStateSet: true,
              tiledState: true,
            ),
            WindowRule(
              matches: @[WindowRuleMatcher(appIdSet: true, appId: "^force-untiled$")],
              tiledStateSet: true,
              tiledState: false,
            ),
          ]
      )
    ).model

    let (next1, _) = model.update(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 1,
        appId: "normal-default",
        title: "Normal",
      )
    )
    model = next1
    let (next2, _) = model.update(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        appId: "float-default",
        title: "Float",
      )
    )
    model = next2
    let (next3, _) = model.update(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        appId: "force-tiled",
        title: "Force Tiled",
      )
    )
    model = next3
    let (next4, _) = model.update(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        appId: "force-untiled",
        title: "Force Untiled",
      )
    )
    model = next4

    check model.tiledEdgesForWindow(model.windowDataForRiverId(1'u32).get()) ==
      RiverAllEdges
    check model.tiledEdgesForWindow(model.windowDataForRiverId(2'u32).get()) == 0'u32
    check model.tiledEdgesForWindow(model.windowDataForRiverId(3'u32).get()) ==
      RiverAllEdges
    check model.tiledEdgesForWindow(model.windowDataForRiverId(4'u32).get()) == 0'u32

  test "Niri compatibility rejects malformed IPC without crashing":
    let malformed = niri_compat.handleNiriRequest("{", baseSnapshot())
    check malformed.handled
    check parseJson(malformed.reply)["Err"].getStr().len > 0

    let unknown = niri_compat.handleNiriRequest(
      """{"Action":{"NotARealAction":{}}}""", baseSnapshot()
    )
    check unknown.handled
    check parseJson(unknown.reply)["Err"].getStr().len > 0

  test "text command parser tolerates malformed commands":
    check parseTextCommand("").isNone
    check parseTextCommand("focus-workspace nope").isNone
    check parseTextCommand("focus-workspace 2").get().kind ==
      MsgKind.CmdFocusWorkspaceIndex

  test "dev mode control IPC validates arguments":
    let bad = parseJson(socket.handleDevModeControl("dev-mode maybe").get())
    check not bad["ok"].getBool()
    check bad["type"].getStr() == "dev-mode"

    let extra = parseJson(socket.handleDevModeControl("dev-mode on now").get())
    check not extra["ok"].getBool()

  test "native live restore parser rejects invalid or old payloads":
    check parseLiveRestoreJson("").isNone
    check parseLiveRestoreJson("""{"workspaces":[{"id":1}]}""").isNone
    check not liveRestorePayloadApplied(
      """{"restore_status":"applied","active_tag":1}"""
    )
    let parsed = parseLiveRestoreJson(
      """
{
  "schema": "triad-live-restore-v2",
  "active_tag": 1,
  "tags": [{"id": 1, "layout_mode": "scroller"}]
}
"""
    )
    check parsed.isSome
    check parsed.get().activeTag == 1

  test "live restore completion preserves applied diagnostic snapshot":
    let path =
      getTempDir() / ("triad-live-restore-test-" & $getCurrentProcessId() & ".json")
    try:
      writeFile(
        path,
        """
{
  "schema": "triad-live-restore-v2",
  "restore_status": "pending",
  "active_tag": 1,
  "tags": [{"id": 1, "layout_mode": "scroller"}]
}
""",
      )
      check loadLiveRestoreState(path).isSome
      check completeLiveRestoreState(path)
      check fileExists(path)
      check liveRestoreStateApplied(path)
      check loadLiveRestoreState(path).isNone

      let applied = parseJson(readFile(path))
      check applied["restore_status"].getStr() == LiveRestoreStatusApplied
      check applied.hasKey("applied_at_unix_ms")
      check applied.hasKey("applied_by_pid")
    finally:
      if fileExists(path):
        removeFile(path)

  test "live restore collapse guard detects same-window collapse":
    var previous = LiveRestoreState(activeTag: 2)
    previous.windows[10'u32] = RestoredWindowState(tagId: 1)
    previous.windows[20'u32] = RestoredWindowState(tagId: 2)

    var candidate = LiveRestoreState(activeTag: 1)
    candidate.windows[10'u32] = RestoredWindowState(tagId: 1)
    candidate.windows[20'u32] = RestoredWindowState(tagId: 1)

    check previous.suspiciousLiveRestoreCollapse(candidate)

    candidate.windows[20'u32] = RestoredWindowState(tagId: 2)
    check not previous.suspiciousLiveRestoreCollapse(candidate)

  test "layout functions handle nonnegative rectangles":
    let screen = Rect(x: 0, y: 0, w: 100, h: 80)
    var tag = ProjectedTag(
      tagId: 1,
      layoutMode: LayoutMode.Scroller,
      focusedWindow: 1,
      masterCount: 1,
      masterSplitRatio: 0.5,
    )
    tag.columns.add(
      ProjectedColumn(windows: @[ProjectionWindowId(1), 2], widthProportion: 0.5)
    )

    let scroller = layoutScroller(
      tag,
      initTable[ProjectionWindowId, ProjectedWindow](),
      screen,
      4,
      2,
      false,
      false,
      "never",
    )
    let tiled = layoutMasterStack(tag, screen, 4, 2)

    for instruction in scroller & tiled:
      check instruction.geom.w >= 0
      check instruction.geom.h >= 0
