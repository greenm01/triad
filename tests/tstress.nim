import algorithm, json, options, os, sequtils, strutils, tables, unittest
import ../src/core/model
import ../src/core/model_utils
import ../src/core/msg
import ../src/core/update
import ../src/ipc/commands
import ../src/ipc/niri_compat
import ../src/layouts/scroller
import ../src/layouts/tiling

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

proc pick(rng: var FuzzRng; upperExclusive: int): int =
  if upperExclusive <= 0:
    return 0
  int(rng.next() mod uint64(upperExclusive))

proc chance(rng: var FuzzRng; numerator, denominator: int): bool =
  rng.pick(denominator) < numerator

proc parseUIntEnv(name: string; fallback: uint64): uint64 =
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
  result = Model(
    activeTag: 1,
    screenWidth: 1920,
    screenHeight: 1080,
    outerGaps: 10,
    innerGaps: 5,
    previousOuterGaps: 10,
    previousInnerGaps: 5,
    enableAnimations: true,
    animationSpeed: 0.2
  )
  result.tags[1] = initTagState(1, Scroller, "main")
  result.tags[2] = initTagState(2, Grid, "web")
  result.tags[3] = initTagState(3, MasterStack, "work")

proc modelSummary(model: Model): string =
  "activeTag=" & $model.activeTag &
    " tags=" & $model.tags.len &
    " windows=" & $model.windows.len &
    " scratchpad=" & $model.scratchpadWindows.len &
    " overview=" & $model.overviewActive &
    " size=" & $model.screenWidth & "x" & $model.screenHeight

proc fail(ctx: FuzzContext; model: Model; msg: string) =
  raise newException(AssertionDefect,
    "stress failure: " & msg &
    " seed=" & $ctx.seed &
    " step=" & $ctx.step &
    " op=" & ctx.op &
    " " & model.modelSummary())

proc require(ctx: FuzzContext; model: Model; cond: bool; msg: string) =
  if not cond:
    fail(ctx, model, msg)

proc existingWindows(model: Model): seq[WindowId] =
  for win in model.windows.keys:
    result.add(win)
  result.sort()

proc placedWindows(model: Model): seq[WindowId] =
  for tagId in model.tags.keys.toSeq.sorted():
    for win in model.tags[tagId].flattenWindows():
      result.add(win)

proc chooseWindow(rng: var FuzzRng; model: Model; preferPlaced = false): WindowId =
  let wins = if preferPlaced: model.placedWindows() else: model.existingWindows()
  if wins.len > 0 and rng.chance(3, 4):
    wins[rng.pick(wins.len)]
  else:
    WindowId(1 + rng.pick(96))

proc chooseTag(rng: var FuzzRng): uint32 =
  uint32(1 + rng.pick(6))

proc chooseDelta(rng: var FuzzRng; magnitude = 40): int32 =
  int32(rng.pick(magnitude * 2 + 1) - magnitude)

proc chooseRatio(rng: var FuzzRng): float32 =
  float32(rng.pick(240) - 70) / 100.0'f32

proc chooseLayout(rng: var FuzzRng): LayoutMode =
  LayoutMode(rng.pick(ord(high(LayoutMode)) + 1))

proc simpleCommand(rng: var FuzzRng): Msg =
  const kinds = [
    CmdFocusNext, CmdFocusPrev, CmdCloseWindow, CmdMoveColumnLeft,
    CmdMoveColumnRight, CmdSwapWindowUp, CmdSwapWindowDown, CmdConsumeWindow,
    CmdExpelWindow, CmdZoom, CmdToggleGaps, CmdMoveToScratchpad,
    CmdToggleScratchpad, CmdToggleOverview, CmdToggleFloating,
    CmdToggleFullscreen, CmdToggleMaximized, CmdMinimize, CmdSelectWindow, CmdTick
  ]
  Msg(kind: kinds[rng.pick(kinds.len)])

