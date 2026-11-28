import std/[json, options, sequtils]
import ../core/[effects, msg]
import ../state/engine
import ../systems/daemon_view
import ../utils/[behavior_log, runtime_deadlines]
from ../types/runtime_values import PointerOpKind
import state

proc rectJson(rect: Rect): JsonNode =
  %*{"x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h}

proc pointerOpPayload(model: Model, op: PointerOpData, trigger: MsgKind): JsonNode =
  %*{
    "kind": $op.kind,
    "window_id": model.runtimeWindowId(op.windowId),
    "tiled": op.tiled,
    "initial_geom": op.initialGeom.rectJson(),
    "trigger": $trigger,
  }

proc logPointerOpTransition*(
    daemon: var TriadDaemon,
    before: PointerOpData,
    trigger: MsgKind,
    effects: seq[Effect],
) =
  ## Writes pointer_op_started and pointer_op_finished behavior events when a
  ## move, resize, or overview drag begins or ends.
  if not behaviorLogEnabled():
    return
  let model = daemon.runtimeState.model
  let after = model.pointerOp
  let wasActive = before.kind != PointerOpKind.OpNone
  let isActive = after.kind != PointerOpKind.OpNone
  if isActive and (not wasActive or after.windowId != before.windowId):
    daemon.pointerOpStartedMs = monotonicMs()
    writeBehaviorEvent("pointer_op_started", model.pointerOpPayload(after, trigger))
  if not wasActive or (isActive and after.windowId == before.windowId):
    return

  let payload = model.pointerOpPayload(before, trigger)
  payload["released"] = %(trigger == MsgKind.WlPointerRelease)
  payload["drag_active"] = %before.dragActive
  payload["total_delta"] = %*{"dx": before.totalDX, "dy": before.totalDY}
  payload["drop_kind"] = %($before.dropKind)
  payload["drop_floating"] = %before.dropFloating
  payload["drop_tag"] = %uint32(before.dropTag)
  payload["resize_end_sent"] = %effects.anyIt(it.kind == EffectKind.EffInformResizeEnd)
  if daemon.pointerOpStartedMs > 0:
    payload["duration_ms"] = %(monotonicMs() - daemon.pointerOpStartedMs)
  let winOpt = model.windowData(before.windowId)
  if winOpt.isSome:
    payload["is_floating"] = %winOpt.get().isFloating
    payload["floating_geom"] = winOpt.get().floatingGeom.rectJson()
  writeBehaviorEvent("pointer_op_finished", payload)
