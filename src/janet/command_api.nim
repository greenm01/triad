import std/[options, strutils]
import ../core/msg
import ../types/runtime_values
import binding

proc layoutFromName(name: string): Option[LayoutMode] =
  case name.normalize()
  of "scroller":
    some(LayoutMode.Scroller)
  of "vertical-scroller":
    some(LayoutMode.VerticalScroller)
  of "tile":
    some(LayoutMode.MasterStack)
  of "grid":
    some(LayoutMode.Grid)
  of "monocle":
    some(LayoutMode.Monocle)
  of "deck":
    some(LayoutMode.Deck)
  of "center-tile":
    some(LayoutMode.CenterTile)
  of "right-tile":
    some(LayoutMode.RightTile)
  of "vertical-tile":
    some(LayoutMode.VerticalTile)
  of "vertical-grid":
    some(LayoutMode.VerticalGrid)
  of "vertical-deck":
    some(LayoutMode.VerticalDeck)
  of "tgmix":
    some(LayoutMode.TGMix)
  else:
    none(LayoutMode)

proc actionMsg*(runtime: JanetHandle, index: int): Option[Msg] =
  case int(triadJanetActionKind(runtime, cint(index)))
  of JanetActionMoveToTag:
    some(
      Msg(
        kind: MsgKind.CmdMoveToTag, targetTag: triadJanetActionU32(runtime, cint(index))
      )
    )
  of JanetActionMoveToWorkspace:
    some(
      Msg(
        kind: MsgKind.CmdMoveToWorkspaceIndex,
        workspaceIndex: triadJanetActionU32(runtime, cint(index)),
      )
    )
  of JanetActionFocusTag:
    some(
      Msg(
        kind: MsgKind.CmdFocusTag, focusTag: triadJanetActionU32(runtime, cint(index))
      )
    )
  of JanetActionSetLayout:
    let layout = layoutFromName($triadJanetActionText(runtime, cint(index)))
    if layout.isSome:
      some(Msg(kind: MsgKind.CmdSetLayout, newLayout: layout.get()))
    else:
      none(Msg)
  of JanetActionToggleFloating:
    some(Msg(kind: MsgKind.CmdToggleFloating))
  of JanetActionSpawn:
    var command: seq[string] = @[]
    let argc = int(triadJanetActionArgc(runtime, cint(index)))
    for argIndex in 0 ..< argc:
      command.add($triadJanetActionArgv(runtime, cint(index), cint(argIndex)))
    if command.len > 0:
      some(Msg(kind: MsgKind.CmdSpawn, spawnCommand: command))
    else:
      none(Msg)
  else:
    none(Msg)
