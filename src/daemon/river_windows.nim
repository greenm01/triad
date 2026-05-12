import std/tables
import chronicles
import protocols/river/client as river
import ../core/msg
import ../systems/daemon_view
import ../types/runtime_values as rv
import message_queue, protocol_surface_runtime, state, wayland_helpers

template currentModel(daemon: TriadDaemon): untyped =
  daemon.runtimeState.model

proc outputIdForPointer(
    daemon: TriadDaemon; output: ptr RiverOutputV1): uint32 =
  if output == nil:
    return 0
  let id = output.id()
  if daemon.outputPointers.hasKey(id):
    id
  else:
    0

proc forgetWindow*(daemon: var TriadDaemon; id: WindowId) =
  daemon.destroyWindowProtocolSurfaces(id)
  daemon.desiredPlacements.del(id)
  daemon.pendingMaximizedAcks.del(id)
  daemon.pendingWindows.del(id)
  daemon.windowUnreliablePids.del(id)
  if daemon.windowNodes.hasKey(id):
    let node = daemon.windowNodes[id]
    daemon.windowNodes.del(id)
    node.destroy()
  if daemon.windowPointers.hasKey(id):
    let win = daemon.windowPointers[id]
    daemon.windowPointers.del(id)
    win.destroy()

proc callbackDaemon(data: pointer): ptr TriadDaemon =
  result = daemonFromData(data)
  if result == nil:
    warn "Ignoring River window callback without daemon context"

proc onWindowAppId(data: pointer; win: ptr RiverWindowV1; appId: cstring) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  let id = win.id()
  let appIdText = cstringOrEmpty(appId)
  debug "Window app-id received", windowId = id, appId = appIdText
  if daemon.pendingWindows.hasKey(id):
    daemon.pendingWindows[id].appId = appIdText
  elif daemon[].currentModel.hasRiverWindow(id):
    daemon.enqueue(Msg(kind: MsgKind.WlWindowAppId, appIdWindowId: id,
        updatedAppId: appIdText))

proc onWindowTitle(data: pointer; win: ptr RiverWindowV1; title: cstring) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  let id = win.id()
  let titleText = cstringOrEmpty(title)
  debug "Window title received", windowId = id, title = titleText
  if daemon.pendingWindows.hasKey(id):
    daemon.pendingWindows[id].title = titleText
  elif daemon[].currentModel.hasRiverWindow(id):
    daemon.enqueue(Msg(kind: MsgKind.WlWindowTitle, titleWindowId: id,
        updatedTitle: titleText))

proc onWindowClosed(data: pointer; win: ptr RiverWindowV1) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  let id = win.id()
  info "Window closed", windowId = id
  daemon.enqueue(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: id))
  daemon[].forgetWindow(id)

