import std/[asyncdispatch, json]
import ../ipc/socket
import state

proc niriEventName(payload: string): string =
  try:
    let root = parseJson(payload)
    if root.kind != JObject:
      return ""
    for eventName, _ in root.pairs:
      return eventName
  except CatchableError:
    discard
  ""

proc coalescesNiriEvent(eventName: string): bool =
  eventName in ["WorkspacesChanged", "OutputsChanged", "KeyboardLayoutsChanged"]

proc removePendingBroadcast(
    daemon: var TriadDaemon, kind: IpcBroadcastKind, eventName: string
): bool =
  var i = 0
  while i < daemon.pendingIpcBroadcasts.len:
    let pending = daemon.pendingIpcBroadcasts[i]
    if pending.kind == kind and pending.eventName == eventName:
      daemon.pendingIpcBroadcasts.delete(i)
      result = true
    else:
      inc i

proc enqueueNiriBroadcast*(daemon: var TriadDaemon, payload: string) =
  if not payload.shouldSendNiriBroadcast():
    inc ipcPerfCounters.niriBroadcastSkippedFiltered
    return
  if subscribers.len == 0:
    inc ipcPerfCounters.niriBroadcastSkippedNoSubscribers
    return

  inc ipcPerfCounters.niriBroadcastQueued
  let eventName = payload.niriEventName()
  if eventName.coalescesNiriEvent() and
      daemon.removePendingBroadcast(IpcBroadcastKind.Niri, eventName):
    inc ipcPerfCounters.niriBroadcastCoalesced

  daemon.pendingIpcBroadcasts.add(
    PendingIpcBroadcast(
      kind: IpcBroadcastKind.Niri, eventName: eventName, payload: payload
    )
  )

proc enqueueTriadBroadcast*(
    daemon: var TriadDaemon, payload: string, eventName: string
) =
  if not triadSubscriberInterested(eventName):
    inc ipcPerfCounters.triadBroadcastSkippedNoSubscribers
    return

  inc ipcPerfCounters.triadBroadcastQueued
  if daemon.removePendingBroadcast(IpcBroadcastKind.Triad, eventName):
    inc ipcPerfCounters.triadBroadcastCoalesced

  daemon.pendingIpcBroadcasts.add(
    PendingIpcBroadcast(
      kind: IpcBroadcastKind.Triad, eventName: eventName, payload: payload
    )
  )

proc flushIpcBroadcasts*(daemon: var TriadDaemon) =
  if daemon.pendingIpcBroadcasts.len == 0:
    return

  let pending = daemon.pendingIpcBroadcasts
  daemon.pendingIpcBroadcasts = @[]
  for broadcast in pending:
    case broadcast.kind
    of IpcBroadcastKind.Niri:
      asyncCheck broadcastJson(broadcast.payload)
    of IpcBroadcastKind.Triad:
      asyncCheck broadcastTriadJson(broadcast.payload, broadcast.eventName)
