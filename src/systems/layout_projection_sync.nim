import ../core/model
import ../types/dod_model
import ../types/dod_runtime_policy
import ../types/layout_projection
import dod_layout
import layout_state

export dod_runtime_policy

type
  LayoutProjectionSyncReport* = object
    authority*: LayoutAuthority
    ok*: bool
    shadowChecked*: bool
    legacyProjection*: LayoutProjection
    dodProjection*: LayoutProjection
    authoritativeProjection*: LayoutProjection
    errors*: seq[string]

proc syncLayoutProjection*(
    legacyModel: var Model; shadow: var DodModel;
    syncShadow: bool;
    authority = LegacyLayoutAuthority): LayoutProjectionSyncReport =
  result.authority = authority
  result.ok = true
  result.legacyProjection = legacyModel.layoutProjection()
  legacyModel.applyLayoutProjection(result.legacyProjection)

  if syncShadow or authority == DodLayoutAuthority:
    result.dodProjection = shadow.layoutProjection()
    shadow.applyLayoutProjection(result.dodProjection)

  case authority
  of LegacyLayoutAuthority:
    result.authoritativeProjection = result.legacyProjection
  of DodLayoutAuthority:
    result.authoritativeProjection = result.dodProjection

  if not syncShadow:
    return

  result.shadowChecked = true

  if result.dodProjection.instructions != result.legacyProjection.instructions:
    result.ok = false
    result.errors.add("layout instructions mismatch")
  if result.dodProjection.viewportTargets != result.legacyProjection.viewportTargets:
    result.ok = false
    result.errors.add("layout viewport targets mismatch")
