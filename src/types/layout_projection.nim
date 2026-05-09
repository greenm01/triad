from runtime_values import RenderInstruction

type
  LayoutViewportTarget* = object
    tagSlot*: uint32
    targetX*: float32
    targetY*: float32

  LayoutProjection* = object
    instructions*: seq[RenderInstruction]
    viewportTargets*: seq[LayoutViewportTarget]
