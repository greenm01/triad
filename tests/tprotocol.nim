import unittest, tables
import ../src/protocols/coverage

suite "River protocol coverage":
  test "active listener events have explicit coverage entries":
    for event in ActiveRiverListenerEvents:
      check hasCoverage(event)
      check coverageFor(event).note.len > 0

  test "coverage entries are unique":
    var seen = initTable[string, bool]()
    for entry in RiverProtocolCoverage:
      check not seen.hasKey(entry.event)
      seen[entry.event] = true

  test "client-facing request coverage matches advertised support":
    check coverageFor("river_window_v1.show_window_menu_requested").state == pcsUnsupported
    check coverageFor("river_window_v1.maximize_requested").state == pcsImplemented
    check coverageFor("river_window_v1.minimize_requested").state == pcsImplemented

  test "implemented hardening paths are tracked":
    check coverageFor("river_window_v1.app_id").state == pcsImplemented
    check coverageFor("river_window_v1.title").state == pcsImplemented
    check coverageFor("river_window_v1.dimensions").state == pcsImplemented
    check coverageFor("river_window_v1.dimensions_hint").state == pcsImplemented
    check coverageFor("river_window_v1.fullscreen_requested").state == pcsImplemented
    check coverageFor("river_output_v1.removed").state == pcsImplemented

  test "advertised capabilities have implemented behavior":
    check (TriadAdvertisedCapabilities and RiverCapabilityWindowMenu) == 0'u32
    check coverageFor("river_window_v1.maximize_requested").state == pcsImplemented
    check coverageFor("river_window_v1.fullscreen_requested").state == pcsImplemented
    check coverageFor("river_window_v1.minimize_requested").state == pcsImplemented
