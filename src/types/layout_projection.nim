from projection_values import
  ProjectedBspPreselection, ProjectedFrameEmptyChrome, ProjectedFrameTabBar,
  RenderInstruction

type
  LayoutViewportTarget* = object
    tagSlot*: uint32
    targetX*: float32
    targetY*: float32

  LayoutProjection* = object
    instructions*: seq[RenderInstruction]
    frameTabBars*: seq[ProjectedFrameTabBar]
    frameEmptyChrome*: seq[ProjectedFrameEmptyChrome]
    bspPreselections*: seq[ProjectedBspPreselection]
    viewportTargets*: seq[LayoutViewportTarget]
