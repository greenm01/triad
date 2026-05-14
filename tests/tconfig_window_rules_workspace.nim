import tconfig_support

suite "KDL Configuration Parser: window rules workspace":
  test "Window rule parser preserves explicit false policy fields":
    let path = getTempDir() / "triad-window-rule-explicit-false.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="demo"
  parented-role "dialog"
  open-fullscreen #false
  open-maximized #false
  open-maximized-to-edges #false
  open-on-all-workspaces #false
  open-overlay #false
  open-unmanaged-global #false
  terminal #false
  allow-swallow #false
  maximize-policy "ignore"
  respect-size-hints #false
  center-floating #false
  dialog-viewport-jump #false
  keyboard-shortcuts-inhibit #false
  idle-inhibit "none"
  presentation-mode "default"
  border { width 0 }
  focus-ring { width 0 }
  clip-to-geometry #false
  tiled-state #false
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].parentedRoleSet
    check config.windowRules[0].parentedRole == ParentedRole.Dialog
    check config.windowRules[0].openFullscreenSet
    check not config.windowRules[0].openFullscreen
    check config.windowRules[0].openMaximizedSet
    check not config.windowRules[0].openMaximized
    check config.windowRules[0].openMaximizedToEdgesSet
    check not config.windowRules[0].openMaximizedToEdges
    check config.windowRules[0].openOnAllWorkspacesSet
    check not config.windowRules[0].openOnAllWorkspaces
    check config.windowRules[0].openOverlaySet
    check not config.windowRules[0].openOverlay
    check config.windowRules[0].openUnmanagedGlobalSet
    check not config.windowRules[0].openUnmanagedGlobal
    check config.windowRules[0].terminalSet
    check not config.windowRules[0].terminal
    check config.windowRules[0].allowSwallowSet
    check not config.windowRules[0].allowSwallow
    check config.windowRules[0].maximizePolicySet
    check config.windowRules[0].maximizePolicy == WindowRuleMaximizePolicy.Ignore
    check config.windowRules[0].respectSizeHintsSet
    check not config.windowRules[0].respectSizeHints
    check config.windowRules[0].centerFloatingSet
    check not config.windowRules[0].centerFloating
    check config.windowRules[0].dialogViewportJumpSet
    check not config.windowRules[0].dialogViewportJump
    check config.windowRules[0].keyboardShortcutsInhibitSet
    check not config.windowRules[0].keyboardShortcutsInhibit
    check config.windowRules[0].idleInhibitModeSet
    check config.windowRules[0].idleInhibitMode ==
      WindowRuleIdleInhibitMode.IdleInhibitNone
    check config.windowRules[0].presentationModeSet
    check config.windowRules[0].presentationMode == PresentationMode.PresentationDefault
    check config.windowRules[0].border.widthSet
    check config.windowRules[0].border.width == 0
    check config.windowRules[0].focusRing.widthSet
    check config.windowRules[0].focusRing.width == 0
    check config.windowRules[0].clipToGeometrySet
    check not config.windowRules[0].clipToGeometry
    check config.windowRules[0].tiledStateSet
    check not config.windowRules[0].tiledState

  test "Window rule parser clamps opening sizing proportions":
    let path = getTempDir() / "triad-window-rule-sizing.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="demo"
  open-on-output "DP-1"
  default-column-width { proportion 2.0 }
  scroller-proportion { proportion 0.65 }
  scroller-single-proportion { proportion 0.0 }
  default-window-width { proportion 0.0 }
  default-window-height { proportion 0.4 }
  floating {
    width -12
    height 70000
  }
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].openOnOutput == "DP-1"
    check config.windowRules[0].defaultColumnWidthSet
    check config.windowRules[0].defaultColumnWidth == 1.0'f32
    check config.windowRules[0].scrollerProportionSet
    check config.windowRules[0].scrollerProportion == 0.65'f32
    check config.windowRules[0].scrollerSingleProportionSet
    check config.windowRules[0].scrollerSingleProportion == 0.05'f32
    check config.windowRules[0].defaultWindowWidthSet
    check config.windowRules[0].defaultWindowWidth == 0.05'f32
    check config.windowRules[0].defaultWindowHeightSet
    check config.windowRules[0].defaultWindowHeight == 0.4'f32
    check config.windowRules[0].floating.widthSet
    check config.windowRules[0].floating.width == 1
    check config.windowRules[0].floating.heightSet
    check config.windowRules[0].floating.height == 65535

  test "Window rule parser ignores empty named scratchpad targets":
    let path = getTempDir() / "triad-window-rule-empty-scratchpad.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="demo"
  open-named-scratchpad ""
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].openNamedScratchpad.len == 0

  test "Window rule parser lets latest floating size field win per axis":
    let path = getTempDir() / "triad-window-rule-floating-size-order.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="demo"
  floating {
    width-ratio 0.25
    width 900
    height 480
    height-ratio 0.5
  }
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].floating.widthSet
    check not config.windowRules[0].floating.widthRatioSet
    check config.windowRules[0].floating.width == 900
    check config.windowRules[0].floating.heightRatioSet
    check not config.windowRules[0].floating.heightSet
    check config.windowRules[0].floating.heightRatio == 0.5'f32

  test "Window rule parser clamps size bounds and preserves explicit zero":
    let path = getTempDir() / "triad-window-rule-bounds.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="demo"
  min-width -1
  min-height 400
  max-width 70000
  max-height 0
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].minWidthSet
    check config.windowRules[0].minWidth == 0
    check config.windowRules[0].minHeightSet
    check config.windowRules[0].minHeight == 400
    check config.windowRules[0].maxWidthSet
    check config.windowRules[0].maxWidth == 65535
    check config.windowRules[0].maxHeightSet
    check config.windowRules[0].maxHeight == 0

  test "Window rule parser reads multiple matches and excludes":
    let path = getTempDir() / "triad-window-rule-matchers.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="^org\\.gimp\\." title="Welcome" is-focused=#true is-active=#false at-startup=#true
  match app-id="^gimp-tool$" is-floating=#true is-active-in-column=#false
  exclude title="Private" is-floating=#false at-startup=#false
  default-workspace 4
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].matches.len == 2
    check config.windowRules[0].matches[0].appIdSet
    check config.windowRules[0].matches[0].appId == "^org\\.gimp\\."
    check config.windowRules[0].matches[0].titleSet
    check config.windowRules[0].matches[0].title == "Welcome"
    check config.windowRules[0].matches[0].isFocusedSet
    check config.windowRules[0].matches[0].isFocused
    check config.windowRules[0].matches[0].isActiveSet
    check not config.windowRules[0].matches[0].isActive
    check config.windowRules[0].matches[0].atStartupSet
    check config.windowRules[0].matches[0].atStartup
    check config.windowRules[0].matches[1].appIdSet
    check config.windowRules[0].matches[1].appId == "^gimp-tool$"
    check config.windowRules[0].matches[1].isFloatingSet
    check config.windowRules[0].matches[1].isFloating
    check config.windowRules[0].matches[1].isActiveInColumnSet
    check not config.windowRules[0].matches[1].isActiveInColumn
    check config.windowRules[0].excludes.len == 1
    check config.windowRules[0].excludes[0].titleSet
    check config.windowRules[0].excludes[0].title == "Private"
    check config.windowRules[0].excludes[0].isFloatingSet
    check not config.windowRules[0].excludes[0].isFloating
    check config.windowRules[0].excludes[0].atStartupSet
    check not config.windowRules[0].excludes[0].atStartup

  test "Window rule parser reads multi-workspace targets":
    let path = getTempDir() / "triad-window-rule-workspaces.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="multi"
  default-workspaces 2 4 2 0
}

