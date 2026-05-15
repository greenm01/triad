{.passC: "-Ivendor/janet".}
{.passC: "-DJANET_NO_DYNAMIC_MODULES".}
{.passC: "-DJANET_NO_NET".}
{.passC: "-DJANET_NO_FFI".}
{.passC: "-DJANET_NO_PROCESSES".}
{.compile: "../../vendor/janet/janet.c".}
{.compile: "binding.c".}

const
  JanetActionMoveToTag* = 1
  JanetActionMoveToWorkspace* = 2
  JanetActionFocusTag* = 3
  JanetActionSetLayout* = 4
  JanetActionToggleFloating* = 5
  JanetActionSpawn* = 6
  JanetActionMoveWindowToTag* = 7
  JanetActionMoveWindowToWorkspace* = 8
  JanetActionSetWindowFloating* = 9
  JanetActionSetLayoutForWorkspace* = 10
  JanetActionFocusWindow* = 11
  JanetActionSetWindowMaximized* = 12

type JanetHandle* = pointer

proc triadJanetNew*(): JanetHandle {.importc: "triad_janet_new".}
proc triadJanetFree*(runtime: JanetHandle) {.importc: "triad_janet_free".}
proc triadJanetEval*(
  runtime: JanetHandle, snapshotSource, source, path: cstring, fuelLimit: int32
): cint {.importc: "triad_janet_eval".}

proc triadJanetLastError*(
  runtime: JanetHandle
): cstring {.importc: "triad_janet_last_error".}

proc triadJanetActionCount*(
  runtime: JanetHandle
): cint {.importc: "triad_janet_action_count".}

proc triadJanetActionKind*(
  runtime: JanetHandle, index: cint
): cint {.importc: "triad_janet_action_kind".}

proc triadJanetActionU32*(
  runtime: JanetHandle, index: cint
): uint32 {.importc: "triad_janet_action_u32".}

proc triadJanetActionU32B*(
  runtime: JanetHandle, index: cint
): uint32 {.importc: "triad_janet_action_u32_b".}

proc triadJanetActionBool*(
  runtime: JanetHandle, index: cint
): cint {.importc: "triad_janet_action_bool".}

proc triadJanetActionText*(
  runtime: JanetHandle, index: cint
): cstring {.importc: "triad_janet_action_text".}

proc triadJanetActionArgc*(
  runtime: JanetHandle, index: cint
): cint {.importc: "triad_janet_action_argc".}

proc triadJanetActionArgv*(
  runtime: JanetHandle, index, argIndex: cint
): cstring {.importc: "triad_janet_action_argv".}
