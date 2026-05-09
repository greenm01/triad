type
  RuntimeAuthority* = enum
    LegacyRuntimeAuthority
    DodRuntimeAuthority

  LayoutAuthority* = enum
    LegacyLayoutAuthority
    DodLayoutAuthority

  StateApplicationAuthority* = enum
    LegacyStateApplicationAuthority
    DodStateApplicationAuthority

  TriadRuntimePolicy* = object
    runtimeAuthority*: RuntimeAuthority
    layoutAuthority*: LayoutAuthority
    stateApplicationAuthority*: StateApplicationAuthority

proc defaultTriadRuntimePolicy*(): TriadRuntimePolicy =
  TriadRuntimePolicy(
    runtimeAuthority: DodRuntimeAuthority,
    layoutAuthority: DodLayoutAuthority,
    stateApplicationAuthority: DodStateApplicationAuthority)
