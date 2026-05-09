import os, osproc, strutils, tables
import ../core/app_identity
import ../core/xdg

type
  ShellOverlayResult* = object
    rootPath*: string
    sharePath*: string
    ok*: bool
    warning*: string

const GenericTerminalSvg = """<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <rect x="6" y="10" width="52" height="44" rx="7" fill="#1f2933"/>
  <rect x="9" y="13" width="46" height="38" rx="5" fill="#111827"/>
  <path d="M18 25l8 7-8 7" fill="none" stroke="#8bd5ff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M31 40h15" fill="none" stroke="#d9e2ec" stroke-width="5" stroke-linecap="round"/>
</svg>
"""

proc defaultRuntimeDir(): string =
  getEnv("XDG_RUNTIME_DIR", "/tmp")

func canonicalDesktopId(id: string): string =
  id.strip().toLowerAscii()

func validIconAliasName(iconName: string): bool =
  let name = iconName.strip()
  if name.len == 0 or name.startsWith(DirSep):
    return false
  if name.contains(DirSep):
    return false
  when defined(windows):
    if name.contains(AltSep):
      return false
  true

proc iconCandidates(shareDir, iconName: string): seq[string] =
  let names =
    if iconName.toLowerAscii() == iconName:
      @[iconName]
    else:
      @[iconName, iconName.toLowerAscii()]

  for name in names:
    for size in ["48x48", "64x64", "32x32", "128x128", "256x256", "512x512"]:
      result.add(shareDir / "icons" / "hicolor" / size / "apps" / (name & ".png"))
    result.add(shareDir / "icons" / "hicolor" / "scalable" / "apps" / (name & ".svg"))
    result.add(shareDir / "pixmaps" / (name & ".png"))
    result.add(shareDir / "pixmaps" / (name & ".svg"))

proc findIconSource(iconNames: openArray[string]): string =
  for iconName in iconNames:
    if iconName.startsWith(DirSep) and fileExists(iconName):
      return iconName

  for shareDir in xdgDataDirs():
    for iconName in iconNames:
      if iconName.len == 0 or iconName.startsWith(DirSep):
        continue
      for candidate in iconCandidates(shareDir, iconName):
        if fileExists(candidate):
          return candidate
  ""

proc replaceWithCopy(sourcePath, destPath: string) =
  if fileExists(destPath) or symlinkExists(destPath):
    removeFile(destPath)
  copyFile(sourcePath, destPath)

proc renderSvgToPng(sourcePath, destPath: string): bool =
  let rsvg = findExe("rsvg-convert")
  if rsvg.len == 0:
    return false

  let process = startProcess(
    rsvg,
    args = @["-w", "48", "-h", "48", "-o", destPath, sourcePath],
    options = {poUsePath}
  )
  let code = process.waitForExit()
  process.close()

  if code != 0:
    if fileExists(destPath) or symlinkExists(destPath):
      removeFile(destPath)
    return false

  fileExists(destPath)

proc writeResolvedIconAlias(rootPath, aliasName: string; iconNames: openArray[
    string]; fallbackSvg = ""): bool =
  if not aliasName.validIconAliasName:
    return false

  let source = findIconSource(iconNames)
  if source.len > 0:
    let ext = source.splitFile().ext.toLowerAscii()
    if ext == ".png":
      let destDir = rootPath / "share" / "icons" / "hicolor" / "48x48" / "apps"
      createDir(destDir)
      replaceWithCopy(source, destDir / (aliasName & ".png"))
      return true
    if ext == ".svg":
      let pngDir = rootPath / "share" / "icons" / "hicolor" / "48x48" / "apps"
      createDir(pngDir)
      if renderSvgToPng(source, pngDir / (aliasName & ".png")):
        return true

      let destDir = rootPath / "share" / "icons" / "hicolor" / "scalable" / "apps"
      createDir(destDir)
      replaceWithCopy(source, destDir / (aliasName & ".svg"))
      return true

  if fallbackSvg.len == 0:
    return false

  let destDir = rootPath / "share" / "icons" / "hicolor" / "scalable" / "apps"
  createDir(destDir)
  writeFile(destDir / (aliasName & ".svg"), fallbackSvg)
  true

