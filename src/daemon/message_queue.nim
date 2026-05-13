import std/deques
import ../core/msg
import state

proc enqueue*(daemon: var TriadDaemon, msg: Msg) =
  daemon.msgQueue.addLast(msg)

proc enqueue*(daemon: ptr TriadDaemon, msg: Msg) =
  if daemon != nil:
    daemon[].enqueue(msg)

proc hasQueuedMessages*(daemon: TriadDaemon): bool =
  daemon.msgQueue.len > 0

proc popQueuedMessage*(daemon: var TriadDaemon): Msg =
  daemon.msgQueue.popFirst()
