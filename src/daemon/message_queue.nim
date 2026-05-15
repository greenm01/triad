import std/deques
import ../core/msg
import state

proc enqueue*(daemon: var TriadDaemon, msg: Msg) =
  daemon.msgQueue.addLast(msg)

proc enqueueNext*(daemon: var TriadDaemon, messages: seq[Msg]) =
  for i in countdown(messages.len - 1, 0):
    daemon.msgQueue.addFirst(messages[i])

proc enqueue*(daemon: ptr TriadDaemon, msg: Msg) =
  if daemon != nil:
    daemon[].enqueue(msg)

proc hasQueuedMessages*(daemon: TriadDaemon): bool =
  daemon.msgQueue.len > 0

proc popQueuedMessage*(daemon: var TriadDaemon): Msg =
  daemon.msgQueue.popFirst()
