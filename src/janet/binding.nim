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
  eventName, eventSource, path: cstring,
  fuelLimit: int32,
): cint {.importc: "triad_janet_script_dispatch".}

proc triadJanetScriptHasLayout*(
  script: JanetScriptHandle, layoutName: cstring
): cint {.importc: "triad_janet_script_has_layout".}

proc triadJanetScriptEvalLayout*(
  runtime: JanetHandle,
  script: JanetScriptHandle,
  layoutName, contextSource, path: cstring,
  fuelLimit: int32,
): cint {.importc: "triad_janet_script_eval_layout".}

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

proc triadJanetLayoutInstructionCount*(
  runtime: JanetHandle
): cint {.importc: "triad_janet_layout_instruction_count".}

proc triadJanetLayoutWindowId*(
  runtime: JanetHandle, index: cint
): uint32 {.importc: "triad_janet_layout_window_id".}

proc triadJanetLayoutTargetKind*(
  runtime: JanetHandle, index: cint
): cint {.importc: "triad_janet_layout_target_kind".}

proc triadJanetLayoutTargetId*(
  runtime: JanetHandle, index: cint
): uint32 {.importc: "triad_janet_layout_target_id".}

proc triadJanetLayoutX*(
  runtime: JanetHandle, index: cint
): int32 {.importc: "triad_janet_layout_x".}

proc triadJanetLayoutY*(
  runtime: JanetHandle, index: cint
): int32 {.importc: "triad_janet_layout_y".}

proc triadJanetLayoutW*(
  runtime: JanetHandle, index: cint
): int32 {.importc: "triad_janet_layout_w".}

proc triadJanetLayoutH*(
  runtime: JanetHandle, index: cint
): int32 {.importc: "triad_janet_layout_h".}
