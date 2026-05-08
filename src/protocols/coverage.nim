type
  ProtocolCoverageState* = enum
    pcsImplemented,
    pcsLoggedIgnored,
    pcsUnsupported

  ProtocolCoverageEntry* = object
    event*: string
    state*: ProtocolCoverageState
    note*: string

const
  RiverCapabilityWindowMenu* = 1'u32
  RiverCapabilityMaximize* = 2'u32
  RiverCapabilityFullscreen* = 4'u32
  RiverCapabilityMinimize* = 8'u32
  TriadAdvertisedCapabilities* = RiverCapabilityMaximize or RiverCapabilityFullscreen or RiverCapabilityMinimize

const ActiveRiverListenerEvents* = [
  "river_window_manager_v1.unavailable",
  "river_window_manager_v1.finished",
  "river_window_manager_v1.manage_start",
  "river_window_manager_v1.render_start",
  "river_window_manager_v1.session_locked",
  "river_window_manager_v1.session_unlocked",
  "river_window_manager_v1.window",
  "river_window_manager_v1.output",
  "river_window_manager_v1.seat",
  "river_window_v1.closed",
  "river_window_v1.dimensions_hint",
  "river_window_v1.dimensions",
  "river_window_v1.app_id",
  "river_window_v1.title",
  "river_window_v1.parent",
  "river_window_v1.decoration_hint",
  "river_window_v1.pointer_move_requested",
  "river_window_v1.pointer_resize_requested",
  "river_window_v1.show_window_menu_requested",
  "river_window_v1.maximize_requested",
  "river_window_v1.unmaximize_requested",
  "river_window_v1.fullscreen_requested",
  "river_window_v1.exit_fullscreen_requested",
  "river_window_v1.minimize_requested",
  "river_window_v1.unreliable_pid",
  "river_window_v1.presentation_hint",
  "river_window_v1.identifier",
  "river_output_v1.removed",
  "river_output_v1.wl_output",
  "river_output_v1.position",
  "river_output_v1.dimensions",
  "river_seat_v1.removed",
  "river_seat_v1.wl_seat",
  "river_seat_v1.pointer_enter",
  "river_seat_v1.pointer_leave",
  "river_seat_v1.window_interaction",
  "river_seat_v1.shell_surface_interaction",
  "river_seat_v1.op_delta",
  "river_seat_v1.op_release",
  "river_seat_v1.pointer_position",
  "river_pointer_binding_v1.pressed",
  "river_pointer_binding_v1.released",
  "river_layer_shell_output_v1.non_exclusive_area",
  "river_layer_shell_seat_v1.focus_exclusive",
  "river_layer_shell_seat_v1.focus_non_exclusive",
  "river_layer_shell_seat_v1.focus_none",
  "river_xkb_binding_v1.pressed",
  "river_xkb_binding_v1.released",
  "river_xkb_binding_v1.stop_repeat"
]

