import std/tables

type
  ProtocolIssueKind* {.pure.} = enum
    Fatal
    Warning

  ProtocolRequirement = object
    interfaceName: string
    minVersion: uint32
    feature: string
    kind: ProtocolIssueKind

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

const ProtocolRequirements = [
  ProtocolRequirement(
    interfaceName: "river_window_manager_v1",
    minVersion: 4'u32,
    feature: "window management",
    kind: ProtocolIssueKind.Fatal,
  ),
  ProtocolRequirement(
    interfaceName: "river_xkb_bindings_v1",
    minVersion: 2'u32,
    feature: "keyboard bindings",
    kind: ProtocolIssueKind.Fatal,
  ),
  ProtocolRequirement(
    interfaceName: "wl_compositor",
    minVersion: 1'u32,
    feature: "Wayland surfaces",
    kind: ProtocolIssueKind.Fatal,
  ),
  ProtocolRequirement(
    interfaceName: "wl_shm",
    minVersion: 1'u32,
    feature: "shared-memory buffers",
    kind: ProtocolIssueKind.Fatal,
  ),
  ProtocolRequirement(
    interfaceName: "zwp_pointer_gestures_v1",
    minVersion: 3'u32,
    feature: "touchpad gesture bindings",
    kind: ProtocolIssueKind.Warning,
  ),
  ProtocolRequirement(
    interfaceName: "river_xkb_config_v1",
    minVersion: 2'u32,
    feature: "keyboard layout and keymap configuration",
    kind: ProtocolIssueKind.Warning,
  ),
  ProtocolRequirement(
    interfaceName: "river_input_manager_v1",
    minVersion: 2'u32,
    feature: "input device repeat and assignment configuration",
    kind: ProtocolIssueKind.Warning,
  ),
  ProtocolRequirement(
    interfaceName: "river_libinput_config_v1",
    minVersion: 2'u32,
    feature: "mouse, touchpad, trackpoint, and trackball configuration",
    kind: ProtocolIssueKind.Warning,
  ),
  ProtocolRequirement(
    interfaceName: "zwlr_output_manager_v1",
    minVersion: 4'u32,
    feature: "output rules, adaptive sync, and monitor power",
    kind: ProtocolIssueKind.Warning,
  ),
  ProtocolRequirement(
    interfaceName: "river_layer_shell_v1",
    minVersion: 1'u32,
    feature: "Triad overlay surfaces",
    kind: ProtocolIssueKind.Warning,
  ),
  ProtocolRequirement(
    interfaceName: "wp_cursor_shape_manager_v1",
    minVersion: 2'u32,
    feature: "cursor shape updates",
    kind: ProtocolIssueKind.Warning,
  ),
  ProtocolRequirement(
    interfaceName: "zwp_idle_inhibit_manager_v1",
    minVersion: 1'u32,
    feature: "idle inhibit requests",
    kind: ProtocolIssueKind.Warning,
  ),
  ProtocolRequirement(
    interfaceName: "wp_single_pixel_buffer_manager_v1",
    minVersion: 1'u32,
    feature: "solid-color protocol surfaces",
    kind: ProtocolIssueKind.Warning,
  ),
]

proc issueMessage(req: ProtocolRequirement, version: uint32, missing: bool): string =
  if missing:
    result = req.interfaceName & " not advertised; Triad requires " & req.feature
  else:
    result =
      req.interfaceName & " v" & $req.minVersion & " is required for " & req.feature &
      "; compositor advertised v" & $version

  if req.kind == ProtocolIssueKind.Fatal:
    result.add("; " & UpstreamRiverHint)

proc riverProtocolDiagnostics*(
    advertisedVersions: Table[string, uint32]
): ProtocolDiagnostics =
  for req in ProtocolRequirements:
    let missing = not advertisedVersions.hasKey(req.interfaceName)
    let version =
      if missing:
        0'u32
      else:
        advertisedVersions[req.interfaceName]
    if not missing and version >= req.minVersion:
      continue

    let issue = ProtocolIssue(
      interfaceName: req.interfaceName,
      feature: req.feature,
      advertisedVersion: version,
      requiredVersion: req.minVersion,
      kind: req.kind,
      missing: missing,
      message: req.issueMessage(version, missing),
    )
    case req.kind
    of ProtocolIssueKind.Fatal:
      result.fatalIssues.add(issue)
    of ProtocolIssueKind.Warning:
      result.warningIssues.add(issue)
