type
  ProtocolCoverageState* = enum
    pcsImplemented
    pcsLoggedIgnored
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
  TriadAdvertisedCapabilities* =
    RiverCapabilityMaximize or RiverCapabilityFullscreen or RiverCapabilityMinimize

const ActiveRiverListenerEvents* = [
  "river_window_manager_v1.unavailable", "river_window_manager_v1.finished",
  "river_window_manager_v1.manage_start", "river_window_manager_v1.render_start",
  "river_window_manager_v1.session_locked", "river_window_manager_v1.session_unlocked",
  "river_window_manager_v1.window", "river_window_manager_v1.output",
  "river_window_manager_v1.seat", "river_window_v1.closed",
  "river_window_v1.dimensions_hint", "river_window_v1.dimensions",
  "river_window_v1.app_id", "river_window_v1.title", "river_window_v1.parent",
  "river_window_v1.decoration_hint", "river_window_v1.pointer_move_requested",
  "river_window_v1.pointer_resize_requested",
  "river_window_v1.show_window_menu_requested", "river_window_v1.maximize_requested",
  "river_window_v1.unmaximize_requested", "river_window_v1.fullscreen_requested",
  "river_window_v1.exit_fullscreen_requested", "river_window_v1.minimize_requested",
  "river_window_v1.unreliable_pid", "river_window_v1.presentation_hint",
  "river_window_v1.identifier", "river_output_v1.removed", "river_output_v1.wl_output",
  "river_output_v1.position", "river_output_v1.dimensions", "river_seat_v1.removed",
  "river_seat_v1.wl_seat", "river_seat_v1.pointer_enter", "river_seat_v1.pointer_leave",
  "river_seat_v1.window_interaction", "river_seat_v1.shell_surface_interaction",
  "river_seat_v1.op_delta", "river_seat_v1.op_release",
  "river_seat_v1.pointer_position", "river_pointer_binding_v1.pressed",
  "river_pointer_binding_v1.released", "river_layer_shell_output_v1.non_exclusive_area",
  "river_layer_shell_seat_v1.focus_exclusive",
  "river_layer_shell_seat_v1.focus_non_exclusive",
  "river_layer_shell_seat_v1.focus_none", "river_xkb_binding_v1.pressed",
  "river_xkb_binding_v1.released", "river_xkb_binding_v1.stop_repeat",
  "river_xkb_bindings_seat_v1.ate_unbound_key",
  "river_xkb_bindings_seat_v1.modifiers_update", "river_input_manager_v1.finished",
  "river_input_manager_v1.input_device", "river_input_device_v1.removed",
  "river_input_device_v1.type", "river_input_device_v1.name",
  "river_input_device_v1.done", "river_xkb_config_v1.finished",
  "river_xkb_config_v1.xkb_keyboard", "river_xkb_keymap_v1.success",
  "river_xkb_keymap_v1.failure", "river_xkb_keyboard_v1.removed",
  "river_xkb_keyboard_v1.input_device", "river_xkb_keyboard_v1.layout",
  "river_xkb_keyboard_v1.capslock_enabled", "river_xkb_keyboard_v1.capslock_disabled",
  "river_xkb_keyboard_v1.numlock_enabled", "river_xkb_keyboard_v1.numlock_disabled",
  "river_xkb_keyboard_v1.done", "river_libinput_config_v1.finished",
  "river_libinput_config_v1.libinput_device", "river_libinput_device_v1.removed",
  "river_libinput_device_v1.input_device",
  "river_libinput_device_v1.send_events_support",
  "river_libinput_device_v1.tap_support",
  "river_libinput_device_v1.accel_profiles_support",
  "river_libinput_device_v1.natural_scroll_support",
  "river_libinput_device_v1.left_handed_support",
  "river_libinput_device_v1.click_method_support",
  "river_libinput_device_v1.middle_emulation_support",
  "river_libinput_device_v1.scroll_method_support",
  "river_libinput_device_v1.dwt_support", "river_libinput_device_v1.dwtp_support",
  "river_libinput_device_v1.done", "river_libinput_result_v1.success",
  "river_libinput_result_v1.unsupported", "river_libinput_result_v1.invalid",
]

