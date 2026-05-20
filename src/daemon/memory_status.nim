import std/[deques, json, os, tables, times]
import protocol_surfaces, quickshell_runner, state
import ../janet/runtime as janet_runtime
import ../state/engine
import ../utils/[behavior_log, process_memory]
import ../ipc/socket

const
  MemorySampleIntervalMs = 60_000'i64
  CloseBurstIntervalMs = 5_000'i64
  CloseBurstThreshold = 4
  MemoryTrimCooldownMs = 30_000'i64
  MemoryTrimFreeThreshold = 16 * 1024 * 1024

when defined(linux):
  proc mallocTrim(pad: csize_t): cint {.importc: "malloc_trim", header: "<malloc.h>".}

proc intOrNull(value: int): JsonNode =
  if value < 0:
    newJNull()
  else:
    %value

proc processMemoryJson(status: ProcessMemoryStatus): JsonNode =
  result =
    %*{
      "available": status.available,
      "vm_peak_kib": status.vmPeakKiB.intOrNull(),
      "vm_size_kib": status.vmSizeKiB.intOrNull(),
      "vm_rss_kib": status.vmRssKiB.intOrNull(),
      "rss_anon_kib": status.rssAnonKiB.intOrNull(),
      "rss_file_kib": status.rssFileKiB.intOrNull(),
      "rss_shmem_kib": status.rssShmemKiB.intOrNull(),
      "vm_data_kib": status.vmDataKiB.intOrNull(),
      "vm_stk_kib": status.vmStkKiB.intOrNull(),
      "vm_exe_kib": status.vmExeKiB.intOrNull(),
      "vm_lib_kib": status.vmLibKiB.intOrNull(),
      "vm_pte_kib": status.vmPteKiB.intOrNull(),
      "vm_swap_kib": status.vmSwapKiB.intOrNull(),
    }

proc nimMemoryJson(): JsonNode =
  %*{
    "occupied_bytes": getOccupiedMem(),
    "free_bytes": getFreeMem(),
    "total_bytes": getTotalMem(),
  }

proc modelCountsJson(counts: ModelDiagnosticCounts): JsonNode =
  %*{
    "windows": counts.windows,
    "tags": counts.tags,
    "columns": counts.columns,
    "frames": counts.frames,
    "bsp_nodes": counts.bspNodes,
    "split_nodes": counts.splitNodes,
    "outputs": counts.outputs,
    "groups": counts.groups,
    "window_tags": counts.windowTags,
    "external_window_ids": counts.externalWindowIds,
    "external_output_ids": counts.externalOutputIds,
    "tag_by_slot": counts.tagBySlot,
    "columns_by_tag": counts.columnsByTag,
    "columns_by_tag_items": counts.columnsByTagItems,
    "windows_by_tag": counts.windowsByTag,
    "windows_by_tag_items": counts.windowsByTagItems,
    "windows_by_column": counts.windowsByColumn,
    "windows_by_column_items": counts.windowsByColumnItems,
    "placement_by_tag_window": counts.placementByTagWindow,
    "frame_roots_by_tag": counts.frameRootsByTag,
    "windows_by_frame": counts.windowsByFrame,
    "windows_by_frame_items": counts.windowsByFrameItems,
    "frame_by_tag_window": counts.frameByTagWindow,
    "bsp_roots_by_tag": counts.bspRootsByTag,
    "bsp_node_by_tag_window": counts.bspNodeByTagWindow,
    "split_roots_by_tag": counts.splitRootsByTag,
    "split_node_by_tag_window": counts.splitNodeByTagWindow,
    "output_tags": counts.outputTags,
    "tag_outputs": counts.tagOutputs,
    "tag_home_output_targets": counts.tagHomeOutputTargets,
    "tag_home_output_pinned": counts.tagHomeOutputPinned,
    "output_last_active_slots": counts.outputLastActiveSlots,
    "group_by_window": counts.groupByWindow,
    "scratchpad_windows": counts.scratchpadWindows,
    "named_scratchpads": counts.namedScratchpads,
    "scratchpad_restore_tags": counts.scratchpadRestoreTags,
    "swallowed_by": counts.swallowedBy,
    "swallowing": counts.swallowing,
  }

proc surfaceKindId(kind: ProtocolSurfaceKind): string =
  case kind
  of ProtocolSurfaceKind.PskShell: "shell"
  of ProtocolSurfaceKind.PskHotkeyOverlay: "hotkey_overlay"
  of ProtocolSurfaceKind.PskExitSessionConfirm: "exit_session_confirm"
  of ProtocolSurfaceKind.PskLayoutSwitchToast: "layout_switch_toast"
  of ProtocolSurfaceKind.PskRecentWindows: "recent_windows"
  of ProtocolSurfaceKind.PskRecentWindowsChrome: "recent_windows_chrome"
  of ProtocolSurfaceKind.PskDecorationAbove: "decoration_above"
  of ProtocolSurfaceKind.PskDecorationBelow: "decoration_below"
  of ProtocolSurfaceKind.PskFrameEmpty: "frame_empty"
  of ProtocolSurfaceKind.PskBspPreselection: "bsp_preselection"

