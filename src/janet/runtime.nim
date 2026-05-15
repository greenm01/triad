import std/[options, os, strutils, tables, times]
import chronicles
import ../core/msg
import ../types/[janet_manifest, runtime_values, shell_snapshot]
import command_api, snapshot_api, binding, prelude

type
  ManifestCacheEntry* = object
    path*: string
    modified*: Time
    source*: string
    failed*: bool
    error*: string

  JanetRuntime* = object
    handle*: JanetHandle
    config*: JanetConfig
    manifests*: Table[string, ManifestCacheEntry]

proc initJanetRuntime*(config: JanetConfig): JanetRuntime =
  result.config = config
  result.manifests = initTable[string, ManifestCacheEntry]()
  if config.enabled:
    result.handle = triadJanetNew()

proc close*(runtime: var JanetRuntime) =
  if runtime.handle != nil:
    triadJanetFree(runtime.handle)
    runtime.handle = nil
  runtime.manifests.clear()

proc configure*(runtime: var JanetRuntime, config: JanetConfig) =
  let wasEnabled = runtime.handle != nil
  if wasEnabled and not config.enabled:
    runtime.close()
    runtime.config = config
    return
  runtime.config = config
  runtime.manifests.clear()
  if config.enabled and runtime.handle == nil:
    runtime.handle = triadJanetNew()

proc evalSource*(
    runtime: var JanetRuntime,
    snapshot: ShellSnapshot,
    source: string,
    path = "<janet>",
    currentWindow = none(ShellWindow),
): tuple[ok: bool, messages: seq[Msg], error: string] =
  if runtime.handle == nil:
    return (true, @[], "")

  let snapshotSource = snapshot.janetSnapshotSource(currentWindow) & JanetPreludeSource
  let ok =
    triadJanetEval(
      runtime.handle,
      cstring(snapshotSource),
      cstring(source),
      cstring(path),
      runtime.config.fuelLimit,
    ) == 1
  if not ok:
    return (false, @[], $triadJanetLastError(runtime.handle))

  for index in 0 ..< int(triadJanetActionCount(runtime.handle)):
    let msg = runtime.handle.actionMsg(index)
    if msg.isSome:
      result.messages.add(msg.get())
  result.ok = true

proc validManifestAppId(appId: string): bool =
  appId.len > 0 and appId.find('/') == -1 and appId.find('\\') == -1 and
    appId.find("..") == -1

proc validManifestName(name: string): bool =
  let stripped = name.strip()
  stripped.len > 0 and stripped.find('/') == -1 and stripped.find('\\') == -1 and
    stripped.find("..") == -1

proc expandManifestDir(path: string): string =
  let stripped = path.strip()
  if stripped == "~":
    getHomeDir()
  elif stripped.startsWith("~/"):
    getHomeDir() / stripped[2 ..^ 1]
  else:
    stripped

proc aliasManifestNames(config: JanetConfig, appId: string): seq[string] =
  for alias in config.manifestAliases:
    let manifest = alias.manifest.strip()
    if alias.appId == appId and manifest.validManifestName():
      result.add(manifest)

proc addCandidatePath(paths: var seq[string], path: string) =
  if path notin paths:
    paths.add(path)

proc candidateManifestPaths(runtime: JanetRuntime, appId: string): seq[string] =
  let aliasNames = runtime.config.aliasManifestNames(appId)
  for dir in [runtime.config.manifestDir, runtime.config.systemManifestDir]:
    let expanded = dir.expandManifestDir()
    if expanded.len > 0:
      result.addCandidatePath(expanded / (appId & ".janet"))
      for aliasName in aliasNames:
        result.addCandidatePath(expanded / (aliasName & ".janet"))

proc manifestEntry(
    runtime: var JanetRuntime, appId: string
): Option[ManifestCacheEntry] =
  if not appId.validManifestAppId():
    return none(ManifestCacheEntry)

  for path in runtime.candidateManifestPaths(appId):
    if not fileExists(path):
      continue
    let modified = getLastModificationTime(path)
    if runtime.manifests.hasKey(path):
      let cached = runtime.manifests[path]
      if cached.modified == modified:
        return some(cached)

    var entry = ManifestCacheEntry(path: path, modified: modified)
    try:
      entry.source = readFile(path)
    except CatchableError as e:
      entry.failed = true
      entry.error = e.msg
      warn "Failed to read Janet manifest", path = path, error = e.msg
    runtime.manifests[path] = entry
    return some(entry)

  none(ManifestCacheEntry)

proc evalManifestDetailed*(
    runtime: var JanetRuntime,
    appId: string,
    snapshot: ShellSnapshot,
    currentWindow = none(ShellWindow),
): ManifestEvalResult =
  result.appId = appId
  result.currentWindow = currentWindow
  if runtime.handle == nil:
    result.outcome = ManifestOutcome.Disabled
    return

  if not appId.validManifestAppId():
    result.outcome = ManifestOutcome.InvalidAppId
    return

  result.candidatePaths = runtime.candidateManifestPaths(appId)
  let entry = runtime.manifestEntry(appId)
  if entry.isNone:
    result.outcome = ManifestOutcome.Missing
    return
  result.path = entry.get().path
  if entry.get().failed:
    result.outcome =
      if entry.get().source.len == 0:
        ManifestOutcome.ReadFailed
      else:
        ManifestOutcome.CachedFailed
    result.error = entry.get().error
    return

  let evaluated =
    runtime.evalSource(snapshot, entry.get().source, entry.get().path, currentWindow)
  if not evaluated.ok:
    warn "Janet manifest failed",
      appId = appId, path = entry.get().path, error = evaluated.error
    var failedEntry = entry.get()
    failedEntry.failed = true
    failedEntry.error = evaluated.error
    runtime.manifests[failedEntry.path] = failedEntry
    result.outcome = ManifestOutcome.EvalFailed
    result.error = evaluated.error
    return

  result.outcome = ManifestOutcome.Evaluated
  result.messages = evaluated.messages

proc evalManifest*(
    runtime: var JanetRuntime,
    appId: string,
    snapshot: ShellSnapshot,
    currentWindow = none(ShellWindow),
): seq[Msg] =
  runtime.evalManifestDetailed(appId, snapshot, currentWindow).messages
