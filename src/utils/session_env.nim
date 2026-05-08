import os, strutils

proc waylandSessionProblem*(runtimeDir, waylandDisplay: string): string =
  if runtimeDir.strip().len == 0:
    return "XDG_RUNTIME_DIR is not set"
  if waylandDisplay.strip().len == 0:
    return "WAYLAND_DISPLAY is not set"
  ""

proc currentWaylandSessionProblem*(): string =
  waylandSessionProblem(
    getEnv("XDG_RUNTIME_DIR", ""),
    getEnv("WAYLAND_DISPLAY", "")
  )