const KnownRiverClientRequests* = [
  "river_window_manager_v1.stop", "river_window_manager_v1.destroy",
  "river_window_manager_v1.manage_finish", "river_window_manager_v1.manage_dirty",
  "river_window_manager_v1.render_finish", "river_window_manager_v1.get_shell_surface",
  "river_window_manager_v1.exit_session", "river_window_v1.destroy",
  "river_window_v1.close", "river_window_v1.get_node",
  "river_window_v1.propose_dimensions", "river_window_v1.hide", "river_window_v1.show",
  "river_window_v1.use_csd", "river_window_v1.use_ssd", "river_window_v1.set_borders",
  "river_window_v1.set_tiled", "river_window_v1.get_decoration_above",
  "river_window_v1.get_decoration_below", "river_window_v1.inform_resize_start",
  "river_window_v1.inform_resize_end", "river_window_v1.set_capabilities",
  "river_window_v1.inform_maximized", "river_window_v1.inform_unmaximized",
  "river_window_v1.inform_fullscreen", "river_window_v1.inform_not_fullscreen",
  "river_window_v1.fullscreen", "river_window_v1.exit_fullscreen",
  "river_window_v1.set_clip_box", "river_window_v1.set_content_clip_box",
  "river_window_v1.set_dimension_bounds", "river_decoration_v1.destroy",
  "river_decoration_v1.set_offset", "river_decoration_v1.sync_next_commit",
  "river_shell_surface_v1.destroy", "river_shell_surface_v1.get_node",
  "river_shell_surface_v1.sync_next_commit", "river_node_v1.destroy",
  "river_node_v1.set_position", "river_node_v1.place_top", "river_node_v1.place_bottom",
  "river_node_v1.place_above", "river_node_v1.place_below", "river_output_v1.destroy",
  "river_output_v1.set_presentation_mode", "river_seat_v1.destroy",
  "river_seat_v1.focus_window", "river_seat_v1.focus_shell_surface",
  "river_seat_v1.clear_focus", "river_seat_v1.op_start_pointer", "river_seat_v1.op_end",
  "river_seat_v1.get_pointer_binding", "river_seat_v1.set_xcursor_theme",
  "river_seat_v1.pointer_warp", "river_pointer_binding_v1.destroy",
  "river_pointer_binding_v1.enable", "river_pointer_binding_v1.disable",
  "river_xkb_bindings_v1.destroy", "river_xkb_bindings_v1.get_xkb_binding",
  "river_xkb_bindings_v1.get_seat", "river_xkb_binding_v1.destroy",
  "river_xkb_binding_v1.set_layout_override", "river_xkb_binding_v1.enable",
  "river_xkb_binding_v1.disable", "river_xkb_bindings_seat_v1.destroy",
  "river_xkb_bindings_seat_v1.ensure_next_key_eaten",
  "river_xkb_bindings_seat_v1.cancel_ensure_next_key_eaten",
  "river_xkb_bindings_seat_v1.modifiers_watch", "river_input_manager_v1.stop",
  "river_input_manager_v1.destroy", "river_input_device_v1.destroy",
  "river_input_device_v1.set_repeat_info", "river_input_device_v1.set_scroll_factor",
  "river_xkb_config_v1.stop", "river_xkb_config_v1.destroy",
  "river_xkb_config_v1.create_keymap", "river_xkb_keymap_v1.destroy",
  "river_xkb_keyboard_v1.destroy", "river_xkb_keyboard_v1.set_keymap",
  "river_xkb_keyboard_v1.capslock_enable", "river_xkb_keyboard_v1.capslock_disable",
  "river_xkb_keyboard_v1.numlock_enable", "river_xkb_keyboard_v1.numlock_disable",
  "river_libinput_config_v1.stop", "river_libinput_config_v1.destroy",
  "river_libinput_device_v1.destroy", "river_libinput_device_v1.set_send_events",
  "river_libinput_device_v1.set_tap", "river_libinput_device_v1.set_tap_button_map",
  "river_libinput_device_v1.set_drag", "river_libinput_device_v1.set_drag_lock",
  "river_libinput_device_v1.set_accel_profile",
  "river_libinput_device_v1.set_accel_speed",
  "river_libinput_device_v1.set_natural_scroll",
  "river_libinput_device_v1.set_left_handed",
  "river_libinput_device_v1.set_click_method",
  "river_libinput_device_v1.set_middle_emulation",
  "river_libinput_device_v1.set_scroll_method",
  "river_libinput_device_v1.set_scroll_button",
  "river_libinput_device_v1.set_scroll_button_lock", "river_libinput_device_v1.set_dwt",
  "river_libinput_device_v1.set_dwtp",
]

