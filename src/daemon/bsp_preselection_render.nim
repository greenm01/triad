import ../types/projection_values
import pixel_buffer

export pixel_buffer

proc bspPreselectionCacheKey*(preselection: ProjectedBspPreselection): string =
  "bsp-preselect-v1:" & $preselection.nodeId & ":" & $preselection.geom.w & ":" &
    $preselection.geom.h & ":" & $preselection.direction & ":" & $preselection.ringWidth &
    ":" & $preselection.ringColor & ":" & $preselection.backgroundColor

proc renderBspPreselectionBuffer*(preselection: ProjectedBspPreselection): PixelBuffer =
  result = initPixelBuffer(
    max(1'i32, preselection.geom.w),
    max(1'i32, preselection.geom.h),
    rgbaColorToArgb(preselection.backgroundColor),
  )
  result.strokeRect(
    0,
    0,
    result.width,
    result.height,
    max(1'i32, preselection.ringWidth),
    rgbaColorToArgb(preselection.ringColor),
  )
