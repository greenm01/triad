{.passC: "-Ivendor/janet".}
{.passC: "-DJANET_NO_DYNAMIC_MODULES".}
{.passC: "-DJANET_NO_NET".}
{.passC: "-DJANET_NO_FFI".}
{.passC: "-DJANET_NO_PROCESSES".}
{.compile: "../../vendor/janet/janet.c".}
{.compile: "binding.c".}

const JanetActionCommand* = 1

type JanetHandle* = pointer
type JanetScriptHandle* = pointer

proc triadJanetNew*(): JanetHandle {.importc: "triad_janet_new".}
proc triadJanetFree*(runtime: JanetHandle) {.importc: "triad_janet_free".}
proc triadJanetEval*(
  runtime: JanetHandle, snapshotSource, source, path: cstring, fuelLimit: int32
): cint {.importc: "triad_janet_eval".}

proc triadJanetScriptLoad*(
  runtime: JanetHandle, bootstrapSource, source, path: cstring, fuelLimit: int32
): JanetScriptHandle {.importc: "triad_janet_script_load".}

proc triadJanetScriptDispatch*(
  runtime: JanetHandle,
  script: JanetScriptHandle,
  eventSource, path: cstring,
  fuelLimit: int32,
): cint {.importc: "triad_janet_script_dispatch".}

proc triadJanetScriptFree*(
  script: JanetScriptHandle
) {.importc: "triad_janet_script_free".}

proc triadJanetLastError*(
  runtime: JanetHandle
): cstring {.importc: "triad_janet_last_error".}

proc triadJanetActionCount*(
  runtime: JanetHandle
): cint {.importc: "triad_janet_action_count".}

proc triadJanetActionKind*(
  runtime: JanetHandle, index: cint
): cint {.importc: "triad_janet_action_kind".}

proc triadJanetActionArgc*(
  runtime: JanetHandle, index: cint
): cint {.importc: "triad_janet_action_argc".}

proc triadJanetActionArgv*(
  runtime: JanetHandle, index, argIndex: cint
): cstring {.importc: "triad_janet_action_argv".}
