import std/deques
import ../core/msg
import state

proc enqueue*(daemon: var TriadDaemon, msg: Msg, origin = QueuedMsgOrigin.Normal) =
  daemon.msgQueue.addLast(QueuedMsg(msg: msg, origin: origin))

proc enqueueNext*(
    daemon: var TriadDaemon, messages: seq[Msg], origin = QueuedMsgOrigin.Normal
) =
  for i in countdown(messages.len - 1, 0):
    daemon.msgQueue.addFirst(QueuedMsg(msg: messages[i], origin: origin))

proc enqueueNextQueued*(daemon: var TriadDaemon, messages: seq[QueuedMsg]) =
  for i in countdown(messages.len - 1, 0):
    daemon.msgQueue.addFirst(messages[i])

proc enqueue*(daemon: ptr TriadDaemon, msg: Msg) =
  if daemon != nil:
    daemon[].enqueue(msg)

proc hasQueuedMessages*(daemon: TriadDaemon): bool =
  daemon.msgQueue.len > 0

proc dropQueuedOutputRemovals*(daemon: var TriadDaemon): int =
  var kept: Deque[QueuedMsg]
  while daemon.msgQueue.len > 0:
    let queued = daemon.msgQueue.popFirst()
    if queued.msg.kind == MsgKind.WlOutputRemoved:
      inc result
    else:
      kept.addLast(queued)
  daemon.msgQueue = kept

proc popQueuedMessageWithOrigin*(daemon: var TriadDaemon): QueuedMsg =
  daemon.msgQueue.popFirst()

proc popQueuedMessage*(daemon: var TriadDaemon): Msg =
  daemon.popQueuedMessageWithOrigin().msg