proc generatedMsg(rng: var FuzzRng; model: Model; ctx: var FuzzContext): seq[Msg] =
  case rng.pick(24)
  of 0:
    let win = chooseWindow(rng, model)
    ctx.op = "create window " & $win
    @[Msg(kind: WlWindowCreated, windowId: win, appId: "app-" & $rng.pick(8), title: "title-" & $rng.pick(12))]
  of 1:
    let win = chooseWindow(rng, model)
    ctx.op = "destroy window " & $win
    @[Msg(kind: WlWindowDestroyed, destroyedId: win)]
  of 2:
    let win = if rng.chance(1, 8): 0'u32 else: chooseWindow(rng, model, true)
    ctx.op = "focus changed " & $win
    @[Msg(kind: WlFocusChanged, newFocusedId: win)]
  of 3:
    const dims = [-100'i32, 0'i32, 1'i32, 20'i32, 360'i32, 1080'i32, 1920'i32, 7680'i32]
    let w = dims[rng.pick(dims.len)]
    let h = dims[rng.pick(dims.len)]
    ctx.op = "output dimensions " & $w & "x" & $h
    @[Msg(kind: WlOutputDimensions, width: w, height: h)]
  of 4:
    let mode = chooseLayout(rng)
    ctx.op = "set layout " & $mode
    @[Msg(kind: CmdSetLayout, newLayout: mode)]
  of 5:
    let tag = chooseTag(rng)
    ctx.op = "move to tag " & $tag
    @[Msg(kind: CmdMoveToTag, targetTag: tag)]
  of 6:
    let tag = chooseTag(rng)
    ctx.op = "swap to tag " & $tag
    @[Msg(kind: CmdSwapWindowToTag, targetTagSwap: tag)]
  of 7:
    let tag = chooseTag(rng)
    ctx.op = "focus tag " & $tag
    @[Msg(kind: CmdFocusTag, focusTag: tag)]
  of 8:
    let win = chooseWindow(rng, model)
    ctx.op = "focus window by id " & $win
    @[Msg(kind: CmdFocusWindowById, focusWindowId: win)]
  of 9:
    let win = chooseWindow(rng, model)
    ctx.op = "close window by id " & $win
    @[Msg(kind: CmdCloseWindowById, closeWindowId: win)]
  of 10:
    case rng.pick(7)
    of 0:
      let delta = chooseRatio(rng)
      ctx.op = "resize width " & $delta
      @[Msg(kind: CmdResizeWidth, deltaW: delta)]
    of 1:
      let delta = chooseRatio(rng)
      ctx.op = "resize height " & $delta
      @[Msg(kind: CmdResizeHeight, deltaH: delta)]
    of 2:
      let width = chooseRatio(rng)
      ctx.op = "set column width " & $width
      @[Msg(kind: CmdSetColumnWidth, targetWidth: width)]
    of 3:
      let delta = chooseDelta(rng)
      ctx.op = "adjust gaps " & $delta
      @[Msg(kind: CmdAdjustGaps, deltaG: delta)]
    of 4:
      let delta = chooseDelta(rng, 3)
      ctx.op = "adjust master count " & $delta
      @[Msg(kind: CmdAdjustMasterCount, deltaMC: int(delta))]
    of 5:
      let delta = chooseRatio(rng)
      ctx.op = "adjust master ratio " & $delta
      @[Msg(kind: CmdAdjustMasterRatio, deltaMR: delta)]
    else:
      let deltaW = chooseDelta(rng, 120)
      let deltaH = chooseDelta(rng, 120)
      ctx.op = "resize floating " & $deltaW & "," & $deltaH
      @[Msg(kind: CmdResizeFloating, deltaFW: deltaW, deltaFH: deltaH)]
  of 11:
    let msg = simpleCommand(rng)
    ctx.op = "simple command " & $msg.kind
    @[msg]
  of 12:
    let dx = chooseDelta(rng, 200)
    let dy = chooseDelta(rng, 200)
    ctx.op = "move floating " & $dx & "," & $dy
    @[Msg(kind: CmdMoveFloating, moveDX: dx, moveDY: dy)]
  of 13:
    let win = chooseWindow(rng, model)
    ctx.op = "window metadata " & $win
    if rng.chance(1, 2):
      @[Msg(kind: WlWindowAppId, appIdWindowId: win, updatedAppId: "late-app-" & $rng.pick(8))]
    else:
      @[Msg(kind: WlWindowTitle, titleWindowId: win, updatedTitle: "late-title-" & $rng.pick(12))]
  of 14:
    let win = chooseWindow(rng, model)
    let minW = chooseDelta(rng, 120)
    let minH = chooseDelta(rng, 120)
    let maxW = int32(rng.pick(500))
    let maxH = int32(rng.pick(500))
    ctx.op = "dimension hint " & $win
    @[Msg(kind: WlWindowDimensionsHint, hintWindowId: win, minWidth: minW, minHeight: minH, maxWidth: maxW, maxHeight: maxH)]
  of 15:
    let win = chooseWindow(rng, model)
    let outputId = if rng.chance(1, 2): 0'u32 else: uint32(1 + rng.pick(4))
    ctx.op = "fullscreen request " & $win & " output " & $outputId
    @[Msg(kind: WlWindowFullscreenRequested, fullscreenRequestId: win, fullscreenOutputId: outputId)]
  of 16:
    let win = chooseWindow(rng, model)
    ctx.op = "exit fullscreen request " & $win
    @[Msg(kind: WlWindowExitFullscreenRequested, exitFullscreenRequestId: win)]
  of 17:
    let outputId = uint32(1 + rng.pick(4))
    ctx.op = "remove output " & $outputId
    @[Msg(kind: WlOutputRemoved, removedOutputId: outputId)]
  of 18:
    let win = chooseWindow(rng, model)
    let w = int32(rng.pick(2400))
    let h = int32(rng.pick(1600))
    ctx.op = "actual dimensions " & $win
    @[Msg(kind: WlWindowDimensions, dimensionsWindowId: win, actualWidth: w, actualHeight: h)]
  of 19:
    let win = chooseWindow(rng, model)
    case rng.pick(3)
    of 0:
      ctx.op = "maximize request " & $win
      @[Msg(kind: WlWindowMaximizeRequested, maximizeRequestId: win)]
    of 1:
      ctx.op = "unmaximize request " & $win
      @[Msg(kind: WlWindowUnmaximizeRequested, unmaximizeRequestId: win)]
    else:
      ctx.op = "minimize request " & $win
      @[Msg(kind: WlWindowMinimizeRequested, minimizeRequestId: win)]
  of 20:
    case rng.pick(3)
    of 0:
      ctx.op = "layer focus exclusive"
      @[Msg(kind: WlLayerFocusExclusive)]
    of 1:
      ctx.op = "layer focus non-exclusive"
      @[Msg(kind: WlLayerFocusNonExclusive)]
    else:
      ctx.op = "layer focus none"
      @[Msg(kind: WlLayerFocusNone)]
  of 21:
    let commands = [
      "focus-next", "focus-prev", "toggle-overview", "focus-workspace 2",
      "focus-workspace -1", "move-to-tag 4", "swap-to-tag junk",
      "resize-width 0.25", "adjust-gaps -100", "set-column-width 8.5",
      "toggle-maximized", "minimize", "spawn-terminal", "lock-session", "mmsg -g -A", "rename-tag stress tag"
    ]
    let command = commands[rng.pick(commands.len)]
    ctx.op = "legacy ipc " & command
    let parsed = parseLegacyCommand(command)
    if parsed.isSome:
      @[parsed.get()]
    else:
      @[]
  else:
    let requests = [
      "\"Outputs\"",
      "\"Workspaces\"",
      "\"Windows\"",
      "\"FocusedWindow\"",
      "\"OverviewState\"",
      "\"KeyboardLayouts\"",
      "\"EventStream\"",
      """{"Action":{"FocusWorkspace":{"reference":{"Index":2}}}}""",
      """{"Action":{"FocusWorkspaceDown":{}}}""",
      """{"Action":{"FocusColumnLeft":{}}}""",
      """{"Action":{"ToggleOverview":{}}}""",
      """{"Action":{"FocusWindow":{"id":1}}}""",
      """{"Action":{"CloseWindow":{"id":1}}}""",
      """{"Action":{"Screenshot":{"path":"/tmp/triad-stress.png"}}}""",
      """{"Action":{"BadAction":{}}}""",
      "{not-json"
    ]
    let request = requests[rng.pick(requests.len)]
    ctx.op = "niri ipc " & request
    let response = handleNiriRequest(request, model)
    if response.reply.len > 0:
      discard parseJson(response.reply)
    for event in response.initialEvents:
      discard parseJson(event)
    response.messages

