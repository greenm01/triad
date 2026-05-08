import asyncnet, asyncdispatch, os, nativesockets, chronicles, options, strutils
import ../core/msg, ../core/model
import commands, niri_compat

type
  IpcServer* = object
    socketPath*: string

var subscribers*: seq[AsyncSocket] = @[]

proc getRuntimeDir*(): string =
  getEnv("XDG_RUNTIME_DIR", "/tmp")

proc getTriadSocketPath*(): string =
  getRuntimeDir() / "triad.sock"

proc startIpcServer*(path: string, onMsg: proc(msg: Msg) {.gcsafe.}, getModel: proc(): Model {.gcsafe.} = nil) {.async.} =
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

        if getModel != nil:
          let niri = handleNiriRequest(line, getModel())
          if niri.handled:
            if niri.reply.len > 0:
              await client.send(niri.reply & "\L")
            for msg in niri.messages:
              onMsg(msg)
            for event in niri.initialEvents:
              await client.send(event & "\L")
            if niri.subscribe:
              subscribers.add(client)
              return
            break
        
        if line.strip() == "event-stream":
          subscribers.add(client)
          return 
        let parsed = parseLegacyCommand(line)
        if parsed.isSome:
          onMsg(parsed.get())
        else:
          warn "Unknown or invalid IPC command", command=line
      
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
