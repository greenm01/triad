import std/options
import ../core/msg
import ../ipc/commands
import binding

proc actionMsg*(runtime: JanetHandle, index: int): Option[Msg] =
  case int(triadJanetActionKind(runtime, cint(index)))
  of JanetActionCommand:
    var parts: seq[string] = @[]
    let argc = int(triadJanetActionArgc(runtime, cint(index)))
    for argIndex in 0 ..< argc:
      parts.add($triadJanetActionArgv(runtime, cint(index), cint(argIndex)))
    parseCommandParts(parts)
  else:
    none(Msg)
