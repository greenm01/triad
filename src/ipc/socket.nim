import asyncnet, asyncdispatch, os, nativesockets, chronicles, strutils, ../core/msg, ../core/model

type
  IpcServer* = object
    socketPath*: string

var subscribers*: seq[AsyncSocket] = @[]

proc getRuntimeDir*(): string =
  getEnv("XDG_RUNTIME_DIR", "/tmp")

proc getTriadSocketPath*(): string =
  getRuntimeDir() / "triad.sock"

proc startIpcServer*(path: string, onMsg: proc(msg: Msg) {.gcsafe.}) {.async.} =
  if fileExists(path):
    removeFile(path)
  
  let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  server.setSockOpt(OptReuseAddr, true)
  server.bindUnix(path)
  server.listen()
  
  info "IPC Server listening", path=path
  
  while true:
    let client = await server.accept()
    asyncCheck (proc() {.async.} =
      while not client.isClosed:
        let line = await client.recvLine()
        if line == "": break
        
        let parts = line.split(' ')
        if parts.len == 0: continue
        let cmd = parts[0]
        
        case cmd
        of "event-stream":
          subscribers.add(client)
          return 
        of "focus-next": onMsg(Msg(kind: CmdFocusNext))
        of "focus-prev": onMsg(Msg(kind: CmdFocusPrev))
        of "close-window": onMsg(Msg(kind: CmdCloseWindow))
        of "reload-config": onMsg(Msg(kind: CmdReloadConfig))
        of "layout-scroller": onMsg(Msg(kind: CmdSetLayout, newLayout: Scroller))
        of "layout-vertical-scroller": onMsg(Msg(kind: CmdSetLayout, newLayout: VerticalScroller))
        of "layout-tile": onMsg(Msg(kind: CmdSetLayout, newLayout: MasterStack))
        of "layout-grid": onMsg(Msg(kind: CmdSetLayout, newLayout: Grid))
        of "layout-monocle": onMsg(Msg(kind: CmdSetLayout, newLayout: Monocle))
        of "toggle-overview": onMsg(Msg(kind: CmdToggleOverview))
        of "toggle-floating": onMsg(Msg(kind: CmdToggleFloating))
        of "toggle-fullscreen": onMsg(Msg(kind: CmdToggleFullscreen))
        of "move-to-scratchpad": onMsg(Msg(kind: CmdMoveToScratchpad))
        of "toggle-scratchpad": onMsg(Msg(kind: CmdToggleScratchpad))
        of "select-window": onMsg(Msg(kind: CmdSelectWindow))
        of "rename-tag":
          if parts.len >= 2:
            onMsg(Msg(kind: CmdRenameTag, newName: parts[1..^1].join(" ")))
        of "group-windows": onMsg(Msg(kind: CmdGroupWindows))
        of "ungroup-window": onMsg(Msg(kind: CmdUngroupWindow))
        of "focus-next-in-group": onMsg(Msg(kind: CmdFocusNextInGroup))
        of "move-floating":
          if parts.len >= 3:
            try: onMsg(Msg(kind: CmdMoveFloating, moveDX: int32(parseInt(parts[1])), moveDY: int32(parseInt(parts[2]))))
            except: warn "Invalid floating move", parts=parts[1..2]
        of "resize-floating":
          if parts.len >= 3:
            try: onMsg(Msg(kind: CmdResizeFloating, deltaFW: int32(parseInt(parts[1])), deltaFH: int32(parseInt(parts[2]))))
            except: warn "Invalid floating resize", parts=parts[1..2]
        of "move-to-tag":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdMoveToTag, targetTag: uint32(parseInt(parts[1]))))
            except: warn "Invalid tag ID", tag=parts[1]
        of "swap-to-tag":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdSwapWindowToTag, targetTagSwap: uint32(parseInt(parts[1]))))
            except: warn "Invalid tag ID", tag=parts[1]
        of "master-count":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdSetMasterCount, count: parseInt(parts[1])))
            except: warn "Invalid master count", count=parts[1]
        of "adjust-master-count":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdAdjustMasterCount, deltaMC: parseInt(parts[1])))
            except: warn "Invalid master count delta", delta=parts[1]
        of "master-ratio":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdSetMasterRatio, ratio: float32(parseFloat(parts[1]))))
            except: warn "Invalid master ratio", ratio=parts[1]
        of "adjust-master-ratio":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdAdjustMasterRatio, deltaMR: float32(parseFloat(parts[1]))))
            except: warn "Invalid master ratio delta", delta=parts[1]
        of "resize-width":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdResizeWidth, deltaW: float32(parseFloat(parts[1]))))
            except: warn "Invalid width delta", delta=parts[1]
        of "resize-height":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdResizeHeight, deltaH: float32(parseFloat(parts[1]))))
            except: warn "Invalid height delta", delta=parts[1]
        of "set-column-width":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdSetColumnWidth, targetWidth: float32(parseFloat(parts[1]))))
            except: warn "Invalid width", width=parts[1]
        of "adjust-gaps":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdAdjustGaps, deltaG: int32(parseInt(parts[1]))))
            except: warn "Invalid gap delta", delta=parts[1]
        of "toggle-gaps": onMsg(Msg(kind: CmdToggleGaps))
        of "zoom": onMsg(Msg(kind: CmdZoom))
        of "consume-window": onMsg(Msg(kind: CmdConsumeWindow))
        of "expel-window": onMsg(Msg(kind: CmdExpelWindow))
        of "move-column-left": onMsg(Msg(kind: CmdMoveColumnLeft))
        of "move-column-right": onMsg(Msg(kind: CmdMoveColumnRight))
        of "move-window-left": onMsg(Msg(kind: CmdMoveWindowLeft))
        of "move-window-right": onMsg(Msg(kind: CmdMoveWindowRight))
        of "move-window-up": onMsg(Msg(kind: CmdMoveWindowUp))
        of "move-window-down": onMsg(Msg(kind: CmdMoveWindowDown))
        of "swap-window-up": onMsg(Msg(kind: CmdSwapWindowUp))
        of "swap-window-down": onMsg(Msg(kind: CmdSwapWindowDown))
        else: warn "Unknown IPC command", command=cmd
      
      client.close()
    )()

proc sendIpcMsg*(path: string, msg: string) {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  await client.connectUnix(path)
  await client.send(msg & "\L")
  client.close()

proc broadcastJson*(payload: string) {.async.} =
  var i = 0
  while i < subscribers.len:
    let client = subscribers[i]
    if client.isClosed:
      subscribers.delete(i)
    else:
      try:
        await client.send(payload & "\L")
        inc i
      except:
        client.close()
        subscribers.delete(i)
