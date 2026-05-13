import std/[algorithm, os, strutils, unittest]
import ../src/config/parser
import ../src/core/msg
import ../src/state/[invariants, snapshot]
import ../src/systems/[runtime_facade, update]
import ../src/types/[model, runtime_values]
import tag_semantics_checks

type
  FuzzRng = object
    state: uint64

  FuzzContext = object
    seed: uint64
    step: int
    op: string

proc initRng(seed: uint64): FuzzRng =
  FuzzRng(state: if seed == 0: 0x9e3779b97f4a7c15'u64 else: seed)

proc next(rng: var FuzzRng): uint64 =
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rng.state = x
  x

proc pick(rng: var FuzzRng, upperExclusive: int): int =
  if upperExclusive <= 0:
    return 0
  int(rng.next() mod uint64(upperExclusive))

proc chance(rng: var FuzzRng, numerator, denominator: int): bool =
  rng.pick(denominator) < numerator

proc parseUIntEnv(name: string, fallback: uint64): uint64 =
  let value = getEnv(name, "")
  if value.len == 0:
    return fallback
  try:
    let parsed = parseBiggestUInt(value)
    if parsed > 0'u64:
      return uint64(parsed)
  except CatchableError:
    discard
  fallback

proc baseModel(): Model =
  initRuntimeStateFromConfig(
    Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.6,
        defaultWindowWidth: 0.8,
        defaultWindowHeight: 0.7,
        enableAnimations: true,
        animationSpeed: 0.2,
        layoutCycle:
          @[LayoutMode.Scroller, LayoutMode.Grid, LayoutMode.Deck, LayoutMode.Monocle],
      ),
      workspaces: WorkspaceConfig(defaultCount: 4),
    )
  ).model

proc modelSummary(model: Model): string =
  let snapshot = model.shellSnapshot()
  "activeTag=" & $snapshot.activeTag & " workspaces=" & $snapshot.workspaces.len &
    " windows=" & $snapshot.windows.len & " overview=" & $snapshot.overviewActive

proc fail(ctx: FuzzContext, model: Model, msg: string) =
  raise newException(
    AssertionDefect,
    "stress failure: " & msg & " seed=" & $ctx.seed & " step=" & $ctx.step & " op=" &
      ctx.op & " " & model.modelSummary(),
  )

proc require(ctx: FuzzContext, model: Model, cond: bool, msg: string) =
  if not cond:
    fail(ctx, model, msg)

proc existingWindows(model: Model): seq[WindowId] =
  for win in model.shellSnapshot().windows:
    result.add(win.id)
  result.sort()

proc chooseWindow(rng: var FuzzRng, model: Model): WindowId =
  let wins = model.existingWindows()
  if wins.len > 0 and rng.chance(3, 4):
    wins[rng.pick(wins.len)]
  else:
    WindowId(1 + rng.pick(96))

proc chooseDelta(rng: var FuzzRng, magnitude = 40): int32 =
  int32(rng.pick(magnitude * 2 + 1) - magnitude)

proc chooseLayout(rng: var FuzzRng): LayoutMode =
  LayoutMode(rng.pick(ord(high(LayoutMode)) + 1))

