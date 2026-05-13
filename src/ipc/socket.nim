import std/[asyncdispatch, asyncnet, json, nativesockets, options, os, strutils]
import std/posix except AF_UNIX, SOCK_STREAM, IPPROTO_IP
import chronicles
import ../core/msg
import ../types/shell_snapshot
import ../utils/behavior_log
import commands, niri_compat, triad_native

type
  IpcServer* = object
    socketPath*: string

  TriadSubscriber* = object
    client*: AsyncSocket
    layout*: bool
    state*: bool

const
  MaxIpcLineBytes* = 256 * 1024
  MaxIpcSubscribers* = 64

var subscribers*: seq[AsyncSocket] = @[]
var triadSubscribers*: seq[TriadSubscriber] = @[]
var lastNiriBroadcastPayload = ""
var lastNiriWorkspaceBroadcastKey = ""
var lastNiriCompactBroadcastKey = ""

proc runtimeDir*(): string =
  getEnv("XDG_RUNTIME_DIR", "/tmp")

proc triadSocketPath*(): string =
  runtimeDir() / "triad.sock"

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
    error "IPC path exists but is not a Unix socket", path = path
    return false

  if await unixSocketAcceptsConnections(path):
    error "IPC socket already accepts connections; refusing to replace it", path = path
    return false

  warn "Removing stale IPC socket", path = path
  try:
    removeFile(path)
    true
  except CatchableError as e:
    error "Failed to remove stale IPC socket", path = path, error = e.msg
    false

proc recvLineLimited(
    client: AsyncSocket, maxBytes = MaxIpcLineBytes
): Future[string] {.async.} =
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

proc pruneTriadSubscribers() =
  var i = 0
  while i < triadSubscribers.len:
    let client = triadSubscribers[i].client
    if client == nil or client.isClosed:
      triadSubscribers.delete(i)
    else:
      inc i

proc canSubscribeTriad(): bool =
  pruneTriadSubscribers()
  triadSubscribers.len < MaxIpcSubscribers