proc protocolSurfacesJson(runtime: ProtocolSurfaceRuntime): JsonNode =
  var byKind = newJObject()
  var estimatedBufferBytes = 0'i64
  for _, surf in runtime.surfaces.pairs:
    let kind = surf.kind.surfaceKindId()
    byKind[kind] =
      if byKind.hasKey(kind):
        %(byKind[kind].getInt() + 1)
      else:
        %1
    estimatedBufferBytes +=
      int64(max(0'i32, surf.bufferW)) * int64(max(0'i32, surf.bufferH)) * 4'i64
  %*{
    "surfaces": runtime.surfaces.len,
    "surface_to_owned": runtime.surfaceToOwned.len,
    "window_decoration_above": runtime.windowDecorationAbove.len,
    "window_decoration_below": runtime.windowDecorationBelow.len,
    "frame_empty_surfaces": runtime.frameEmptySurfaces.len,
    "bsp_preselection_surfaces": runtime.bspPreselectionSurfaces.len,
    "estimated_buffer_bytes": estimatedBufferBytes,
    "by_kind": byKind,
  }

proc janetJson(counts: JanetRuntimeDiagnosticCounts): JsonNode =
  %*{
    "enabled": counts.enabled,
    "handle_active": counts.handleActive,
    "configured_layouts": counts.configuredLayouts,
    "cached_scripts": counts.cachedScripts,
    "cached_failed_scripts": counts.cachedFailedScripts,
    "cached_source_bytes": counts.cachedSourceBytes,
    "runtime_action_count": counts.runtimeActionCount,
    "runtime_action_capacity": counts.runtimeActionCapacity,
    "runtime_layout_instruction_count": counts.runtimeLayoutInstructionCount,
    "runtime_layout_instruction_capacity": counts.runtimeLayoutInstructionCapacity,
    "runtime_estimated_c_bytes": counts.runtimeEstimatedCBytes,
    "script_handler_lists": counts.scriptHandlerLists,
    "script_handler_list_capacity": counts.scriptHandlerListCapacity,
    "script_handlers": counts.scriptHandlers,
    "script_handler_capacity": counts.scriptHandlerCapacity,
    "script_layouts": counts.scriptLayouts,
    "script_layout_capacity": counts.scriptLayoutCapacity,
    "script_layout_movements": counts.scriptLayoutMovements,
    "script_layout_movement_capacity": counts.scriptLayoutMovementCapacity,
    "script_waiters": counts.scriptWaiters,
    "script_waiter_capacity": counts.scriptWaiterCapacity,
    "script_estimated_c_bytes": counts.scriptEstimatedCBytes,
    "estimated_c_bytes": counts.runtimeEstimatedCBytes + counts.scriptEstimatedCBytes,
    "janet_gc_heap_bytes": newJNull(),
  }

proc quickshellJson(runner: QuickshellRunner): JsonNode =
  %*{
    "tracked": runner.trackedProcess != nil,
    "tracked_shell": runner.trackedShellName,
    "spawn_pending": runner.spawnPending,
    "recovery_pending": runner.recoveryPending,
    "recovery_attempts": runner.recoveryAttempts,
  }

proc ipcJson(): JsonNode =
  %*{
    "niri_subscribers": subscribers.len,
    "triad_subscribers": triadSubscribers.len,
    "total_subscribers": subscribers.len + triadSubscribers.len,
  }

