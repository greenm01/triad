import std/[os, sets, tables]
import chronicles
import ../core/layout_mode_codec
import ../core/native_layout_codec
import wayland/native/client
import protocols/river/client as river
import wayland/protocols/wayland/client as wlCore
import wayland/protocols/staging/singlepixelbuffer/v1/client as singlepixel
import ../systems/[hotkey_overlay, recent_windows]
from ../types/core import Rect
from ../types/projection_values import
  ProjectedBspPreselection, ProjectedFrameEmptyChrome, ProjectedFrameTabBar
import ../types/runtime_values
import
  bsp_preselection_render, exit_session_dialog_render, frame_tab_bar_render,
  hotkey_overlay_render, layout_switch_toast_render, overview_overlay_render,
  pixel_buffer, protocol_surfaces, recent_windows_overlay_render, state, wayland_helpers
from std/posix import nil

when defined(linux):
  const MemfdCloseOnExec = 0x0001.cuint

  proc memfd_create(
    name: cstring, flags: cuint
  ): cint {.importc, header: "<sys/mman.h>".}

template currentModel(daemon: TriadDaemon): untyped =
  daemon.runtimeState.model

template surfaceTable(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.surfaces

template ownedShellSurfaceId(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.ownedShellSurfaceId

template hotkeyOverlaySurfaceId(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.hotkeyOverlaySurfaceId

template exitSessionConfirmSurfaceId(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.exitSessionConfirmSurfaceId

template layoutSwitchToastSurfaceId(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.layoutSwitchToastSurfaceId

template recentWindowsSurfaceId(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.recentWindowsSurfaceId

template recentWindowsChromeSurfaceId(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.recentWindowsChromeSurfaceId

template windowDecorationAbove(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.windowDecorationAbove

template windowDecorationBelow(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.windowDecorationBelow

template frameEmptySurfaces(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.frameEmptySurfaces

template bspPreselectionSurfaces(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.bspPreselectionSurfaces

proc premulColor*(value: uint32): tuple[r, g, b, a: uint32] =
  let r8 = (value shr 24) and 0xff
  let g8 = (value shr 16) and 0xff
  let b8 = (value shr 8) and 0xff
  let a8 = value and 0xff
  let max32 = uint64(high(uint32))
  result.r = uint32((uint64(r8) * uint64(a8) * max32) div (255'u64 * 255'u64))
  result.g = uint32((uint64(g8) * uint64(a8) * max32) div (255'u64 * 255'u64))
  result.b = uint32((uint64(b8) * uint64(a8) * max32) div (255'u64 * 255'u64))
  result.a = uint32((uint64(a8) * max32) div 255)

proc createProtocolBuffer(daemon: TriadDaemon, kind: ProtocolSurfaceKind): ptr Buffer =
  if daemon.singlePixelManager == nil:
    return nil
  let alpha =
    if daemon.currentModel.protocolSurfaces.visibleDebug: 0x80000000'u32 else: 0'u32
  let color =
    case kind
    of ProtocolSurfaceKind.PskShell:
      0x3aa5ff00'u32 or alpha
    of ProtocolSurfaceKind.PskHotkeyOverlay:
      0x11111100'u32 or alpha
    of ProtocolSurfaceKind.PskExitSessionConfirm:
      0x11111100'u32 or alpha
    of ProtocolSurfaceKind.PskLayoutSwitchToast:
      0x11111100'u32 or alpha
    of ProtocolSurfaceKind.PskRecentWindows:
      0x11111100'u32 or alpha
    of ProtocolSurfaceKind.PskRecentWindowsChrome:
      0x11111100'u32 or alpha
    of ProtocolSurfaceKind.PskDecorationAbove:
      0xffcc0000'u32 or alpha
    of ProtocolSurfaceKind.PskDecorationBelow:
      0x2233cc00'u32 or alpha
    of ProtocolSurfaceKind.PskFrameEmpty:
      0x00000000'u32 or alpha
    of ProtocolSurfaceKind.PskBspPreselection:
      0x00000000'u32 or alpha
  let rgba = premulColor(color)
  daemon.singlePixelManager.createU32RgbaBuffer(rgba.r, rgba.g, rgba.b, rgba.a)

proc writeAll(fd: cint, data: string): bool =
  var offset = 0
  while offset < data.len:
    let written = posix.write(fd, unsafeAddr data[offset], data.len - offset)
    if written <= 0:
      return false
    offset += written
  true

proc createArgbBufferFromFd(
    daemon: var TriadDaemon, fd: cint, width, height: int32
): ptr Buffer =
  let size = width * height * 4
  let pool = daemon.shm.createPool(fd, size)
  if pool == nil:
    return nil
  result =
    pool.createBuffer(0, width, height, width * 4, uint32(ShmFormat.format_argb8888))
  pool.destroy()

proc createArgbMemfdBuffer(daemon: var TriadDaemon, buf: PixelBuffer): ptr Buffer =
  when defined(linux):
    let size = buf.width * buf.height * 4
    let fd = memfd_create("triad-argb-overlay", MemfdCloseOnExec)
    if fd < 0:
      return nil
    try:
      if posix.ftruncate(fd, posix.Off(size)) != 0:
        return nil
      if not writeAll(fd, argbBytes(buf.pixels)):
        return nil
      daemon.createArgbBufferFromFd(fd, buf.width, buf.height)
    finally:
      discard posix.close(fd)
  else:
    nil

proc createArgbTempFileBuffer(daemon: var TriadDaemon, buf: PixelBuffer): ptr Buffer =
  let path =
    getTempDir() /
    ("triad-argb-overlay-" & $getCurrentProcessId() & "-" & $daemon.shmBufferCounter)
  try:
    writeFile(path, argbBytes(buf.pixels))
    let fd = posix.open(path.cstring, posix.O_RDWR)
    if fd < 0:
      return nil
    try:
      result = daemon.createArgbBufferFromFd(fd, buf.width, buf.height)
    finally:
      discard posix.close(fd)
  except CatchableError as e:
    warn "Unable to create ARGB overlay shm buffer", path = path, error = e.msg
  finally:
    try:
      if fileExists(path):
        removeFile(path)
    except CatchableError:
      discard

proc createArgbShmBuffer(daemon: var TriadDaemon, buf: PixelBuffer): ptr Buffer =
  if daemon.shm == nil:
    return nil
  inc daemon.shmBufferCounter
  result = daemon.createArgbMemfdBuffer(buf)
  if result == nil:
    result = daemon.createArgbTempFileBuffer(buf)

proc createMappedOverviewOverlayBuffer(
    daemon: var TriadDaemon, screen: Rect
): ptr Buffer =
  if daemon.shm == nil:
    return nil
  when defined(linux):
    let
      width = max(1'i32, screen.w)
      height = max(1'i32, screen.h)
      size = int(width * height * 4)
    inc daemon.shmBufferCounter
    let fd = memfd_create("triad-overview-overlay", MemfdCloseOnExec)
    if fd < 0:
      return nil
    try:
      if posix.ftruncate(fd, posix.Off(size)) != 0:
        return nil
      let mapped = posix.mmap(
        nil,
        size,
        posix.PROT_READ or posix.PROT_WRITE,
        posix.MAP_SHARED,
        fd,
        posix.Off(0),
      )
      if mapped == posix.MAP_FAILED:
        return nil
      try:
        zeroMem(mapped, size)
        var pixels =
          initPixelBufferView(width, height, cast[ptr UncheckedArray[uint32]](mapped))
        daemon.currentModel.drawOverviewOverlayBuffer(screen, pixels)
        result = daemon.createArgbBufferFromFd(fd, width, height)
      finally:
        discard posix.munmap(mapped, size)
    finally:
      discard posix.close(fd)
  else:
    daemon.createArgbShmBuffer(daemon.currentModel.renderOverviewOverlayBuffer(screen))

proc createProtocolWlSurface(
    daemon: var TriadDaemon, kind: ProtocolSurfaceKind
): OwnedProtocolSurface =
  result.kind = kind
  if daemon.compositor == nil:
    return
  result.surface = daemon.compositor.createSurface()
  if result.surface == nil:
    return
  result.buffer = daemon.createProtocolBuffer(kind)
  result.bufferW = 1
  result.bufferH = 1

proc commitProtocolSurface*(daemon: var TriadDaemon, surf: var OwnedProtocolSurface) =
  if surf.surface == nil:
    return
  if surf.shellSurface != nil:
    surf.shellSurface.syncNextCommit()
  if surf.decoration != nil:
    surf.decoration.syncNextCommit()
  if daemon.compositor != nil:
    let input = daemon.compositor.createRegion()
    if input != nil:
      if surf.inputW > 0 and surf.inputH > 0:
        input.add(0, 0, surf.inputW, surf.inputH)
      surf.surface.setInputRegion(input)
      input.destroy()
  if surf.buffer != nil:
    surf.surface.attach(surf.buffer, 0, 0)
    surf.surface.damage(0, 0, max(1'i32, surf.bufferW), max(1'i32, surf.bufferH))
  surf.surface.commit()
  surf.syncPending = false

proc setProtocolSurfaceBuffer*(
    surf: var OwnedProtocolSurface, buffer: ptr Buffer, width, height: int32
) =
  if surf.buffer != nil and surf.buffer != buffer:
    surf.buffer.destroy()
  surf.buffer = buffer
  surf.bufferW = width
  surf.bufferH = height

proc destroyProtocolSurface*(daemon: var TriadDaemon, surf: var OwnedProtocolSurface) =
  if surf.node != nil:
    surf.node.destroy()
    surf.node = nil
  if surf.decoration != nil:
    surf.decoration.destroy()
    surf.decoration = nil
  if surf.shellSurface != nil:
    daemon.shellSurfacePointers.del(surf.shellSurface.id())
    surf.shellSurface.destroy()
    surf.shellSurface = nil
  if surf.surface != nil:
    daemon.protocolSurfaceRuntime.surfaceToOwned.del(surf.surface.id())
    surf.surface.attach(nil, 0, 0)
    surf.surface.commit()
    surf.surface.destroy()
    surf.surface = nil
  if surf.buffer != nil:
    surf.buffer.destroy()
    surf.buffer = nil

proc ensureOwnedShellSurface*(daemon: var TriadDaemon) =
  if not daemon.currentModel.protocolSurfaces.enabled:
    return
  if daemon.ownedShellSurfaceId != 0 and
      daemon.surfaceTable.hasKey(daemon.ownedShellSurfaceId):
    return
  if daemon.riverManager == nil or daemon.compositor == nil:
    return
  var surf = daemon.createProtocolWlSurface(ProtocolSurfaceKind.PskShell)
  if surf.surface == nil:
    warn "Unable to create protocol shell wl_surface"
    return
  surf.shellSurface = daemon.riverManager.getShellSurface(surf.surface)
  if surf.shellSurface == nil:
    warn "Unable to create River shell surface"
    daemon.destroyProtocolSurface(surf)
    return
  surf.node = surf.shellSurface.getNode()
  daemon.ownedShellSurfaceId = surf.shellSurface.id()
  daemon.shellSurfacePointers[daemon.ownedShellSurfaceId] = surf.shellSurface
  daemon.commitProtocolSurface(surf)
  daemon.surfaceTable[daemon.ownedShellSurfaceId] = surf
  debug "Created protocol shell surface", shellSurfaceId = daemon.ownedShellSurfaceId

proc ensureHotkeyOverlaySurface*(daemon: var TriadDaemon) =
  if not daemon.currentModel.protocolSurfaces.enabled:
    return
  if daemon.hotkeyOverlaySurfaceId != 0 and
      daemon.surfaceTable.hasKey(daemon.hotkeyOverlaySurfaceId):
    return
  if daemon.riverManager == nil or daemon.compositor == nil:
    return
  var surf = daemon.createProtocolWlSurface(ProtocolSurfaceKind.PskHotkeyOverlay)
  if surf.surface == nil:
    warn "Unable to create hotkey overlay wl_surface"
    return
  surf.shellSurface = daemon.riverManager.getShellSurface(surf.surface)
  if surf.shellSurface == nil:
    warn "Unable to create hotkey overlay shell surface"
    daemon.destroyProtocolSurface(surf)
    return
  surf.node = surf.shellSurface.getNode()
  daemon.hotkeyOverlaySurfaceId = surf.shellSurface.id()
  daemon.shellSurfacePointers[daemon.hotkeyOverlaySurfaceId] = surf.shellSurface
  daemon.commitProtocolSurface(surf)
  daemon.surfaceTable[daemon.hotkeyOverlaySurfaceId] = surf
  debug "Created hotkey overlay shell surface",
    shellSurfaceId = daemon.hotkeyOverlaySurfaceId

proc ensureExitSessionConfirmSurface*(daemon: var TriadDaemon) =
  if not daemon.currentModel.protocolSurfaces.enabled:
    return
  if daemon.exitSessionConfirmSurfaceId != 0 and
      daemon.surfaceTable.hasKey(daemon.exitSessionConfirmSurfaceId):
    return
  if daemon.riverManager == nil or daemon.compositor == nil:
    return
  var surf = daemon.createProtocolWlSurface(ProtocolSurfaceKind.PskExitSessionConfirm)
  if surf.surface == nil:
    warn "Unable to create exit-session confirmation wl_surface"
    return
  surf.shellSurface = daemon.riverManager.getShellSurface(surf.surface)
  if surf.shellSurface == nil:
    warn "Unable to create exit-session confirmation shell surface"
    daemon.destroyProtocolSurface(surf)
    return
  surf.node = surf.shellSurface.getNode()
  daemon.exitSessionConfirmSurfaceId = surf.shellSurface.id()
  daemon.shellSurfacePointers[daemon.exitSessionConfirmSurfaceId] = surf.shellSurface
  daemon.commitProtocolSurface(surf)
  daemon.surfaceTable[daemon.exitSessionConfirmSurfaceId] = surf
  debug "Created exit-session confirmation shell surface",
    shellSurfaceId = daemon.exitSessionConfirmSurfaceId

proc ensureLayoutSwitchToastSurface*(daemon: var TriadDaemon) =
  if not daemon.currentModel.protocolSurfaces.enabled:
    return
  if daemon.layoutSwitchToastSurfaceId != 0 and
      daemon.surfaceTable.hasKey(daemon.layoutSwitchToastSurfaceId):
    return
  if daemon.riverManager == nil or daemon.compositor == nil:
    return
  var surf = daemon.createProtocolWlSurface(ProtocolSurfaceKind.PskLayoutSwitchToast)
  if surf.surface == nil:
    warn "Unable to create layout-switch toast wl_surface"
    return
  surf.shellSurface = daemon.riverManager.getShellSurface(surf.surface)
  if surf.shellSurface == nil:
    warn "Unable to create layout-switch toast shell surface"
    daemon.destroyProtocolSurface(surf)
    return
  surf.node = surf.shellSurface.getNode()
  daemon.layoutSwitchToastSurfaceId = surf.shellSurface.id()
  daemon.shellSurfacePointers[daemon.layoutSwitchToastSurfaceId] = surf.shellSurface
  daemon.commitProtocolSurface(surf)
  daemon.surfaceTable[daemon.layoutSwitchToastSurfaceId] = surf
  debug "Created layout-switch toast shell surface",
    shellSurfaceId = daemon.layoutSwitchToastSurfaceId

proc ensureRecentWindowsSurface*(daemon: var TriadDaemon) =
  if not daemon.currentModel.protocolSurfaces.enabled:
    return
  if daemon.recentWindowsSurfaceId != 0 and
      daemon.surfaceTable.hasKey(daemon.recentWindowsSurfaceId):
    return
  if daemon.riverManager == nil or daemon.compositor == nil:
    return
  var surf = daemon.createProtocolWlSurface(ProtocolSurfaceKind.PskRecentWindows)
  if surf.surface == nil:
    warn "Unable to create recent-windows wl_surface"
    return
  surf.shellSurface = daemon.riverManager.getShellSurface(surf.surface)
  if surf.shellSurface == nil:
    warn "Unable to create recent-windows shell surface"
    daemon.destroyProtocolSurface(surf)
    return
  surf.node = surf.shellSurface.getNode()
  daemon.recentWindowsSurfaceId = surf.shellSurface.id()
  daemon.shellSurfacePointers[daemon.recentWindowsSurfaceId] = surf.shellSurface
  daemon.commitProtocolSurface(surf)
  daemon.surfaceTable[daemon.recentWindowsSurfaceId] = surf
  debug "Created recent-windows shell surface",
    shellSurfaceId = daemon.recentWindowsSurfaceId

proc ensureRecentWindowsChromeSurface*(daemon: var TriadDaemon) =
  if not daemon.currentModel.protocolSurfaces.enabled:
    return
  if daemon.recentWindowsChromeSurfaceId != 0 and
      daemon.surfaceTable.hasKey(daemon.recentWindowsChromeSurfaceId):
    return
  if daemon.riverManager == nil or daemon.compositor == nil:
    return
  var surf = daemon.createProtocolWlSurface(ProtocolSurfaceKind.PskRecentWindowsChrome)
  if surf.surface == nil:
    warn "Unable to create recent-windows chrome wl_surface"
    return
  surf.shellSurface = daemon.riverManager.getShellSurface(surf.surface)
  if surf.shellSurface == nil:
    warn "Unable to create recent-windows chrome shell surface"
    daemon.destroyProtocolSurface(surf)
    return
  surf.node = surf.shellSurface.getNode()
  daemon.recentWindowsChromeSurfaceId = surf.shellSurface.id()
  daemon.shellSurfacePointers[daemon.recentWindowsChromeSurfaceId] = surf.shellSurface
  daemon.commitProtocolSurface(surf)
  daemon.surfaceTable[daemon.recentWindowsChromeSurfaceId] = surf
  debug "Created recent-windows chrome shell surface",
    shellSurfaceId = daemon.recentWindowsChromeSurfaceId

proc syncOwnedShellSurface*(daemon: var TriadDaemon, screen: Rect) =
  if daemon.ownedShellSurfaceId == 0 or
      not daemon.surfaceTable.hasKey(daemon.ownedShellSurfaceId):
    return

  var surf = daemon.surfaceTable[daemon.ownedShellSurfaceId]
  let wantsShield = daemon.currentModel.overviewActive and daemon.shm != nil
  let desiredW =
    if wantsShield:
      max(1'i32, screen.w)
    else:
      1'i32
  let desiredH =
    if wantsShield:
      max(1'i32, screen.h)
    else:
      1'i32
  let overlayKey =
    if wantsShield:
      daemon.currentModel.overviewOverlayCacheKey(screen)
    else:
      ""
  if surf.buffer == nil or surf.bufferW != desiredW or surf.bufferH != desiredH or
      surf.bufferCacheKey != overlayKey:
    let buffer =
      if wantsShield:
        daemon.createMappedOverviewOverlayBuffer(screen)
      else:
        daemon.createProtocolBuffer(ProtocolSurfaceKind.PskShell)
    if buffer != nil:
      surf.setProtocolSurfaceBuffer(buffer, desiredW, desiredH)
      surf.bufferCacheKey = overlayKey
    elif wantsShield:
      warn "Overview input shield unavailable; previews may receive pointer"

  if wantsShield and surf.bufferW == desiredW and surf.bufferH == desiredH:
    surf.inputW = desiredW
    surf.inputH = desiredH
  else:
    surf.inputW = 0
    surf.inputH = 0
  daemon.commitProtocolSurface(surf)
  daemon.surfaceTable[daemon.ownedShellSurfaceId] = surf

proc syncHotkeyOverlaySurface*(daemon: var TriadDaemon, screen: Rect) =
  if not daemon.currentModel.hotkeyOverlayOpen:
    if daemon.hotkeyOverlaySurfaceId != 0 and
        daemon.surfaceTable.hasKey(daemon.hotkeyOverlaySurfaceId):
      var surf = daemon.surfaceTable[daemon.hotkeyOverlaySurfaceId]
      surf.inputW = 0
      surf.inputH = 0
      let buffer = daemon.createProtocolBuffer(ProtocolSurfaceKind.PskHotkeyOverlay)
      if buffer != nil:
        surf.setProtocolSurfaceBuffer(buffer, 1, 1)
      if surf.node != nil:
        surf.node.placeBottom()
      daemon.commitProtocolSurface(surf)
      daemon.surfaceTable[daemon.hotkeyOverlaySurfaceId] = surf
    return

  daemon.ensureHotkeyOverlaySurface()
  if daemon.hotkeyOverlaySurfaceId == 0 or
      not daemon.surfaceTable.hasKey(daemon.hotkeyOverlaySurfaceId):
    return

  let rows = daemon.currentModel.hotkeyOverlayRows()
  let rendered =
    renderHotkeyOverlayBuffer(rows, screen, daemon.currentModel.hotkeyOverlay.columns)
  var surf = daemon.surfaceTable[daemon.hotkeyOverlaySurfaceId]
  let buffer = daemon.createArgbShmBuffer(rendered)
  if buffer != nil:
    surf.setProtocolSurfaceBuffer(buffer, rendered.width, rendered.height)
  else:
    warn "Hotkey overlay buffer unavailable"
    return
  surf.inputW = 0
  surf.inputH = 0
  daemon.commitProtocolSurface(surf)
  if surf.node != nil:
    let placement = hotkeyOverlayPlacement(
      screen, surf.bufferW, surf.bufferH, daemon.currentModel.hotkeyOverlay.position
    )
    surf.node.setPosition(placement.x, placement.y)
    surf.node.placeTop()
  daemon.surfaceTable[daemon.hotkeyOverlaySurfaceId] = surf

proc syncExitSessionConfirmSurface*(daemon: var TriadDaemon, screen: Rect) =
  if not daemon.currentModel.exitSessionConfirmOpen:
    if daemon.exitSessionConfirmSurfaceId != 0 and
        daemon.surfaceTable.hasKey(daemon.exitSessionConfirmSurfaceId):
      var surf = daemon.surfaceTable[daemon.exitSessionConfirmSurfaceId]
      surf.inputW = 0
      surf.inputH = 0
      let buffer =
        daemon.createProtocolBuffer(ProtocolSurfaceKind.PskExitSessionConfirm)
      if buffer != nil:
        surf.setProtocolSurfaceBuffer(buffer, 1, 1)
      if surf.node != nil:
        surf.node.placeBottom()
      daemon.commitProtocolSurface(surf)
      daemon.surfaceTable[daemon.exitSessionConfirmSurfaceId] = surf
    return

  daemon.ensureExitSessionConfirmSurface()
  if daemon.exitSessionConfirmSurfaceId == 0 or
      not daemon.surfaceTable.hasKey(daemon.exitSessionConfirmSurfaceId):
    return

  let rendered = renderExitSessionDialogBuffer(screen)
  var surf = daemon.surfaceTable[daemon.exitSessionConfirmSurfaceId]
  let buffer = daemon.createArgbShmBuffer(rendered)
  if buffer != nil:
    surf.setProtocolSurfaceBuffer(buffer, rendered.width, rendered.height)
  else:
    warn "Exit-session confirmation buffer unavailable"
    return
  surf.inputW = surf.bufferW
  surf.inputH = surf.bufferH
  daemon.commitProtocolSurface(surf)
  if surf.node != nil:
    let placement = exitSessionDialogPlacement(screen, surf.bufferW, surf.bufferH)
    surf.node.setPosition(placement.x, placement.y)
    surf.node.placeTop()
  daemon.surfaceTable[daemon.exitSessionConfirmSurfaceId] = surf

proc syncLayoutSwitchToastSurface*(daemon: var TriadDaemon, screen: Rect) =
  if not daemon.currentModel.layoutSwitchToastOpen:
    if daemon.layoutSwitchToastSurfaceId != 0 and
        daemon.surfaceTable.hasKey(daemon.layoutSwitchToastSurfaceId):
      var surf = daemon.surfaceTable[daemon.layoutSwitchToastSurfaceId]
      surf.inputW = 0
      surf.inputH = 0
      let buffer = daemon.createProtocolBuffer(ProtocolSurfaceKind.PskLayoutSwitchToast)
      if buffer != nil:
        surf.setProtocolSurfaceBuffer(buffer, 1, 1)
      if surf.node != nil:
        surf.node.placeBottom()
      daemon.commitProtocolSurface(surf)
      daemon.surfaceTable[daemon.layoutSwitchToastSurfaceId] = surf
    return

  daemon.ensureLayoutSwitchToastSurface()
  if daemon.layoutSwitchToastSurfaceId == 0 or
      not daemon.surfaceTable.hasKey(daemon.layoutSwitchToastSurfaceId):
    return

  let customLayout = string(daemon.currentModel.layoutSwitchToastCustomLayout)
  let nativeLayout =
    daemon.currentModel.layoutSwitchToastNativeLayout.nativeLayoutIdString()
  let layoutLabel =
    if customLayout.len > 0:
      customLayout
    elif nativeLayout.len > 0:
      nativeLayout
    else:
      daemon.currentModel.layoutSwitchToastLayout.layoutModeId()
  let rendered = renderLayoutSwitchToastLabelBuffer(
    screen, layoutLabel, daemon.currentModel.borderWidth,
    daemon.currentModel.layoutSwitchToast.ringColor,
  )
  var surf = daemon.surfaceTable[daemon.layoutSwitchToastSurfaceId]
  let buffer = daemon.createArgbShmBuffer(rendered)
  if buffer != nil:
    surf.setProtocolSurfaceBuffer(buffer, rendered.width, rendered.height)
  else:
    warn "Layout-switch toast buffer unavailable"
    return
  surf.inputW = 0
  surf.inputH = 0
  daemon.commitProtocolSurface(surf)
  if surf.node != nil:
    let placement = layoutSwitchToastPlacement(screen, surf.bufferW, surf.bufferH)
    surf.node.setPosition(placement.x, placement.y)
    surf.node.placeTop()
  daemon.surfaceTable[daemon.layoutSwitchToastSurfaceId] = surf

proc syncRecentWindowsSurface*(daemon: var TriadDaemon, screen: Rect) =
  if not daemon.currentModel.recentWindowsVisible():
    if daemon.recentWindowsSurfaceId != 0 and
        daemon.surfaceTable.hasKey(daemon.recentWindowsSurfaceId):
      var surf = daemon.surfaceTable[daemon.recentWindowsSurfaceId]
      surf.inputW = 0
      surf.inputH = 0
      let buffer = daemon.createProtocolBuffer(ProtocolSurfaceKind.PskRecentWindows)
      if buffer != nil:
        surf.setProtocolSurfaceBuffer(buffer, 1, 1)
      if surf.node != nil:
        surf.node.placeBottom()
      daemon.commitProtocolSurface(surf)
      daemon.surfaceTable[daemon.recentWindowsSurfaceId] = surf
    if daemon.recentWindowsChromeSurfaceId != 0 and
        daemon.surfaceTable.hasKey(daemon.recentWindowsChromeSurfaceId):
      var surf = daemon.surfaceTable[daemon.recentWindowsChromeSurfaceId]
      surf.inputW = 0
      surf.inputH = 0
      let buffer =
        daemon.createProtocolBuffer(ProtocolSurfaceKind.PskRecentWindowsChrome)
      if buffer != nil:
        surf.setProtocolSurfaceBuffer(buffer, 1, 1)
      if surf.node != nil:
        surf.node.placeBottom()
      daemon.commitProtocolSurface(surf)
      daemon.surfaceTable[daemon.recentWindowsChromeSurfaceId] = surf
    return

  daemon.ensureRecentWindowsSurface()
  daemon.ensureRecentWindowsChromeSurface()
  if daemon.recentWindowsSurfaceId == 0 or
      not daemon.surfaceTable.hasKey(daemon.recentWindowsSurfaceId):
    return
  if daemon.recentWindowsChromeSurfaceId == 0 or
      not daemon.surfaceTable.hasKey(daemon.recentWindowsChromeSurfaceId):
    return

  let backdrop = renderRecentWindowsBackdropBuffer(daemon.currentModel, screen)
  var backdropSurf = daemon.surfaceTable[daemon.recentWindowsSurfaceId]
  let backdropBuffer = daemon.createArgbShmBuffer(backdrop)
  if backdropBuffer != nil:
    backdropSurf.setProtocolSurfaceBuffer(
      backdropBuffer, backdrop.width, backdrop.height
    )
  else:
    warn "Recent-windows backdrop buffer unavailable"
    return
  backdropSurf.inputW = 0
  backdropSurf.inputH = 0
  daemon.commitProtocolSurface(backdropSurf)
  if backdropSurf.node != nil:
    backdropSurf.node.setPosition(screen.x, screen.y)
  daemon.surfaceTable[daemon.recentWindowsSurfaceId] = backdropSurf

  let chrome = renderRecentWindowsChromeBuffer(daemon.currentModel, screen)
  var chromeSurf = daemon.surfaceTable[daemon.recentWindowsChromeSurfaceId]
  let chromeBuffer = daemon.createArgbShmBuffer(chrome)
  if chromeBuffer != nil:
    chromeSurf.setProtocolSurfaceBuffer(chromeBuffer, chrome.width, chrome.height)
  else:
    warn "Recent-windows chrome buffer unavailable"
    return
  chromeSurf.inputW = chromeSurf.bufferW
  chromeSurf.inputH = chromeSurf.bufferH
  daemon.commitProtocolSurface(chromeSurf)
  if chromeSurf.node != nil:
    chromeSurf.node.setPosition(screen.x, screen.y)
  daemon.surfaceTable[daemon.recentWindowsChromeSurfaceId] = chromeSurf

proc ensureDecorationSurface*(
    daemon: var TriadDaemon, windowId: uint32, kind: ProtocolSurfaceKind
): uint32 =
  if not daemon.currentModel.protocolSurfaces.enabled:
    return 0
  if not daemon.windowPointers.hasKey(windowId) or daemon.compositor == nil:
    return 0
  if kind == ProtocolSurfaceKind.PskDecorationAbove and
      daemon.windowDecorationAbove.hasKey(windowId):
    return daemon.windowDecorationAbove[windowId]
  if kind == ProtocolSurfaceKind.PskDecorationBelow and
      daemon.windowDecorationBelow.hasKey(windowId):
    return daemon.windowDecorationBelow[windowId]

  var surf = daemon.createProtocolWlSurface(kind)
  if surf.surface == nil:
    return 0
  surf.windowId = windowId
  case kind
  of ProtocolSurfaceKind.PskDecorationAbove:
    surf.decoration = daemon.windowPointers[windowId].getDecorationAbove(surf.surface)
  of ProtocolSurfaceKind.PskDecorationBelow:
    surf.decoration = daemon.windowPointers[windowId].getDecorationBelow(surf.surface)
  else:
    discard
  if surf.decoration == nil:
    daemon.destroyProtocolSurface(surf)
    return 0
  surf.decoration.setOffset(0, 0)
  daemon.commitProtocolSurface(surf)
  let id = surf.decoration.id()
  daemon.surfaceTable[id] = surf
  daemon.protocolSurfaceRuntime.surfaceToOwned[surf.surface.id()] = id
  if kind == ProtocolSurfaceKind.PskDecorationAbove:
    daemon.windowDecorationAbove[windowId] = id
  elif kind == ProtocolSurfaceKind.PskDecorationBelow:
    daemon.windowDecorationBelow[windowId] = id
  let kindText = $kind
  debug "Created protocol decoration surface",
    windowId = windowId, decorationId = id, kind = kindText
  id

proc clearDecorationSurface(daemon: var TriadDaemon, id: uint32) =
  if not daemon.surfaceTable.hasKey(id):
    return
  var surf = daemon.surfaceTable[id]
  if surf.kind notin
      {ProtocolSurfaceKind.PskDecorationAbove, ProtocolSurfaceKind.PskDecorationBelow}:
    return
  if surf.decoration == nil:
    return
  let key = "clear:" & $daemon.currentModel.protocolSurfaces.visibleDebug
  let dirty =
    surf.offsetX != 0 or surf.offsetY != 0 or surf.inputW != 0 or surf.inputH != 0 or
    surf.bufferCacheKey != key
  surf.decoration.setOffset(0, 0)
  surf.offsetX = 0
  surf.offsetY = 0
  surf.inputW = 0
  surf.inputH = 0
  if surf.bufferCacheKey != key:
    surf.setProtocolSurfaceBuffer(daemon.createProtocolBuffer(surf.kind), 1, 1)
    surf.bufferCacheKey = key
  if dirty:
    daemon.commitProtocolSurface(surf)
  daemon.surfaceTable[id] = surf

proc ensureFrameEmptySurface(daemon: var TriadDaemon, frameId: uint32): uint32 =
  if daemon.frameEmptySurfaces.hasKey(frameId):
    let surfaceId = daemon.frameEmptySurfaces[frameId]
    if daemon.surfaceTable.hasKey(surfaceId):
      return surfaceId
  if daemon.riverManager == nil or daemon.compositor == nil:
    return 0
  var surf = daemon.createProtocolWlSurface(ProtocolSurfaceKind.PskFrameEmpty)
  if surf.surface == nil:
    return 0
  surf.frameId = frameId
  surf.shellSurface = daemon.riverManager.getShellSurface(surf.surface)
  if surf.shellSurface == nil:
    daemon.destroyProtocolSurface(surf)
    return 0
  surf.node = surf.shellSurface.getNode()
  let id = surf.shellSurface.id()
  daemon.shellSurfacePointers[id] = surf.shellSurface
  daemon.protocolSurfaceRuntime.surfaceToOwned[surf.surface.id()] = id
  daemon.commitProtocolSurface(surf)
  daemon.surfaceTable[id] = surf
  daemon.frameEmptySurfaces[frameId] = id
  debug "Created frame empty chrome surface", frameId = frameId, shellSurfaceId = id
  id

proc ensureBspPreselectionSurface(daemon: var TriadDaemon, nodeId: uint32): uint32 =
  if daemon.bspPreselectionSurfaces.hasKey(nodeId):
    let surfaceId = daemon.bspPreselectionSurfaces[nodeId]
    if daemon.surfaceTable.hasKey(surfaceId):
      return surfaceId
  if daemon.riverManager == nil or daemon.compositor == nil:
    return 0
  var surf = daemon.createProtocolWlSurface(ProtocolSurfaceKind.PskBspPreselection)
  if surf.surface == nil:
    return 0
  surf.shellSurface = daemon.riverManager.getShellSurface(surf.surface)
  if surf.shellSurface == nil:
    daemon.destroyProtocolSurface(surf)
    return 0
  surf.node = surf.shellSurface.getNode()
  let id = surf.shellSurface.id()
  daemon.shellSurfacePointers[id] = surf.shellSurface
  daemon.protocolSurfaceRuntime.surfaceToOwned[surf.surface.id()] = id
  daemon.commitProtocolSurface(surf)
  daemon.surfaceTable[id] = surf
  daemon.bspPreselectionSurfaces[nodeId] = id
  debug "Created BSP preselection surface", nodeId = nodeId, shellSurfaceId = id
  id

proc syncFrameTabBarSurfaces*(
    daemon: var TriadDaemon, tabBars: openArray[ProjectedFrameTabBar]
) =
  if not daemon.currentModel.protocolSurfaces.enabled:
    for _, surfaceId in daemon.windowDecorationAbove.pairs:
      daemon.clearDecorationSurface(surfaceId)
    return

  var activeWindows = initHashSet[uint32]()
  for bar in tabBars:
    if bar.windowId == 0 or bar.geom.w <= 0 or bar.geom.h <= 0 or bar.tabs.len == 0:
      continue
    let surfaceId = daemon.ensureDecorationSurface(
      bar.windowId, ProtocolSurfaceKind.PskDecorationAbove
    )
    if surfaceId == 0 or not daemon.surfaceTable.hasKey(surfaceId):
      continue
    activeWindows.incl(bar.windowId)
    var surf = daemon.surfaceTable[surfaceId]
    let key = bar.frameTabBarCacheKey()
    let ringInset = max(0'i32, bar.ringWidth)
    let surfaceH = max(1'i32, bar.geom.h + ringInset)
    let surfaceW = max(1'i32, bar.geom.w + ringInset * 2)
    let windowGeom =
      if daemon.desiredPlacements.hasKey(bar.windowId):
        daemon.desiredPlacements[bar.windowId]
      else:
        Rect(
          x: bar.geom.x,
          y: bar.geom.y + bar.geom.h,
          w: bar.geom.w,
          h: max(1'i32, bar.geom.h),
        )
    let offsetX = bar.geom.x - windowGeom.x - ringInset
    let offsetY = bar.geom.y - windowGeom.y - ringInset
    surf.decoration.setOffset(offsetX, offsetY)
    surf.offsetX = offsetX
    surf.offsetY = offsetY
    surf.inputW = surfaceW
    surf.inputH = surfaceH
    if surf.bufferCacheKey != key:
      let rendered = renderFrameTabBarBuffer(bar)
      let buffer = daemon.createArgbShmBuffer(rendered)
      if buffer != nil:
        surf.setProtocolSurfaceBuffer(buffer, rendered.width, rendered.height)
        surf.bufferCacheKey = key
        daemon.commitProtocolSurface(surf)
    daemon.surfaceTable[surfaceId] = surf

  for windowId, surfaceId in daemon.windowDecorationAbove.pairs:
    if not activeWindows.contains(windowId):
      daemon.clearDecorationSurface(surfaceId)

proc syncFrameEmptySurfaces*(
    daemon: var TriadDaemon, frames: openArray[ProjectedFrameEmptyChrome]
) =
  if not daemon.currentModel.protocolSurfaces.enabled:
    var staleIds: seq[uint32]
    for _, surfaceId in daemon.frameEmptySurfaces.pairs:
      staleIds.add(surfaceId)
    daemon.frameEmptySurfaces.clear()
    for surfaceId in staleIds:
      if daemon.surfaceTable.hasKey(surfaceId):
        var surf = daemon.surfaceTable[surfaceId]
        daemon.surfaceTable.del(surfaceId)
        daemon.destroyProtocolSurface(surf)
    return

  var activeFrames = initHashSet[uint32]()
  for frame in frames:
    if frame.frameId == 0 or frame.geom.w <= 0 or frame.geom.h <= 0:
      continue
    let surfaceId = daemon.ensureFrameEmptySurface(frame.frameId)
    if surfaceId == 0 or not daemon.surfaceTable.hasKey(surfaceId):
      continue
    activeFrames.incl(frame.frameId)
    var surf = daemon.surfaceTable[surfaceId]
    let key = frame.frameEmptyChromeCacheKey()
    surf.frameId = frame.frameId
    surf.inputW = max(1'i32, frame.geom.w)
    surf.inputH = max(1'i32, frame.geom.h)
    if surf.bufferCacheKey != key:
      let rendered = renderFrameEmptyChromeBuffer(frame)
      let buffer = daemon.createArgbShmBuffer(rendered)
      if buffer != nil:
        surf.setProtocolSurfaceBuffer(buffer, rendered.width, rendered.height)
        surf.bufferCacheKey = key
        daemon.commitProtocolSurface(surf)
    if surf.node != nil:
      surf.node.setPosition(frame.geom.x, frame.geom.y)
      surf.node.placeTop()
    daemon.surfaceTable[surfaceId] = surf

  var staleFrames: seq[uint32]
  for frameId in daemon.frameEmptySurfaces.keys:
    if not activeFrames.contains(frameId):
      staleFrames.add(frameId)
  for frameId in staleFrames:
    let surfaceId = daemon.frameEmptySurfaces[frameId]
    daemon.frameEmptySurfaces.del(frameId)
    if daemon.surfaceTable.hasKey(surfaceId):
      var surf = daemon.surfaceTable[surfaceId]
      daemon.surfaceTable.del(surfaceId)
      daemon.destroyProtocolSurface(surf)

proc syncBspPreselectionSurfaces*(
    daemon: var TriadDaemon, preselections: openArray[ProjectedBspPreselection]
) =
  if not daemon.currentModel.protocolSurfaces.enabled:
    var staleIds: seq[uint32]
    for _, surfaceId in daemon.bspPreselectionSurfaces.pairs:
      staleIds.add(surfaceId)
    daemon.bspPreselectionSurfaces.clear()
    for surfaceId in staleIds:
      if daemon.surfaceTable.hasKey(surfaceId):
        var surf = daemon.surfaceTable[surfaceId]
        daemon.surfaceTable.del(surfaceId)
        daemon.destroyProtocolSurface(surf)
    return

  var activeNodes = initHashSet[uint32]()
  for preselection in preselections:
    if preselection.nodeId == 0 or preselection.geom.w <= 0 or preselection.geom.h <= 0:
      continue
    let surfaceId = daemon.ensureBspPreselectionSurface(preselection.nodeId)
    if surfaceId == 0 or not daemon.surfaceTable.hasKey(surfaceId):
      continue
    activeNodes.incl(preselection.nodeId)
    var surf = daemon.surfaceTable[surfaceId]
    let key = preselection.bspPreselectionCacheKey()
    surf.inputW = 0
    surf.inputH = 0
    if surf.bufferCacheKey != key:
      let rendered = renderBspPreselectionBuffer(preselection)
      let buffer = daemon.createArgbShmBuffer(rendered)
      if buffer != nil:
        surf.setProtocolSurfaceBuffer(buffer, rendered.width, rendered.height)
        surf.bufferCacheKey = key
        daemon.commitProtocolSurface(surf)
    if surf.node != nil:
      surf.node.setPosition(preselection.geom.x, preselection.geom.y)
      surf.node.placeTop()
    daemon.surfaceTable[surfaceId] = surf

  var staleNodes: seq[uint32]
  for nodeId in daemon.bspPreselectionSurfaces.keys:
    if not activeNodes.contains(nodeId):
      staleNodes.add(nodeId)
  for nodeId in staleNodes:
    let surfaceId = daemon.bspPreselectionSurfaces[nodeId]
    daemon.bspPreselectionSurfaces.del(nodeId)
    if daemon.surfaceTable.hasKey(surfaceId):
      var surf = daemon.surfaceTable[surfaceId]
      daemon.surfaceTable.del(surfaceId)
      daemon.destroyProtocolSurface(surf)

proc destroyWindowProtocolSurfaces*(daemon: var TriadDaemon, windowId: uint32) =
  if daemon.windowDecorationAbove.hasKey(windowId):
    let id = daemon.windowDecorationAbove[windowId]
    daemon.windowDecorationAbove.del(windowId)
    if daemon.surfaceTable.hasKey(id):
      var surf = daemon.surfaceTable[id]
      daemon.surfaceTable.del(id)
      daemon.destroyProtocolSurface(surf)
  if daemon.windowDecorationBelow.hasKey(windowId):
    let id = daemon.windowDecorationBelow[windowId]
    daemon.windowDecorationBelow.del(windowId)
    if daemon.surfaceTable.hasKey(id):
      var surf = daemon.surfaceTable[id]
      daemon.surfaceTable.del(id)
      daemon.destroyProtocolSurface(surf)

proc destroyAllProtocolSurfaces*(daemon: var TriadDaemon) =
  var ids: seq[uint32] = @[]
  for id in daemon.surfaceTable.keys:
    ids.add(id)
  for id in ids:
    var surf = daemon.surfaceTable[id]
    daemon.surfaceTable.del(id)
    daemon.destroyProtocolSurface(surf)
  daemon.ownedShellSurfaceId = 0
  daemon.hotkeyOverlaySurfaceId = 0
  daemon.exitSessionConfirmSurfaceId = 0
  daemon.layoutSwitchToastSurfaceId = 0
  daemon.recentWindowsSurfaceId = 0
  daemon.recentWindowsChromeSurfaceId = 0
  daemon.windowDecorationAbove.clear()
  daemon.windowDecorationBelow.clear()
  daemon.frameEmptySurfaces.clear()
  daemon.bspPreselectionSurfaces.clear()
  daemon.protocolSurfaceRuntime.surfaceToOwned.clear()
