import std/[json, options, osproc, times]
import ../state/engine
import ../utils/[behavior_log, process_tree]
import state

const
  SpawnPlacementTtlMs = 15_000'i64
  SpawnPlacementManageCycles = 4

proc unixMs(): int64 =
  int64(epochTime() * 1000.0)

proc spawnPlacementSlot(model: Model, outputId: OutputId): uint32 =
  if outputId != NullOutputId and model.hasOutput(outputId):
    let tagId = model.outputActiveTag(outputId)
    let tagOpt = model.tagData(tagId)
    if tagOpt.isSome:
      return tagOpt.get().slot
  let activeTagOpt = model.tagData(model.activeTag)
  if activeTagOpt.isSome:
    return activeTagOpt.get().slot
  model.activeSlot

proc activeSpawnPlacementContext(model: Model): tuple[outputId: uint32, slot: uint32] =
  var outputId =
    if model.activeOutput != NullOutputId and model.hasOutput(model.activeOutput):
      model.activeOutput
    elif model.primaryOutput != NullOutputId and model.hasOutput(model.primaryOutput):
      model.primaryOutput
    else:
      NullOutputId
  var slot = model.spawnPlacementSlot(outputId)
  if slot == 0:
    slot = 1'u32
  (uint32(outputId), slot)

proc rememberSpawnPlacementForPid*(
    daemon: var TriadDaemon,
    pid: int32,
    outputId: uint32,
    slot: uint32,
    outputName: string,
    command = "",
) =
  if pid <= 0:
    return
  if slot == 0:
    return
  daemon.pendingSpawnPlacements.add(
    SpawnPlacementContext(
      pid: pid,
      outputId: outputId,
      slot: slot,
      createdMs: unixMs(),
      remainingManageCycles: SpawnPlacementManageCycles,
    )
  )
  writeBehaviorEvent(
    "spawn_placement_context_recorded",
    %*{
      "pid": pid,
      "command": command,
      "output": outputName,
      "slot": slot,
      "pending_contexts": daemon.pendingSpawnPlacements.len,
    },
  )

proc rememberSpawnPlacementForPid*(
    daemon: var TriadDaemon, pid: int32, model: Model, command = ""
) =
  let context = model.activeSpawnPlacementContext()
  daemon.rememberSpawnPlacementForPid(
    pid,
    context.outputId,
    context.slot,
    model.shellOutputName(OutputId(context.outputId)),
    command,
  )

proc rememberSpawnPlacement*(
    daemon: var TriadDaemon, process: Process, model: Model, command = ""
) =
  if process == nil:
    return
  daemon.rememberSpawnPlacementForPid(int32(process.processID), model, command)

proc expireSpawnPlacementContexts*(daemon: var TriadDaemon) =
  let now = unixMs()
  var i = 0
  while i < daemon.pendingSpawnPlacements.len:
    let context = daemon.pendingSpawnPlacements[i]
    if context.remainingManageCycles <= 0 or
        now - context.createdMs > SpawnPlacementTtlMs:
      daemon.pendingSpawnPlacements.delete(i)
    else:
      inc i

proc ageSpawnPlacementContexts*(daemon: var TriadDaemon) =
  for context in daemon.pendingSpawnPlacements.mitems:
    dec context.remainingManageCycles
  daemon.expireSpawnPlacementContexts()

proc matchSpawnPlacementIndex(
    daemon: TriadDaemon, pid: int32, parentPid: ParentPidReader
): int =
  result = -1
  if pid <= 0:
    return
  for i, context in daemon.pendingSpawnPlacements:
    if context.pid == pid:
      return i
    if result < 0 and isDescendantProcess(context.pid, pid, parentPid):
      result = i

proc consumeSpawnPlacementForPid*(
    daemon: var TriadDaemon, pid: int32, parentPid: ParentPidReader = parentPidFromProc
): SpawnPlacementContext =
  daemon.expireSpawnPlacementContexts()
  let index = daemon.matchSpawnPlacementIndex(pid, parentPid)
  if index < 0:
    return
  result = daemon.pendingSpawnPlacements[index]
  daemon.pendingSpawnPlacements.delete(index)
  writeBehaviorEvent(
    "spawn_placement_context_consumed",
    %*{
      "spawn_pid": result.pid,
      "window_pid": pid,
      "output_id": result.outputId,
      "slot": result.slot,
      "pending_contexts": daemon.pendingSpawnPlacements.len,
    },
  )
