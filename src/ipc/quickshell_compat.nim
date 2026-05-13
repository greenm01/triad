import std/[os, posix, strtabs, strutils]
import shell_overlay, socket
import ../core/xdg
import ../types/runtime_values

type
  QuickshellReloadAction* {.pure.} = enum
    Noop
    SpawnOnly
    AuthoritativeStop
    AuthoritativeRestart

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

proc quickshellLaunchArgs*(config: QuickshellConfig): seq[string] =
  if config.theme.strip().len == 0:
    return @[]
  result = @["-c", config.theme]
  for arg in config.args:
    result.add(arg)

proc quickshellKillArgs*(config: QuickshellConfig): seq[string] =
  if not config.enabled or config.theme.strip().len == 0:
    return @[]
  @["kill", "-c", config.theme, "--any-display"]

proc sameQuickshellConfig*(a, b: QuickshellConfig): bool =
  a.enabled == b.enabled and a.command == b.command and a.theme == b.theme and
    a.args == b.args

proc quickshellStartupAction*(config: QuickshellConfig): QuickshellReloadAction =
  if config.enabled and config.theme.strip().len > 0:
    QuickshellReloadAction.SpawnOnly
  else:
    QuickshellReloadAction.Noop

proc quickshellConfigReloadAction*(
    previous, current: QuickshellConfig
): QuickshellReloadAction =
  if sameQuickshellConfig(previous, current):
    return QuickshellReloadAction.Noop
  if current.enabled and current.theme.strip().len > 0:
    QuickshellReloadAction.AuthoritativeRestart
  else:
    QuickshellReloadAction.AuthoritativeStop

proc defaultNiriCompatSocketPath*(): string =
  runtimeDir() / "triad-niri.sock"

proc chooseNiriCompatSocketPath*(triadSocketPath: string): string =
  let requested = getEnv("NIRI_SOCKET", "")
  if requested.len > 0 and requested != triadSocketPath and not unixPathExists(
    requested
  ):
    return requested
  defaultNiriCompatSocketPath()

proc copyCurrentEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value

proc readIniValue(path, sectionName, keyName: string): string =
  if not fileExists(path):
    return ""

  var inSection = sectionName.len == 0
  for rawLine in lines(path):
    let line = rawLine.strip()
    if line.len == 0 or line[0] == '#' or line[0] == ';':
      continue
    if line[0] == '[' and line[^1] == ']':
      inSection = line[1 ..< line.len - 1].strip().cmpIgnoreCase(sectionName) == 0
      continue
    if not inSection:
      continue

    let sep = line.find('=')
    if sep < 0:
      continue
    if line[0 ..< sep].strip().cmpIgnoreCase(keyName) == 0:
      return line[sep + 1 .. ^1].strip().strip(chars = {'"'})

  ""

proc detectIconTheme(): string =
  result = readIniValue(
    getHomeDir() / ".config" / "gtk-3.0" / "settings.ini",
    "Settings",
    "gtk-icon-theme-name",
  )
  if result.len > 0:
    return

  let gtk2 = getHomeDir() / ".gtkrc-2.0"
  if fileExists(gtk2):
    for rawLine in lines(gtk2):
      let line = rawLine.strip()
      if line.len == 0 or line[0] == '#':
        continue
      let sep = line.find('=')
      if sep < 0:
        continue
      if line[0 ..< sep].strip().cmpIgnoreCase("gtk-icon-theme-name") == 0:
        result = line[sep + 1 .. ^1].strip().strip(chars = {'"'})
        return

  result = readIniValue(
    getHomeDir() / ".config" / "qt6ct" / "qt6ct.conf", "Appearance", "icon_theme"
  )
  if result.len > 0:
    return
  result = readIniValue(
    getHomeDir() / ".config" / "qt5ct" / "qt5ct.conf", "Appearance", "icon_theme"
  )

proc chooseQtPlatformTheme(current: string): string =
  let normalized = current.strip().toLowerAscii()
  if normalized.len > 0 and normalized != "qt5ct":
    return current

  if findExe("qt6ct").len > 0:
    return "qt6ct"
  if fileExists("/usr/lib/qt6/plugins/platformthemes/libqgtk3.so"):
    return "gtk3"
  current

proc addUniqueDataDir(dirs: var seq[string], path: string) =
  let trimmed = path.strip()
  if trimmed.len == 0:
    return
  for existing in dirs:
    if normalizedPath(existing) == normalizedPath(trimmed):
      return
  dirs.add(trimmed)

proc xdgDataDirsWithOverlay(overlaySharePath: string): string =
  var dirs: seq[string] = @[]
  dirs.addUniqueDataDir(overlaySharePath)
  for dir in xdgDataDirs(includeHome = false):
    dirs.addUniqueDataDir(dir)
  dirs.join($PathSep)

proc appendWarning(existing, warning: string): string =
  if warning.len == 0:
    return existing
  if existing.len == 0:
    return warning
  existing & "; " & warning

proc installNiriShim(
    compatBinPath, triadNiriPath: string
): tuple[ok: bool, warning: string] =
  if triadNiriPath.len == 0:
    return
      (false, "triad_niri was not found; command-side Niri compatibility is disabled")

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
    setFilePermissions(
      shimPath,
      {
        fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
        fpOthersExec,
      },
    )
    return (true, "")
  except CatchableError as e:
    (false, "failed to install niri shim: " & e.msg)

proc prepareQuickshellCompatEnv*(
    niriSocketPath: string,
    runtimeDir = runtimeDir(),
    triadNiriPath = findTriadNiri(),
    triadSocketPath = "",
): QuickshellCompatEnv =
  result.env = copyCurrentEnv()
  result.niriSocketPath = niriSocketPath
  result.compatBinPath = runtimeDir / "triad-compat-bin"
  result.niriShimPath = result.compatBinPath / "niri"
  result.triadNiriPath = triadNiriPath

  result.env["NIRI_SOCKET"] = niriSocketPath
  result.env["TRIAD_SOCKET"] =
    if triadSocketPath.len > 0:
      triadSocketPath
    else:
      runtimeDir / "triad.sock"
  result.env["XDG_CURRENT_DESKTOP"] = "triad"

  let iconTheme = result.env.getOrDefault("QS_ICON_THEME", "").strip()
  if iconTheme.len == 0:
    let detected = detectIconTheme()
    if detected.len > 0:
      result.env["QS_ICON_THEME"] = detected

  let platformTheme =
    chooseQtPlatformTheme(result.env.getOrDefault("QT_QPA_PLATFORMTHEME", ""))
  if platformTheme.len > 0:
    result.env["QT_QPA_PLATFORMTHEME"] = platformTheme

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
    result.env["XDG_DATA_DIRS"] = xdgDataDirsWithOverlay(result.xdgSharePath)
