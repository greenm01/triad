import std/tables
import projection_values
import runtime_values

type
  JanetLayoutContext* = object
    layoutId*: runtime_values.JanetLayoutId
    screen*: Rect
    outerGap*: int32
    innerGap*: int32
    tag*: ProjectedTag
    windows*: Table[ProjectionWindowId, ProjectedWindow]

  JanetLayoutOutcome* {.pure.} = enum
    Disabled
    Missing
    LoadFailed
    EvalFailed
    Invalid
    Applied

  JanetLayoutEvalResult* = object
    layoutId*: runtime_values.JanetLayoutId
    path*: string
    outcome*: JanetLayoutOutcome
    error*: string
    fallbackReason*: string
    durationMs*: int64
    inputWindowCount*: int
    instructionCount*: int
    instructions*: seq[RenderInstruction]
