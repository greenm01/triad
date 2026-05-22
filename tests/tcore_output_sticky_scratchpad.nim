import std/sets
from ../src/core/layout_selection_codec import janetLayoutId
from ../src/core/native_layout_codec import nativeLayoutId
import ../src/systems/daemon_view
import tcore_support

proc fullyWithin(rect, screen: Rect): bool =
  rect.x >= screen.x and rect.y >= screen.y and rect.x + rect.w <= screen.x + screen.w and
    rect.y + rect.h <= screen.y + screen.h

proc inactiveOutputLocalFocusScenario(
    layoutId: string
): tuple[model: Model, localWindow: uint32, activeWindow: uint32, localScreen: Rect] =
  var model = initRuntimeStateFromConfig(
    Config(
      layout: LayoutConfig(borderWidth: 4), workspaces: WorkspaceConfig(defaultCount: 3)
    )
  ).model
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 2560, height: 1440)
  )
  model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-2"))
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1920, height: 1080)
  )
  model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-3"))

  let middle = model.outputForExternal(ExternalOutputId(1))
  let left = model.outputForExternal(ExternalOutputId(2))
  let tag1 = model.tagForSlot(1)
  let tag3 = model.tagForSlot(3)
  discard model.setOutputTag(middle, tag1)
  discard model.setOutputTag(left, tag3)

  model.applyMsg(
    Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "term", title: "term")
  )
  model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
  model.applyMsg(
    Msg(kind: MsgKind.WlWindowCreated, windowId: 30, appId: "files", title: "files")
  )

  case layoutId
  of "dwindle":
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("dwindle"))
    )
  of "bsp-tree":
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("bsp-tree"))
    )
  of "i3", "i3-tabbed":
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("i3"))
    )
  of "frame-tree":
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
  of "notion":
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("notion"))
    )
  else:
    discard

  model.applyMsg(
    Msg(kind: MsgKind.WlWindowCreated, windowId: 31, appId: "shell", title: "shell")
  )
  model.applyMsg(
    Msg(kind: MsgKind.WlWindowCreated, windowId: 32, appId: "log", title: "log")
  )
  if layoutId == "i3-tabbed":
    model.applyMsg(Msg(kind: MsgKind.CmdSplitTreeLayoutTabbed))
  model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 30))
  model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

  (
    model: model,
    localWindow: 30'u32,
    activeWindow: 10'u32,
    localScreen: model.outputScreen(left),
  )

