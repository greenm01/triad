import os, options, strutils, tables

type
  DesktopEntry* = object
    id*: string
    name*: string
    icon*: string
    execBase*: string
    startupWmClass*: string

  AppIdentityIndex* = object
    entries: seq[DesktopEntry]
    byDesktopId: Table[string, int]
    byExecBase: Table[string, int]
    byStartupWmClass: Table[string, int]

const TerminalAliases = {
  "alacritty": "alacritty.desktop",
  "foot": "foot.desktop",
  "footclient": "foot.desktop",
  "ghostty": "com.mitchellh.ghostty.desktop",
  "kitty": "kitty.desktop",
  "wezterm": "org.wezfurlong.wezterm.desktop"
}.toTable

var defaultIndex: Option[AppIdentityIndex]

func normalizeKey(value: string): string =
  value.strip().toLowerAscii()

func canonicalDesktopId(id: string): string =
  id.normalizeKey()

proc desktopIdFor(path, root: string): string =
  var rel = path
  try:
    rel = relativePath(path, root)
  except OSError:
    rel = extractFilename(path)
  result = rel.replace(DirSep, '-')
  when defined(windows):
    result = result.replace(AltSep, '-')

func baseKey(key: string): string =
  let bracket = key.find('[')
  if bracket >= 0:
    key[0 ..< bracket]
  else:
    key

func stripExecFieldCodes(value: string): string =
  var i = 0
  while i < value.len:
    if value[i] == '%' and i + 1 < value.len:
      i += 2
    else:
      result.add(value[i])
      inc i

func firstExecToken(value: string): string =
  let clean = value.stripExecFieldCodes().strip()
  if clean.len == 0:
    return ""

  var quote: char = '\0'
  var token = ""
  for ch in clean:
    if quote != '\0':
      if ch == quote:
        quote = '\0'
      else:
        token.add(ch)
    elif ch == '\'' or ch == '"':
      quote = ch
    elif ch.isSpaceAscii():
      break
    else:
      token.add(ch)

  extractFilename(token.strip())

proc parseDesktopEntry*(path, root: string): Option[DesktopEntry] =
  if not fileExists(path):
    return none(DesktopEntry)

  var entry = DesktopEntry(id: desktopIdFor(path, root))
  var inDesktopEntry = false
  var hidden = false

  for rawLine in lines(path):
    let line = rawLine.strip()
    if line.len == 0 or line[0] == '#':
      continue

    if line[0] == '[' and line[^1] == ']':
      inDesktopEntry = line == "[Desktop Entry]"
      continue

    if not inDesktopEntry:
      continue

    let sep = line.find('=')
    if sep < 0:
      continue

    let key = line[0 ..< sep].baseKey()
    let value = line[sep + 1 .. ^1].strip()
    case key
    of "Name":
      if entry.name.len == 0:
        entry.name = value
    of "Icon":
      entry.icon = value
    of "Exec":
      entry.execBase = firstExecToken(value)
    of "StartupWMClass":
      entry.startupWmClass = value
    of "Hidden":
      hidden = value.normalizeKey() == "true"
    else:
      discard

  if hidden:
    none(DesktopEntry)
  else:
    some(entry)

proc addIfMissing(table: var Table[string, int]; key: string; idx: int) =
  let normalized = key.normalizeKey()
  if normalized.len > 0 and not table.hasKey(normalized):
    table[normalized] = idx

proc addEntry*(index: var AppIdentityIndex; entry: DesktopEntry) =
  let idx = index.entries.len
  index.entries.add(entry)
  index.byDesktopId.addIfMissing(entry.id, idx)
  if entry.id.endsWith(".desktop"):
    index.byDesktopId.addIfMissing(entry.id[0 ..< entry.id.len - ".desktop".len], idx)
  index.byExecBase.addIfMissing(entry.execBase, idx)
  index.byStartupWmClass.addIfMissing(entry.startupWmClass, idx)

proc buildAppIdentityIndex*(applicationDirs: openArray[string]): AppIdentityIndex =
  for dir in applicationDirs:
    if not dirExists(dir):
      continue
    for path in walkDirRec(dir):
      if path.endsWith(".desktop"):
        let parsed = parseDesktopEntry(path, dir)
        if parsed.isSome:
          result.addEntry(parsed.get())

proc xdgApplicationDirs*(): seq[string] =
  let dataHome = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")
  result.add(dataHome / "applications")

  let dataDirs = getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
  for dir in dataDirs.split(PathSep):
    let trimmed = dir.strip()
    if trimmed.len > 0:
      result.add(trimmed / "applications")

proc defaultAppIdentityIndex*(): AppIdentityIndex =
  if defaultIndex.isNone:
    defaultIndex = some(buildAppIdentityIndex(xdgApplicationDirs()))
  defaultIndex.get()

proc compatAppId*(rawAppId: string; index: AppIdentityIndex): string =
  let raw = rawAppId.strip()
  if raw.len == 0:
    return ""

  let key = raw.normalizeKey()
  if index.byDesktopId.hasKey(key):
    return canonicalDesktopId(index.entries[index.byDesktopId[key]].id)
  if index.byDesktopId.hasKey(key & ".desktop"):
    return canonicalDesktopId(index.entries[index.byDesktopId[key & ".desktop"]].id)
  if index.byStartupWmClass.hasKey(key):
    return canonicalDesktopId(index.entries[index.byStartupWmClass[key]].id)
  if index.byExecBase.hasKey(key):
    return canonicalDesktopId(index.entries[index.byExecBase[key]].id)
  if TerminalAliases.hasKey(key):
    return TerminalAliases[key]
  raw

proc compatAppId*(rawAppId: string): string =
  compatAppId(rawAppId, defaultAppIdentityIndex())