window-rule {
  match app-id="plural-wins"
  default-workspace 2
  default-workspaces 5 3 5
}

window-rule {
  match app-id="singular-wins"
  default-workspaces 2 3
  default-workspace 4
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 3
    check config.windowRules[0].defaultWorkspace == 2
    check config.windowRules[0].defaultWorkspaces == @[2'u32, 4'u32]
    check config.windowRules[1].defaultWorkspace == 5
    check config.windowRules[1].defaultWorkspaces == @[5'u32, 3'u32]
    check config.windowRules[2].defaultWorkspace == 4
    check config.windowRules[2].defaultWorkspaces == @[4'u32]

  test "workspace config uses global default layout and explicit overrides":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2, defaultLayout: LayoutMode.Deck),
        tagRules:
          @[
            TagRule(
              tagId: 1,
              name: "term",
              defaultLayoutSet: true,
              defaultLayout: LayoutMode.Grid,
            ),
            TagRule(tagId: 3, name: "dynamic"),
          ],
      )
    ).model

    var snapshot = model.shellSnapshot()
    check snapshot.workspaces[0].name == "term"
    check snapshot.workspaces[0].layoutMode == LayoutMode.Grid
    check snapshot.workspaces[1].layoutMode == LayoutMode.Deck

    let dynamicTag = model.ensureWorkspaceSlot(3)
    check dynamicTag != NullTagId
    let dynamic = model.tagData(dynamicTag)
    check dynamic.isSome
    check dynamic.get().name == "dynamic"
    check dynamic.get().layoutMode == LayoutMode.Deck

  test "legacy tag config names are not accepted":
    let path = getTempDir() / "triad-legacy-tag-config.kdl"
    writeFile(
      path,
      """
workspaces { default-count 3 }
tag-rules {
  tag 2 name="web" default-layout="grid"
}
window-rule {
  match app-id="qemu"
  default-tag 3
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.tagRules.len == 0
    check config.windowRules.len == 1
    check config.windowRules[0].defaultWorkspace == 0

  test "overview hot corner geometry follows output bounds":
    var model = initRuntimeStateFromConfig(
      Config(
        overview: OverviewConfig(
          hotCorners:
            OverviewHotCornersConfig(size: 10, topLeft: true, bottomRight: true)
        )
      )
    ).model
    discard model.addOutput(ExternalOutputId(1), x = 0, y = 0, w = 100, h = 100)
    discard model.addOutput(ExternalOutputId(2), x = 100, y = 0, w = 100, h = 100)

    check model.overviewHotCornerAt(0, 0)
    check model.overviewHotCornerAt(199, 99)
    check not model.overviewHotCornerAt(99, 0)
    check not model.overviewHotCornerAt(50, 50)
