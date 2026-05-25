import std/tables

type
  ProtocolIssueKind* {.pure.} = enum
    Fatal
    Warning

  ProtocolSpecKind* {.pure.} = enum
    BoundOnly
    Required
    Optional

  ProtocolSpec* = object
    interfaceName*: string
    minVersion*: uint32
    maxBindVersion*: uint32
    feature*: string
    kind*: ProtocolSpecKind

  ProtocolIssue* = object
    interfaceName*: string
    feature*: string
    advertisedVersion*: uint32
    requiredVersion*: uint32
    kind*: ProtocolIssueKind
    missing*: bool
    message*: string

  ProtocolDiagnostics* = object
    fatalIssues*: seq[ProtocolIssue]
    warningIssues*: seq[ProtocolIssue]

const UpstreamRiverHint* = "install upstream River 0.4+ or set TRIAD_RIVER_BIN"

const RiverXkbBindingsModifierWatchVersion* = 3'u32

const ProtocolSpecs* = [
  ProtocolSpec(
    interfaceName: "river_window_manager_v1",
    minVersion: 4'u32,
    maxBindVersion: 4'u32,
    feature: "window management",
    kind: ProtocolSpecKind.Required,
  ),
  ProtocolSpec(
    interfaceName: "river_xkb_bindings_v1",
    minVersion: 2'u32,
    maxBindVersion: 3'u32,
    feature: "keyboard bindings",
    kind: ProtocolSpecKind.Required,
  ),
  ProtocolSpec(
    interfaceName: "wl_compositor",
    minVersion: 1'u32,
    maxBindVersion: 6'u32,
    feature: "Wayland surfaces",
    kind: ProtocolSpecKind.Required,
  ),
  ProtocolSpec(
    interfaceName: "wl_shm",
    minVersion: 1'u32,
    maxBindVersion: 1'u32,
    feature: "shared-memory buffers",
    kind: ProtocolSpecKind.Required,
  ),
  ProtocolSpec(
    interfaceName: "wl_output",
    minVersion: 1'u32,
    maxBindVersion: 4'u32,
    feature: "Wayland output state",
    kind: ProtocolSpecKind.BoundOnly,
  ),
  ProtocolSpec(
    interfaceName: "wl_seat",
    minVersion: 1'u32,
    maxBindVersion: 9'u32,
    feature: "Wayland seats",
    kind: ProtocolSpecKind.BoundOnly,
  ),
  ProtocolSpec(
    interfaceName: "zwp_pointer_gestures_v1",
    minVersion: 3'u32,
    maxBindVersion: 3'u32,
    feature: "touchpad gesture bindings",
    kind: ProtocolSpecKind.Optional,
  ),
  ProtocolSpec(
    interfaceName: "river_xkb_config_v1",
    minVersion: 2'u32,
    maxBindVersion: 2'u32,
    feature: "keyboard layout and keymap configuration",
    kind: ProtocolSpecKind.Optional,
  ),
  ProtocolSpec(
    interfaceName: "river_input_manager_v1",
    minVersion: 2'u32,
    maxBindVersion: 2'u32,
    feature: "input device repeat and assignment configuration",
    kind: ProtocolSpecKind.Optional,
  ),
  ProtocolSpec(
    interfaceName: "river_libinput_config_v1",
    minVersion: 2'u32,
    maxBindVersion: 2'u32,
    feature: "mouse, touchpad, trackpoint, and trackball configuration",
    kind: ProtocolSpecKind.Optional,
  ),
  ProtocolSpec(
    interfaceName: "zwlr_output_manager_v1",
    minVersion: 4'u32,
    maxBindVersion: 4'u32,
    feature: "output rules, adaptive sync, and monitor power",
    kind: ProtocolSpecKind.Optional,
  ),
  ProtocolSpec(
    interfaceName: "river_layer_shell_v1",
    minVersion: 1'u32,
    maxBindVersion: 1'u32,
    feature: "Triad overlay surfaces",
    kind: ProtocolSpecKind.Optional,
  ),
  ProtocolSpec(
    interfaceName: "wp_cursor_shape_manager_v1",
    minVersion: 2'u32,
    maxBindVersion: 2'u32,
    feature: "cursor shape updates",
    kind: ProtocolSpecKind.Optional,
  ),
  ProtocolSpec(
    interfaceName: "zwp_idle_inhibit_manager_v1",
    minVersion: 1'u32,
    maxBindVersion: 1'u32,
    feature: "idle inhibit requests",
    kind: ProtocolSpecKind.Optional,
  ),
  ProtocolSpec(
    interfaceName: "wp_single_pixel_buffer_manager_v1",
    minVersion: 1'u32,
    maxBindVersion: 1'u32,
    feature: "solid-color protocol surfaces",
    kind: ProtocolSpecKind.Optional,
  ),
]

proc protocolSpec*(interfaceName: string): ProtocolSpec =
  for spec in ProtocolSpecs:
    if spec.interfaceName == interfaceName:
      return spec

proc protocolIsKnown*(interfaceName: string): bool =
  for spec in ProtocolSpecs:
    if spec.interfaceName == interfaceName:
      return true

proc protocolIsUsable*(interfaceName: string, advertisedVersion: uint32): bool =
  let spec = protocolSpec(interfaceName)
  spec.interfaceName.len > 0 and advertisedVersion >= spec.minVersion

proc protocolBindVersion*(interfaceName: string, advertisedVersion: uint32): uint32 =
  let spec = protocolSpec(interfaceName)
  if spec.interfaceName.len == 0 or advertisedVersion < spec.minVersion:
    return 0'u32
  min(advertisedVersion, spec.maxBindVersion)

proc issueKind(spec: ProtocolSpec): ProtocolIssueKind =
  case spec.kind
  of ProtocolSpecKind.Required: ProtocolIssueKind.Fatal
  of ProtocolSpecKind.Optional: ProtocolIssueKind.Warning
  of ProtocolSpecKind.BoundOnly: ProtocolIssueKind.Warning

proc issueMessage(spec: ProtocolSpec, version: uint32, missing: bool): string =
  if missing:
    result = spec.interfaceName & " not advertised; Triad requires " & spec.feature
  else:
    result =
      spec.interfaceName & " v" & $spec.minVersion & " is required for " & spec.feature &
      "; compositor advertised v" & $version

  if spec.kind == ProtocolSpecKind.Required:
    result.add("; " & UpstreamRiverHint)

proc riverProtocolDiagnostics*(
    advertisedVersions: Table[string, uint32]
): ProtocolDiagnostics =
  for spec in ProtocolSpecs:
    if spec.kind == ProtocolSpecKind.BoundOnly:
      continue
    let missing = not advertisedVersions.hasKey(spec.interfaceName)
    let version =
      if missing:
        0'u32
      else:
        advertisedVersions[spec.interfaceName]
    if not missing and version >= spec.minVersion:
      continue

    let issue = ProtocolIssue(
      interfaceName: spec.interfaceName,
      feature: spec.feature,
      advertisedVersion: version,
      requiredVersion: spec.minVersion,
      kind: spec.issueKind(),
      missing: missing,
      message: spec.issueMessage(version, missing),
    )
    case issue.kind
    of ProtocolIssueKind.Fatal:
      result.fatalIssues.add(issue)
    of ProtocolIssueKind.Warning:
      result.warningIssues.add(issue)