proc onWindowDimensionsHint(
    data: pointer;
    win: ptr RiverWindowV1;
    minWidth: int32;
    minHeight: int32;
    maxWidth: int32;
    maxHeight: int32) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  trace "Window dimensions hint received",
    windowId = win.id(),
    minWidth = minWidth,
    minHeight = minHeight,
    maxWidth = maxWidth,
    maxHeight = maxHeight
  if daemon.pendingWindows.hasKey(win.id()):
    daemon.pendingWindows[win.id()].minWidth = max(0'i32, minWidth)
    daemon.pendingWindows[win.id()].minHeight = max(0'i32, minHeight)
    daemon.pendingWindows[win.id()].maxWidth = max(0'i32, maxWidth)
    daemon.pendingWindows[win.id()].maxHeight = max(0'i32, maxHeight)
  elif daemon[].currentModel.hasRiverWindow(win.id()):
    daemon.enqueue(Msg(
      kind: MsgKind.WlWindowDimensionsHint,
      hintWindowId: win.id(),
      minWidth: minWidth,
      minHeight: minHeight,
      maxWidth: maxWidth,
      maxHeight: maxHeight))

proc onWindowDimensions(
    data: pointer; win: ptr RiverWindowV1; width: int32; height: int32) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  trace "Window dimensions acknowledged", windowId = win.id(),
      width = width, height = height
  if daemon.pendingWindows.hasKey(win.id()):
    daemon.pendingWindows[win.id()].actualW = max(0'i32, width)
    daemon.pendingWindows[win.id()].actualH = max(0'i32, height)
  else:
    daemon.enqueue(Msg(kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: win.id(), actualWidth: width,
        actualHeight: height))

proc onWindowParent(
    data: pointer; win: ptr RiverWindowV1; parent: ptr RiverWindowV1) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  let parentId = if parent == nil: 0'u32 else: parent.id()
  trace "Window parent received", windowId = win.id(), parentId = parentId
  if daemon.pendingWindows.hasKey(win.id()):
    daemon.pendingWindows[win.id()].parentId = parentId
  else:
    daemon.enqueue(Msg(kind: MsgKind.WlWindowParent,
        childWindowId: win.id(), parentWindowId: parentId))

proc onWindowDecorationHint(
    data: pointer; win: ptr RiverWindowV1; hint: uint32) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  trace "Window decoration hint received", windowId = win.id(), hint = hint
  if daemon.pendingWindows.hasKey(win.id()):
    daemon.pendingWindows[win.id()].hasDecorationHint = true
    daemon.pendingWindows[win.id()].decorationHint = hint
  else:
    daemon.enqueue(Msg(kind: MsgKind.WlWindowDecorationHint,
        decorationWindowId: win.id(), decorationHint: hint))

proc onWindowPointerMoveRequested(
    data: pointer; win: ptr RiverWindowV1; seat: ptr RiverSeatV1) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  debug "Pointer move requested", windowId = win.id()
  daemon.enqueue(Msg(kind: MsgKind.WlPointerMoveRequested,
      moveWinId: win.id(), moveSeat: seat))

proc onWindowPointerResizeRequested(
    data: pointer; win: ptr RiverWindowV1; seat: ptr RiverSeatV1;
    edges: uint32) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  debug "Pointer resize requested", windowId = win.id(), edges = edges
  daemon.enqueue(Msg(kind: MsgKind.WlPointerResizeRequested,
      resizeWinId: win.id(), resizeSeat: seat, resizeEdges: edges))

proc onWindowShowMenuRequested(
    data: pointer; win: ptr RiverWindowV1; x: int32; y: int32) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  debug "Window menu requested", windowId = win.id(), x = x, y = y
  daemon.enqueue(Msg(kind: MsgKind.WlWindowMenuRequested,
      menuWindowId: win.id(), menuX: x, menuY: y))

proc onWindowMaximizeRequested(data: pointer; win: ptr RiverWindowV1) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  debug "Window maximize requested", windowId = win.id()
  if daemon.pendingWindows.hasKey(win.id()):
    daemon.pendingWindows[win.id()].isMaximized = true
    daemon.pendingWindows[win.id()].isMinimized = false
  elif daemon[].consumeMaximizedAck(win.id(), true):
    trace "Consumed self-generated maximize acknowledgement",
      windowId = win.id()
  else:
    daemon.enqueue(Msg(kind: MsgKind.WlWindowMaximizeRequested,
        maximizeRequestId: win.id()))

proc onWindowUnmaximizeRequested(data: pointer; win: ptr RiverWindowV1) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  debug "Window unmaximize requested", windowId = win.id()
  if daemon.pendingWindows.hasKey(win.id()):
    daemon.pendingWindows[win.id()].isMaximized = false
  elif daemon[].consumeMaximizedAck(win.id(), false):
    trace "Consumed self-generated unmaximize acknowledgement",
      windowId = win.id()
  else:
    daemon.enqueue(Msg(kind: MsgKind.WlWindowUnmaximizeRequested,
        unmaximizeRequestId: win.id()))

proc onWindowFullscreenRequested(
    data: pointer; win: ptr RiverWindowV1; output: ptr RiverOutputV1) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  let requestedOutput = daemon[].outputIdForPointer(output)
  debug "Window fullscreen requested", windowId = win.id(),
      outputId = requestedOutput
  if daemon.pendingWindows.hasKey(win.id()):
    daemon.pendingWindows[win.id()].isFullscreen = true
    daemon.pendingWindows[win.id()].fullscreenOutput = requestedOutput
  else:
    daemon.enqueue(Msg(kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: win.id(), fullscreenOutputId: requestedOutput))

proc onWindowExitFullscreenRequested(data: pointer; win: ptr RiverWindowV1) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  debug "Window exit fullscreen requested", windowId = win.id()
  if daemon.pendingWindows.hasKey(win.id()):
    daemon.pendingWindows[win.id()].isFullscreen = false
    daemon.pendingWindows[win.id()].fullscreenOutput = 0
  else:
    daemon.enqueue(Msg(kind: MsgKind.WlWindowExitFullscreenRequested,
        exitFullscreenRequestId: win.id()))

proc onWindowMinimizeRequested(data: pointer; win: ptr RiverWindowV1) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  debug "Window minimize requested", windowId = win.id()
  if daemon.pendingWindows.hasKey(win.id()):
    daemon.pendingWindows[win.id()].isMinimized = true
    daemon.pendingWindows[win.id()].isMaximized = false
  else:
    daemon.enqueue(Msg(kind: MsgKind.WlWindowMinimizeRequested,
        minimizeRequestId: win.id()))

proc onWindowUnreliablePid(
    data: pointer; win: ptr RiverWindowV1; unreliablePid: int32) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  daemon.windowUnreliablePids[win.id()] = unreliablePid
  trace "Window unreliable pid received", windowId = win.id(),
      pid = unreliablePid

proc onWindowPresentationHint(
    data: pointer; win: ptr RiverWindowV1; hint: uint32) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  trace "Window presentation hint received", windowId = win.id(), hint = hint
  if daemon.pendingWindows.hasKey(win.id()):
    daemon.pendingWindows[win.id()].hasPresentationHint = true
    daemon.pendingWindows[win.id()].presentationHint = hint
  else:
    daemon.enqueue(Msg(kind: MsgKind.WlWindowPresentationHint,
        presentationWindowId: win.id(), presentationHint: hint))

proc onWindowIdentifier(
    data: pointer; win: ptr RiverWindowV1; identifier: cstring) =
  let daemon = callbackDaemon(data)
  if daemon == nil:
    return
  let text = cstringOrEmpty(identifier)
  let id = win.id()
  trace "Window identifier received", windowId = id, identifier = text
  if daemon.pendingWindows.hasKey(id):
    daemon.pendingWindows[id].identifier = text
  else:
    daemon.enqueue(Msg(kind: MsgKind.WlWindowIdentifier,
        identifierWindowId: id, identifier: text))

var riverWindowListener* = RiverWindowV1Listener(
  closed: onWindowClosed,
  dimensionsHint: onWindowDimensionsHint,
  dimensions: onWindowDimensions,
  appId: onWindowAppId,
  title: onWindowTitle,
  parent: onWindowParent,
  decorationHint: onWindowDecorationHint,
  pointerMoveRequested: onWindowPointerMoveRequested,
  pointerResizeRequested: onWindowPointerResizeRequested,
  showWindowMenuRequested: onWindowShowMenuRequested,
  maximizeRequested: onWindowMaximizeRequested,
  unmaximizeRequested: onWindowUnmaximizeRequested,
  fullscreenRequested: onWindowFullscreenRequested,
  exitFullscreenRequested: onWindowExitFullscreenRequested,
  minimizeRequested: onWindowMinimizeRequested,
  unreliablePid: onWindowUnreliablePid,
  presentationHint: onWindowPresentationHint,
  identifier: onWindowIdentifier
)

proc trackWindow*(daemon: var TriadDaemon; win: ptr RiverWindowV1) =
  let id = win.id()
  info "Window discovered", windowId = id
  daemon.windowPointers[id] = win
  daemon.windowNodes[id] = win.getNode()
  daemon.pendingWindows[id] = rv.WindowData(
    id: id, appId: "unknown", title: "unknown")
  discard win.addListener(riverWindowListener.addr, daemonData(daemon))
