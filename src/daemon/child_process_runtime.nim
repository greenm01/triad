import std/[json, osproc]
import chronicles
import ../utils/behavior_log
import state

proc trackChildProcess*(daemon: var TriadDaemon, process: Process, command = "") =
  if process == nil:
    return
  daemon.fireAndForgetProcesses.add(process)
  writeBehaviorEvent(
    "child_process_tracked",
    %*{
      "pid": process.processID,
      "command": command,
      "tracked_count": daemon.fireAndForgetProcesses.len,
    },
  )

proc trackChildProcesses*(daemon: var TriadDaemon, processes: openArray[Process]) =
  for process in processes:
    daemon.trackChildProcess(process)

proc reapChildProcesses*(daemon: var TriadDaemon): int =
  var i = 0
  while i < daemon.fireAndForgetProcesses.len:
    let process = daemon.fireAndForgetProcesses[i]
    if process == nil:
      daemon.fireAndForgetProcesses.delete(i)
      continue

    let code = process.peekExitCode()
    if code == -1:
      inc i
      continue

    let pid = process.processID
    try:
      process.close()
    except CatchableError as e:
      warn "Failed to close exited child process handle", pid = pid, error = e.msg
    daemon.fireAndForgetProcesses.delete(i)
    inc result
    writeBehaviorEvent(
      "child_process_reaped",
      %*{
        "pid": pid,
        "exit_code": code,
        "tracked_count": daemon.fireAndForgetProcesses.len,
      },
    )
