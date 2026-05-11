import wayland/native/client

proc wlId*(p: pointer): uint32 =
  get_id(cast[ptr Proxy](p))

proc id*(p: pointer): uint32 =
  wlId(p)

proc cstringOrEmpty*(value: cstring): string =
  if value == nil:
    ""
  else:
    $value