const RiverProtocolCoverage* = [
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.stop",
    state: pcsImplemented,
    note: "Exposed through the stop-manager IPC command for graceful manager shutdown.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.destroy",
    state: pcsImplemented,
    note: "Destroyed during cleanup after finish.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.manage_finish",
    state: pcsImplemented,
    note: "Completes each manage phase.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.manage_dirty",
    state: pcsImplemented,
    note: "Requests manage on dirty model state.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.render_finish",
    state: pcsImplemented,
    note: "Completes each render phase.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.get_shell_surface",
    state: pcsImplemented,
    note: "Creates a minimal Triad-owned shell surface and tracks its node/lifecycle.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.exit_session",
    state: pcsImplemented,
    note:
      "Exposed through exit-session IPC behind an explicit allow-exit-session config guard.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.destroy",
    state: pcsImplemented,
    note: "Destroys window proxies during cleanup.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.close",
    state: pcsImplemented,
    note: "Used by close-window commands.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.get_node",
    state: pcsImplemented,
    note: "Tracks render-list nodes for windows.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.propose_dimensions",
    state: pcsImplemented,
    note: "Proposes layout dimensions during manage.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.hide",
    state: pcsImplemented,
    note: "Hides non-visible windows during render.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.show",
    state: pcsImplemented,
    note: "Shows visible windows during render.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.use_csd",
    state: pcsImplemented,
    note: "Used when a decoration hint says the client only supports CSD.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.use_ssd",
    state: pcsImplemented,
    note: "Default decoration policy.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.set_borders",
    state: pcsImplemented,
    note: "Draws focus borders.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.set_tiled",
    state: pcsImplemented,
    note: "Communicates tiled/floating edge state.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.get_decoration_above",
    state: pcsImplemented,
    note: "Creates a minimal per-window above decoration surface.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.get_decoration_below",
    state: pcsImplemented,
    note: "Creates a minimal per-window below decoration surface.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.inform_resize_start",
    state: pcsImplemented,
    note: "Sent for interactive floating resize.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.inform_resize_end",
    state: pcsImplemented,
    note: "Sent when interactive floating resize ends.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.set_capabilities",
    state: pcsImplemented,
    note: "Advertises only capabilities Triad can service.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.inform_maximized",
    state: pcsImplemented,
    note: "Sent when maximized state is enabled.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.inform_unmaximized",
    state: pcsImplemented,
    note: "Sent when maximized state is cleared.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.inform_fullscreen",
    state: pcsImplemented,
    note: "Sent when fullscreen state is enabled.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.inform_not_fullscreen",
    state: pcsImplemented,
    note: "Sent when fullscreen state is cleared.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.fullscreen",
    state: pcsImplemented,
    note: "Moves windows into fullscreen state.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.exit_fullscreen",
    state: pcsImplemented,
    note: "Exits fullscreen state.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.set_clip_box",
    state: pcsImplemented,
    note: "Clips windows to the active screen.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.set_content_clip_box",
    state: pcsImplemented,
    note: "Clips client content alongside window clipping.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.set_dimension_bounds",
    state: pcsImplemented,
    note: "Applies max dimension hints.",
  ),
  ProtocolCoverageEntry(
    event: "river_decoration_v1.destroy",
    state: pcsImplemented,
    note: "Destroys Triad-owned decoration proxies with their windows.",
  ),
  ProtocolCoverageEntry(
    event: "river_decoration_v1.set_offset",
    state: pcsImplemented,
    note: "Sets offsets on Triad-owned decoration surfaces.",
  ),
  ProtocolCoverageEntry(
    event: "river_decoration_v1.sync_next_commit",
    state: pcsImplemented,
    note: "Synchronizes decoration state with wl_surface commits.",
  ),
  ProtocolCoverageEntry(
    event: "river_shell_surface_v1.destroy",
    state: pcsImplemented,
    note: "Destroys Triad-owned shell surface proxies during cleanup.",
  ),
  ProtocolCoverageEntry(
    event: "river_shell_surface_v1.get_node",
    state: pcsImplemented,
    note: "Tracks the node for Triad-owned shell surfaces.",
  ),
  ProtocolCoverageEntry(
    event: "river_shell_surface_v1.sync_next_commit",
    state: pcsImplemented,
    note: "Synchronizes shell-surface state with wl_surface commits.",
  ),
  ProtocolCoverageEntry(
    event: "river_node_v1.destroy",
    state: pcsImplemented,
    note: "Destroys tracked window nodes.",
  ),
  ProtocolCoverageEntry(
    event: "river_node_v1.set_position",
    state: pcsImplemented,
    note: "Positions window nodes during render.",
  ),
  ProtocolCoverageEntry(
    event: "river_node_v1.place_top",
    state: pcsImplemented,
    note: "Raises focused, floating, fullscreen, and scratchpad windows.",
  ),
  ProtocolCoverageEntry(
    event: "river_node_v1.place_bottom",
    state: pcsImplemented,
    note: "Keeps Triad-owned shell surfaces below managed windows.",
  ),
  ProtocolCoverageEntry(
    event: "river_node_v1.place_above",
    state: pcsImplemented,
    note: "Orders tiled windows during render.",
  ),
  ProtocolCoverageEntry(
    event: "river_node_v1.place_below",
    state: pcsImplemented,
    note:
      "Places Triad-owned shell surfaces below the first managed window when available.",
  ),
  ProtocolCoverageEntry(
    event: "river_output_v1.destroy",
    state: pcsImplemented,
    note: "Destroys output proxies after removal.",
  ),
  ProtocolCoverageEntry(
    event: "river_output_v1.set_presentation_mode",
    state: pcsImplemented,
    note: "Applies optional presentation-mode config during render.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.destroy",
    state: pcsImplemented,
    note: "Destroys seat proxies after removal.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.focus_window",
    state: pcsImplemented,
    note: "Focuses managed windows.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.focus_shell_surface",
    state: pcsImplemented,
    note: "Focuses interacted shell surfaces when tracked.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.clear_focus",
    state: pcsImplemented,
    note: "Clears focus for lock and exclusive layer states.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.op_start_pointer",
    state: pcsImplemented,
    note: "Starts interactive pointer operations.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.op_end",
    state: pcsImplemented,
    note: "Ends interactive pointer operations.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.get_pointer_binding",
    state: pcsImplemented,
    note: "Creates configured pointer bindings.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.set_xcursor_theme",
    state: pcsImplemented,
    note: "Applies optional cursor config.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.pointer_warp",
    state: pcsImplemented,
    note: "Exposed through the warp-pointer IPC command.",
  ),
  ProtocolCoverageEntry(
    event: "river_pointer_binding_v1.destroy",
    state: pcsImplemented,
    note: "Destroys configured pointer bindings.",
  ),
  ProtocolCoverageEntry(
    event: "river_pointer_binding_v1.enable",
    state: pcsImplemented,
    note: "Enables configured pointer bindings.",
  ),
  ProtocolCoverageEntry(
    event: "river_pointer_binding_v1.disable",
    state: pcsImplemented,
    note: "Disables pointer bindings before destroying/recreating them.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_bindings_v1.destroy",
    state: pcsImplemented,
    note: "Destroys the XKB bindings global object during River cleanup.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_bindings_v1.get_xkb_binding",
    state: pcsImplemented,
    note: "Creates configured key bindings.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_bindings_v1.get_seat",
    state: pcsImplemented,
    note: "Tracks XKB seat modifier state when protocol v2+ is available.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_binding_v1.destroy",
    state: pcsImplemented,
    note: "Destroys configured key bindings.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_binding_v1.set_layout_override",
    state: pcsImplemented,
    note: "Optional bind layout=<index> config applies XKB layout overrides.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_binding_v1.enable",
    state: pcsImplemented,
    note: "Enables configured key bindings.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_binding_v1.disable",
    state: pcsImplemented,
    note: "Disables XKB bindings before destroying/recreating them.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_bindings_seat_v1.destroy",
    state: pcsImplemented,
    note: "Destroys XKB seat objects on binding teardown.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_bindings_seat_v1.ensure_next_key_eaten",
    state: pcsImplemented,
    note: "Exposed through the eat-next-key IPC command.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_bindings_seat_v1.cancel_ensure_next_key_eaten",
    state: pcsImplemented,
    note: "Exposed through the cancel-eat-next-key IPC command.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_bindings_seat_v1.modifiers_watch",
    state: pcsImplemented,
    note: "Watches active modifiers for shell/future policy.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.unavailable",
    state: pcsImplemented,
    note: "Stops and cleans up River objects.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.finished",
    state: pcsImplemented,
    note: "Stops and cleans up River objects.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.manage_start",
    state: pcsImplemented,
    note: "Creates pending windows and completes manage sequences.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.render_start",
    state: pcsImplemented,
    note: "Applies placement, visibility, clipping, and z order.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.session_locked",
    state: pcsImplemented,
    note: "Tracks lock state and clears normal window focus while locked.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.session_unlocked",
    state: pcsImplemented,
    note: "Restores normal focus policy after unlock.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.window",
    state: pcsImplemented,
    note: "Tracks window and node proxies until manage start.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.output",
    state: pcsImplemented,
    note: "Tracks outputs and layer-shell output handles.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_manager_v1.seat",
    state: pcsImplemented,
    note: "Tracks seats and default bindings.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.closed",
    state: pcsImplemented,
    note: "Destroys model/proxy state.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.dimensions_hint",
    state: pcsImplemented,
    note: "Stores min/max hints and bounds proposals.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.dimensions",
    state: pcsImplemented,
    note: "Acknowledged dimensions are stored for shell and clipping sanity.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.app_id",
    state: pcsImplemented,
    note: "Updates pending and live window metadata.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.title",
    state: pcsImplemented,
    note: "Updates pending and live window metadata.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.parent",
    state: pcsImplemented,
    note: "Stores parent window id.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.decoration_hint",
    state: pcsImplemented,
    note: "Tracked and used to choose CSD when the client only supports CSD.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.pointer_move_requested",
    state: pcsImplemented,
    note: "Starts pointer move for floating windows.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.pointer_resize_requested",
    state: pcsImplemented,
    note: "Starts pointer resize for floating windows.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.show_window_menu_requested",
    state: pcsImplemented,
    note:
      "Spawns the optional configured window menu command; capability is advertised only when configured.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.maximize_requested",
    state: pcsImplemented,
    note: "Tracks maximize state and informs clients.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.unmaximize_requested",
    state: pcsImplemented,
    note: "Clears maximize state and informs clients.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.fullscreen_requested",
    state: pcsImplemented,
    note: "Honors request and requested output when possible.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.exit_fullscreen_requested",
    state: pcsImplemented,
    note: "Exits fullscreen and informs the window.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.minimize_requested",
    state: pcsImplemented,
    note: "Tracks minimized state, hides the window, and recomputes focus.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.unreliable_pid",
    state: pcsImplemented,
    note: "Captured in diagnostics for crash triage.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.presentation_hint",
    state: pcsImplemented,
    note: "Stored for diagnostics; output presentation policy is controlled by config.",
  ),
  ProtocolCoverageEntry(
    event: "river_window_v1.identifier",
    state: pcsImplemented,
    note: "Stored for stable shell/IPC identity.",
  ),
  ProtocolCoverageEntry(
    event: "river_output_v1.removed",
    state: pcsImplemented,
    note: "Removes output and clears affected fullscreen state.",
  ),
  ProtocolCoverageEntry(
    event: "river_output_v1.wl_output",
    state: pcsImplemented,
    note: "Stores wl_output names alongside logical River output ids.",
  ),
  ProtocolCoverageEntry(
    event: "river_output_v1.position",
    state: pcsImplemented,
    note: "Updates output logical position.",
  ),
  ProtocolCoverageEntry(
    event: "river_output_v1.dimensions",
    state: pcsImplemented,
    note: "Updates output logical size.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.removed",
    state: pcsImplemented,
    note: "Destroys seat-related bindings and layer handles.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.wl_seat",
    state: pcsImplemented,
    note: "Stores wl_seat names alongside River seat proxy ids.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.pointer_enter",
    state: pcsImplemented,
    note: "Tracks the window under the pointer per seat.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.pointer_leave",
    state: pcsImplemented,
    note: "Clears per-seat pointer window tracking.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.window_interaction",
    state: pcsImplemented,
    note: "Updates focused window.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.shell_surface_interaction",
    state: pcsImplemented,
    note: "Tracks interacted shell surfaces and can refocus them.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.op_delta",
    state: pcsImplemented,
    note: "Updates active pointer move/resize operation.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.op_release",
    state: pcsImplemented,
    note: "Ends active pointer operation.",
  ),
  ProtocolCoverageEntry(
    event: "river_seat_v1.pointer_position",
    state: pcsImplemented,
    note: "Tracks the last pointer position per seat.",
  ),
  ProtocolCoverageEntry(
    event: "river_pointer_binding_v1.pressed",
    state: pcsImplemented,
    note: "Maps default pointer bindings to move/resize.",
  ),
  ProtocolCoverageEntry(
    event: "river_pointer_binding_v1.released",
    state: pcsImplemented,
    note: "Tracks pressed/released binding state.",
  ),
  ProtocolCoverageEntry(
    event: "river_layer_shell_output_v1.non_exclusive_area",
    state: pcsImplemented,
    note: "Updates usable output area.",
  ),
  ProtocolCoverageEntry(
    event: "river_layer_shell_seat_v1.focus_exclusive",
    state: pcsImplemented,
    note: "Suppresses normal window focus while exclusive layer focus is active.",
  ),
  ProtocolCoverageEntry(
    event: "river_layer_shell_seat_v1.focus_non_exclusive",
    state: pcsImplemented,
    note: "Restores normal window focus management.",
  ),
  ProtocolCoverageEntry(
    event: "river_layer_shell_seat_v1.focus_none",
    state: pcsImplemented,
    note: "Requests remanage after layer focus clears.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_binding_v1.pressed",
    state: pcsImplemented,
    note: "Maps default key bindings to Triad commands.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_binding_v1.released",
    state: pcsImplemented,
    note: "Tracks pressed/released key-binding state.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_binding_v1.stop_repeat",
    state: pcsImplemented,
    note: "Tracks repeat-stop events for protocol completeness.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_bindings_seat_v1.ate_unbound_key",
    state: pcsImplemented,
    note: "Counts eaten unbound keys after eat-next-key requests.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_bindings_seat_v1.modifiers_update",
    state: pcsImplemented,
    note: "Updates active modifier snapshot.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_manager_v1.stop",
    state: pcsImplemented,
    note: "Stops input-device event streams during runtime cleanup.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_manager_v1.destroy",
    state: pcsImplemented,
    note: "Destroys the input manager after its finished event.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_device_v1.destroy",
    state: pcsImplemented,
    note: "Destroys tracked input-device proxies when devices are removed.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_device_v1.set_repeat_info",
    state: pcsImplemented,
    note: "Applies configured keyboard repeat rate and delay.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_device_v1.set_scroll_factor",
    state: pcsImplemented,
    note: "Applies configured pointer scroll factors.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_config_v1.stop",
    state: pcsImplemented,
    note: "Stops XKB config streams during runtime cleanup.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_config_v1.destroy",
    state: pcsImplemented,
    note: "Destroys the XKB config object after its finished event.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_config_v1.create_keymap",
    state: pcsImplemented,
    note: "Creates keymaps from input keyboard XKB config.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keymap_v1.destroy",
    state: pcsImplemented,
    note: "Destroys replaced XKB keymap objects.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.destroy",
    state: pcsImplemented,
    note: "Destroys tracked XKB keyboard proxies when removed.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.set_keymap",
    state: pcsImplemented,
    note: "Applies successfully compiled XKB keymaps to keyboards.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.capslock_enable",
    state: pcsImplemented,
    note: "Applies configured CapsLock enabled state.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.capslock_disable",
    state: pcsImplemented,
    note: "Applies configured CapsLock disabled state.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.numlock_enable",
    state: pcsImplemented,
    note: "Applies configured NumLock enabled state.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.numlock_disable",
    state: pcsImplemented,
    note: "Applies configured NumLock disabled state.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_config_v1.stop",
    state: pcsImplemented,
    note: "Stops libinput config streams during runtime cleanup.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_config_v1.destroy",
    state: pcsImplemented,
    note: "Destroys the libinput config object after its finished event.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.destroy",
    state: pcsImplemented,
    note: "Destroys tracked libinput device proxies when removed.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_send_events",
    state: pcsImplemented,
    note: "Applies pointer off and touchpad disabled-on-external-mouse config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_tap",
    state: pcsImplemented,
    note: "Applies touchpad tap-to-click config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_tap_button_map",
    state: pcsImplemented,
    note: "Applies touchpad tap button mapping.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_drag",
    state: pcsImplemented,
    note: "Applies touchpad tap-and-drag config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_drag_lock",
    state: pcsImplemented,
    note: "Applies touchpad drag-lock config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_accel_profile",
    state: pcsImplemented,
    note: "Applies pointer acceleration profile config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_accel_speed",
    state: pcsImplemented,
    note: "Applies pointer acceleration speed config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_natural_scroll",
    state: pcsImplemented,
    note: "Applies natural-scroll config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_left_handed",
    state: pcsImplemented,
    note: "Applies left-handed pointer config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_click_method",
    state: pcsImplemented,
    note: "Applies touchpad click method config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_middle_emulation",
    state: pcsImplemented,
    note: "Applies middle-button emulation config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_scroll_method",
    state: pcsImplemented,
    note: "Applies pointer scroll method config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_scroll_button",
    state: pcsImplemented,
    note: "Applies pointer scroll button config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_scroll_button_lock",
    state: pcsImplemented,
    note: "Applies pointer scroll button lock config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_dwt",
    state: pcsImplemented,
    note: "Applies touchpad disable-while-typing config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.set_dwtp",
    state: pcsImplemented,
    note: "Applies touchpad disable-while-trackpointing config.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_manager_v1.finished",
    state: pcsImplemented,
    note: "Completes input manager cleanup.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_manager_v1.input_device",
    state: pcsImplemented,
    note: "Tracks input devices for repeat and scroll-factor config.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_device_v1.removed",
    state: pcsImplemented,
    note: "Forgets removed input devices.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_device_v1.type",
    state: pcsImplemented,
    note: "Classifies keyboard and pointer devices.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_device_v1.name",
    state: pcsImplemented,
    note: "Tracks device names for pointer class fallback.",
  ),
  ProtocolCoverageEntry(
    event: "river_input_device_v1.done",
    state: pcsImplemented,
    note: "Applies input config after device metadata is complete.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_config_v1.finished",
    state: pcsImplemented,
    note: "Completes XKB config cleanup.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_config_v1.xkb_keyboard",
    state: pcsImplemented,
    note: "Tracks XKB keyboards for keymap and lock-state config.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keymap_v1.success",
    state: pcsImplemented,
    note: "Applies accepted keymaps to tracked keyboards.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keymap_v1.failure",
    state: pcsImplemented,
    note: "Logs and drops rejected keymaps.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.removed",
    state: pcsImplemented,
    note: "Forgets removed XKB keyboards.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.input_device",
    state: pcsImplemented,
    note: "Links XKB keyboards to input devices.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.layout",
    state: pcsImplemented,
    note: "Ignored for now; layout-switching commands are not implemented.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.capslock_enabled",
    state: pcsImplemented,
    note: "Acknowledges CapsLock state events.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.capslock_disabled",
    state: pcsImplemented,
    note: "Acknowledges CapsLock state events.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.numlock_enabled",
    state: pcsImplemented,
    note: "Acknowledges NumLock state events.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.numlock_disabled",
    state: pcsImplemented,
    note: "Acknowledges NumLock state events.",
  ),
  ProtocolCoverageEntry(
    event: "river_xkb_keyboard_v1.done",
    state: pcsImplemented,
    note: "Applies XKB config after keyboard metadata is complete.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_config_v1.finished",
    state: pcsImplemented,
    note: "Completes libinput config cleanup.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_config_v1.libinput_device",
    state: pcsImplemented,
    note: "Tracks libinput devices for pointer config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.removed",
    state: pcsImplemented,
    note: "Forgets removed libinput devices.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.input_device",
    state: pcsImplemented,
    note: "Links libinput devices to River input devices.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.send_events_support",
    state: pcsImplemented,
    note: "Gates send-events config requests.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.tap_support",
    state: pcsImplemented,
    note: "Gates touchpad tap/drag config requests.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.accel_profiles_support",
    state: pcsImplemented,
    note: "Gates acceleration profile config requests.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.natural_scroll_support",
    state: pcsImplemented,
    note: "Gates natural-scroll config requests.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.left_handed_support",
    state: pcsImplemented,
    note: "Gates left-handed config requests.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.click_method_support",
    state: pcsImplemented,
    note: "Gates touchpad click-method config requests.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.middle_emulation_support",
    state: pcsImplemented,
    note: "Gates middle-emulation config requests.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.scroll_method_support",
    state: pcsImplemented,
    note: "Gates scroll-method config requests.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.dwt_support",
    state: pcsImplemented,
    note: "Gates touchpad disable-while-typing config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.dwtp_support",
    state: pcsImplemented,
    note: "Gates touchpad disable-while-trackpointing config.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_device_v1.done",
    state: pcsImplemented,
    note: "Applies pointer config after libinput metadata is complete.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_result_v1.success",
    state: pcsImplemented,
    note: "Clears successful libinput result tracking.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_result_v1.unsupported",
    state: pcsImplemented,
    note: "Logs unsupported libinput config requests.",
  ),
  ProtocolCoverageEntry(
    event: "river_libinput_result_v1.invalid",
    state: pcsImplemented,
    note: "Logs invalid libinput config requests.",
  ),
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
