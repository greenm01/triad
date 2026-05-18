from projection_values import ProjectedFrameTabBar, RenderInstruction

type
  LayoutViewportTarget* = object
    tagSlot*: uint32
    targetX*: float32
    targetY*: float32

  LayoutProjection* = object
    instructions*: seq[RenderInstruction]
    frameTabBars*: seq[ProjectedFrameTabBar]
    viewportTargets*: seq[LayoutViewportTarget]
