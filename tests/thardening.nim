import
  std/[
    asyncdispatch, asyncnet, json, nativesockets, options, os, sequtils, strtabs,
    strutils, tables, unittest,
  ]
import ../src/config/parser
import ../src/core/[effects, msg, restore_state]
import
  ../src/daemon/[
    bindings_runtime, child_process_runtime, cursor_shake, effects_runtime,
    input_device_classification, live_restore_runtime, memory_status, message_queue,
    output_management_runtime, process_runner, reload_runtime, render_invalidation,
    spawn_context, switch_event_runtime,
  ]
from ../src/daemon/state import
  OutputManagementHeadRuntime, consumeMaximizedAck, expectMaximizedAck, initTriadDaemon
from ../src/daemon/state import QueuedMsgOrigin
import ../src/ipc/[binding_dispatch, commands, niri_compat, socket]
import ../src/layouts/scroller
import ../src/state/[invariants, snapshot]
import ../src/systems/[daemon_view, runtime, runtime_facade, update]
from ../src/types/model import Model, OutputRuleData
import ../src/types/[projection_values, runtime_values, shell_snapshot]
import ../src/utils/[process_memory, session_env]

var observedConfigNotificationEvent: ConfigNotificationEvent
var observedConfigNotificationCommand: seq[string]

proc recordConfigNotification(
    daemon: pointer, event: ConfigNotificationEvent, command: seq[string]
) {.nimcall.} =
  discard daemon
  observedConfigNotificationEvent = event
  observedConfigNotificationCommand = command

proc proposedOutput(
    name: string, width, height: int32, rule = OutputRuleData()
): ProposedHead =
  ProposedHead(
    head: OutputManagementHeadRuntime(name: name, enabled: true, enabledSet: true),
    ruleOpt: (found: rule.target.len > 0 or rule.positionSet, rule: rule),
    enabled: true,
    width: width,
    height: height,
  )

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

proc discardIpcMsg(msg: Msg) {.gcsafe.} =
  discard msg

proc hardeningIpcSnapshot(): ShellSnapshot {.gcsafe.} =
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

proc persistentNiriReplies(
    path: string, idleDelayMs = 0, requestTimeoutMs = IpcRequestTimeoutMs
): Future[seq[string]] {.async.} =
  asyncCheck socket.startIpcServer(
    path, discardIpcMsg, hardeningIpcSnapshot, requestTimeoutMs = requestTimeoutMs
  )

  var ready = false
  for _ in 0 ..< 50:
    if await socket.unixSocketAcceptsConnections(path):
      ready = true
      break
    await sleepAsync(10)
  doAssert ready

  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    await client.connectUnix(path)
    await client.send("\"Workspaces\"\L")
    result.add(await client.recvLine())
    if idleDelayMs > 0:
      await sleepAsync(idleDelayMs)
    await client.send("""{"Action":{"FocusWorkspace":{"reference":{"Id":1}}}}""" & "\L")
    result.add(await client.recvLine())
  finally:
    if not client.isClosed:
      client.close()

proc triadSubscriberCountAfterClientClose(path: string): Future[int] {.async.} =
  socket.triadSubscribers.setLen(0)
  asyncCheck socket.startIpcServer(
    path, discardIpcMsg, hardeningIpcSnapshot, requestTimeoutMs = IpcNoRequestTimeoutMs
  )

  var ready = false
  for _ in 0 ..< 50:
    if await socket.unixSocketAcceptsConnections(path):
      ready = true
      break
    await sleepAsync(10)
  doAssert ready

  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    await client.connectUnix(path)
    await client.send(
      """{"triad":{"version":1,"request":"event-stream","events":["state"]}}""" & "\L"
    )
    discard await client.recvLine()
    discard await client.recvLine()
  finally:
    if not client.isClosed:
      client.close()

  for _ in 0 ..< 50:
    if socket.triadSubscribers.len == 0:
      break
    await sleepAsync(10)
  result = socket.triadSubscribers.len
  socket.triadSubscribers.setLen(0)

