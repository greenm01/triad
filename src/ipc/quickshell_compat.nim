import os, posix, strtabs, strutils
import shell_overlay
import socket

type
  QuickshellCompatEnv* = object
    env*: StringTableRef
    niriSocketPath*: string
    compatBinPath*: string
    xdgOverlayPath*: string
    xdgSharePath*: string
    niriShimPath*: string
    triadNiriPath*: string
    shimReady*: bool
    overlayReady*: bool
    warning*: string

proc shellQuote(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc findTriadNiri*(triadExe = getAppFilename()): string =
  let exeDir = triadExe.splitFile().dir
  if exeDir.len > 0:
    let sibling = exeDir / "triad_niri"
    if fileExists(sibling):
      return sibling

  let pathExe = findExe("triad_niri")
  if pathExe.len > 0:
    return pathExe

  ""

proc defaultNiriCompatSocketPath*(): string =
  getRuntimeDir() / "triad-niri.sock"

proc chooseNiriCompatSocketPath*(triadSocketPath: string): string =
  let requested = getEnv("NIRI_SOCKET", "")
  if requested.len > 0 and requested != triadSocketPath and not unixPathExists(requested):
    return requested
  defaultNiriCompatSocketPath()

proc copyCurrentEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value

proc appendWarning(existing, warning: string): string =
  if warning.len == 0:
    return existing
  if existing.len == 0:
    return warning
  existing & "; " & warning

proc installNiriShim(compatBinPath, triadNiriPath: string): tuple[ok: bool, warning: string] =
  if triadNiriPath.len == 0:
    return (false, "triad_niri was not found; command-side Niri compatibility is disabled")

  try:
    createDir(compatBinPath)
  except CatchableError as e:
    return (false, "failed to create Quickshell compatibility bin: " & e.msg)

  let shimPath = compatBinPath / "niri"
  if unixPathExists(shimPath):
    if dirExists(shimPath):
      return (false, "compatibility shim path is a directory: " & shimPath)
    try:
      removeFile(shimPath)
    except CatchableError as e:
      return (false, "failed to replace existing niri shim: " & e.msg)

  if symlink(triadNiriPath.cstring, shimPath.cstring) == 0:
    return (true, "")

  try:
    writeFile(shimPath, "#!/bin/sh\nexec " & shellQuote(triadNiriPath) & " \"$@\"\n")
    setFilePermissions(shimPath, {
      fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec,
      fpOthersRead, fpOthersExec
    })
    return (true, "")
  except CatchableError as e:
    (false, "failed to install niri shim: " & e.msg)

proc prepareQuickshellCompatEnv*(
    niriSocketPath: string;
    runtimeDir = getRuntimeDir();
    triadNiriPath = findTriadNiri()
  ): QuickshellCompatEnv =
  result.env = copyCurrentEnv()
  result.niriSocketPath = niriSocketPath
  result.compatBinPath = runtimeDir / "triad-compat-bin"
  result.niriShimPath = result.compatBinPath / "niri"
  result.triadNiriPath = triadNiriPath

  result.env["NIRI_SOCKET"] = niriSocketPath
  result.env["XDG_CURRENT_DESKTOP"] = "triad"

  let installed = installNiriShim(result.compatBinPath, triadNiriPath)
  result.shimReady = installed.ok
  result.warning = installed.warning

  let overlay = installShellOverlay(runtimeDir)
  result.overlayReady = overlay.ok
  result.xdgOverlayPath = overlay.rootPath
  result.xdgSharePath = overlay.sharePath
  result.warning = result.warning.appendWarning(overlay.warning)

  if result.shimReady:
    let currentPath = result.env.getOrDefault("PATH", "")
    if currentPath.len > 0:
      result.env["PATH"] = result.compatBinPath & ":" & currentPath
    else:
      result.env["PATH"] = result.compatBinPath

  if result.overlayReady:
    let currentDataDirs = result.env.getOrDefault("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
    if currentDataDirs.len > 0:
      result.env["XDG_DATA_DIRS"] = result.xdgSharePath & PathSep & currentDataDirs
    else:
      result.env["XDG_DATA_DIRS"] = result.xdgSharePath
