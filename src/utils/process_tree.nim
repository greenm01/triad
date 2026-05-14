import std/strutils

type ParentPidReader* = proc(pid: int32): int32 {.gcsafe.}

proc parentPidFromProc*(pid: int32): int32 =
  if pid <= 0:
    return 0
  try:
    let stat = readFile("/proc/" & $pid & "/stat")
    let endComm = stat.rfind(")")
    if endComm < 0 or endComm + 4 >= stat.len:
      return 0
    let fields = stat[endComm + 2 .. ^1].splitWhitespace()
    if fields.len < 2:
      return 0
    int32(parseInt(fields[1]))
  except CatchableError:
    0'i32

proc isDescendantProcess*(
    ancestorPid, childPid: int32,
    parentPid: ParentPidReader = parentPidFromProc,
    maxDepth = 64,
): bool =
  if ancestorPid <= 0 or childPid <= 0 or ancestorPid == childPid:
    return false
  var current = childPid
  var depth = 0
  while current > 0 and depth < maxDepth:
    current = parentPid(current)
    if current == ancestorPid:
      return true
    inc depth
  false
