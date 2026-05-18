import std/tables
import projection_values
import runtime_values

type
  JanetLayoutTargetKind* {.pure.} = enum
    None
    Window
    Frame
    BspNode

  JanetLayoutInstruction* = object
    targetKind*: JanetLayoutTargetKind
    targetId*: uint32
    geom*: Rect

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
    inputFrameCount*: int
    inputBspNodeCount*: int
    instructionCount*: int
    outputTargetKind*: JanetLayoutTargetKind
    instructions*: seq[RenderInstruction]
    frameInstructions*: seq[JanetLayoutInstruction]
