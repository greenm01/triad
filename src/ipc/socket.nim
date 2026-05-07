import asyncnet, asyncdispatch, os, nativesockets, chronicles, strutils, ../core/msg, ../core/model

type
  IpcServer* = object
    socketPath*: string

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
        of "focus-next": onMsg(Msg(kind: CmdFocusNext))
        of "focus-prev": onMsg(Msg(kind: CmdFocusPrev))
        of "reload-config": onMsg(Msg(kind: CmdReloadConfig))
        of "layout-scroller": onMsg(Msg(kind: CmdSetLayout, newLayout: Scroller))
        of "layout-tile": onMsg(Msg(kind: CmdSetLayout, newLayout: MasterStack))
        of "layout-grid": onMsg(Msg(kind: CmdSetLayout, newLayout: Grid))
        of "layout-monocle": onMsg(Msg(kind: CmdSetLayout, newLayout: Monocle))
        of "toggle-overview": onMsg(Msg(kind: CmdToggleOverview))
        of "toggle-floating": onMsg(Msg(kind: CmdToggleFloating))
        of "select-window": onMsg(Msg(kind: CmdSelectWindow))
        of "move-to-tag":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdMoveToTag, targetTag: uint32(parseInt(parts[1]))))
            except: warn "Invalid tag ID", tag=parts[1]
        of "master-count":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdSetMasterCount, count: parseInt(parts[1])))
            except: warn "Invalid master count", count=parts[1]
        of "master-ratio":
          if parts.len >= 2:
            try: onMsg(Msg(kind: CmdSetMasterRatio, ratio: float32(parseFloat(parts[1]))))
            except: warn "Invalid master ratio", ratio=parts[1]
        else: warn "Unknown IPC command", command=cmd
      
      client.close()
    )()

proc sendIpcMsg*(path: string, msg: string) {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  await client.connectUnix(path)
  await client.send(msg & "\L")
  client.close()