proc startIpcServer*(
    path: string,
    onMsg: proc(msg: Msg) {.gcsafe.},
    getSnapshot: proc(): ShellSnapshot {.gcsafe.} = nil,
    getLiveRestoreJson: proc(): string {.gcsafe.} = nil,
) {.async.} =
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
    error "IPC server failed to start", path = path, error = e.msg
    if not server.isClosed:
      server.close()
    return

  info "IPC server listening", path = path

  while true:
    var client: AsyncSocket
    try:
      client = await server.accept()
      if client == nil:
        warn "IPC accept returned nil client", path = path
        continue
      debug "IPC client connected", path = path
    except CatchableError as e:
      warn "IPC accept failed", path = path, error = e.msg
      continue

    let acceptedClient = client
    asyncCheck (
      proc() {.async.} =
        let client = acceptedClient
        var keepOpen = false
        try:
          while client != nil and not client.isClosed:
            let line = await recvLineLimited(client)
            if line == "":
              break

            if getSnapshot != nil:
              if line.strip() == "dump-live-restore-state":
                if getLiveRestoreJson != nil:
                  await client.send(getLiveRestoreJson() & "\L")
                else:
                  await client.send("""{"error":"live restore unavailable"}""" & "\L")
                break

              let snapshot = getSnapshot()
              let triad = handleTriadRequest(line, snapshot)
              if triad.handled:
                if (triad.subscribeLayout or triad.subscribeState) and
                    not canSubscribeTriad():
                  await client.send(
                    """{"ok":false,"error":"too many event-stream subscribers"}""" & "\L"
                  )
                  break
                if triad.reply.len > 0:
                  await client.send(triad.reply & "\L")
                for msg in triad.messages:
                  onMsg(msg)
                for event in triad.initialEvents:
                  await client.send(event & "\L")
                if triad.subscribeLayout or triad.subscribeState:
                  triadSubscribers.add(
                    TriadSubscriber(
                      client: client,
                      layout: triad.subscribeLayout,
                      state: triad.subscribeState,
                    )
                  )
                  keepOpen = true
                break

              let niri = handleNiriRequest(line, snapshot)
              if niri.handled:
                if niri.subscribe and not canSubscribe():
                  await client.send(
                    """{"Err":"too many event-stream subscribers"}""" & "\L"
                  )
                  break
                if niri.reply.len > 0:
                  await client.send(niri.reply & "\L")
                for msg in niri.messages:
                  onMsg(msg)
                for event in niri.initialEvents:
                  await client.send(event & "\L")
                if niri.subscribe:
                  subscribers.add(client)
                  writeBehaviorEvent(
                    "niri_compat_event_stream_subscribed",
                    %*{"path": path, "subscriber_count": subscribers.len},
                  )
                  keepOpen = true
                break

            if line.strip() == "event-stream":
              if not canSubscribe():
                warn "Rejecting event-stream subscriber; subscriber cap reached",
                  cap = MaxIpcSubscribers
                break
              subscribers.add(client)
              writeBehaviorEvent(
                "niri_compat_event_stream_subscribed",
                %*{
                  "path": path,
                  "subscriber_count": subscribers.len,
                  "legacy_request": true,
                },
              )
              keepOpen = true
              break
            let parsed = parseTextCommand(line)
            if parsed.isSome:
              onMsg(parsed.get())
            else:
              warn "Unknown or invalid IPC command", command = line
        except CatchableError as e:
          warn "IPC client error", path = path, error = e.msg

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

proc sendIpcRequest*(
    path: string, msg: string, timeoutMs = 3000
): Future[string] {.async.} =
  let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    await client.connectUnix(path)
    await client.send(msg & "\L")
    let reply = client.recvLine()
    if await reply.withTimeout(timeoutMs):
      result = reply.read()
    else:
      raise newException(IOError, "IPC request timed out after " & $timeoutMs & " ms")
  except CatchableError:
    if not client.isClosed:
      client.close()
    raise
  client.close()

proc niriBroadcastLogPayload(payload: string, subscriberCount: int): JsonNode =
  try:
    let root = parseJson(payload)
    if root.kind != JObject:
      return
    for eventName, eventPayload in root.pairs:
      result = %*{"subscriber_count": subscriberCount}
      result["niri_event"] = %eventName

      case eventName
      of "WorkspacesChanged":
        if eventPayload.kind == JObject and eventPayload.hasKey("workspaces") and
            eventPayload["workspaces"].kind == JArray:
          let distribution = newJArray()
          var signatureParts: seq[string]
          for workspace in eventPayload["workspaces"]:
            if workspace.kind != JObject:
              continue
            var entry = newJObject()
            for key in [
              "id", "idx", "name", "is_active", "is_focused", "occupied",
              "active_window_id",
            ]:
              if workspace.hasKey(key):
                entry[key] = workspace[key]
            distribution.add(entry)
            let id =
              if workspace.hasKey("id"):
                workspace["id"].getInt()
              else:
                0
            let idx =
              if workspace.hasKey("idx"):
                workspace["idx"].getInt()
              else:
                0
            let active =
              workspace.hasKey("is_active") and workspace["is_active"].kind == JBool and
              workspace["is_active"].getBool()
            let occupied =
              workspace.hasKey("occupied") and workspace["occupied"].kind == JBool and
              workspace["occupied"].getBool()
            signatureParts.add($id & ":" & $idx & ":" & $active & ":" & $occupied)
            if workspace.kind == JObject and workspace.hasKey("is_active") and
                workspace["is_active"].kind == JBool and workspace["is_active"].getBool():
              if workspace.hasKey("id"):
                result["active_tag"] = workspace["id"]
              if workspace.hasKey("idx"):
                result["active_workspace_idx"] = workspace["idx"]
          result["workspace_distribution"] = distribution
          result["workspace_signature"] = %signatureParts.join("|")
        let activeTag =
          if result.hasKey("active_tag"):
            result["active_tag"].getInt()
          else:
            0
        let activeIdx =
          if result.hasKey("active_workspace_idx"):
            result["active_workspace_idx"].getInt()
          else:
            0
        let signature =
          if result.hasKey("workspace_signature"):
            result["workspace_signature"].getStr()
          else:
            ""
        let key =
          $subscriberCount & ":" & $activeTag & ":" & $activeIdx & ":" & signature
        if key == lastNiriWorkspaceBroadcastKey:
          return nil
        lastNiriWorkspaceBroadcastKey = key
        lastNiriCompactBroadcastKey = ""
      of "WorkspaceActivated":
        if eventPayload.kind == JObject:
          for key in ["id", "focused"]:
            if eventPayload.hasKey(key):
              result[key] = eventPayload[key]
      of "WorkspaceActiveWindowChanged":
        if eventPayload.kind == JObject:
          for key in ["workspace_id", "active_window_id"]:
            if eventPayload.hasKey(key):
              result[key] = eventPayload[key]
      of "WindowFocusChanged":
        if eventPayload.kind == JObject and eventPayload.hasKey("id"):
          result["window_id"] = eventPayload["id"]
      else:
        return nil
      if eventName != "WorkspacesChanged":
        let key = $subscriberCount & ":" & eventName & ":" & $result
        if key == lastNiriCompactBroadcastKey:
          return nil
        lastNiriCompactBroadcastKey = key
      break
  except CatchableError as e:
    result = %*{"subscriber_count": subscriberCount}
    result["parse_error"] = %e.msg

proc broadcastJson*(payload: string) {.async.} =
  if payload == lastNiriBroadcastPayload:
    return
  lastNiriBroadcastPayload = payload

  let logPayload = niriBroadcastLogPayload(payload, subscribers.len)
  if logPayload != nil:
    writeBehaviorEvent("niri_compat_broadcast", logPayload)
  var i = 0
  while i < subscribers.len:
    let client = subscribers[i]
    if client == nil or client.isClosed:
      writeBehaviorEvent(
        "niri_compat_event_stream_disconnected", %*{"reason": "closed"}
      )
      subscribers.delete(i)
    else:
      try:
        await client.send(payload & "\L")
        inc i
      except CatchableError as e:
        warn "Dropping failed IPC subscriber", error = e.msg
        writeBehaviorEvent(
          "niri_compat_event_stream_disconnected",
          %*{"reason": "send failed", "error": e.msg},
        )
        client.close()
        subscribers.delete(i)

proc broadcastTriadJson*(payload: string, eventName: string) {.async.} =
  var i = 0
  while i < triadSubscribers.len:
    let subscriber = triadSubscribers[i]
    let client = subscriber.client
    if client == nil or client.isClosed:
      triadSubscribers.delete(i)
    elif (eventName == "layout" and not subscriber.layout) or
        (eventName == "state" and not subscriber.state):
      inc i
    else:
      try:
        await client.send(payload & "\L")
        inc i
      except CatchableError as e:
        warn "Dropping failed Triad IPC subscriber", error = e.msg
        client.close()
        triadSubscribers.delete(i)
