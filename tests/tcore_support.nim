import std/[asyncdispatch, json, options, os, sequtils, strutils, tables, unittest]
import ../src/config/[apply, parser]
import ../src/core/[effects, msg, render_visibility, restore_state, triad_state]
import ../src/daemon/render_runtime
import ../src/daemon/state as daemon_state
import ../src/state/engine
import
  ../src/systems/[
    hotkey_overlay, layout_projection, overview_geometry, popup_tree, runtime_facade,
    recent_windows, update, window_lifecycle, window_rules, workspaces,
  ]
import ../src/types/model
import ../src/types/projection_values except WindowId
import ../src/utils/[overview_hit_test, process_tree, screenshot_capture]
import tag_semantics_checks

export
  asyncdispatch, json, options, os, sequtils, strutils, tables, unittest, apply, parser,
  effects, msg, render_visibility, restore_state, triad_state, render_runtime, engine,
  hotkey_overlay, layout_projection, overview_geometry, popup_tree, recent_windows,
  runtime_facade, update, window_lifecycle, window_rules, workspaces, model,
  overview_hit_test, process_tree, screenshot_capture, tag_semantics_checks
export projection_values except WindowId

proc initTriadDaemon*(): auto =
  daemon_state.initTriadDaemon()

proc configuredModel*(): Model =
  initRuntimeStateFromConfig(
    Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.7,
        defaultWindowWidth: 0.8,
        defaultWindowHeight: 0.6,
        defaultMasterCount: 2,
        defaultMasterRatio: 0.65,
      ),
      workspaces: WorkspaceConfig(defaultCount: 3),
      windowRules:
        @[
          WindowRule(appIdMatch: "float-me", openFloating: true),
          WindowRule(appIdMatch: "qemu", keyboardShortcutsInhibit: true),
        ],
    )
  ).model

proc cameraModel*(): Model =
  initRuntimeStateFromConfig(
    Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.7,
        centerFocusedColumn: "always",
        enableAnimations: true,
        animationSpeed: 0.5,
      ),
      workspaces: WorkspaceConfig(defaultCount: 3),
    )
  ).model

proc applyMsg*(model: var Model, msg: Msg) =
  let (nextModel, _) = model.update(msg)
  model = nextModel

proc focusedWindowId*(model: Model): uint32 =
  for win in model.shellSnapshot().windows:
    if win.isFocused:
      return uint32(win.id)
  0'u32

proc activeWorkspaceFocusId*(model: Model): uint32 =
  for workspace in model.shellSnapshot().workspaces:
    if workspace.isActive:
      return uint32(workspace.focusedWindow)
  0'u32

proc updateModel*(model: var Model, msg: Msg): seq[Effect] =
  let (nextModel, effects) = model.update(msg)
  model = nextModel
  effects

proc hasFocusEffect*(effects: seq[Effect], id: uint32): bool =
  effects.anyIt(it.kind == EffectKind.EffFocusWindow and uint32(it.focusId) == id)

proc hasFullscreenEffect*(effects: seq[Effect], id: uint32, fullscreen: bool): bool =
  effects.anyIt(
    it.kind == EffectKind.EffSetFullscreen and uint32(it.fsWinId) == id and
      it.isFullscreen == fullscreen
  )

proc hasMaximizedEffect*(effects: seq[Effect], id: uint32, maximized: bool): bool =
  effects.anyIt(
    it.kind == EffectKind.EffSetMaximized and uint32(it.maxWinId) == id and
      it.isMaximized == maximized
  )

proc hasIdleInhibitEffect*(effects: seq[Effect], active: bool): bool =
  effects.anyIt(
    it.kind == EffectKind.EffSetIdleInhibit and it.idleInhibitActive == active
  )

proc viewport*(model: Model, slot: uint32): ViewportState =
  let tagId = model.tagForSlot(slot)
  let tag = model.tagData(tagId).get()
  ViewportState(
    targetViewportXOffset: tag.targetViewportXOffset,
    currentViewportXOffset: tag.currentViewportXOffset,
    targetViewportYOffset: tag.targetViewportYOffset,
    currentViewportYOffset: tag.currentViewportYOffset,
  )

proc instructionGeom*(model: Model, id: uint32): Rect =
  let projection = model.layoutProjection()
  for instr in projection.instructions:
    if uint32(instr.windowId) == id:
      return instr.geom
  Rect()

proc rectCenter*(rect: Rect): tuple[x, y: int32] =
  (rect.x + rect.w div 2, rect.y + rect.h div 2)

proc snapshotWindow*(model: Model, id: uint32): ShellWindow =
  for win in model.shellSnapshot().windows:
    if uint32(win.id) == id:
      return win
  ShellWindow()

proc restoreWindowJson*(model: Model, id: uint32): JsonNode =
  let root = parseJson(model.liveRestoreJson())
  for node in root["windows"]:
    if node["id"].getInt() == int(id):
      return node
  newJNull()

proc restoreTagJson*(model: Model, id: uint32): JsonNode =
  let root = parseJson(model.liveRestoreJson())
  for node in root["tags"]:
    if node["id"].getInt() == int(id):
      return node
  newJNull()

proc columnHeads*(model: Model, slot: uint32): seq[uint32] =
  let tagId = model.tagForSlot(slot)
  for columnId, _ in model.columnsOnTagWithId(tagId):
    for winId, _ in model.windowsOnColumnWithId(columnId):
      result.add(uint32(model.windowData(winId).get().externalId))
      break

proc setViewport*(
    model: var Model,
    slot: uint32,
    targetX, currentX: float32,
    targetY = 0.0'f32,
    currentY = 0.0'f32,
) =
  let tagId = model.tagForSlot(slot)
  discard model.setTagViewportTarget(tagId, targetX, targetY)
  discard model.setTagViewportCurrent(tagId, currentX, currentY)
  discard model.clearTagViewportRetarget(tagId)

proc seedCameraWindows*(model: var Model, count = 3'u32) =
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
  )
  for id in 1'u32 .. count:
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: id,
        appId: "app",
        title: "Window " & $id,
      )
    )

proc directionalModel*(mode: LayoutMode, count = 5'u32): Model =
  result = cameraModel()
  result.seedCameraWindows(count)
  result.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: mode))

proc focusExternal*(model: var Model, id: uint32) =
  model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: id))

proc focusDirection*(model: var Model, direction: Direction): uint32 =
  model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: direction))
  model.focusedWindowId()

proc restoreMatchingModel*(): Model =
  initRuntimeStateFromConfig(
    Config(
      workspaces: WorkspaceConfig(defaultCount: 3),
      windowRules: @[WindowRule(appIdMatch: "generic-app", defaultWorkspace: 2)],
    )
  ).model

proc addRestoredWindow*(
    restore: var PendingRestoreState,
    externalId: ExternalWindowId,
    slot: uint32,
    appId, title: string,
    isMaximized = false,
    identifier = "",
) =
  restore.windows[externalId] = RestoredWindowData(
    slot: slot,
    appId: appId,
    title: title,
    identifier: identifier,
    widthProportion: 0.8,
    heightProportion: 0.6,
    isMaximized: isMaximized,
  )
  restore.tagByWindow[externalId] = slot
  restore.tags[slot] = RestoredTagData(
    slot: slot,
    layoutMode: LayoutMode.Scroller,
    focusedWindow: externalId,
    columns: @[RestoredColumnData(windows: @[externalId], widthProportion: 0.7)],
    masterCount: 1,
    masterSplitRatio: 0.5,
  )