const RiverProtocolCoverage* = [
  ProtocolCoverageEntry(event: "river_window_manager_v1.unavailable", state: pcsImplemented, note: "Stops and cleans up River objects."),
  ProtocolCoverageEntry(event: "river_window_manager_v1.finished", state: pcsImplemented, note: "Stops and cleans up River objects."),
  ProtocolCoverageEntry(event: "river_window_manager_v1.manage_start", state: pcsImplemented, note: "Creates pending windows and completes manage sequences."),
  ProtocolCoverageEntry(event: "river_window_manager_v1.render_start", state: pcsImplemented, note: "Applies placement, visibility, clipping, and z order."),
  ProtocolCoverageEntry(event: "river_window_manager_v1.session_locked", state: pcsLoggedIgnored, note: "Logged only; no lock-specific policy yet."),
  ProtocolCoverageEntry(event: "river_window_manager_v1.session_unlocked", state: pcsLoggedIgnored, note: "Logged only; no unlock-specific policy yet."),
  ProtocolCoverageEntry(event: "river_window_manager_v1.window", state: pcsImplemented, note: "Tracks window and node proxies until manage start."),
  ProtocolCoverageEntry(event: "river_window_manager_v1.output", state: pcsImplemented, note: "Tracks outputs and layer-shell output handles."),
  ProtocolCoverageEntry(event: "river_window_manager_v1.seat", state: pcsImplemented, note: "Tracks seats and default bindings."),
  ProtocolCoverageEntry(event: "river_window_v1.closed", state: pcsImplemented, note: "Destroys model/proxy state."),
  ProtocolCoverageEntry(event: "river_window_v1.dimensions_hint", state: pcsImplemented, note: "Stores min/max hints and bounds proposals."),
  ProtocolCoverageEntry(event: "river_window_v1.dimensions", state: pcsImplemented, note: "Acknowledged dimensions are stored for shell and clipping sanity."),
  ProtocolCoverageEntry(event: "river_window_v1.app_id", state: pcsImplemented, note: "Updates pending and live window metadata."),
  ProtocolCoverageEntry(event: "river_window_v1.title", state: pcsImplemented, note: "Updates pending and live window metadata."),
  ProtocolCoverageEntry(event: "river_window_v1.parent", state: pcsImplemented, note: "Stores parent window id."),
  ProtocolCoverageEntry(event: "river_window_v1.decoration_hint", state: pcsLoggedIgnored, note: "Triad currently forces SSD."),
  ProtocolCoverageEntry(event: "river_window_v1.pointer_move_requested", state: pcsImplemented, note: "Starts pointer move for floating windows."),
  ProtocolCoverageEntry(event: "river_window_v1.pointer_resize_requested", state: pcsImplemented, note: "Starts pointer resize for floating windows."),
  ProtocolCoverageEntry(event: "river_window_v1.show_window_menu_requested", state: pcsUnsupported, note: "No window menu implementation; capability is not advertised."),
  ProtocolCoverageEntry(event: "river_window_v1.maximize_requested", state: pcsImplemented, note: "Tracks maximize state and informs clients."),
  ProtocolCoverageEntry(event: "river_window_v1.unmaximize_requested", state: pcsImplemented, note: "Clears maximize state and informs clients."),
  ProtocolCoverageEntry(event: "river_window_v1.fullscreen_requested", state: pcsImplemented, note: "Honors request and requested output when possible."),
  ProtocolCoverageEntry(event: "river_window_v1.exit_fullscreen_requested", state: pcsImplemented, note: "Exits fullscreen and informs the window."),
  ProtocolCoverageEntry(event: "river_window_v1.minimize_requested", state: pcsImplemented, note: "Tracks minimized state, hides the window, and recomputes focus."),
  ProtocolCoverageEntry(event: "river_window_v1.unreliable_pid", state: pcsLoggedIgnored, note: "Logged for diagnostics only."),
  ProtocolCoverageEntry(event: "river_window_v1.presentation_hint", state: pcsLoggedIgnored, note: "No presentation-mode policy yet."),
  ProtocolCoverageEntry(event: "river_window_v1.identifier", state: pcsImplemented, note: "Stored for stable shell/IPC identity."),
  ProtocolCoverageEntry(event: "river_output_v1.removed", state: pcsImplemented, note: "Removes output and clears affected fullscreen state."),
  ProtocolCoverageEntry(event: "river_output_v1.wl_output", state: pcsLoggedIgnored, note: "Logged only; logical River output id is used internally."),
  ProtocolCoverageEntry(event: "river_output_v1.position", state: pcsImplemented, note: "Updates output logical position."),
  ProtocolCoverageEntry(event: "river_output_v1.dimensions", state: pcsImplemented, note: "Updates output logical size."),
  ProtocolCoverageEntry(event: "river_seat_v1.removed", state: pcsImplemented, note: "Destroys seat-related bindings and layer handles."),
  ProtocolCoverageEntry(event: "river_seat_v1.wl_seat", state: pcsLoggedIgnored, note: "Logged only; River seat proxy is used internally."),
  ProtocolCoverageEntry(event: "river_seat_v1.pointer_enter", state: pcsLoggedIgnored, note: "Logged only; focus follows window interaction."),
  ProtocolCoverageEntry(event: "river_seat_v1.pointer_leave", state: pcsLoggedIgnored, note: "Logged only."),
  ProtocolCoverageEntry(event: "river_seat_v1.window_interaction", state: pcsImplemented, note: "Updates focused window."),
  ProtocolCoverageEntry(event: "river_seat_v1.shell_surface_interaction", state: pcsLoggedIgnored, note: "Logged only; layer focus events drive focus suppression."),
  ProtocolCoverageEntry(event: "river_seat_v1.op_delta", state: pcsImplemented, note: "Updates active pointer move/resize operation."),
  ProtocolCoverageEntry(event: "river_seat_v1.op_release", state: pcsImplemented, note: "Ends active pointer operation."),
  ProtocolCoverageEntry(event: "river_seat_v1.pointer_position", state: pcsLoggedIgnored, note: "Logged only; no pointer-warp policy yet."),
  ProtocolCoverageEntry(event: "river_pointer_binding_v1.pressed", state: pcsImplemented, note: "Maps default pointer bindings to move/resize."),
  ProtocolCoverageEntry(event: "river_pointer_binding_v1.released", state: pcsLoggedIgnored, note: "Release is not needed for current binding behavior."),
  ProtocolCoverageEntry(event: "river_layer_shell_output_v1.non_exclusive_area", state: pcsImplemented, note: "Updates usable output area."),
  ProtocolCoverageEntry(event: "river_layer_shell_seat_v1.focus_exclusive", state: pcsImplemented, note: "Suppresses normal window focus while exclusive layer focus is active."),
  ProtocolCoverageEntry(event: "river_layer_shell_seat_v1.focus_non_exclusive", state: pcsImplemented, note: "Restores normal window focus management."),
  ProtocolCoverageEntry(event: "river_layer_shell_seat_v1.focus_none", state: pcsImplemented, note: "Requests remanage after layer focus clears."),
  ProtocolCoverageEntry(event: "river_xkb_binding_v1.pressed", state: pcsImplemented, note: "Maps default key bindings to Triad commands."),
  ProtocolCoverageEntry(event: "river_xkb_binding_v1.released", state: pcsLoggedIgnored, note: "Key releases are not needed for current commands."),
  ProtocolCoverageEntry(event: "river_xkb_binding_v1.stop_repeat", state: pcsLoggedIgnored, note: "Repeating commands are not modeled yet.")
]

proc coverageFor*(event: string): ProtocolCoverageEntry =
  for entry in RiverProtocolCoverage:
    if entry.event == event:
      return entry
  ProtocolCoverageEntry(event: event, state: pcsUnsupported, note: "")

proc hasCoverage*(event: string): bool =
  for entry in RiverProtocolCoverage:
    if entry.event == event:
      return true
  false
