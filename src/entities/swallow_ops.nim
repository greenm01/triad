import std/tables
import ../types/[core, model]

proc setSwallowRelation*(model: var Model, host, child: WindowId): bool =
  if host == NullWindowId or child == NullWindowId or host == child:
    return false
  if model.swallowing.getOrDefault(host, NullWindowId) == child and
      model.swallowedBy.getOrDefault(child, NullWindowId) == host:
    return false
  if model.swallowing.hasKey(host):
    model.swallowedBy.del(model.swallowing[host])
  if model.swallowedBy.hasKey(child):
    model.swallowing.del(model.swallowedBy[child])
  model.swallowing[host] = child
  model.swallowedBy[child] = host
  true

proc clearSwallowRelationForHost*(model: var Model, host: WindowId): bool =
  if not model.swallowing.hasKey(host):
    return false
  let child = model.swallowing[host]
  model.swallowing.del(host)
  model.swallowedBy.del(child)
  true

proc clearSwallowRelationForChild*(model: var Model, child: WindowId): bool =
  if not model.swallowedBy.hasKey(child):
    return false
  let host = model.swallowedBy[child]
  model.swallowedBy.del(child)
  model.swallowing.del(host)
  true

proc clearSwallowRelations*(model: var Model, winId: WindowId): bool =
  result = model.clearSwallowRelationForHost(winId)
  result = model.clearSwallowRelationForChild(winId) or result
