import std/[os, strutils, tables]

proc addUnique(result: var seq[string]; seen: var Table[string, bool];
    path: string) =
  let trimmed = path.strip()
  if trimmed.len == 0:
    return

  let key = normalizedPath(trimmed)
  if seen.hasKey(key):
    return

  seen[key] = true
  result.add(trimmed)

proc xdgDataDirs*(includeHome = true): seq[string] =
  var seen = initTable[string, bool]()

  if includeHome:
    let dataHome = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")
    result.addUnique(seen, dataHome)

  let dataDirs = getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
  for dir in dataDirs.split(PathSep):
    result.addUnique(seen, dir)

  let flatpakUser = getHomeDir() / ".local" / "share" / "flatpak" / "exports" / "share"
  if dirExists(flatpakUser):
    result.addUnique(seen, flatpakUser)

  let flatpakSystem = "/var/lib/flatpak/exports/share"
  if dirExists(flatpakSystem):
    result.addUnique(seen, flatpakSystem)

proc xdgApplicationsDirs*(): seq[string] =
  for dir in xdgDataDirs():
    result.add(dir / "applications")
