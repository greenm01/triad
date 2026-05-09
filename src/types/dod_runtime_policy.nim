type
  RuntimeAuthority* = enum
    LegacyRuntimeAuthority
    DodRuntimeAuthority

  LayoutAuthority* = enum
    LegacyLayoutAuthority
    DodLayoutAuthority

  TriadRuntimePolicy* = object
    runtimeAuthority*: RuntimeAuthority
    layoutAuthority*: LayoutAuthority

proc defaultTriadRuntimePolicy*(): TriadRuntimePolicy =
  TriadRuntimePolicy(
    runtimeAuthority: DodRuntimeAuthority,
    layoutAuthority: DodLayoutAuthority)
