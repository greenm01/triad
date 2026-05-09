import ../core/model
import ../types/dod_model
import ../types/layout_projection
import dod_layout
import layout_state

type
  LayoutProjectionSyncReport* = object
    ok*: bool
    shadowChecked*: bool
    legacyProjection*: LayoutProjection
    dodProjection*: LayoutProjection
    errors*: seq[string]

proc syncLayoutProjection*(
    legacyModel: var Model; shadow: var DodModel;
    syncShadow: bool): LayoutProjectionSyncReport =
  result.ok = true
  result.legacyProjection = legacyModel.layoutProjection()
  legacyModel.applyLayoutProjection(result.legacyProjection)

  if not syncShadow:
    return

  result.shadowChecked = true
  result.dodProjection = shadow.layoutProjection()
  shadow.applyLayoutProjection(result.dodProjection)

  if result.dodProjection.instructions != result.legacyProjection.instructions:
    result.ok = false
    result.errors.add("layout instructions mismatch")
  if result.dodProjection.viewportTargets != result.legacyProjection.viewportTargets:
    result.ok = false
    result.errors.add("layout viewport targets mismatch")
