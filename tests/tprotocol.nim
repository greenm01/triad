import std/[tables, unittest]
import ../src/protocols/coverage

suite "River protocol coverage":
  test "active listener events have explicit coverage entries":
    for event in ActiveRiverListenerEvents:
      check hasCoverage(event)
      check coverageFor(event).note.len > 0

  test "known generated client requests have explicit coverage entries":
    for request in KnownRiverClientRequests:
      check hasCoverage(request)
      check coverageFor(request).note.len > 0

  test "coverage entries are unique":
    var seen = initTable[string, bool]()
    for entry in RiverProtocolCoverage:
      check not seen.hasKey(entry.event)
      seen[entry.event] = true

  test "client-facing request coverage matches advertised support":
    check coverageFor("river_window_v1.show_window_menu_requested").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.maximize_requested").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.minimize_requested").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.get_decoration_above").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_xkb_bindings_seat_v1.ensure_next_key_eaten").state ==
      ProtocolCoverageState.pcsImplemented

  test "strict protocol coverage has no request or active event gaps":
    for request in KnownRiverClientRequests:
      check coverageFor(request).state == ProtocolCoverageState.pcsImplemented
    for event in ActiveRiverListenerEvents:
      check coverageFor(event).state == ProtocolCoverageState.pcsImplemented

  test "implemented hardening paths are tracked":
    check coverageFor("river_window_v1.app_id").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.title").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.dimensions").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.dimensions_hint").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.fullscreen_requested").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_output_v1.removed").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.inform_resize_start").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.set_content_clip_box").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_seat_v1.focus_shell_surface").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_seat_v1.pointer_warp").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_xkb_binding_v1.set_layout_override").state ==
      ProtocolCoverageState.pcsImplemented

  test "advertised capabilities have implemented behavior":
    check (TriadAdvertisedCapabilities and RiverCapabilityWindowMenu) == 0'u32
    check coverageFor("river_window_v1.maximize_requested").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.fullscreen_requested").state ==
      ProtocolCoverageState.pcsImplemented
    check coverageFor("river_window_v1.minimize_requested").state ==
      ProtocolCoverageState.pcsImplemented
