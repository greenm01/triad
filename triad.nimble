# Package

version = "0.1.0"
author = "Mason Green"
description = "Dynamic window management client for River"
license = "MIT"
srcDir = "src"
bin = @["triad", "triad_niri"]

# Dependencies

requires "nim >= 2.2.10"
requires "nimkdl >= 2.1.0"
requires "https://github.com/panno8M/wayland-nim == 0.1.0"
requires "https://github.com/Nimaoth/fsnotify >= 0.1.6"
requires "chronicles >= 0.10.3"
requires "pixie >= 5.1.0"

proc runTestSuite(path: string) =
  exec "nimble c -r --hints:off --nimcache:tests/nimcache " & path

proc runCoreSuites() =
  for path in [
    "tests/tcore_smoke.nim", "tests/tcore_navigation_layout.nim",
    "tests/tcore_lifecycle_basic.nim", "tests/tcore_parented_popups.nim",
    "tests/tcore_parented_geometry.nim", "tests/tcore_window_rules_merge.nim",
    "tests/tcore_window_rules_policy.nim", "tests/tcore_window_rules_matchers.nim",
    "tests/tcore_floating_rules.nim", "tests/tcore_window_movement.nim",
    "tests/tcore_restore_identity.nim", "tests/tcore_window_rules_placement.nim",
    "tests/tcore_output_sticky_scratchpad.nim", "tests/tcore_presentation_overview.nim",
    "tests/tcore_overview.nim", "tests/tcore_overview_interactions.nim",
    "tests/tcore_recent_windows.nim", "tests/tcore_shell_snapshot_ipc.nim",
    "tests/tcore_unmanaged_global.nim",
  ]:
    runTestSuite(path)

proc runConfigSuites() =
  for path in [
    "tests/tconfig_loading_reload.nim", "tests/tconfig_parser_defaults.nim",
    "tests/tconfig_window_rules_workspace.nim",
  ]:
    runTestSuite(path)

proc runUnitSuites() =
  for path in [
    "tests/tapp_identity.nim", "tests/tcompat.nim", "tests/tstate.nim",
    "tests/thardening.nim", "tests/tlayouts.nim", "tests/tlogging.nim",
    "tests/tprotocol.nim",
  ]:
    runTestSuite(path)
  runConfigSuites()
  runCoreSuites()

proc runDaemonSuites() =
  for path in ["tests/tstate.nim", "tests/thardening.nim"]:
    runTestSuite(path)

task tidy, "Remove local Nim build outputs and project cache artifacts":
  for path in [
    "triad", "triad_niri", "src/config/parser", "src/triad", "src/triad_niri",
    "tests/tapp_identity", "tests/tcompat", "tests/tconfig_loading_reload",
    "tests/tconfig_parser_defaults", "tests/tconfig_window_rules_workspace",
    "tests/tcore_smoke", "tests/tcore_navigation_layout", "tests/tcore_lifecycle_basic",
    "tests/tcore_parented_popups", "tests/tcore_parented_geometry",
    "tests/tcore_window_rules_merge", "tests/tcore_window_rules_policy",
    "tests/tcore_window_rules_matchers", "tests/tcore_floating_rules",
    "tests/tcore_window_movement", "tests/tcore_restore_identity",
    "tests/tcore_window_rules_placement", "tests/tcore_output_sticky_scratchpad",
    "tests/tcore_presentation_overview", "tests/tcore_overview",
    "tests/tcore_overview_interactions", "tests/tcore_recent_windows",
    "tests/tcore_shell_snapshot_ipc", "tests/tcore_unmanaged_global", "tests/tstate",
    "tests/thardening", "tests/tlayouts", "tests/tlogging", "tests/tprotocol",
    "tests/tstress", "triad-live-smoke.events", "triad-live-smoke.log",
    "triad-live-smoke.out",
  ]:
    if fileExists(path):
      rmFile(path)

  for path in [
    ".nimcache", "nimcache", "src/.nimcache", "src/nimcache", "tests/.nimcache",
    "tests/nimcache",
  ]:
    if dirExists(path):
      rmDir(path)

task verify, "Run tests, build, tidy, and binary hygiene checks":
  exec "sh tools/preflight.sh"

task buildAll, "Build all Triad binaries":
  exec "nimble build"

task testAppIdentity, "Run app identity tests":
  runTestSuite("tests/tapp_identity.nim")

task testCompat, "Run shell compatibility contract tests":
  runTestSuite("tests/tcompat.nim")

task testConfig, "Run configuration parser tests":
  runConfigSuites()

task testCore, "Run core model/update tests":
  runCoreSuites()

task testState, "Run runtime state tests":
  runTestSuite("tests/tstate.nim")

task testDaemon, "Run daemon-facing runtime and hardening tests":
  runDaemonSuites()

task testHardening, "Run crash hardening tests":
  runTestSuite("tests/thardening.nim")

task testLayouts, "Run layout algorithm tests":
  runTestSuite("tests/tlayouts.nim")

task testLogging, "Run runtime logging tests":
  runTestSuite("tests/tlogging.nim")

task testProtocol, "Run River protocol coverage tests":
  runTestSuite("tests/tprotocol.nim")

task testStress, "Run deterministic stress tests":
  runTestSuite("tests/tstress.nim")

task testUnit, "Run all non-stress test suites":
  runUnitSuites()

task testAll, "Run all explicit test suites":
  runUnitSuites()
  runTestSuite("tests/tstress.nim")

task liveReload,
  "Build release binaries, install them, and restart the live Triad manager":
  exec "nimble build -d:release"
  exec "sh tools/live_reload.sh"
