import std/tables
import chronicles
import wayland/native/client
import protocols/river/client as river
import protocols/river_layer_shell/client as riverLayer
import protocols/river_xkb_bindings/client as riverXkb
import wayland/protocols/wayland/client as wlCore
import wayland/protocols/staging/singlepixelbuffer/v1/client as singlepixel
import ../core/msg
import
  bindings_runtime, manage_requests, message_queue, protocol_surface_runtime,
  river_manager_runtime, river_outputs_runtime, state

proc handleGlobal*(
    data: pointer,
    registry: ptr Registry,
    name: uint32,
    interfaceNameRaw: cstring,
    version: uint32,
) =
  let daemon = daemonFromData(data)
  if daemon == nil:
    warn "Ignoring Wayland global without daemon context"
    return

  let interfaceName = $interfaceNameRaw
  debug "Wayland global advertised",
    name = name, interfaceName = interfaceName, version = version
  if interfaceName == "river_window_manager_v1":
    if version < 4'u32:
      fatal "river_window_manager_v1 v4 is required", advertisedVersion = version
      quit 1
    daemon.riverManager = cast[ptr RiverWindowManagerV1](registry.`bind`(
      name, river_window_manager_v1_interface.addr, 4'u32
    ))
    discard
      daemon.riverManager.addListener(riverManagerListener.addr, daemonData(daemon[]))
    info "Bound to river_window_manager_v1",
      name = name, advertisedVersion = version, boundVersion = 4
    daemon[].ensureOwnedShellSurface()
  elif interfaceName == "wl_compositor":
    daemon.compositor = cast[ptr Compositor](registry.`bind`(
      name, wl_compositor_interface.addr, min(version, 6'u32)
    ))
    info "Bound to wl_compositor", name = name, advertisedVersion = version
    daemon[].ensureOwnedShellSurface()
  elif interfaceName == "wl_shm":
    daemon.shm = cast[ptr Shm](registry.`bind`(
      name, wlCore.wl_shm_interface.addr, min(version, 1'u32)
    ))
    info "Bound to wl_shm", name = name, advertisedVersion = version
  elif interfaceName == "wl_output":
    let wlOutput = cast[ptr Output](registry.`bind`(
      name, wlCore.wl_output_interface.addr, min(version, 4'u32)
    ))
    daemon.wlOutputPointers[name] = wlOutput
    let listenerData = WlOutputListenerData(daemon: daemon, globalName: name)
    daemon.wlOutputListenerData[name] = new(WlOutputListenerData)
    daemon.wlOutputListenerData[name][] = listenerData
    discard wlOutput.addListener(
      wlOutputListener.addr, cast[pointer](daemon.wlOutputListenerData[name])
    )
    debug "Bound to wl_output",
      name = name, advertisedVersion = version, boundVersion = min(version, 4'u32)
  elif interfaceName == "wl_seat":
    let wlSeat = cast[ptr Seat](registry.`bind`(
      name, wlCore.wl_seat_interface.addr, min(version, 9'u32)
    ))
    daemon.wlSeatPointers[name] = wlSeat
    let listenerData = WlSeatListenerData(daemon: daemon, globalName: name)
    daemon.wlSeatListenerData[name] = new(WlSeatListenerData)
    daemon.wlSeatListenerData[name][] = listenerData
    discard wlSeat.addListener(
      wlSeatListener.addr, cast[pointer](daemon.wlSeatListenerData[name])
    )
    debug "Bound to wl_seat",
      name = name, advertisedVersion = version, boundVersion = min(version, 9'u32)
  elif interfaceName == "river_layer_shell_v1":
    daemon.riverLayerShell = cast[ptr riverLayer.RiverLayerShellV1](registry.`bind`(
      name, riverLayer.river_layer_shell_v1_interface.addr, min(version, 1'u32)
    ))
    for outputId in daemon.outputPointers.keys:
      daemon[].attachLayerOutput(outputId)
    for seat in daemon.seatPointers:
      daemon[].attachLayerSeat(seat)
    info "Bound to river_layer_shell_v1", name = name, advertisedVersion = version
  elif interfaceName == "river_xkb_bindings_v1":
    daemon.riverXkbBindings = cast[ptr riverXkb.RiverXkbBindingsV1](registry.`bind`(
      name, riverXkb.river_xkb_bindings_v1_interface.addr, min(version, 3'u32)
    ))
    daemon.bindingsConfigured = false
    daemon[].requestManage("xkb bindings discovered")
    info "Bound to river_xkb_bindings_v1", name = name, advertisedVersion = version
  elif interfaceName == "wp_single_pixel_buffer_manager_v1":
    daemon.singlePixelManager = cast[ptr singlepixel.WpSinglePixelBufferManagerV1](registry.`bind`(
      name,
      singlepixel.wp_single_pixel_buffer_manager_v1_interface.addr,
      min(version, 1'u32),
    ))
    info "Bound to wp_single_pixel_buffer_manager_v1",
      name = name, advertisedVersion = version

proc handleGlobalRemove*(data: pointer, registry: ptr Registry, name: uint32) =
  let daemon = daemonFromData(data)
  if daemon == nil:
    warn "Ignoring Wayland global removal without daemon context"
    return

  debug "Wayland global removed", name = name
  if daemon.wlOutputPointers.hasKey(name):
    daemon.wlOutputPointers[name].release()
    daemon.wlOutputPointers.del(name)
  daemon.wlOutputListenerData.del(name)
  if daemon.wlSeatPointers.hasKey(name):
    daemon[].detachWlPointer(name)
    daemon.wlSeatPointers[name].release()
    daemon.wlSeatPointers.del(name)
  daemon.wlSeatListenerData.del(name)
  daemon.outputGlobalNames.del(name)
  if daemon.outputGlobalOwners.hasKey(name):
    let outputId = daemon.outputGlobalOwners[name]
    daemon.outputGlobalOwners.del(name)
    daemon.enqueue(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: outputId, outputName: "")
    )

var registryListener* =
  RegistryListener(global: handleGlobal, globalRemove: handleGlobalRemove)
