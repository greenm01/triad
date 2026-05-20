import std/[json, options, strutils]

type
  BindingDispatchKind* {.pure.} = enum
    BindKey
    BindPointer
    BindAxis
    BindGesture

  BindingDispatchRequest* = object
    kind*: BindingDispatchKind
    binding*: string
    ticks*: int32
    fingers*: uint32

  BindingDispatchResult* = object
    ok*: bool
    error*: string
    request*: BindingDispatchRequest
    command*: string
    dispatched*: int32

proc bindingDispatchKindId*(kind: BindingDispatchKind): string =
  case kind
  of BindingDispatchKind.BindKey: "key"
  of BindingDispatchKind.BindPointer: "pointer"
  of BindingDispatchKind.BindAxis: "axis"
  of BindingDispatchKind.BindGesture: "gesture"

proc parseBindingDispatchKind*(value: string): Option[BindingDispatchKind] =
  case value.normalize()
  of "key":
    some(BindingDispatchKind.BindKey)
  of "pointer", "mouse":
    some(BindingDispatchKind.BindPointer)
  of "axis", "wheel", "scroll":
    some(BindingDispatchKind.BindAxis)
  of "gesture":
    some(BindingDispatchKind.BindGesture)
  else:
    none(BindingDispatchKind)

proc parseInt32(value: string): Option[int32] =
  try:
    let parsed = parseInt(value)
    if parsed >= int(low(int32)) and parsed <= int(high(int32)):
      return some(int32(parsed))
  except CatchableError:
    discard
  none(int32)

proc parseUInt32(value: string): Option[uint32] =
  try:
    let parsed = parseInt(value)
    if parsed >= 0 and parsed <= int(high(uint32)):
      return some(uint32(parsed))
  except CatchableError:
    discard
  none(uint32)

proc parseBindingDispatchText*(line: string): Option[BindingDispatchRequest] =
  let parts = line.strip().splitWhitespace()
  if parts.len < 3 or parts[0] != "dispatch-binding":
    return none(BindingDispatchRequest)
  let kind = parseBindingDispatchKind(parts[1])
  if kind.isNone:
    return none(BindingDispatchRequest)
  var request = BindingDispatchRequest(
    kind: kind.get(), binding: parts[2], ticks: 1'i32, fingers: 0'u32
  )
  case kind.get()
  of BindingDispatchKind.BindKey, BindingDispatchKind.BindPointer:
    if parts.len != 3:
      return none(BindingDispatchRequest)
  of BindingDispatchKind.BindAxis:
    if parts.len > 4:
      return none(BindingDispatchRequest)
    if parts.len == 4:
      let ticks = parseInt32(parts[3])
      if ticks.isNone:
        return none(BindingDispatchRequest)
      request.ticks = ticks.get()
  of BindingDispatchKind.BindGesture:
    if parts.len != 4:
      return none(BindingDispatchRequest)
    let fingers = parseUInt32(parts[3])
    if fingers.isNone:
      return none(BindingDispatchRequest)
    request.fingers = fingers.get()
  some(request)

proc stringField(node: JsonNode, field: string): string =
  if node.kind == JObject and node.hasKey(field) and node[field].kind == JString:
    node[field].getStr()
  else:
    ""

proc int32Field(node: JsonNode, field: string): Option[int32] =
  if node.kind != JObject or not node.hasKey(field) or node[field].kind != JInt:
    return none(int32)
  let value = node[field].getInt()
  if value >= int(low(int32)) and value <= int(high(int32)):
    some(int32(value))
  else:
    none(int32)

proc uint32Field(node: JsonNode, field: string): Option[uint32] =
  if node.kind != JObject or not node.hasKey(field) or node[field].kind != JInt:
    return none(uint32)
  let value = node[field].getInt()
  if value >= 0 and value <= int(high(uint32)):
    some(uint32(value))
  else:
    none(uint32)

proc bindingDispatchRequestFromPayload*(
    payload: JsonNode
): Option[BindingDispatchRequest] =
  let kind = parseBindingDispatchKind(payload.stringField("kind"))
  if kind.isNone:
    return none(BindingDispatchRequest)
  let binding = payload.stringField("binding")
  if binding.len == 0:
    return none(BindingDispatchRequest)
  var request = BindingDispatchRequest(
    kind: kind.get(), binding: binding, ticks: 1'i32, fingers: 0'u32
  )
  case kind.get()
  of BindingDispatchKind.BindKey, BindingDispatchKind.BindPointer:
    discard
  of BindingDispatchKind.BindAxis:
    if payload.hasKey("ticks"):
      let ticks = payload.int32Field("ticks")
      if ticks.isNone:
        return none(BindingDispatchRequest)
      request.ticks = ticks.get()
  of BindingDispatchKind.BindGesture:
    let fingers = payload.uint32Field("fingers")
    if fingers.isNone:
      return none(BindingDispatchRequest)
    request.fingers = fingers.get()
  some(request)

proc bindingDispatchPayload*(request: BindingDispatchRequest): string =
  var payload =
    %*{
      "triad": {
        "version": 1,
        "request": "dispatch-binding",
        "kind": request.kind.bindingDispatchKindId(),
        "binding": request.binding,
      }
    }
  case request.kind
  of BindingDispatchKind.BindAxis:
    payload["triad"]["ticks"] = %request.ticks
  of BindingDispatchKind.BindGesture:
    payload["triad"]["fingers"] = %request.fingers
  of BindingDispatchKind.BindKey, BindingDispatchKind.BindPointer:
    discard
  $payload

proc bindingDispatchAck*(dispatch: BindingDispatchResult): string =
  $(
    %*{
      "ok": true,
      "triad": {
        "version": 1,
        "type": "binding-dispatch",
        "kind": dispatch.request.kind.bindingDispatchKindId(),
        "binding": dispatch.request.binding,
        "command": dispatch.command,
        "dispatched": dispatch.dispatched,
      },
    }
  )

proc bindingDispatchError*(message: string): string =
  $(%*{"ok": false, "error": message})

proc bindingDispatchReply*(dispatch: BindingDispatchResult): string =
  if dispatch.ok:
    bindingDispatchAck(dispatch)
  else:
    bindingDispatchError(dispatch.error)
