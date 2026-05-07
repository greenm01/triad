import asyncnet, asyncdispatch, os, nativesockets, ../core/msg, ../core/model

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
  
  echo "IPC Server listening on ", path
  
  while true:
    let client = await server.accept()
    asyncCheck (proc() {.async.} =
      while not client.isClosed:
        let line = await client.recvLine()
        if line == "": break
        
        # Simple command parsing
        case line
        of "focus-next": onMsg(Msg(kind: CmdFocusNext))
        of "focus-prev": onMsg(Msg(kind: CmdFocusPrev))
        of "reload-config": onMsg(Msg(kind: CmdReloadConfig))
        of "layout-scroller": onMsg(Msg(kind: CmdSetLayout, newLayout: Scroller))
        of "layout-tile": onMsg(Msg(kind: CmdSetLayout, newLayout: MasterStack))
        of "layout-grid": onMsg(Msg(kind: CmdSetLayout, newLayout: Grid))
        of "layout-monocle": onMsg(Msg(kind: CmdSetLayout, newLayout: Monocle))
        else: echo "Unknown IPC command: ", line
      
      client.close()
    )()

proc sendIpcMsg*(path: string, msg: string) {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  await client.connectUnix(path)
  await client.send(msg & "\L")
  client.close()