suite "Crash hardening":
  test "output layout row resolves left-to-right physical coordinates":
    var model = Model(
      outputLayoutRows:
        @[
          OutputLayoutRow(
            targets: @["DP-3", "DP-2", "DP-1"], align: OutputLayoutRowAlign.Center
          )
        ]
    )
    var heads =
      @[
        proposedOutput("DP-1", 1920, 1080),
        proposedOutput("DP-2", 2560, 1440),
        proposedOutput("DP-3", 1920, 1080),
      ]

    model.resolveLayoutPositions(heads)

    check heads.mapIt((it.head.name, it.x, it.y)) ==
      @[
        ("DP-1", 4480'i32, 180'i32), ("DP-2", 1920'i32, 0'i32), ("DP-3", 0'i32, 180'i32)
      ]

  test "output layout matrix supports stacked monitors":
    var model = Model(
      outputLayoutRows:
        @[
          OutputLayoutRow(targets: @["DP-1"], align: OutputLayoutRowAlign.Center),
          OutputLayoutRow(targets: @["DP-2"], align: OutputLayoutRowAlign.Center),
        ]
    )
    var heads =
      @[proposedOutput("DP-1", 1920, 1080), proposedOutput("DP-2", 2560, 1440)]

    model.resolveLayoutPositions(heads)

    check heads.mapIt((it.head.name, it.x, it.y)) ==
      @[("DP-1", 320'i32, 0'i32), ("DP-2", 0'i32, 1080'i32)]

  test "output layout centers uneven rows and closes missing target gaps":
    var model = Model(
      outputLayoutRows:
        @[
          OutputLayoutRow(targets: @["DP-4"], align: OutputLayoutRowAlign.Center),
          OutputLayoutRow(
            targets: @["DP-3", "missing-output", "DP-2"],
            align: OutputLayoutRowAlign.Center,
          ),
        ]
    )
    var heads =
      @[
        proposedOutput("DP-2", 2000, 1000),
        proposedOutput("DP-3", 1000, 1000),
        proposedOutput("DP-4", 1000, 500),
      ]

    model.resolveLayoutPositions(heads)

    check heads.mapIt((it.head.name, it.x, it.y)) ==
      @[
        ("DP-2", 1000'i32, 500'i32), ("DP-3", 0'i32, 500'i32), ("DP-4", 1000'i32, 0'i32)
      ]

  test "output layout seeds existing auto placement for unlisted outputs":
    var model = Model(
      outputLayoutRows:
        @[
          OutputLayoutRow(
            targets: @["DP-1", "DP-2"], align: OutputLayoutRowAlign.Center
          )
        ]
    )
    var heads =
      @[
        proposedOutput("DP-1", 1000, 1000),
        proposedOutput("DP-2", 1000, 1000),
        proposedOutput(
          "DP-9",
          500,
          500,
          OutputRuleData(
            target: "DP-9",
            positionSet: true,
            positionKind: OutputPositionKind.OutputPositionAutoRight,
          ),
        ),
      ]

    model.resolveLayoutPositions(heads)
    heads.resolveAutoPositions()

    check heads.mapIt((it.head.name, it.x, it.y)) ==
      @[("DP-1", 0'i32, 0'i32), ("DP-2", 1000'i32, 0'i32), ("DP-9", 2000'i32, 0'i32)]

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

  test "message queue preserves Janet hook origin":
    var daemon = initTriadDaemon()

    daemon.enqueue(Msg(kind: MsgKind.CmdFocusTag, focusTag: 2))
    daemon.enqueue(
      Msg(kind: MsgKind.CmdMoveToTag, targetTag: 3), QueuedMsgOrigin.JanetHook
    )

    let normal = daemon.popQueuedMessageWithOrigin()
    let hook = daemon.popQueuedMessageWithOrigin()
    check normal.origin == QueuedMsgOrigin.Normal
    check normal.msg.focusTag == 2
    check hook.origin == QueuedMsgOrigin.JanetHook
    check hook.msg.targetTag == 3

  test "message queue can drop pending output removals":
    var daemon = initTriadDaemon()

    daemon.enqueue(Msg(kind: MsgKind.CmdFocusTag, focusTag: 2))
    daemon.enqueue(Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: 1))
    daemon.enqueue(Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: 2))
    daemon.enqueue(
      Msg(kind: MsgKind.CmdMoveToTag, targetTag: 3), QueuedMsgOrigin.JanetHook
    )

    check daemon.dropQueuedOutputRemovals() == 2
    let normal = daemon.popQueuedMessageWithOrigin()
    let hook = daemon.popQueuedMessageWithOrigin()
    check normal.msg.kind == MsgKind.CmdFocusTag
    check normal.msg.focusTag == 2
    check normal.origin == QueuedMsgOrigin.Normal
    check hook.msg.kind == MsgKind.CmdMoveToTag
    check hook.msg.targetTag == 3
    check hook.origin == QueuedMsgOrigin.JanetHook
    check not daemon.hasQueuedMessages()

  test "render start skip requires clean render state":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(Config())

    check daemon.renderDirty
    check not daemon.canSkipRenderStart()

    daemon.markRenderCleanAfterFullRender()
    check daemon.canSkipRenderStart()

    daemon.markRenderDirty("layout")
    check daemon.renderDirtyReason == "layout"
    check not daemon.canSkipRenderStart()

  test "render start fast path bypasses general runtime update":
    let source = readFile("src/daemon/app.nim")
    let renderStart = source.find("if msg.kind == MsgKind.WlRenderStart:")
    let runtimeUpdate = source.find("let effects = syncRuntimeUpdate")

    check renderStart >= 0
    check runtimeUpdate >= 0
    check renderStart < runtimeUpdate

  test "clean render start is finished in callback without queueing":
    let source = readFile("src/daemon/river_manager_runtime.nim")
    let renderStart = source.find("proc onRenderStart")
    let cleanSkip = source.find("daemon[].canSkipRenderStart()")
    let renderFinish = source.find("mgr.renderFinish()")
    let enqueue = source.find("daemon.enqueue(Msg(kind: MsgKind.WlRenderStart))")

    check renderStart >= 0
    check cleanSkip > renderStart
    check renderFinish > cleanSkip
    check enqueue > renderFinish

  test "pending admissions force full render start":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(Config())
    discard daemon.runtimeState.applyRuntimeUpdate(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 42,
        appId: "app",
        title: "Pending",
        deferAdmission: true,
      )
    )
    daemon.markRenderCleanAfterFullRender()

    check not daemon.canSkipRenderStart()

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

  test "fire-and-forget child processes are tracked and reaped":
    var daemon = initTriadDaemon()
    let child = spawnCommand(Model(), @["sh", "-c", "exit 7"])

    daemon.trackChildProcess(child, "test-child")
    check daemon.fireAndForgetProcesses.len == 1

    var reaped = 0
    for _ in 0 ..< 20:
      reaped += daemon.reapChildProcesses()
      if reaped > 0:
        break
      sleep(25)

    check reaped == 1
    check daemon.fireAndForgetProcesses.len == 0

  test "spawn placement context matches descendant window pid":
    var daemon = initTriadDaemon()
    daemon.rememberSpawnPlacementForPid(100, 2, 4, "DP-2", "launcher")
    proc parentPid(pid: int32): int32 {.gcsafe.} =
      case pid
      of 120: 110
      of 110: 100
      else: 0

    let context = daemon.consumeSpawnPlacementForPid(120, parentPid)

    check context.pid == 100
    check context.outputId == 2
    check context.slot == 4
    check daemon.pendingSpawnPlacements.len == 0

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

  test "IPC binding dispatch triggers configured active bindings":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        hotkeyOverlay: HotkeyOverlayConfig(skipAtStartup: true),
        keyBindings:
          @[
            KeyBindingConfig(key: "h", modifiers: 64'u32, command: "focus-left"),
            KeyBindingConfig(
              key: "k",
              modifiers: 64'u32,
              command: "focus-up",
              mode: BindingMode.BindOverview,
            ),
          ],
        pointerBindings:
          @[
            PointerBindingConfig(
              button: 0x112'u32, modifiers: 64'u32, command: "focus-right"
            ),
            PointerBindingConfig(
              button: 0x110'u32,
              modifiers: 64'u32,
              op: PointerOpKind.OpMove,
              command: "move",
            ),
          ],
        axisBindings:
          @[
            AxisBindingConfig(
              direction: AxisBindingDirection.AxisUp,
              modifiers: 64'u32,
              command: "focus-left",
            )
          ],
        gestureBindings:
          @[
            GestureBindingConfig(
              direction: GestureBindingDirection.GestureSwipeLeft,
              fingers: 3,
              modifiers: 64'u32,
              command: "focus-left",
            )
          ],
      )
    )

    let keyResult = daemon.dispatchBindingRequest(
      BindingDispatchRequest(
        kind: BindingDispatchKind.BindKey, binding: "Super+h", ticks: 1
      )
    )
    check keyResult.ok
    check daemon.popQueuedMessage().direction == Direction.DirLeft

    check not daemon.dispatchBindingRequest(
      BindingDispatchRequest(
        kind: BindingDispatchKind.BindKey, binding: "Super+k", ticks: 1
      )
    ).ok
    daemon.runtimeState.model.overviewActive = true
    check daemon.dispatchBindingRequest(
      BindingDispatchRequest(
        kind: BindingDispatchKind.BindKey, binding: "Super+k", ticks: 1
      )
    ).ok
    check daemon.popQueuedMessage().direction == Direction.DirUp
    daemon.runtimeState.model.overviewActive = false

    check daemon.dispatchBindingRequest(
      BindingDispatchRequest(
        kind: BindingDispatchKind.BindPointer, binding: "Super+middle", ticks: 1
      )
    ).ok
    check daemon.popQueuedMessage().direction == Direction.DirRight
    check not daemon.dispatchBindingRequest(
      BindingDispatchRequest(
        kind: BindingDispatchKind.BindPointer, binding: "Super+left", ticks: 1
      )
    ).ok

    let axisResult = daemon.dispatchBindingRequest(
      BindingDispatchRequest(
        kind: BindingDispatchKind.BindAxis, binding: "Super+wheel-up", ticks: 2
      )
    )
    check axisResult.ok
    check axisResult.dispatched == 2
    check daemon.popQueuedMessage().direction == Direction.DirLeft
    check daemon.popQueuedMessage().direction == Direction.DirLeft

    check daemon.dispatchBindingRequest(
      BindingDispatchRequest(
        kind: BindingDispatchKind.BindGesture,
        binding: "Super+swipe-left",
        ticks: 1,
        fingers: 3,
      )
    ).ok
    check daemon.popQueuedMessage().direction == Direction.DirLeft

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

  test "daemon overview hot corner blocked enter can still open before leave":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(
      Config(
        overview:
          OverviewConfig(hotCorners: OverviewHotCornersConfig(size: 10, topLeft: true))
      )
    )
    daemon.runtimeState.model.screenWidth = 100
    daemon.runtimeState.model.screenHeight = 100
    daemon.runtimeState.model.layerFocusExclusive = true

    check not daemon.updateOverviewHotCornerState(1, 0, 0)
    daemon.runtimeState.model.layerFocusExclusive = false
    check daemon.updateOverviewHotCornerState(1, 5, 5)
    check not daemon.updateOverviewHotCornerState(1, 6, 6)

  test "daemon overview hot corner successful open requires leave before reopen":
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
    daemon.runtimeState.model.overviewActive = true
    check not daemon.updateOverviewHotCornerState(1, 5, 5)
    daemon.runtimeState.model.overviewActive = false
    check not daemon.updateOverviewHotCornerState(1, 5, 5)
    check not daemon.updateOverviewHotCornerState(1, 50, 50)
    check daemon.updateOverviewHotCornerState(1, 0, 0)

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
    daemon.xkbBindings[99'u32] = Msg(kind: MsgKind.CmdCloseWindow)

    check daemon.applyConfigReload(configPath, "")
    check daemon.bindingsConfigured
    check daemon.bindingsReconfigurePending
    check daemon.xkbBindings.hasKey(99'u32)
    check daemon.liveRestoreCommitPending
    check fileExists(restorePath)
    check not liveRestoreStateApplied(restorePath)

    if fileExists(configPath):
      removeFile(configPath)
    if fileExists(restorePath):
      removeFile(restorePath)

  test "binding reconfigure request preserves active bindings until manage":
    var daemon = initTriadDaemon()
    daemon.bindingsConfigured = true
    daemon.xkbBindings[77'u32] = Msg(kind: MsgKind.CmdCloseWindow)
    daemon.xkbBindingModes[77'u32] = BindingMode.BindAlways

    daemon.requestBindingReconfigure("test")

    check daemon.bindingsConfigured
    check daemon.bindingsReconfigurePending
    check daemon.xkbBindings.hasKey(77'u32)
    check daemon.xkbBindingModes.hasKey(77'u32)
    check not daemon.hasQueuedMessages()

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

  test "Niri command socket accepts repeated requests":
    let path =
      getTempDir() / ("triad-niri-persistent-" & $getCurrentProcessId() & ".sock")
    if fileExists(path):
      removeFile(path)

    let replies = waitFor persistentNiriReplies(path)
    check replies.len == 2
    check parseJson(replies[0])["Ok"].hasKey("Workspaces")
    check replies[1] == """{"Ok":"Handled"}"""

  test "Niri command socket can idle between repeated requests":
    let path = getTempDir() / ("triad-niri-idle-" & $getCurrentProcessId() & ".sock")
    if fileExists(path):
      removeFile(path)

    let replies = waitFor persistentNiriReplies(
      path, idleDelayMs = 60, requestTimeoutMs = IpcNoRequestTimeoutMs
    )
    check replies.len == 2
    check parseJson(replies[0])["Ok"].hasKey("Workspaces")
    check replies[1] == """{"Ok":"Handled"}"""

  test "native Triad event-stream subscriber is pruned after client close":
    let path = getTempDir() / ("triad-native-prune-" & $getCurrentProcessId() & ".sock")
    if fileExists(path):
      removeFile(path)

    check (waitFor triadSubscriberCountAfterClientClose(path)) == 0

  test "text command parser tolerates malformed commands":
    check parseTextCommand("").isNone
    check parseTextCommand("focus-workspace nope").isNone
    check parseTextCommand("focus-workspace 2").get().kind ==
      MsgKind.CmdFocusWorkspaceIndex
    check parseTextCommand("new-workspace").get().kind == MsgKind.CmdNewWorkspace

  test "dev mode control IPC validates arguments":
    let bad = parseJson(socket.handleDevModeControl("dev-mode maybe").get())
    check not bad["ok"].getBool()
    check bad["type"].getStr() == "dev-mode"

    let extra = parseJson(socket.handleDevModeControl("dev-mode on now").get())
    check not extra["ok"].getBool()

  test "process memory parser reads proc status counters":
    let status = parseProcessMemoryStatus(
      """
Name: triad
VmPeak:    56264 kB
VmSize:    56264 kB
VmRSS:    54388 kB
RssAnon:    40100 kB
RssFile:    14288 kB
VmData:    38500 kB
VmSwap:        0 kB
"""
    )
    check status.available
    check status.vmPeakKiB == 56264
    check status.vmSizeKiB == 56264
    check status.vmRssKiB == 54388
    check status.rssAnonKiB == 40100
    check status.rssFileKiB == 14288
    check status.vmDataKiB == 38500
    check status.vmSwapKiB == 0
    check status.rssShmemKiB == -1

  test "daemon memory status includes model, ipc, and Janet diagnostics":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(Config())

    let status = parseJson(daemon.memoryStatusJson())
    check status["ok"].getBool()
    check status["type"].getStr() == "mem-status"
    check status["pid"].getInt() > 0
    check status.hasKey("process")
    check status.hasKey("nim")
    check status["model_counts"]["tags"].getInt() >= 0
    check status["daemon_counts"]["msg_queue"].getInt() == 0
    check status["protocol_surfaces"]["surfaces"].getInt() == 0
    check status["janet"]["handle_active"].getBool() == false
    check status["janet"].hasKey("janet_gc_heap_bytes")
    check status["ipc"].hasKey("total_subscribers")
    check status["memory_pressure"]["pending"].getBool() == false
    check status["memory_pressure"]["reason"].getStr() == ""

  test "window close burst schedules quiet memory compaction":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(Config())
    let startMs = 10_000'i64

    daemon.noteWindowDestroyedForMemoryPressure(startMs)
    daemon.noteWindowDestroyedForMemoryPressure(startMs + 100)
    daemon.noteWindowDestroyedForMemoryPressure(startMs + 200)
    check daemon.memoryPressureDueMs == 0

    daemon.noteWindowDestroyedForMemoryPressure(startMs + 300)
    check daemon.memoryPressureDueMs == startMs + 300 + 750
    check daemon.memoryPressureCloseCount == 4
    check daemon.memoryPressureReason == "window_close_burst"

    daemon.noteWindowDestroyedForMemoryPressure(startMs + 600)
    check daemon.memoryPressureDueMs == startMs + 600 + 750
    check daemon.memoryPressureCloseCount == 5

    daemon.maybeRunMemoryPressureCompaction(startMs + 600 + 749)
    check daemon.memoryPressureDueMs == startMs + 600 + 750

    daemon.enqueue(Msg(kind: MsgKind.CmdFocusNext))
    daemon.maybeRunMemoryPressureCompaction(startMs + 600 + 750)
    check daemon.memoryPressureDueMs == startMs + 600 + 1500
    discard daemon.popQueuedMessage()

    daemon.maybeRunMemoryPressureCompaction(startMs + 600 + 1500)
    check daemon.memoryPressureDueMs == 0
    check daemon.memoryPressureCloseCount == 0
    check daemon.memoryPressureReason == ""
    check daemon.closeBurstDestroyedCount == 0

  test "overview close schedules quiet memory compaction":
    var daemon = initTriadDaemon()
    daemon.runtimeState = initRuntimeStateFromConfig(Config())
    let startMs = 20_000'i64

    daemon.scheduleMemoryPressureCompaction("overview_closed", startMs)
    check daemon.memoryPressureDueMs == startMs + 750
    check daemon.memoryPressureReason == "overview_closed"
    check daemon.memoryPressureCloseCount == 0

    daemon.maybeRunMemoryPressureCompaction(startMs + 750)
    check daemon.memoryPressureDueMs == 0
    check daemon.memoryPressureReason == ""

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

  test "pending live restore is marked applied immediately after runtime apply":
    let path =
      getTempDir() / ("triad-live-restore-apply-" & $getCurrentProcessId() & ".json")
    try:
      writeFile(
        path,
        """
{
  "schema": "triad-live-restore-v2",
  "restore_status": "pending",
  "active_tag": 2,
  "tags": [{"id": 2, "layout_mode": "scroller"}]
}
""",
      )
      let restore = loadLiveRestoreState(path)
      check restore.isSome

      var daemon = initTriadDaemon()
      daemon.pendingLiveRestorePath = path
      daemon.pendingLiveRestore = restore
      daemon.runtimeState = initRuntimeStateFromConfig(Config())

      daemon.applyPendingLiveRestore("test")

      check daemon.pendingLiveRestore.isNone
      check not daemon.liveRestoreCommitPending
      check liveRestoreStateApplied(path)
      check loadLiveRestoreState(path).isNone
    finally:
      if fileExists(path):
        removeFile(path)

  test "runtime live restore write rejects collapse against applied snapshot":
    let path =
      getTempDir() / ("triad-live-restore-collapse-" & $getCurrentProcessId() & ".json")
    try:
      writeFile(
        path,
        """
{
  "schema": "triad-live-restore-v2",
  "restore_status": "applied",
  "active_tag": 2,
  "tags": [{"id": 1, "layout_mode": "scroller"}, {"id": 2, "layout_mode": "scroller"}],
  "windows": [{"id": 10, "tag_id": 1}, {"id": 20, "tag_id": 2}]
}
""",
      )

      var daemon = initTriadDaemon()
      daemon.pendingLiveRestorePath = path
      daemon.runtimeState =
        initRuntimeStateFromConfig(Config(workspaces: WorkspaceConfig(defaultCount: 2)))
      discard daemon.runtimeState.applyRuntimeUpdate(
        Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "app", title: "One")
      )
      discard daemon.runtimeState.applyRuntimeUpdate(
        Msg(kind: MsgKind.WlWindowCreated, windowId: 20, appId: "app", title: "Two")
      )

      let result = daemon.writeCurrentLiveRestoreState()

      check not result.ok
      check result.error == "refusing suspicious live restore collapse"
      check liveRestoreStateApplied(path)
      let retained = readLiveRestoreState(path)
      check retained.isSome
      check retained.get().windows[10'u32].tagId == 1
      check retained.get().windows[20'u32].tagId == 2
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
    for instruction in scroller:
      check instruction.geom.w >= 0
      check instruction.geom.h >= 0
