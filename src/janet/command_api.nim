import std/[options, strutils]
import ../core/msg
import ../ipc/commands
import binding

proc actionParts*(runtime: JanetHandle, index: int): seq[string] =
  let argc = int(triadJanetActionArgc(runtime, cint(index)))
  for argIndex in 0 ..< argc:
    result.add($triadJanetActionArgv(runtime, cint(index), cint(argIndex)))

proc actionText*(parts: openArray[string]): string =
  if parts.len == 0:
    return "<empty>"
  parts.join(" ")

proc actionMsg*(runtime: JanetHandle, index: int): Option[Msg] =
  case int(triadJanetActionKind(runtime, cint(index)))
  of JanetActionCommand:
    parseCommandParts(runtime.actionParts(index))
  else:
    none(Msg)

proc actionError*(runtime: JanetHandle, index: int): string =
  case int(triadJanetActionKind(runtime, cint(index)))
  of JanetActionCommand:
    "invalid Janet command: " & runtime.actionParts(index).actionText()
  else:
    "unsupported Janet action"