proc writeTerminalIconAlias(rootPath: string; entry: DesktopEntry) =
  discard writeResolvedIconAlias(
    rootPath,
    entry.shellOverlayIconName(),
    [
      entry.icon,
      entry.id.stripDesktopSuffix(),
      entry.id.stripDesktopSuffix().toLowerAscii()
    ],
    GenericTerminalSvg
  )

proc writeDesktopIconAlias(rootPath: string; entry: DesktopEntry;
    seen: var Table[string, bool]) =
  let iconName = entry.icon.strip()
  if not iconName.validIconAliasName:
    return
  let key = iconName.toLowerAscii()
  if seen.hasKey(key):
    return
  seen[key] = true

  discard writeResolvedIconAlias(
    rootPath,
    iconName,
    [
      iconName,
      entry.id.stripDesktopSuffix(),
      entry.id.stripDesktopSuffix().toLowerAscii()
    ]
  )

func desktopEntryText(entry: DesktopEntry): string =
  let desktopId = entry.id.canonicalDesktopId()
  let name = if entry.name.len > 0: entry.name else: entry.id.stripDesktopSuffix()
  let execLine = if entry.execLine.len > 0: entry.execLine else: entry.execBase
  let categories =
    if entry.categories.len > 0: entry.categories.join(";") & ";"
    else: "System;TerminalEmulator;"

  "[Desktop Entry]\n" &
  "Type=Application\n" &
  "Name=" & name & "\n" &
  "GenericName=Terminal\n" &
  "Comment=Terminal emulator\n" &
  "Exec=" & execLine & "\n" &
  "Icon=" & entry.shellOverlayIconName() & "\n" &
  "Terminal=false\n" &
  "Categories=" & categories & "\n" &
  "X-Triad-SourceDesktopId=" & desktopId & "\n"

proc writeIconThemeIndex(rootPath: string) =
  let themeDir = rootPath / "share" / "icons" / "hicolor"
  createDir(themeDir)
  writeFile(themeDir / "index.theme", """
[Icon Theme]
Name=Triad Shell Compatibility
Comment=Runtime icon aliases generated by Triad
Directories=scalable/apps,48x48/apps

[scalable/apps]
Size=48
MinSize=16
MaxSize=256
Type=Scalable
Context=Applications

[48x48/apps]
Size=48
Type=Fixed
Context=Applications
""")

proc terminalEntries(index: AppIdentityIndex): seq[DesktopEntry] =
  var seen = initTable[string, bool]()
  for entry in index.desktopEntries:
    if not entry.isTerminalEntry:
      continue
    let id = entry.id.canonicalDesktopId()
    if id.len == 0 or seen.hasKey(id):
      continue
    seen[id] = true
    result.add(entry)

proc installShellOverlay*(
    runtimeDir = defaultRuntimeDir();
    index = defaultAppIdentityIndex()
  ): ShellOverlayResult =
  result.rootPath = runtimeDir / "triad-shell-compat"
  result.sharePath = result.rootPath / "share"

  try:
    if dirExists(result.rootPath):
      removeDir(result.rootPath)

    let applicationsDir = result.sharePath / "applications"
    createDir(applicationsDir)
    writeIconThemeIndex(result.rootPath)

    var seenDesktopIcons = initTable[string, bool]()
    for entry in index.desktopEntries:
      if entry.sourcePath.startsWith(result.sharePath):
        continue
      writeDesktopIconAlias(result.rootPath, entry, seenDesktopIcons)

    for entry in terminalEntries(index):
      if entry.sourcePath.startsWith(result.sharePath):
        continue
      writeFile(applicationsDir / entry.shellOverlayDesktopId(),
          desktopEntryText(entry))
      writeTerminalIconAlias(result.rootPath, entry)

    result.ok = true
  except CatchableError as e:
    result.ok = false
    result.warning = "failed to install shell compatibility overlay: " & e.msg
