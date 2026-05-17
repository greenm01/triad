import std/tables
import projection_values

type
  JanetLayoutId* = distinct string

  JanetLayoutContext* = object
    layoutId*: JanetLayoutId
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
    layoutId*: JanetLayoutId
    path*: string
    outcome*: JanetLayoutOutcome
    error*: string
    fallbackReason*: string
    durationMs*: int64
    inputWindowCount*: int
    instructionCount*: int
    instructions*: seq[RenderInstruction]