proc renderTag(ctx: FuzzContext; model: Model; tagId: uint32; tag: TagState) =
  var tagCopy = tag
  let screen = Rect(x: 0, y: 0, w: model.screenWidth, h: model.screenHeight)
  let instructions =
    case tagCopy.layoutMode
    of Scroller:
      layoutScroller(tagCopy, model.windows, screen, model.outerGaps, model.innerGaps, model.scrollerFocusCenter, model.scrollerPreferCenter, model.centerFocusedColumn)
    of VerticalScroller:
      layoutVerticalScroller(tagCopy, model.windows, screen, model.outerGaps, model.innerGaps, model.scrollerFocusCenter, model.scrollerPreferCenter, model.centerFocusedColumn)
    of MasterStack:
      layoutMasterStack(tagCopy, screen, model.outerGaps, model.innerGaps)
    of Grid:
      layoutGrid(tagCopy, screen, model.outerGaps, model.innerGaps)
    of Monocle:
      layoutMonocle(tagCopy, screen, model.outerGaps)

  for instr in instructions:
    require(ctx, model, instr.geom.w >= 0, "negative rendered width on tag " & $tagId)
    require(ctx, model, instr.geom.h >= 0, "negative rendered height on tag " & $tagId)

proc checkInvariants(ctx: FuzzContext; model: Model) =
  let errors = model.validateModel()
  if errors.len > 0:
    fail(ctx, model, errors.join("; "))

  var seen = initTable[WindowId, string]()
  for tagId, tag in model.tags.pairs:
    for win in tag.flattenWindows():
      require(ctx, model, not seen.hasKey(win), "duplicate placement for window " & $win)
      seen[win] = "tag " & $tagId
    if tag.focusedWindow != 0:
      require(ctx, model, tag.containsWindow(tag.focusedWindow), "focused window is not in tag " & $tagId)
    renderTag(ctx, model, tagId, tag)

  for win in model.scratchpadWindows:
    require(ctx, model, not seen.hasKey(win), "scratchpad duplicate for window " & $win)
    seen[win] = "scratchpad"

  discard parseJson($niriWorkspacesJson(model))
  discard parseJson($niriWindowsJson(model))
  discard parseJson($niriOutputsJson(model))
  discard parseJson($niriOverviewJson(model))
  for event in initialNiriEvents(model):
    discard parseJson(event)

proc runStress(seed: uint64; steps: int) =
  var rng = initRng(seed)
  var model = baseModel()
  var ctx = FuzzContext(seed: seed, step: 0, op: "initial")
  checkInvariants(ctx, model)

  for step in 0 ..< steps:
    ctx.step = step
    let messages = generatedMsg(rng, model, ctx)
    for message in messages:
      var nextModel: Model
      try:
        let updated = update(model, message)
        nextModel = updated[0]
      except CatchableError as e:
        fail(ctx, model, "update raised " & $e.name & ": " & e.msg)
      model = nextModel
      checkInvariants(ctx, model)

suite "Deterministic stress":
  test "model update/layout/ipc fuzz":
    let steps = int(parseUIntEnv("TRIAD_STRESS_STEPS", 500))
    let seedOverride = getEnv("TRIAD_STRESS_SEED", "")
    let seeds =
      if seedOverride.len > 0:
        @[parseUIntEnv("TRIAD_STRESS_SEED", 1)]
      else:
        @[0xC0FFEE'u64, 0xBAD5EED'u64, 0x12345678'u64, 0xDEADBEEF'u64, 0xA11CE'u64]

    for seed in seeds:
      runStress(seed, steps)
