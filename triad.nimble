# Package

version       = "0.1.0"
author        = "Mason Green"
description   = "Dynamic window management client for River"
license       = "MIT"
srcDir        = "src"
bin           = @["triad", "triad_niri"]


# Dependencies

requires "nim >= 2.2.10"
requires "nimkdl >= 2.1.0"
requires "https://github.com/panno8M/wayland-nim == 0.1.0"
requires "https://github.com/Nimaoth/fsnotify >= 0.1.6"
requires "chronicles >= 0.10.3"

task tidy, "Remove local Nim build outputs and project cache artifacts":
  for path in [
    "triad",
    "triad_niri",
    "src/config/parser",
    "src/triad",
    "src/triad_niri",
    "tests/tcompat",
    "tests/tconfig",
    "tests/tcore",
    "tests/thardening",
    "tests/tlayouts",
    "tests/tlogging",
    "tests/tprotocol",
    "tests/tstress",
    "triad-live-smoke.events",
    "triad-live-smoke.log",
    "triad-live-smoke.out"
  ]:
    if fileExists(path):
      rmFile(path)

  for path in [
    ".nimcache",
    "nimcache",
    "src/.nimcache",
    "src/nimcache",
    "tests/.nimcache",
    "tests/nimcache"
  ]:
    if dirExists(path):
      rmDir(path)

task verify, "Run tests, build, tidy, and binary hygiene checks":
  exec "sh tools/preflight.sh"