suite "Core Runtime Logic: output sticky scratchpad":
  test "Output identity events store make model and description":
    var model = initRuntimeStateFromConfig(Config()).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputIdentity,
        identityOutputId: 2,
        outputMake: "Dell Inc.",
        outputModel: "DELL U2720Q",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputDescription,
        descriptionOutputId: 2,
        outputDescription: "Dell Inc. 27 inch",
      )
    )

    let output = model.outputData(model.outputForExternal(ExternalOutputId(2))).get()
    check output.make == "Dell Inc."
    check output.model == "DELL U2720Q"
    check output.description == "Dell Inc. 27 inch"

  test "Workspace rules pin workspace home output after output appears":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        tagRules: @[TagRule(tagId: 2, openOnOutput: "HDMI-A-1")],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )

    let tagId = model.tagForSlot(2)
    let outputId = model.outputForExternal(ExternalOutputId(2))
    check model.workspaceOutput(tagId) == outputId
    check model.tagHomeOutputTargets[tagId] == "HDMI-A-1"

  test "Output rules pin workspace home output after output appears":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules: @[OutputRule(target: "HDMI-A-1", workspaceSlots: @[2'u32])],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )

    let tagId = model.tagForSlot(2)
    let outputId = model.outputForExternal(ExternalOutputId(2))
    check model.workspaceOutput(tagId) == outputId
    check model.tagHomeOutputTargets[tagId] == "HDMI-A-1"

  test "Workspace rules override output rule workspace affinity":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules: @[OutputRule(target: "HDMI-A-1", workspaceSlots: @[2'u32])],
        tagRules: @[TagRule(tagId: 2, openOnOutput: "DP-1")],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 900, height: 600)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-1"))

    let tagId = model.tagForSlot(2)
    let outputId = model.outputForExternal(ExternalOutputId(3))
    check model.workspaceOutput(tagId) == outputId
    check model.tagHomeOutputTargets[tagId] == "DP-1"

  test "Output rule pinned workspace focus uses configured monitor":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules: @[OutputRule(target: "DP-1", workspaceSlots: @[2'u32])],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

    let pinnedOutput = model.outputForExternal(ExternalOutputId(1))
    let activeOutput = model.outputForExternal(ExternalOutputId(2))
    let tag1 = model.tagForSlot(1)
    let tag2 = model.tagForSlot(2)
    let tag3 = model.tagForSlot(3)
    discard model.setOutputTag(pinnedOutput, tag1)
    discard model.setOutputTag(activeOutput, tag3)
    discard model.setActiveOutput(activeOutput)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.activeOutput == pinnedOutput
    check model.activeTag == tag2
    check model.outputActiveTag(pinnedOutput) == tag2
    check model.outputActiveTag(activeOutput) == tag3
    check model.workspaceOutput(tag2) == pinnedOutput

  test "Workspace rule pinned focus repairs wrong visible output":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        tagRules: @[TagRule(tagId: 2, openOnOutput: "DP-1")],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

    let pinnedOutput = model.outputForExternal(ExternalOutputId(1))
    let wrongOutput = model.outputForExternal(ExternalOutputId(2))
    let tag1 = model.tagForSlot(1)
    let tag2 = model.tagForSlot(2)
    discard model.setOutputTag(pinnedOutput, tag1)
    discard model.setOutputTag(wrongOutput, tag2)
    discard model.setActiveOutput(wrongOutput)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.activeOutput == pinnedOutput
    check model.outputActiveTag(pinnedOutput) == tag2
    check model.outputActiveTag(wrongOutput) != tag2
    check model.workspaceOutput(tag2) == pinnedOutput

  test "Pinned workspace focus falls back while output is missing":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        tagRules: @[TagRule(tagId: 2, openOnOutput: "DP-1")],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

    let fallbackOutput = model.outputForExternal(ExternalOutputId(2))
    let tag2 = model.tagForSlot(2)
    discard model.setActiveOutput(fallbackOutput)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.activeOutput == fallbackOutput
    check model.outputActiveTag(fallbackOutput) == tag2
    check model.tagHomeOutputPinned.contains(tag2)
    check model.tagHomeOutputTargets[tag2] == "DP-1"

  test "Multiple workspaces pinned to one output switch on that output":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 4),
        outputRules: @[OutputRule(target: "DP-1", workspaceSlots: @[2'u32, 4'u32])],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

    let pinnedOutput = model.outputForExternal(ExternalOutputId(1))
    let sideOutput = model.outputForExternal(ExternalOutputId(2))
    let tag1 = model.tagForSlot(1)
    let tag2 = model.tagForSlot(2)
    let tag4 = model.tagForSlot(4)
    discard model.setOutputTag(sideOutput, tag1)
    discard model.setActiveOutput(sideOutput)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    check model.activeOutput == pinnedOutput
    check model.outputActiveTag(pinnedOutput) == tag2
    check model.outputActiveTag(sideOutput) == tag1

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 4))
    check model.activeOutput == pinnedOutput
    check model.outputActiveTag(pinnedOutput) == tag4
    check model.outputActiveTag(sideOutput) == tag1
    check model.workspaceOutput(tag2) == pinnedOutput
    check model.workspaceOutput(tag4) == pinnedOutput

  test "Output focus-at-startup focuses configured output once":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules:
          @[
            OutputRule(
              target: "HDMI-A-1", focusAtStartup: true, workspaceSlots: @[2'u32]
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )

    let outputId = model.outputForExternal(ExternalOutputId(2))
    check model.outputStartupFocusResolved
    check model.activeOutput == outputId
    check model.activeSlot == 1
    check model.outputActiveTag(outputId) == model.tagForSlot(1)
    check model.workspaceOutput(model.tagForSlot(2)) == outputId

  test "Output focus-at-startup does not run on config reload":
    var state =
      initRuntimeStateFromConfig(Config(workspaces: WorkspaceConfig(defaultCount: 3)))
    state.model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    state.model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "eDP-1")
    )
    state.model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    state.model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    let originalOutput = state.model.activeOutput

    discard state.applyRuntimeConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules: @[OutputRule(target: "HDMI-A-1", focusAtStartup: true)],
      )
    )

    check state.model.outputStartupFocusResolved
    check state.model.activeOutput == originalOutput

  test "Output focus-at-startup claims workspace one when unpinned":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules: @[OutputRule(target: "DP-2", focusAtStartup: true)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1920, height: 1080)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 1, outputX: 4480, outputY: 180
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 2560, height: 1440)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1920, outputY: 0
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 1920, height: 1080)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-3"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputPosition, positionOutputId: 3, outputX: 0, outputY: 180)
    )

    let right = model.outputForExternal(ExternalOutputId(1))
    let center = model.outputForExternal(ExternalOutputId(2))
    let left = model.outputForExternal(ExternalOutputId(3))
    let tag1 = model.tagForSlot(1)

    check model.outputStartupFocusResolved
    check model.activeOutput == center
    check model.activeTag == tag1
    check model.outputActiveTag(center) == tag1
    check model.workspaceOutput(tag1) == center
    check model.outputActiveTag(left) != tag1
    check model.outputActiveTag(right) != tag1
    check model.outputActiveTag(left) != model.outputActiveTag(right)

  test "Output commands focus and move active workspace by target":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputPosition, positionOutputId: 1, outputX: 0, outputY: 0)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "HDMI-A-1")
    )

    let outputId = model.outputForExternal(ExternalOutputId(2))
    check model.activeOutput == outputId
    check model.workspaceOutput(model.tagForSlot(2)) == outputId
    check model.outputTags[outputId] == model.tagForSlot(2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusOutput, outputTarget: "left"))
    check model.activeOutput == model.outputForExternal(ExternalOutputId(1))

  test "Layer shell default output follows active output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )

    let first = model.outputForExternal(ExternalOutputId(1))
    let second = model.outputForExternal(ExternalOutputId(2))
    discard model.setActiveOutput(second)

    check model.primaryOutput == first
    check model.activeOutput == second
    check model.activeLayerDefaultOutputRiverId() == 2'u32

  test "External focus on visible secondary workspace moves active output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputPosition, positionOutputId: 1, outputX: 0, outputY: 0)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(1)), model.tagForSlot(1)
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(2)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "left", title: "Left")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 20, appId: "right", title: "Right")
    )
    check model.activeOutput == model.outputForExternal(ExternalOutputId(2))

    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 10))
    check model.activeOutput == model.outputForExternal(ExternalOutputId(1))
    check model.activeTag == model.tagForSlot(1)

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 11, appId: "next", title: "Next")
    )
    check model.snapshotWindow(11).workspaceIdx == 1

  test "Moving workspace to middle output leaves side outputs visible":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1920, height: 1080)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 1, outputX: 4480, outputY: 180
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 2560, height: 1440)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1920, outputY: 0
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 1920, height: 1080)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-3"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputPosition, positionOutputId: 3, outputX: 0, outputY: 180)
    )

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))

    let right = model.outputForExternal(ExternalOutputId(1))
    let middle = model.outputForExternal(ExternalOutputId(2))
    let left = model.outputForExternal(ExternalOutputId(3))
    check model.outputActiveTag(middle) == model.tagForSlot(2)
    check model.outputActiveTag(left) != NullTagId
    check model.outputActiveTag(right) != NullTagId
    check model.outputActiveTag(left) != model.outputActiveTag(middle)
    check model.outputActiveTag(right) != model.outputActiveTag(middle)

    let snapshot = model.shellSnapshot()
    check snapshot.workspaces.anyIt(it.outputName == "DP-3" and it.isOutputVisible)
    check snapshot.workspaces.anyIt(
      it.outputName == "DP-2" and it.isOutputVisible and it.isActive
    )
    check snapshot.workspaces.anyIt(it.outputName == "DP-1" and it.isOutputVisible)

  test "Focusing workspace on third output keeps center workspace visible":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 4))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1920, height: 1080)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 1, outputX: 4480, outputY: 180
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 2560, height: 1440)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1920, outputY: 0
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 1920, height: 1080)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-3"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputPosition, positionOutputId: 3, outputX: 0, outputY: 180)
    )

    let right = model.outputForExternal(ExternalOutputId(1))
    let center = model.outputForExternal(ExternalOutputId(2))
    let left = model.outputForExternal(ExternalOutputId(3))
    let tag1 = model.tagForSlot(1)
    let tag2 = model.tagForSlot(2)
    let tag4 = model.tagForSlot(4)
    discard model.setTagOutput(tag1, right)
    discard model.setTagOutput(tag2, center)
    discard model.setTagOutput(tag4, left)
    discard model.setOutputTag(right, tag1)
    discard model.setOutputTag(center, tag2)
    discard model.setOutputTag(left, tag4)
    discard model.setActiveOutput(center)
    discard model.setActiveWorkspace(tag2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusOutput, outputTarget: "DP-3"))

    check model.activeOutput == left
    check model.activeTag == tag4
    check model.outputActiveTag(center) == tag2
    check model.outputActiveTag(left) == tag4
    check model.tagOutputs[tag2] == center
    check model.tagOutputs[tag4] == left

    let snapshot = model.shellSnapshot()
    check snapshot.workspaces.anyIt(
      it.workspaceIdx == 2 and it.outputName == "DP-2" and it.isOutputVisible
    )
    check snapshot.workspaces.anyIt(
      it.workspaceIdx == 4 and it.outputName == "DP-3" and it.isOutputVisible and
        it.isActive
    )

  test "Layout projection renders output-visible workspaces on their outputs":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1920, height: 1080)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 1, outputX: 4480, outputY: 180
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 2560, height: 1440)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1920, outputY: 0
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 1920, height: 1080)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-3"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputPosition, positionOutputId: 3, outputX: 0, outputY: 180)
    )

    let right = model.outputForExternal(ExternalOutputId(1))
    let middle = model.outputForExternal(ExternalOutputId(2))
    let left = model.outputForExternal(ExternalOutputId(3))
    discard model.setOutputTag(left, model.tagForSlot(1))
    discard model.setOutputTag(middle, model.tagForSlot(2))
    discard model.setOutputTag(right, model.tagForSlot(3))

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "left", title: "Left")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 20, appId: "middle", title: "Middle")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 30, appId: "right", title: "Right")
    )

    let projection = model.layoutProjection()
    check projection.instructions.mapIt(uint32(it.windowId)).contains(10'u32)
    check projection.instructions.mapIt(uint32(it.windowId)).contains(20'u32)
    check projection.instructions.mapIt(uint32(it.windowId)).contains(30'u32)
    check model.instructionGeom(10).fullyWithin(model.outputScreen(left))
    check model.instructionGeom(20).fullyWithin(model.outputScreen(middle))
    check model.instructionGeom(30).fullyWithin(model.outputScreen(right))

  test "Normal render keeps inactive output local focus border unfocused":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(borderWidth: 4),
        workspaces: WorkspaceConfig(defaultCount: 3),
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 2560, height: 1440)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-2"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1920, height: 1080)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-3"))

    let middle = model.outputForExternal(ExternalOutputId(1))
    let left = model.outputForExternal(ExternalOutputId(2))
    let tag1 = model.tagForSlot(1)
    let tag3 = model.tagForSlot(3)
    discard model.setOutputTag(middle, tag1)
    discard model.setOutputTag(left, tag3)

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "term", title: "term")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 30, appId: "files", title: "files")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 31, appId: "shell", title: "shell")
    )
    model.focusExternal(31)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    let localActive = model.windowForExternal(ExternalWindowId(31))
    check model.effectiveTagFocusedWindow(tag3) == localActive
    check model.focusedWindowId() == 10'u32
    check model.renderWindowBorder(localActive, focused = false).width == 4
    check model.renderWindowBorder(localActive, focused = true).width == 4

    var overview = model
    overview.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    check overview.renderWindowBorder(localActive, focused = false).width == 4

  test "Inactive output monocle keeps local focused window visible":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 5))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1200, height: 800)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1200, outputY: 0
      )
    )

    let activeOutput = model.outputForExternal(ExternalOutputId(1))
    let localOutput = model.outputForExternal(ExternalOutputId(2))
    let tag2 = model.tagForSlot(2)
    let tag5 = model.tagForSlot(5)
    discard model.setOutputTag(activeOutput, tag2)
    discard model.setOutputTag(localOutput, tag5)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 5))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("monocle"))
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 50, appId: "kitty", title: "shell")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 51, appId: "kitty", title: "btop")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 20, appId: "browser", title: "web")
    )

    let localFocused = model.windowForExternal(ExternalWindowId(51))
    let projection = model.layoutProjection()
    let localProjected =
      projection.instructions.filterIt(uint32(it.windowId) in [50'u32, 51'u32])

    check model.activeTag == tag2
    check model.effectiveTagFocusedWindow(tag5) == localFocused
    check localProjected.len == 1
    check localProjected[0].windowId == 51'u32
    check localProjected[0].geom.fullyWithin(model.outputScreen(localOutput))

  test "Inactive output local focus keeps border alignment across layouts":
    for layoutId in ["scroller", "dwindle", "bsp-tree", "i3"]:
      let scenario = inactiveOutputLocalFocusScenario(layoutId)
      let localLogical =
        scenario.model.windowForExternal(ExternalWindowId(scenario.localWindow))
      let activeLogical =
        scenario.model.windowForExternal(ExternalWindowId(scenario.activeWindow))
      let projection = scenario.model.layoutProjection()
      let localInstructions =
        projection.instructions.filterIt(it.windowId == scenario.localWindow)
      let activeInstructions =
        projection.instructions.filterIt(it.windowId == scenario.activeWindow)

      check localInstructions.len == 1
      check activeInstructions.len == 1
      check scenario.model.renderWindowBorder(localLogical, focused = false).width == 4
      check scenario.model.renderWindowBorder(activeLogical, focused = true).width == 4

      var daemon = initTriadDaemon()
      daemon.runtimeState.model = scenario.model
      let localState = daemon.desiredRenderWindowState(
        scenario.localWindow, localInstructions[0].geom, scenario.localScreen, false
      )
      let activeState = daemon.desiredRenderWindowState(
        scenario.activeWindow,
        activeInstructions[0].geom,
        scenario.model.activeWorkspaceScreen(),
        false,
      )

      check localState.visible
      check localState.borderWidth == 4
      check localState.renderBorderWidth == 4
      check activeState.visible
      check activeState.focused
      check activeState.borderWidth == 4
      check activeState.renderBorderWidth == 4

  test "Inactive output local focus keeps unfocused aligned tab chrome":
    for layoutId in ["frame-tree", "notion", "i3-tabbed"]:
      let scenario = inactiveOutputLocalFocusScenario(layoutId)
      let localLogical =
        scenario.model.windowForExternal(ExternalWindowId(scenario.localWindow))
      let projection = scenario.model.layoutProjection()
      let bars = projection.frameTabBars.filterIt(it.windowId == scenario.localWindow)

      check scenario.model.renderWindowBorder(localLogical, focused = false).width == 4
      check bars.len == 1
      check not bars[0].focused
      check bars[0].ringWidth == 4

      let matching = projection.instructions.filterIt(it.windowId == bars[0].windowId)
      check matching.len == 1
      check matching[0].geom.x == bars[0].geom.x
      check matching[0].geom.w == bars[0].geom.w
      check matching[0].geom.y == bars[0].geom.y + bars[0].geom.h

  test "Clicking inactive output tabs activates their workspace":
    for layoutId in ["notion", "i3-tabbed"]:
      let scenario = inactiveOutputLocalFocusScenario(layoutId)
      var model = scenario.model
      let tag3 = model.tagForSlot(3)
      let dp3 = model.outputForExternal(ExternalOutputId(2))
      let bars = model.layoutProjection().frameTabBars.filterIt(
          it.windowId == scenario.localWindow
        )

      check bars.len == 1
      check bars[0].tabs.len >= 2
      model.applyMsg(
        Msg(
          kind: MsgKind.WlFrameTabClicked,
          frameClickContainerKind: bars[0].containerKind,
          frameClickContainerId: bars[0].frameId,
          frameClickWindowId: bars[0].tabs[1].windowId,
          frameClickTabIndex: 1,
        )
      )

      check model.activeTag == tag3
      check model.activeOutput == dp3
      check model.focusedWindowId() == 31'u32

  test "Visible workspace focus repairs stale learned output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )
    let right = model.outputForExternal(ExternalOutputId(1))
    let middle = model.outputForExternal(ExternalOutputId(2))
    let tag2 = model.tagForSlot(2)
    discard model.setOutputTag(middle, tag2)
    model.tagOutputs[tag2] = right

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.activeOutput == middle
    check model.workspaceOutput(tag2) == middle
    check model.tagOutputs[tag2] == middle

  test "Active workspace sync follows visible output over stale active output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )

    let first = model.outputForExternal(ExternalOutputId(1))
    let second = model.outputForExternal(ExternalOutputId(2))
    let tag1 = model.tagForSlot(1)
    let tag2 = model.tagForSlot(2)
    discard model.setOutputTag(first, tag1)
    discard model.setOutputTag(second, tag2)
    model.activeTag = tag1
    model.activeSlot = 1
    model.activeOutput = second

    check model.syncPrimaryOutputTag()
    check model.activeOutput == first
    check model.outputActiveTag(first) == tag1
    check model.outputActiveTag(second) == tag2

  test "Focusing nonvisible workspace uses learned home output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )

    let first = model.outputForExternal(ExternalOutputId(1))
    let second = model.outputForExternal(ExternalOutputId(2))
    let tag3 = model.tagForSlot(3)
    discard model.setTagOutput(tag3, second)
    discard model.setActiveOutput(first)
    discard model.setActiveWorkspace(model.tagForSlot(1))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))

    check model.activeOutput == second
    check model.outputActiveTag(second) == tag3
    check model.outputActiveTag(first) != tag3
    check model.tagOutputs[tag3] == second

  test "Unpinned workspace without learned output uses active output fallback":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )

    let first = model.outputForExternal(ExternalOutputId(1))
    let second = model.outputForExternal(ExternalOutputId(2))
    let tag2 = model.tagForSlot(2)
    discard model.clearTagOutput(tag2)
    discard model.setActiveOutput(second)
    discard model.setActiveWorkspace(model.tagForSlot(1))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.activeOutput == second
    check model.outputActiveTag(second) == tag2
    check model.outputActiveTag(first) != tag2

  test "New window uses selected output visible workspace":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )

    let first = model.outputForExternal(ExternalOutputId(1))
    let second = model.outputForExternal(ExternalOutputId(2))
    let tag1 = model.tagForSlot(1)
    let tag2 = model.tagForSlot(2)
    discard model.setOutputTag(first, tag1)
    discard model.setOutputTag(second, tag2)
    model.activeTag = tag1
    model.activeSlot = 1
    model.activeOutput = second

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 11, appId: "kitty", title: "Term")
    )

    check model.snapshotWindow(11).workspaceIdx == 2
    check model.instructionGeom(11).fullyWithin(model.outputScreen(second))
    check model.outputActiveTag(first) == tag1
    check model.outputActiveTag(second) == tag2
    check model.workspaceOutput(tag2) == second

  test "Spawn context places new window on launcher output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )

    let left = model.outputForExternal(ExternalOutputId(1))
    let right = model.outputForExternal(ExternalOutputId(2))
    discard model.setOutputTag(left, model.tagForSlot(1))
    discard model.setOutputTag(right, model.tagForSlot(2))
    discard model.setActiveOutput(left)
    discard model.setActiveWorkspace(model.tagForSlot(1))

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 12,
        appId: "spawned",
        title: "Spawned",
        spawnContextOutputId: uint32(right),
        spawnContextSlot: 2,
      )
    )

    check model.activeOutput == left
    check model.snapshotWindow(12).workspaceIdx == 2
    check model.instructionGeom(12).fullyWithin(model.outputScreen(right))

  test "Explicit workspace rule overrides spawn context":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules: @[WindowRule(appIdMatch: "ruled", defaultWorkspace: 1)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )

    let left = model.outputForExternal(ExternalOutputId(1))
    let right = model.outputForExternal(ExternalOutputId(2))
    discard model.setOutputTag(left, model.tagForSlot(1))
    discard model.setOutputTag(right, model.tagForSlot(2))

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 13,
        appId: "ruled",
        title: "Ruled",
        spawnContextOutputId: uint32(right),
        spawnContextSlot: 2,
      )
    )

    check model.snapshotWindow(13).workspaceIdx == 1
    check model.instructionGeom(13).fullyWithin(model.outputScreen(left))

  test "Spawn-context floating window uses launcher output geometry":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[WindowRule(appIdMatch: "float", openFloatingSet: true, openFloating: true)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )

    let left = model.outputForExternal(ExternalOutputId(1))
    let right = model.outputForExternal(ExternalOutputId(2))
    discard model.setOutputTag(left, model.tagForSlot(1))
    discard model.setOutputTag(right, model.tagForSlot(2))
    discard model.setActiveOutput(left)
    discard model.setActiveWorkspace(model.tagForSlot(1))

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 14,
        appId: "float",
        title: "Float",
        spawnContextOutputId: uint32(right),
        spawnContextSlot: 2,
      )
    )

    let geom = model.snapshotWindow(14).floatingGeom
    check model.snapshotWindow(14).workspaceIdx == 2
    check geom.fullyWithin(model.outputScreen(right))

  test "Command focus on visible output makes new windows open there":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )
    let left = model.outputForExternal(ExternalOutputId(1))
    let right = model.outputForExternal(ExternalOutputId(2))
    discard model.setOutputTag(left, model.tagForSlot(1))
    discard model.setOutputTag(right, model.tagForSlot(2))

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "left", title: "Left")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 20, appId: "right", title: "Right")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 10))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 11, appId: "next", title: "Next")
    )

    check model.activeOutput == left
    check model.snapshotWindow(11).workspaceIdx == 1
    check model.instructionGeom(11).fullyWithin(model.outputScreen(left))

  test "Floating windows use the focused output coordinate space":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[WindowRule(appIdMatch: "float", openFloatingSet: true, openFloating: true)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )
    let left = model.outputForExternal(ExternalOutputId(1))
    let right = model.outputForExternal(ExternalOutputId(2))
    discard model.setOutputTag(left, model.tagForSlot(1))
    discard model.setOutputTag(right, model.tagForSlot(2))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 20, appId: "float", title: "Float")
    )

    let geom = model.snapshotWindow(20).floatingGeom
    check model.activeOutput == right
    check geom.fullyWithin(model.outputScreen(right))
    check geom.x >= model.outputScreen(right).x
    check geom.x < model.outputScreen(right).x + model.outputScreen(right).w

  test "Overview preview slots are scoped to the focused output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 800, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-3"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 3, outputX: 1900, outputY: 0
      )
    )
    let left = model.outputForExternal(ExternalOutputId(1))
    let middle = model.outputForExternal(ExternalOutputId(2))
    let right = model.outputForExternal(ExternalOutputId(3))
    discard model.setOutputTag(left, model.tagForSlot(1))
    discard model.setOutputTag(middle, model.tagForSlot(2))
    discard model.setOutputTag(right, model.tagForSlot(3))

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "one", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 20, appId: "two", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 30, appId: "three", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.activeOutput == middle
    check model.previewSlots() == @[2'u32]
    check model.previewSlotsForOutput(left) == @[1'u32]
    check model.previewSlotsForOutput(middle) == @[2'u32]
    check model.previewSlotsForOutput(right) == @[3'u32]

    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    let projection = model.layoutProjection()
    let ids = projection.instructions.mapIt(uint32(it.windowId))
    check ids.contains(10'u32)
    check ids.contains(20'u32)
    check ids.contains(30'u32)
    check model.instructionGeom(10).fullyWithin(model.outputScreen(left))
    check model.instructionGeom(20).fullyWithin(model.outputScreen(middle))
    check model.instructionGeom(30).fullyWithin(model.outputScreen(right))

  test "Output-visible dynamic workspaces survive pruning":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 1))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-3"))

    let second = model.outputForExternal(ExternalOutputId(2))
    let third = model.outputForExternal(ExternalOutputId(3))
    let secondTag = model.outputActiveTag(second)
    let thirdTag = model.outputActiveTag(third)
    check secondTag != NullTagId
    check thirdTag != NullTagId
    check model.tagData(secondTag).isSome
    check model.tagData(thirdTag).isSome

    discard model.pruneDynamicWorkspaces()

    check model.outputActiveTag(second) == secondTag
    check model.outputActiveTag(third) == thirdTag
    check model.tagData(secondTag).isSome
    check model.tagData(thirdTag).isSome

  test "New workspace opens on active output and prunes empty after leaving":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

    let first = model.outputForExternal(ExternalOutputId(1))
    let second = model.outputForExternal(ExternalOutputId(2))
    let firstTag = model.outputActiveTag(first)
    let previousSecondTag = model.outputActiveTag(second)
    discard model.setActiveOutput(second)

    model.applyMsg(Msg(kind: MsgKind.CmdNewWorkspace))

    let dynamicTag = model.tagForSlot(3)
    check dynamicTag != NullTagId
    check model.activeOutput == second
    check model.activeTag == dynamicTag
    check model.outputActiveTag(first) == firstTag
    check model.outputActiveTag(second) == dynamicTag
    check model.workspaceOutput(dynamicTag) == second

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    check model.tagData(dynamicTag).isNone
    check model.outputActiveTag(second) == previousSecondTag

  test "New workspace with a window keeps its output home after leaving":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

    let first = model.outputForExternal(ExternalOutputId(1))
    let second = model.outputForExternal(ExternalOutputId(2))
    discard model.setActiveOutput(second)

    model.applyMsg(Msg(kind: MsgKind.CmdNewWorkspace))
    let dynamicTag = model.tagForSlot(3)
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 40, appId: "term", title: "term")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    check model.activeOutput == first
    check model.tagData(dynamicTag).isSome
    check model.outputActiveTag(second) == dynamicTag
    check model.workspaceOutput(dynamicTag) == second

  test "New workspace reuses hidden empty dynamic workspace":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))

    let outputId = model.outputForExternal(ExternalOutputId(1))
    discard model.setActiveOutput(outputId)
    let emptyTag = model.ensureWorkspaceSlot(4)
    discard model.setTagName(emptyTag, "code")
    let occupiedTag = model.ensureWorkspaceSlot(5)
    discard model.setActiveWorkspace(occupiedTag)
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 50, appId: "term", title: "term")
    )
    discard model.setActiveWorkspace(model.tagForSlot(1))
    model.refreshVisibleWorkspaceSlots()

    check model.trailingWorkspaceSlot() == 0
    check model.visibleWorkspaceSlots().find(6'u32) == -1

    model.applyMsg(Msg(kind: MsgKind.CmdNewWorkspace))

    check model.activeTag == emptyTag
    check model.outputActiveTag(outputId) == emptyTag
    check model.tagForSlot(6) == NullTagId

  test "Hidden empty dynamic workspace focuses on active output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

    let first = model.outputForExternal(ExternalOutputId(1))
    let second = model.outputForExternal(ExternalOutputId(2))
    discard model.setActiveOutput(second)
    let dynamicTag = model.ensureWorkspaceSlot(4)
    check model.workspaceOutput(dynamicTag) == second

    discard model.setActiveOutput(first)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 4))

    check model.activeOutput == first
    check model.outputActiveTag(first) == dynamicTag
    check model.workspaceOutput(dynamicTag) == first

  test "Hidden occupied dynamic workspace keeps learned output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

    let first = model.outputForExternal(ExternalOutputId(1))
    let second = model.outputForExternal(ExternalOutputId(2))
    discard model.setActiveOutput(second)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 4))
    let dynamicTag = model.tagForSlot(4)
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 41, appId: "term", title: "term")
    )
    discard model.setOutputTag(second, model.tagForSlot(2))
    discard model.setActiveOutput(first)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 4))

    check model.activeOutput == second
    check model.outputActiveTag(second) == dynamicTag
    check model.workspaceOutput(dynamicTag) == second

  test "Active workspace output sync keeps visible workspace anchored":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))

    let first = model.outputForExternal(ExternalOutputId(1))
    let second = model.outputForExternal(ExternalOutputId(2))
    let tagId = model.tagForSlot(2)
    check model.outputActiveTag(second) == tagId

    discard model.setActiveOutput(first)
    discard model.syncPrimaryOutputTag()

    check model.activeOutput == second
    check model.outputActiveTag(first) != tagId
    check model.outputActiveTag(second) == tagId

  test "Live restore preserves primary output visible workspace":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 4))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 4))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-1"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))

    let restore = parseLiveRestoreJson(model.liveRestoreJson()).get()
    var restoredModel = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 4))
    ).model
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1")
    )
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2")
    )
    restoredModel.applyMsg(
      Msg(
        kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0
      )
    )
    restoredModel.applyLiveRestore(restore.pendingRestoreState())

    let primary = restoredModel.outputForExternal(ExternalOutputId(1))
    let second = restoredModel.outputForExternal(ExternalOutputId(2))
    check restoredModel.outputActiveTag(primary) == restoredModel.tagForSlot(4)
    check restoredModel.outputActiveTag(second) == restoredModel.tagForSlot(2)
    check restoredModel.activeWorkspaceSlot() == 2

  test "Live restore suppresses startup output focus":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        outputRules: @[OutputRule(target: "DP-2", focusAtStartup: true)],
      )
    ).model
    var restore = PendingRestoreState(activeSlot: 3)
    model.applyLiveRestore(restore)

    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

    check model.activeWorkspaceSlot() == 3

  test "Live restore preserves nonvisible workspace home output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 4))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-3"))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 4))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-3"))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 40, appId: "chat", title: "chat")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))

    let restore = parseLiveRestoreJson(model.liveRestoreJson()).get()
    check restore.tagOutputs[4] == 3'u32

    var restoredModel = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 4))
    ).model
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1")
    )
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 700)
    )
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2")
    )
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 1000, height: 700)
    )
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-3")
    )
    restoredModel.applyLiveRestore(restore.pendingRestoreState())
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 40, appId: "chat", title: "chat")
    )

    var workspace4 = ShellWorkspace()
    for workspace in restoredModel.shellSnapshot().workspaces:
      if workspace.tagId == 4:
        workspace4 = workspace
    check workspace4.tagId == 4
    check workspace4.occupied
    check not workspace4.isOutputVisible
    check workspace4.outputName == "DP-3"

  test "Moved workspace restores to reconnected output":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "HDMI-A-1")
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: 2))

    check model.workspaceOutput(model.tagForSlot(2)) == model.primaryOutput

    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )

    let outputId = model.outputForExternal(ExternalOutputId(2))
    check model.workspaceOutput(model.tagForSlot(2)) == outputId
    check model.outputTags[outputId] == model.tagForSlot(2)

  test "Window rule open-on-output matches stable output identity":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              openOnOutput: "Dell Inc. DELL U2720Q Unknown",
              openFocusedSet: true,
              openFocused: false,
            ),
            WindowRule(
              appIdMatch: "docs",
              openOnOutput: "benq pd3220u",
              openFocusedSet: true,
              openFocused: false,
            ),
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputIdentity,
        identityOutputId: 2,
        outputMake: "Dell Inc.",
        outputModel: "DELL U2720Q",
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 900, height: 700)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputDescription,
        descriptionOutputId: 3,
        outputDescription: "BenQ PD3220U",
      )
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(2)
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(3)), model.tagForSlot(3)
    )

    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 4, appId: "chat"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 5, appId: "docs"))

    check model.snapshotWindow(4).workspaceIdx == 2
    check model.snapshotWindow(5).workspaceIdx == 3

  test "Window rule open-on-output ignores unknown-only identity":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              openOnOutput: "Unknown Unknown Unknown",
              openFocusedSet: true,
              openFocused: false,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOutputIdentity,
        identityOutputId: 2,
        outputMake: "Unknown",
        outputModel: "Unknown",
      )
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(2)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    check model.snapshotWindow(3).workspaceIdx == 1

  test "Window rule open-on-output falls back when output is unknown":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules: @[WindowRule(appIdMatch: "chat", openOnOutput: "missing")],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    check model.snapshotWindow(3).workspaceIdx == 1

  test "Window rule default workspace remaps safe open-on-output":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              defaultWorkspace: 3,
              openOnOutput: "HDMI-A-1",
              openFocusedSet: true,
              openFocused: false,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(2)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    check model.snapshotWindow(3).workspaceIdx == 3
    check model.workspaceOutput(model.tagForSlot(3)) ==
      model.outputForExternal(ExternalOutputId(2))
    check model.activeTag == model.tagForSlot(1)

  test "Window rule output remap moves workspace between non-primary outputs":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 4),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              defaultWorkspace: 3,
              openOnOutput: "DP-2",
              openFocusedSet: true,
              openFocused: false,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 3, width: 900, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 3, outputName: "DP-2"))
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(3)
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(3)), model.tagForSlot(2)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    let hdmi = model.outputForExternal(ExternalOutputId(2))
    let dp = model.outputForExternal(ExternalOutputId(3))
    check model.snapshotWindow(3).workspaceIdx == 3
    check model.workspaceOutput(model.tagForSlot(3)) == dp
    check model.outputTags[dp] == model.tagForSlot(3)
    check model.outputTags.getOrDefault(hdmi, NullTagId) != model.tagForSlot(3)

  test "Window rule output remap does not change active primary workspace":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "chat",
              defaultWorkspace: 2,
              openOnOutput: "eDP-1",
              openFocusedSet: true,
              openFocused: false,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "eDP-1")
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "chat", title: "Main")
    )

    check model.snapshotWindow(3).workspaceIdx == 2
    check model.activeTag == model.tagForSlot(1)
    check model.outputTags[model.primaryOutput] == model.tagForSlot(1)

  test "Parented windows do not remap outputs for workspace rules":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "dialog",
              defaultWorkspace: 3,
              openOnOutput: "HDMI-A-1",
              openFocusedSet: true,
              openFocused: false,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(2)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "parent", title: "Main")
    )

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 11,
        createdParentWindowId: 10,
        appId: "dialog",
        title: "Dialog",
      )
    )

    check model.snapshotWindow(11).workspaceIdx == 3
    check model.outputTags[model.outputForExternal(ExternalOutputId(2))] ==
      model.tagForSlot(2)

  test "Live restore state wins over opening sizing and output rules":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "generic-app",
              defaultWorkspaces: @[2'u32, 3'u32],
              openOnOutput: "HDMI-A-1",
              defaultColumnWidthSet: true,
              defaultColumnWidth: 0.30,
              defaultWindowWidthSet: true,
              defaultWindowWidth: 0.40,
              defaultWindowHeightSet: true,
              defaultWindowHeight: 0.50,
              openNamedScratchpad: "files",
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 800, height: 600)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "HDMI-A-1")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    discard model.setOutputTag(
      model.outputForExternal(ExternalOutputId(2)), model.tagForSlot(2)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    var restore = PendingRestoreState(activeSlot: 1)
    restore.addRestoredWindow(ExternalWindowId(50), 1, "generic-app", "Old title")
    model.applyLiveRestore(restore)

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 50,
        appId: "generic-app",
        title: "Old title",
      )
    )
    let placement =
      model.firstWindowPosition(model.windowForExternal(ExternalWindowId(50)))
    let win = model.snapshotWindow(50)

    check win.workspaceIdx == 1
    check win.widthProportion == 0.8'f32
    check win.heightProportion == 0.6'f32
    check model.scratchpadWindowCount() == 0
    check model.namedScratchpadWindow("files") == NullWindowId
    check placement.found
    check model.placementForWindowOnTag(
      model.tagForSlot(3), model.windowForExternal(ExternalWindowId(50))
    ).isNone
    let columnId = model.columnAt(placement.tagId, int(placement.colIdx) - 1)
    check model.columnData(columnId).get().widthProportion == 0.7'f32

  test "Window rule open-on-all-workspaces places sticky windows everywhere":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "status",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 20, appId: "status", title: "bar")
    )
    let winId = model.windowForExternal(ExternalWindowId(20))

    check model.windowData(winId).get().isSticky
    for slot in 1'u32 .. 3'u32:
      check model.placementForWindowOnTag(model.tagForSlot(slot), winId).isSome
    for workspace in model.shellSnapshot().workspaces:
      check not workspace.occupied

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    check model.activeWorkspaceFocusId() == 20
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 21, appId: "local", title: "main")
    )
    check model.activeWorkspaceFocusId() == 21

  test "Window rule open-on-all-workspaces obeys later explicit false":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "app", openOnAllWorkspacesSet: true, openOnAllWorkspaces: true
            ),
            WindowRule(
              appIdMatch: "app",
              titleMatch: "single",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: false,
            ),
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 22, appId: "app", title: "single")
    )
    let winId = model.windowForExternal(ExternalWindowId(22))

    check not model.windowData(winId).get().isSticky
    check model.placementForWindowOnTag(model.tagForSlot(1), winId).isSome
    check model.placementForWindowOnTag(model.tagForSlot(2), winId).isNone

  test "Window rule open-overlay creates managed overlay without floating":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules: @[WindowRule(appIdMatch: "hud", openOverlay: true)],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 30, appId: "hud", title: "HUD")
    )
    let winId = model.windowForExternal(ExternalWindowId(30))
    let win = model.windowData(winId).get()
    let snapshot = model.shellSnapshot()
    let shellWin = snapshotWindow(model, 30)
    let stateJson = triadStateJson(snapshot)

    check win.isOverlay
    check not win.isFloating
    check shellWin.isOverlay
    check stateJson["windows"][0]["is_overlay"].getBool()

  test "Window rule open-overlay refreshes on dynamic rule changes":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 1))
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 31, appId: "panel", title: "Main")
    )
    let winId = model.windowForExternal(ExternalWindowId(31))
    check not model.windowData(winId).get().isOverlay

    model.applyConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 1),
        windowRules: @[WindowRule(appIdMatch: "panel", openOverlay: true)],
      )
    )
    check model.windowData(winId).get().isOverlay

    model.applyConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 1),
        windowRules:
          @[
            WindowRule(appIdMatch: "panel", openOverlay: true),
            WindowRule(
              appIdMatch: "panel",
              titleMatch: "Main",
              openOverlaySet: true,
              openOverlay: false,
            ),
          ],
      )
    )
    check not model.windowData(winId).get().isOverlay

  test "Overlay render order is above normal managed windows":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 1),
        windowRules: @[WindowRule(appIdMatch: "hud", openOverlay: true)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 32, appId: "term", title: "A")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 33, appId: "hud", title: "HUD")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 34, appId: "term", title: "B")
    )

    var daemon = initTriadDaemon()
    daemon.runtimeState.model = model
    daemon.recordDesiredPlacement(
      RenderInstruction(windowId: 32, geom: Rect(x: 0, y: 0, w: 100, h: 100))
    )
    daemon.recordDesiredPlacement(
      RenderInstruction(windowId: 33, geom: Rect(x: 0, y: 0, w: 100, h: 100))
    )
    daemon.recordDesiredPlacement(
      RenderInstruction(windowId: 34, geom: Rect(x: 0, y: 0, w: 100, h: 100))
    )
    let order = daemon.orderedDesiredInstructions().mapIt(uint32(it.windowId))

    check order[^1] == 33'u32

  test "Sticky windows sync to dynamic workspaces without pinning them occupied":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 1),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "status",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 23, appId: "status", title: "bar")
    )
    let winId = model.windowForExternal(ExternalWindowId(23))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 4))

    check model.tagForSlot(4) != NullTagId
    check model.placementForWindowOnTag(model.tagForSlot(4), winId).isSome
    check model.activeWorkspaceFocusId() == 23

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 1))
    discard model.pruneDynamicWorkspaces()
    check model.tagForSlot(4) == NullTagId

  test "Parented dialog sticky rules require plain parented role":
    var dialogModel = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "child",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model
    dialogModel.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 24, appId: "parent", title: "main")
    )
    dialogModel.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 25,
        createdParentWindowId: 24,
        appId: "child",
        title: "dialog",
      )
    )
    let dialogId = dialogModel.windowForExternal(ExternalWindowId(25))
    check not dialogModel.windowData(dialogId).get().isSticky
    check dialogModel.placementForWindowOnTag(dialogModel.tagForSlot(2), dialogId).isNone

    var plainModel = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "child",
              parentedRoleSet: true,
              parentedRole: ParentedRole.Plain,
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model
    plainModel.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 26, appId: "parent", title: "main")
    )
    plainModel.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 27,
        createdParentWindowId: 26,
        appId: "child",
        title: "plain",
      )
    )
    let plainId = plainModel.windowForExternal(ExternalWindowId(27))
    check plainModel.windowData(plainId).get().isSticky
    check plainModel.placementForWindowOnTag(plainModel.tagForSlot(2), plainId).isSome

  test "Scratchpad clears sticky state and restores previous tag set":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "status",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 28, appId: "status", title: "bar")
    )
    let winId = model.windowForExternal(ExternalWindowId(28))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))

    check not model.windowData(winId).get().isSticky
    check model.placementForWindowOnTag(model.tagForSlot(1), winId).isNone
    check model.placementForWindowOnTag(model.tagForSlot(2), winId).isNone

    model.applyMsg(Msg(kind: MsgKind.CmdRestoreScratchpad))
    check not model.windowData(winId).get().isSticky
    check model.placementForWindowOnTag(model.tagForSlot(1), winId).isSome
    check model.placementForWindowOnTag(model.tagForSlot(2), winId).isSome

  test "Live restore preserves scratchpad restore workspace":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 29, appId: "term", title: "home")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))

    let restore = parseLiveRestoreJson(model.liveRestoreJson()).get()
    var restoredModel = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    restoredModel.applyLiveRestore(restore.pendingRestoreState())
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 29, appId: "term", title: "home")
    )
    restoredModel.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    restoredModel.applyMsg(Msg(kind: MsgKind.CmdRestoreScratchpad))

    let restoredId = restoredModel.windowForExternal(ExternalWindowId(29))
    check restoredModel.activeWorkspaceSlot() == 1
    check restoredModel.placementForWindowOnTag(restoredModel.tagForSlot(1), restoredId).isSome
    check restoredModel.placementForWindowOnTag(restoredModel.tagForSlot(2), restoredId).isNone

  test "Live restore preserves sticky window state":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "status",
              openOnAllWorkspacesSet: true,
              openOnAllWorkspaces: true,
            )
          ],
      )
    ).model

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 29, appId: "status", title: "bar")
    )
    check model.restoreWindowJson(29)["is_sticky"].getBool()
    let restore = parseLiveRestoreJson(model.liveRestoreJson()).get()

    var restoredModel = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    restoredModel.applyLiveRestore(restore.pendingRestoreState())
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 29, appId: "status", title: "bar")
    )
    let restoredId = restoredModel.windowForExternal(ExternalWindowId(29))

    check restoredModel.windowData(restoredId).get().isSticky
    check restoredModel.placementForWindowOnTag(restoredModel.tagForSlot(1), restoredId).isSome
    check restoredModel.placementForWindowOnTag(restoredModel.tagForSlot(2), restoredId).isSome