proc generatedMsg(rng: var FuzzRng, model: Model, nextWindow: var WindowId): Msg =
  case rng.pick(42)
  of 0:
    result = Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: nextWindow,
      appId: "app-" & $nextWindow,
      title: "window-" & $nextWindow,
    )
    inc nextWindow
  of 1:
    result = Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: rng.chooseWindow(model))
  of 2:
    result = Msg(kind: MsgKind.WlFocusChanged, newFocusedId: rng.chooseWindow(model))
  of 3:
    result =
      Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: uint32(1 + rng.pick(6)))
  of 4:
    result = Msg(
      kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: uint32(1 + rng.pick(6))
    )
  of 5:
    result = Msg(
      kind: MsgKind.CmdSetLayout,
      newLayout: rng.chooseLayout(),
      layoutTargetTag: uint32(rng.pick(5)),
    )
  of 6:
    result = Msg(kind: MsgKind.CmdToggleFloating)
  of 7:
    result = Msg(kind: MsgKind.CmdToggleFullscreen)
  of 8:
    result = Msg(
      kind: MsgKind.CmdMoveFloating,
      moveDX: rng.chooseDelta(),
      moveDY: rng.chooseDelta(),
    )
  of 9:
    result = Msg(
      kind: MsgKind.CmdResizeFloating,
      deltaFW: rng.chooseDelta(),
      deltaFH: rng.chooseDelta(),
    )
  of 10:
    result = Msg(kind: MsgKind.CmdMoveWindowLeft)
  of 11:
    result = Msg(kind: MsgKind.CmdMoveWindowRight)
  of 12:
    result = Msg(kind: MsgKind.CmdMoveWindowUp)
  of 13:
    result = Msg(kind: MsgKind.CmdMoveWindowDown)
  of 14:
    result = Msg(kind: MsgKind.CmdMoveToScratchpad)
  of 15:
    result = Msg(kind: MsgKind.CmdToggleScratchpad)
  of 16:
    result = Msg(kind: MsgKind.CmdToggleOverview)
  of 17:
    result = Msg(kind: MsgKind.CmdAdjustGaps, deltaG: rng.chooseDelta(8))
  of 18:
    result = Msg(
      kind: MsgKind.WlOutputDimensions,
      outputId: uint32(1 + rng.pick(3)),
      width: int32(640 + rng.pick(1920)),
      height: int32(480 + rng.pick(1080)),
    )
  of 19:
    result =
      Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: uint32(1 + rng.pick(3)))
  of 20:
    result = Msg(
      kind: MsgKind.WlWindowDimensions,
      dimensionsWindowId: rng.chooseWindow(model),
      actualWidth: int32(rng.pick(2000)),
      actualHeight: int32(rng.pick(1200)),
    )
  of 21:
    result = Msg(kind: MsgKind.CmdFocusNext)
  of 22:
    result = Msg(kind: MsgKind.CmdFocusPrev)
  of 23:
    result = Msg(kind: MsgKind.CmdFocusTagLeft)
  of 24:
    result = Msg(kind: MsgKind.CmdFocusTagRight)
  of 25:
    result = Msg(kind: MsgKind.CmdFocusOccupiedTagLeft)
  of 26:
    result = Msg(kind: MsgKind.CmdFocusOccupiedTagRight)
  of 27:
    result = Msg(kind: MsgKind.CmdMoveToTagLeft)
  of 28:
    result = Msg(kind: MsgKind.CmdMoveToTagRight)
  of 29:
    result = Msg(kind: MsgKind.CmdMoveWindowUpOrToWorkspaceUp)
  of 30:
    result = Msg(kind: MsgKind.CmdMoveWindowDownOrToWorkspaceDown)
  of 31:
    result =
      Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: rng.chooseWindow(model))
  of 32:
    result = Msg(kind: MsgKind.CmdOpenOverview)
  of 33:
    result = Msg(kind: MsgKind.CmdCloseOverview)
  of 34:
    result = Msg(kind: MsgKind.CmdSelectWindow)
  of 35:
    result = Msg(
      kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: rng.chooseWindow(model),
    )
  of 36:
    result = Msg(
      kind: MsgKind.WlWindowUnmaximizeRequested,
      unmaximizeRequestId: rng.chooseWindow(model),
    )
  of 37:
    result = Msg(
      kind: MsgKind.WlWindowMinimizeRequested,
      minimizeRequestId: rng.chooseWindow(model),
    )
  of 38:
    result = Msg(kind: MsgKind.CmdToggleMaximized)
  of 39:
    result = Msg(
      kind: MsgKind.CmdToggleFullscreenById, fullscreenWindowId: rng.chooseWindow(model)
    )
  of 40:
    result = Msg(
      kind: MsgKind.CmdSetLayout,
      newLayout: LayoutMode.TGMix,
      layoutTargetTag: uint32(rng.pick(7)),
    )
  else:
    result = Msg(kind: MsgKind.CmdTick)

proc checkInvariants(ctx: FuzzContext, model: Model) =
  let report = model.validateInvariants()
  if not report.ok:
    var errors: seq[string]
    for error in report.errors:
      errors.add(error.message)
    fail(ctx, model, errors.join("; "))

  try:
    model.requireTagShellSemantics(
      "stress seed=" & $ctx.seed & " step=" & $ctx.step & " op=" & ctx.op
    )
  except AssertionDefect as e:
    fail(ctx, model, e.msg)

suite "Deterministic runtime stress":
  test "random reducer trace preserves invariants":
    let seed = parseUIntEnv("TRIAD_STRESS_SEED", 0xC0FFEE'u64)
    let steps = int(parseUIntEnv("TRIAD_STRESS_STEPS", 400))
    var rng = initRng(seed)
    var model = baseModel()
    var nextWindow = WindowId(1)

    for step in 0 ..< steps:
      var ctx = FuzzContext(seed: seed, step: step)
      let msg = rng.generatedMsg(model, nextWindow)
      ctx.op = $msg.kind
      let (next, _) = model.update(msg)
      model = next
      checkInvariants(ctx, model)

    check model.validateInvariants().ok
