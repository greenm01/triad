import asyncnet, asyncdispatch, os, nativesockets, chronicles, options, strutils
import posix except AF_UNIX, SOCK_STREAM, IPPROTO_IP
import ../core/msg, ../core/model
import commands, niri_compat

type
  IpcServer* = object
    socketPath*: string

const
  MaxIpcLineBytes* = 256 * 1024
  MaxIpcSubscribers* = 64

var subscribers*: seq[AsyncSocket] = @[]

proc getRuntimeDir*(): string =
  getEnv("XDG_RUNTIME_DIR", "/tmp")

proc getTriadSocketPath*(): string =
  getRuntimeDir() / "triad.sock"

proc unixPathExists*(path: string): bool =
  var st: Stat
  lstat(path.cstring, st) == 0

proc unixPathIsSocket*(path: string): bool =
  var st: Stat
  if lstat(path.cstring, st) != 0:
    return false
  S_ISSOCK(st.st_mode)

proc unixSocketAcceptsConnections*(path: string): Future[bool] {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    let connectFuture = client.connectUnix(path)
    let completed = await connectFuture.withTimeout(100)
    if not completed:
      return true
    result = not connectFuture.failed
  except CatchableError:
    result = false
  finally:
    if not client.isClosed:
      client.close()

proc prepareUnixSocketPath(path: string): Future[bool] {.async.} =
  if not unixPathExists(path):
    return true

  if not unixPathIsSocket(path):
    error "IPC path exists but is not a Unix socket", path=path
    return false

  if await unixSocketAcceptsConnections(path):
    error "IPC socket already accepts connections; refusing to replace it", path=path
    return false

  warn "Removing stale IPC socket", path=path
  try:
    removeFile(path)
    true
  except CatchableError as e:
    error "Failed to remove stale IPC socket", path=path, error=e.msg
    false

proc recvLineLimited(client: AsyncSocket; maxBytes = MaxIpcLineBytes): Future[string] {.async.} =
  var line = ""
  while line.len <= maxBytes:
    let chunk = await client.recv(1)
    if chunk.len == 0:
      return ""
    if chunk[0] == '\n':
      if line.len > 0 and line[^1] == '\r':
        line.setLen(line.len - 1)
      return line
    line.add(chunk)
  raise newException(ValueError, "IPC request line exceeds " & $maxBytes & " bytes")

proc pruneSubscribers() =
  var i = 0
  while i < subscribers.len:
    let client = subscribers[i]
    if client == nil or client.isClosed:
      subscribers.delete(i)
    else:
      inc i

proc canSubscribe(): bool =
  pruneSubscribers()
  subscribers.len < MaxIpcSubscribers

proc startIpcServer*(path: string, onMsg: proc(msg: Msg) {.gcsafe.}, getModel: proc(): Model {.gcsafe.} = nil) {.async.} =
  let server = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    if not await prepareUnixSocketPath(path):
      if not server.isClosed:
        server.close()
      return

    server.setSockOpt(OptReuseAddr, true)
    server.bindUnix(path)
    server.listen()
  except CatchableError as e:
    error "IPC server failed to start", path=path, error=e.msg
    if not server.isClosed:
      server.close()
    return
  
  info "IPC server listening", path=path
  
  while true:
    var client: AsyncSocket
    try:
      client = await server.accept()
      if client == nil:
        warn "IPC accept returned nil client", path=path
        continue
      debug "IPC client connected", path=path
    except CatchableError as e:
      warn "IPC accept failed", path=path, error=e.msg
      continue

    let acceptedClient = client
    asyncCheck (proc() {.async.} =
      let client = acceptedClient
      var keepOpen = false
      try:
        while client != nil and not client.isClosed:
          let line = await recvLineLimited(client)
          if line == "": break

          if getModel != nil:
            let niri = handleNiriRequest(line, getModel())
            if niri.handled:
              if niri.subscribe and not canSubscribe():
                await client.send("""{"Err":"too many event-stream subscribers"}""" & "\L")
                break
              if niri.reply.len > 0:
                await client.send(niri.reply & "\L")
              for msg in niri.messages:
                onMsg(msg)
              for event in niri.initialEvents:
                await client.send(event & "\L")
              if niri.subscribe:
                subscribers.add(client)
                keepOpen = true
              break

          if line.strip() == "event-stream":
            if not canSubscribe():
              warn "Rejecting event-stream subscriber; subscriber cap reached", cap=MaxIpcSubscribers
              break
            subscribers.add(client)
            keepOpen = true
            break
          let parsed = parseLegacyCommand(line)
          if parsed.isSome:
            onMsg(parsed.get())
          else:
            warn "Unknown or invalid IPC command", command=line
      except CatchableError as e:
        warn "IPC client error", path=path, error=e.msg

      if client != nil and not keepOpen and not client.isClosed:
        client.close()
    )()

proc sendIpcMsg*(path: string, msg: string) {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    await client.connectUnix(path)
    await client.send(msg & "\L")
  except CatchableError:
    if not client.isClosed:
      client.close()
    raise
  client.close()

proc sendIpcRequest*(path: string, msg: string): Future[string] {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    await client.connectUnix(path)
    await client.send(msg & "\L")
    result = await client.recvLine()
  except CatchableError:
    if not client.isClosed:
      client.close()
    raise
  client.close()

proc broadcastJson*(payload: string) {.async.} =
  var i = 0
  while i < subscribers.len:
    let client = subscribers[i]
    if client == nil or client.isClosed:
      subscribers.delete(i)
    else:
      try:
        await client.send(payload & "\L")
        inc i
      except CatchableError as e:
        warn "Dropping failed IPC subscriber", error=e.msg
        client.close()
        subscribers.delete(i)