proc memoryStatusPayload*(daemon: TriadDaemon): JsonNode =
  let nowMs = int64(epochTime() * 1000.0)
  %*{
    "pid": getCurrentProcessId(),
    "uptime_ms": max(0'i64, nowMs - daemon.startUnixMs),
    "dev_mode": devModeEnabled(),
    "behavior_log_enabled": behaviorLogEnabled(),
    "process": currentProcessMemoryStatus().processMemoryJson(),
    "nim": nimMemoryJson(),
    "model_counts": daemon.runtimeState.model.modelDiagnosticCounts().modelCountsJson(),
    "daemon_counts": {
      "msg_queue": len(daemon.msgQueue),
      "pending_manage_effects": daemon.pendingManageEffects.len,
      "desired_placements": daemon.desiredPlacements.len,
      "desired_placement_clips": daemon.desiredPlacementClips.len,
      "desired_placement_order": daemon.desiredPlacementOrder.len,
      "current_frame_tab_bars": daemon.currentFrameTabBars.len,
      "current_frame_empty_chrome": daemon.currentFrameEmptyChrome.len,
      "current_bsp_preselections": daemon.currentBspPreselections.len,
      "last_render_window_states": daemon.lastRenderWindowStates.len,
      "last_render_order": daemon.lastRenderOrder.len,
      "window_pointers": daemon.windowPointers.len,
      "window_nodes": daemon.windowNodes.len,
      "output_pointers": daemon.outputPointers.len,
      "seat_pointers": daemon.seatPointers.len,
      "shell_surface_pointers": daemon.shellSurfacePointers.len,
      "pending_windows": daemon.pendingWindows.len,
      "fire_and_forget_processes": daemon.fireAndForgetProcesses.len,
    },
    "protocol_surfaces": daemon.protocolSurfaceRuntime.protocolSurfacesJson(),
    "janet": daemon.janetRuntime.diagnosticCounts().janetJson(),
    "shell": daemon.quickshellState.quickshellJson(),
    "ipc": ipcJson(),
  }

proc memoryStatusJson*(daemon: TriadDaemon): string =
  let payload = daemon.memoryStatusPayload()
  payload["ok"] = %true
  payload["type"] = %"mem-status"
  $payload

proc writeMemorySample*(daemon: TriadDaemon, reason: string) =
  if not behaviorLogEnabled():
    return
  let payload = daemon.memoryStatusPayload()
  payload["reason"] = %reason
  writeBehaviorEvent("memory_sample", payload)

proc shouldTrimNimHeap(): bool =
  let freeBytes = getFreeMem()
  let totalBytes = getTotalMem()
  freeBytes >= MemoryTrimFreeThreshold and freeBytes * 2 >= totalBytes

proc writeMemoryTrimEvent(
    reason: string,
    beforeProcess: ProcessMemoryStatus,
    beforeOccupied, beforeFree, beforeTotal: int,
    mallocTrimResult: int,
) =
  if not behaviorLogEnabled():
    return
  let afterProcess = currentProcessMemoryStatus()
  writeBehaviorEvent(
    "memory_trim",
    %*{
      "reason": reason,
      "before_process": beforeProcess.processMemoryJson(),
      "after_process": afterProcess.processMemoryJson(),
      "before_nim": {
        "occupied_bytes": beforeOccupied,
        "free_bytes": beforeFree,
        "total_bytes": beforeTotal,
      },
      "after_nim": nimMemoryJson(),
      "malloc_trim_result": mallocTrimResult,
    },
  )

proc trimMemoryAfterPressure*(daemon: var TriadDaemon, reason: string) =
  let nowMs = int64(epochTime() * 1000.0)
  if daemon.lastMemoryTrimMs > 0 and
      nowMs - daemon.lastMemoryTrimMs < MemoryTrimCooldownMs:
    return
  if not shouldTrimNimHeap():
    return

  let beforeProcess = currentProcessMemoryStatus()
  let beforeOccupied = getOccupiedMem()
  let beforeFree = getFreeMem()
  let beforeTotal = getTotalMem()
  GC_fullCollect()
  let trimResult =
    when defined(linux):
      int(mallocTrim(0))
    else:
      -1
  daemon.lastMemoryTrimMs = nowMs
  writeMemoryTrimEvent(
    reason, beforeProcess, beforeOccupied, beforeFree, beforeTotal, trimResult
  )

proc noteWindowDestroyedForMemoryPressure*(daemon: var TriadDaemon) =
  let nowMs = int64(epochTime() * 1000.0)
  if daemon.closeBurstStartMs == 0 or
      nowMs - daemon.closeBurstStartMs > CloseBurstIntervalMs:
    daemon.closeBurstStartMs = nowMs
    daemon.closeBurstDestroyedCount = 1
    return

  inc daemon.closeBurstDestroyedCount
  if daemon.closeBurstDestroyedCount >= CloseBurstThreshold:
    daemon.closeBurstStartMs = nowMs
    daemon.closeBurstDestroyedCount = 0
    daemon.trimMemoryAfterPressure("window_close_burst")

proc maybeWriteMemorySample*(daemon: var TriadDaemon, nowMs: int64) =
  if not behaviorLogEnabled():
    return
  if daemon.lastMemorySampleMs == 0:
    daemon.lastMemorySampleMs = nowMs
    return
  if daemon.lastMemorySampleMs > 0 and
      nowMs - daemon.lastMemorySampleMs < MemorySampleIntervalMs:
    return
  daemon.lastMemorySampleMs = nowMs
  daemon.writeMemorySample("periodic")
