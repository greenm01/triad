{.passC: "-Ivendor/janet".}
{.passC: "-DJANET_NO_DYNAMIC_MODULES".}
{.passC: "-DJANET_NO_NET".}
{.passC: "-DJANET_NO_FFI".}
{.passC: "-DJANET_NO_PROCESSES".}
{.compile: "../../vendor/janet/janet.c".}
{.compile: "binding.c".}

const JanetActionCommand* = 1
const JanetMovementNoop* = 1
const JanetMovementMoveOrder* = 2

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

proc triadJanetScriptInterestedInEvent*(
  script: JanetScriptHandle, eventName: cstring
): cint {.importc: "triad_janet_script_interested_in_event".}

proc triadJanetScriptHasLayout*(
  script: JanetScriptHandle, layoutName: cstring
): cint {.importc: "triad_janet_script_has_layout".}

proc triadJanetScriptHasLayoutMovement*(
  script: JanetScriptHandle, layoutName: cstring
): cint {.importc: "triad_janet_script_has_layout_movement".}

proc triadJanetScriptEvalLayout*(
  runtime: JanetHandle,
  script: JanetScriptHandle,
  layoutName, contextSource, path: cstring,
  fuelLimit: int32,
): cint {.importc: "triad_janet_script_eval_layout".}

proc triadJanetScriptEvalLayoutMovement*(
  runtime: JanetHandle,
  script: JanetScriptHandle,
  layoutName, contextSource, direction, path: cstring,
  fuelLimit: int32,
): cint {.importc: "triad_janet_script_eval_layout_movement".}

proc triadJanetScriptFree*(
  script: JanetScriptHandle
) {.importc: "triad_janet_script_free".}

proc triadJanetRuntimeActionCapacity*(
  runtime: JanetHandle
): cint {.importc: "triad_janet_runtime_action_capacity".}

proc triadJanetRuntimeLayoutInstructionCapacity*(
  runtime: JanetHandle
): cint {.importc: "triad_janet_runtime_layout_instruction_capacity".}

proc triadJanetRuntimeEstimatedCBytes*(
  runtime: JanetHandle
): cint {.importc: "triad_janet_runtime_estimated_c_bytes".}

proc triadJanetScriptHandlerListCount*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_handler_list_count".}

proc triadJanetScriptHandlerListCapacity*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_handler_list_capacity".}

proc triadJanetScriptHandlerCount*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_handler_count".}

proc triadJanetScriptHandlerCapacity*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_handler_capacity".}

proc triadJanetScriptLayoutCount*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_layout_count".}

proc triadJanetScriptLayoutCapacity*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_layout_capacity".}

proc triadJanetScriptLayoutMovementCount*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_layout_movement_count".}

proc triadJanetScriptLayoutMovementCapacity*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_layout_movement_capacity".}

proc triadJanetScriptWaiterCount*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_waiter_count".}

proc triadJanetScriptWaiterCapacity*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_waiter_capacity".}

proc triadJanetScriptEstimatedCBytes*(
  script: JanetScriptHandle
): cint {.importc: "triad_janet_script_estimated_c_bytes".}

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

proc triadJanetMovementOp*(
  runtime: JanetHandle
): cint {.importc: "triad_janet_movement_op".}

proc triadJanetMovementDelta*(
  runtime: JanetHandle
): int32 {.importc: "triad_janet_movement_delta".}
