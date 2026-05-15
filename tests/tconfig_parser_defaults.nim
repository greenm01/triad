import tconfig_support

suite "KDL Configuration Parser: parser defaults":
  test "Parser reads layout, workspace, binding, and command settings":
    let path = getCurrentDir() / "test_config_dod.kdl"
    writeFile(
      path,
      """
layout {
  gaps 32
  center-focused-column "always"
  default-column-width { proportion 0.7 }
  default-window-width { proportion 0.8 }
  default-window-height { proportion 0.9 }
  master {
    count 2
    split-ratio 0.6
  }
  border {
    width 3
    active-color "#112233"
    inactive-color "#445566"
  }
  scroller-focus-center #true
  scroller-prefer-center #true
  scroller-proportion-presets 1.2 0.25 0.5 0.5
  enable-animations #false
  animation-speed 0.4
  animation-snap-threshold 2.5
  smart-gaps #true
  layout-cycle "scroller" "deck" "vertical-grid"
}
workspaces {
  default-count 4
  default-layout "scroller"
}
output "HDMI-A-1" {
  focus-at-startup
  workspaces 2 4 -1 2
}
output "DP-1" {
  workspaces "invalid"
}
workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web" default-layout="grid" open-on-output="HDMI-A-1"
}
window-rule {
  match app-id="qemu"
  default-workspace 3
  open-on-output "HDMI-A-1"
  open-named-scratchpad "files"
  default-column-width { proportion 0.65 }
  default-window-width { proportion 0.75 }
  default-window-height { proportion 0.85 }
  min-width 640
  min-height 400
  max-width 1920
  max-height 1200
  open-floating #true
  open-focused #false
  open-fullscreen #false
  open-maximized #true
  open-maximized-to-edges #false
  open-on-all-workspaces #true
  open-overlay #true
  open-unmanaged-global #true
  respect-size-hints #false
  center-floating #true
  parented-role "tool"
  presentation-mode "async"
  border {
    width 5
    active-color "#abcdef"
    inactive-color "#12345680"
  }
  focus-ring {
    width 7
    active-color "#fedcba"
  }
  clip-to-geometry #true
  default-floating-position x=32 y=48 relative-to="bottom-left"
  dialog-viewport-jump #true
  floating {
    x-ratio 0.02
    y-ratio 0.08
    width 880
    height 640
  }
}
spawn-at-startup "notify-send" "triad"
environment {
  GTK_THEME "Adwaita:dark"
  TRIAD_EMPTY ""
  SSH_AUTH_SOCK #null
  GTK_THEME "Breeze"
  BAD-NAME "ignored"
}
quickshell {
  command "qs"
  theme "noctalia"
  args "--verbose"
}
terminal { command "kitty" }
screenshot {
  directory "~/shots"
  filename-prefix "triad-test"
  capture-command "grim -t png"
  region-selector-command "slurp -d"
  clipboard-command "wl-copy --type image/png"
  show-pointer #true
}
input {
  keyboard {
    repeat-rate 40
    repeat-delay 300
    numlock
    capslock #false
    xkb {
      rules "evdev"
      model "pc105"
      layout "us,us"
      variant ",dvorak"
      options "grp:alt_shift_toggle,ctrl:nocaps"
    }
  }
  mouse {
    natural-scroll
    accel-profile "flat"
    accel-speed -0.25
    scroll-method "on-button-down"
    scroll-button 274
    scroll-button-lock
    left-handed #false
    middle-emulation
    scroll-factor 1.5
  }
  touchpad {
    tap
    tap-button-map "left-middle-right"
    drag #false
    drag-lock
    dwt
    dwtp #false
    natural-scroll
    click-method "clickfinger"
    accel-profile "adaptive"
    accel-speed 0.2
    scroll-method "two-finger"
    disabled-on-external-mouse
  }
  trackpoint {
    off #false
    scroll-method "on-button-down"
    middle-emulation
  }
  trackball {
    accel-profile "none"
    scroll-factor 0.75
  }
}
screen-lock { command "swaylock" }
window-menu-command "bemenu"
scratchpad {
  width-ratio 0.7
  height-ratio 0.6
}
overview {
  outer-gap 80
  inner-gap-multiplier 1.75
  zoom 0.25
  tab-mode
  hot-corners {
    size 12
    top-left
    top-right #false
    bottom-right
  }
}
recent-windows {
  debounce-ms 500
  open-delay-ms 90
  highlight {
    active-color "#101112"
    urgent-color "#202122"
    padding 18
    corner-radius 4
  }
  previews {
    max-height 360
    max-scale 0.4
  }
  binds {
    bind "Alt+Tab" "recent-window-next --scope workspace"
  }
}
cursor {
  theme "Bibata"
  size 32
  shake-to-find
  hide-when-typing
  hide-after-inactive-ms 1250
}
presentation-mode "async"
allow-exit-session #true
protocol-surfaces {
  enabled #true
  visible-debug #true
}
hotkey-overlay {
  skip-at-startup
  hide-not-bound
  position "center"
  columns 4
}
config-notification {
  reload-succeeded "notify-send" "Triad" "Config reloaded"
  reload-failed "notify-send Triad failed"
  reload-rolled-back "notify-send" "Triad" "Config rolled back"
  unknown-notification "notify-send" "ignored"
}
bindings {
  mirror-hjkl-arrows #true
  bind "Super+Return" "spawn-terminal"
  bind "SUPER+CTRL+c" "layout-center-tile" allow-inhibiting=#false
  bind "Super+/" "toggle-hotkey-overlay" hotkey-overlay-title="Show Important Hotkeys"
  bind "Super+Shift+?" "focus-last" hotkey-overlay-title=#null
  bind "NONE+F12" "focus-last"
  bind "Super+Escape" "lock-session" on-release=#true
  bind "Ctrl+Alt+l" "lock-session" while-locked=#true
  pointer-bind "Super+left" "move"
  pointer-bind "Super+middle" "toggle-maximized"
  pointer-bind "right" "close-window" mode="overview"
  pointer-bind "Super+btn_back" "focus-last"
  axis-bind "Super+wheel-up" "focus-column-left"
  axis-bind "Super+wheel-down" "focus-column-right" mode="overview" allow-inhibiting=#false
  axis-bind "Super+up" "focus-up"
  gesture-bind "Super+swipe-left" "focus-left" fingers=3
  gesture-bind "Super+swipe-up" "toggle-overview" fingers=4 mode="normal" allow-inhibiting=#false
  gesture-bind "Super+pinch-in" "focus-up" fingers=3
  gesture-bind "Super+swipe-down" "focus-down" fingers=2
}
switch-events {
  lid-open "spawn notify-send open"
  lid-open "spawn notify-send opened"
  lid-close "lock-session"
  tablet-mode-on "spawn onboard"
  unknown-switch "spawn ignored"
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.layout.gaps == 32
    check config.mirrorHjklArrows
    check config.layout.borderWidth == 3
    check config.layout.centerFocusedColumn == "always"
    check config.layout.scrollerProportionPresets ==
      @[1.0'f32, 0.25'f32, 0.5'f32, 0.5'f32]
    check config.layout.animationSnapThreshold == 2.5'f32
    check config.layout.layoutCycle ==
      @[LayoutMode.Scroller, LayoutMode.Deck, LayoutMode.VerticalGrid]
    check config.workspaces.defaultCount == 4
    check config.workspaces.defaultLayout == LayoutMode.Scroller
    check config.outputRules.len == 2
    check config.outputRules[0].target == "HDMI-A-1"
    check config.outputRules[0].focusAtStartup
    check config.outputRules[0].workspaceSlots == @[2'u32, 4'u32]
    check config.outputRules[1].target == "DP-1"
    check config.outputRules[1].workspaceSlots.len == 0
    check config.tagRules.len == 2
    check config.tagRules[0].tagId == 1
    check config.tagRules[0].name == "term"
    check not config.tagRules[0].defaultLayoutSet
    check config.tagRules[1].tagId == 2
    check config.tagRules[1].defaultLayoutSet
    check config.tagRules[1].defaultLayout == LayoutMode.Grid
    check config.tagRules[1].openOnOutput == "HDMI-A-1"
    check config.windowRules.len == 1
    check config.windowRules[0].matches.len == 1
    check config.windowRules[0].matches[0].appIdSet
    check config.windowRules[0].matches[0].appId == "qemu"
    check not config.windowRules[0].matches[0].titleSet
    check config.windowRules[0].defaultWorkspace == 3
    check config.windowRules[0].openOnOutput == "HDMI-A-1"
    check config.windowRules[0].openNamedScratchpad == "files"
    check config.windowRules[0].defaultColumnWidthSet
    check config.windowRules[0].defaultColumnWidth == 0.65'f32
    check config.windowRules[0].defaultWindowWidthSet
    check config.windowRules[0].defaultWindowWidth == 0.75'f32
    check config.windowRules[0].defaultWindowHeightSet
    check config.windowRules[0].defaultWindowHeight == 0.85'f32
    check config.windowRules[0].minWidthSet
    check config.windowRules[0].minWidth == 640
    check config.windowRules[0].minHeightSet
    check config.windowRules[0].minHeight == 400
    check config.windowRules[0].maxWidthSet
    check config.windowRules[0].maxWidth == 1920
    check config.windowRules[0].maxHeightSet
    check config.windowRules[0].maxHeight == 1200
    check config.windowRules[0].openFloatingSet
    check config.windowRules[0].openFloating
    check config.windowRules[0].openFocusedSet
    check not config.windowRules[0].openFocused
    check config.windowRules[0].openFullscreenSet
    check not config.windowRules[0].openFullscreen
    check config.windowRules[0].openMaximizedSet
    check config.windowRules[0].openMaximized
    check config.windowRules[0].openMaximizedToEdgesSet
    check not config.windowRules[0].openMaximizedToEdges
    check config.windowRules[0].openOnAllWorkspacesSet
    check config.windowRules[0].openOnAllWorkspaces
    check config.windowRules[0].openOverlaySet
    check config.windowRules[0].openOverlay
    check config.windowRules[0].openUnmanagedGlobalSet
    check config.windowRules[0].openUnmanagedGlobal
    check config.windowRules[0].respectSizeHintsSet
    check not config.windowRules[0].respectSizeHints
    check config.windowRules[0].centerFloatingSet
    check config.windowRules[0].centerFloating
    check config.windowRules[0].parentedRoleSet
    check config.windowRules[0].parentedRole == ParentedRole.Tool
    check config.windowRules[0].presentationModeSet
    check config.windowRules[0].presentationMode == PresentationMode.PresentationAsync
    check config.windowRules[0].border.widthSet
    check config.windowRules[0].border.width == 5
    check config.windowRules[0].border.activeColorSet
    check config.windowRules[0].border.activeColor == 0xabcdefff'u32
    check config.windowRules[0].border.inactiveColorSet
    check config.windowRules[0].border.inactiveColor == 0x12345680'u32
    check config.windowRules[0].focusRing.widthSet
    check config.windowRules[0].focusRing.width == 7
    check config.windowRules[0].focusRing.activeColorSet
    check config.windowRules[0].focusRing.activeColor == 0xfedcbaff'u32
    check config.windowRules[0].clipToGeometrySet
    check config.windowRules[0].clipToGeometry
    check config.windowRules[0].defaultFloatingPosition.set
    check config.windowRules[0].defaultFloatingPosition.x == 32
    check config.windowRules[0].defaultFloatingPosition.y == 48
    check config.windowRules[0].defaultFloatingPosition.relativeTo ==
      FloatingPositionAnchor.BottomLeft
    check config.windowRules[0].dialogViewportJumpSet
    check config.windowRules[0].dialogViewportJump
    check config.windowRules[0].floating.xRatioSet
    check config.windowRules[0].floating.xRatio == 0.02'f32
    check config.windowRules[0].floating.yRatioSet
    check config.windowRules[0].floating.yRatio == 0.08'f32
    check config.windowRules[0].floating.widthSet
    check config.windowRules[0].floating.width == 880
    check config.windowRules[0].floating.heightSet
    check config.windowRules[0].floating.height == 640
    check config.startupCommands == @[@["notify-send", "triad"]]
    check config.environment.len == 4
    check config.environment[0].name == "GTK_THEME"
    check config.environment[0].value == "Adwaita:dark"
    check config.environment[1].name == "TRIAD_EMPTY"
    check config.environment[1].value == ""
    check config.environment[2].name == "SSH_AUTH_SOCK"
    check config.environment[2].unset
    check config.environment[3].name == "GTK_THEME"
    check config.environment[3].value == "Breeze"
    check config.quickshell.theme == "noctalia"
    check config.terminal.command.len > 0
    check config.screenshot.directory == "~/shots"
    check config.screenshot.filenamePrefix == "triad-test"
    check config.screenshot.captureCommand == "grim -t png"
    check config.screenshot.regionSelectorCommand == "slurp -d"
    check config.screenshot.clipboardCommand == "wl-copy --type image/png"
    check config.screenshot.showPointer
    check config.input.keyboard.repeatRateSet
    check config.input.keyboard.repeatRate == 40
    check config.input.keyboard.repeatDelaySet
    check config.input.keyboard.repeatDelay == 300
    check config.input.keyboard.numlockSet
    check config.input.keyboard.numlock
    check config.input.keyboard.capslockSet
    check not config.input.keyboard.capslock
    check config.input.keyboard.xkb.rulesSet
    check config.input.keyboard.xkb.rules == "evdev"
    check config.input.keyboard.xkb.modelSet
    check config.input.keyboard.xkb.model == "pc105"
    check config.input.keyboard.xkb.layoutSet
    check config.input.keyboard.xkb.layout == "us,us"
    check config.input.keyboard.xkb.variantSet
    check config.input.keyboard.xkb.variant == ",dvorak"
    check config.input.keyboard.xkb.optionsSet
    check config.input.keyboard.xkb.options == "grp:alt_shift_toggle,ctrl:nocaps"
    check config.input.mouse.naturalScrollSet
    check config.input.mouse.naturalScroll
    check config.input.mouse.accelProfileSet
    check config.input.mouse.accelProfile == InputAccelProfile.AccelFlat
    check config.input.mouse.accelSpeedSet
    check config.input.mouse.accelSpeed == -0.25'f32
    check config.input.mouse.scrollMethodSet
    check config.input.mouse.scrollMethod == InputScrollMethod.ScrollOnButtonDown
    check config.input.mouse.scrollButtonSet
    check config.input.mouse.scrollButton == 274'u32
    check config.input.mouse.scrollButtonLockSet
    check config.input.mouse.scrollButtonLock
    check config.input.mouse.leftHandedSet
    check not config.input.mouse.leftHanded
    check config.input.mouse.middleEmulationSet
    check config.input.mouse.middleEmulation
    check config.input.mouse.scrollFactorSet
    check config.input.mouse.scrollFactor == 1.5'f32
    check config.input.touchpad.tapSet
    check config.input.touchpad.tap
    check config.input.touchpad.tapButtonMapSet
    check config.input.touchpad.tapButtonMap == InputButtonMap.ButtonMapLeftMiddleRight
    check config.input.touchpad.dragSet
    check not config.input.touchpad.drag
    check config.input.touchpad.dragLockSet
    check config.input.touchpad.dragLock
    check config.input.touchpad.dwtSet
    check config.input.touchpad.dwt
    check config.input.touchpad.dwtpSet
    check not config.input.touchpad.dwtp
    check config.input.touchpad.pointer.naturalScrollSet
    check config.input.touchpad.pointer.naturalScroll
    check config.input.touchpad.clickMethodSet
    check config.input.touchpad.clickMethod == InputClickMethod.ClickFinger
    check config.input.touchpad.pointer.accelProfileSet
    check config.input.touchpad.pointer.accelProfile == InputAccelProfile.AccelAdaptive
    check config.input.touchpad.pointer.accelSpeedSet
    check config.input.touchpad.pointer.accelSpeed == 0.2'f32
    check config.input.touchpad.pointer.scrollMethodSet
    check config.input.touchpad.pointer.scrollMethod == InputScrollMethod.ScrollTwoFinger
    check config.input.touchpad.disabledOnExternalMouseSet
    check config.input.touchpad.disabledOnExternalMouse
    check config.input.trackpoint.offSet
    check not config.input.trackpoint.off
    check config.input.trackpoint.scrollMethod == InputScrollMethod.ScrollOnButtonDown
    check config.input.trackpoint.middleEmulation
    check config.input.trackball.accelProfileSet
    check config.input.trackball.accelProfile == InputAccelProfile.AccelNone
    check config.input.trackball.scrollFactorSet
    check config.input.trackball.scrollFactor == 0.75'f32
    check config.screenLock.command == @["swaylock"]
    check config.windowMenu.command == @["bemenu"]
    check config.scratchpad.widthRatio == 0.7'f32
    check config.overview.outerGap == 80
    check config.overview.innerGapMultiplier == 1.75'f32
    check config.overview.zoom == 0.25'f32
    check config.overview.tabMode
    check config.overview.hotCorners.size == 12
    check config.overview.hotCorners.topLeft
    check not config.overview.hotCorners.topRight
    check not config.overview.hotCorners.bottomLeft
    check config.overview.hotCorners.bottomRight
    check config.recentWindows.enabled
    check config.recentWindows.debounceMs == 500
    check config.recentWindows.openDelayMs == 90
    check config.recentWindows.highlight.activeColor == 0x101112ff'u32
    check config.recentWindows.highlight.urgentColor == 0x202122ff'u32
    check config.recentWindows.highlight.padding == 18
    check config.recentWindows.highlight.cornerRadius == 4
    check config.recentWindows.previews.maxHeight == 360
    check config.recentWindows.previews.maxScale == 0.4'f32
    check config.commandForBinding("Tab", Alt, BindingMode.BindRecent) ==
      "recent-window-next --scope workspace"
    check config.cursor.theme == "Bibata"
    check config.cursor.shakeToFind
    check config.cursor.hideWhenTyping
    check config.cursor.hideAfterInactiveMs == 1250
    check config.presentationMode == PresentationMode.PresentationAsync
    check config.allowExitSession
    check config.protocolSurfaces.enabled
    check config.hotkeyOverlay.skipAtStartup
    check config.hotkeyOverlay.hideNotBound
    check config.hotkeyOverlay.position == HotkeyOverlayPosition.Center
    check config.hotkeyOverlay.columns == 4
    check config.configNotification.reloadSucceeded ==
      @["notify-send", "Triad", "Config reloaded"]
    check config.configNotification.reloadFailed == @["notify-send", "Triad", "failed"]
    check config.configNotification.reloadRolledBack ==
      @["notify-send", "Triad", "Config rolled back"]
    check config.keyBindings.len > 0
    check config.commandForBinding("c", Super + Ctrl) == "layout-center-tile"
    let uppercaseBindings =
      config.keyBindings.filterIt(it.key == "c" and it.modifiers == Super + Ctrl)
    check uppercaseBindings.len == 1
    check uppercaseBindings[0].bypassShortcutsInhibit
    check config.commandForBinding("Slash", Super) == "toggle-hotkey-overlay"
    let titledBindings =
      config.keyBindings.filterIt(it.key == "Slash" and it.modifiers == Super)
    check titledBindings.len == 1
    check titledBindings[0].hotkeyOverlayTitleKind ==
      HotkeyOverlayTitleKind.HotkeyTitleCustom
    check titledBindings[0].hotkeyOverlayTitle == "Show Important Hotkeys"
    let hiddenBindings = config.keyBindings.filterIt(
      it.key == "Question" and it.modifiers == Super + Shift
    )
    check hiddenBindings.len == 1
    check hiddenBindings[0].hotkeyOverlayTitleKind ==
      HotkeyOverlayTitleKind.HotkeyTitleHidden
    check config.commandForBinding("F12", 0'u32) == "focus-last"
    let releaseBindings =
      config.keyBindings.filterIt(it.key == "Escape" and it.modifiers == Super)
    check releaseBindings.len == 1
    check releaseBindings[0].onRelease
    check not releaseBindings[0].whileLocked
    let lockedBindings =
      config.keyBindings.filterIt(it.key == "l" and it.modifiers == Ctrl + Alt)
    check lockedBindings.len == 1
    check lockedBindings[0].whileLocked
    check not lockedBindings[0].onRelease
    check config.pointerBindings.len == 4
    check config.pointerBindings.anyIt(
      it.button == 0x110'u32 and it.op == PointerOpKind.OpMove
    )
    check config.pointerBindings.anyIt(
      it.button == 0x112'u32 and it.command == "toggle-maximized"
    )
    check config.pointerBindings.anyIt(
      it.button == 0x111'u32 and it.command == "close-window" and
        it.mode == BindingMode.BindOverview
    )
    check config.pointerBindings.anyIt(
      it.button == 0x116'u32 and it.command == "focus-last"
    )
    check config.axisBindings.len == 2
    check config.axisBindings.anyIt(
      it.direction == AxisBindingDirection.AxisUp and it.modifiers == Super and
        it.command == "focus-column-left"
    )
    check config.axisBindings.anyIt(
      it.direction == AxisBindingDirection.AxisDown and it.modifiers == Super and
        it.command == "focus-column-right" and it.mode == BindingMode.BindOverview and
        it.bypassShortcutsInhibit
    )
    check config.gestureBindings.len == 2
    check config.gestureBindings.anyIt(
      it.direction == GestureBindingDirection.GestureSwipeLeft and it.fingers == 3 and
        it.modifiers == Super and it.command == "focus-left"
    )
    check config.gestureBindings.anyIt(
      it.direction == GestureBindingDirection.GestureSwipeUp and it.fingers == 4 and
        it.modifiers == Super and it.command == "toggle-overview" and
        it.mode == BindingMode.BindNormal and it.bypassShortcutsInhibit
    )
    check config.switchEvents.len == 3
    check config.switchEvents.anyIt(
      it.kind == SwitchEventKind.SwitchLidOpen and
        it.command == "spawn notify-send opened"
    )
    check config.switchEvents.anyIt(
      it.kind == SwitchEventKind.SwitchLidClose and it.command == "lock-session"
    )
    check config.switchEvents.anyIt(
      it.kind == SwitchEventKind.SwitchTabletModeOn and it.command == "spawn onboard"
    )

  test "HJKL mirroring preserves binding settings":
    let path = getCurrentDir() / "test_config_mirror.kdl"
    writeFile(
      path,
      """
bindings {
  mirror-hjkl-arrows #true
  bind "Super+h" "focus-left" allow-inhibiting=#false
  bind "Super+j" "focus-down" mode="overview"
  bind "Super+k" "focus-up" allow-inhibiting=#false
  bind "Super+Left" "custom-left"
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.commandForBinding("Left", Super) == "custom-left"
    check config.commandForBinding("Down", Super, BindingMode.BindOverview) ==
      "focus-down"
    let mirroredDown = config.keyBindings.filterIt(
      it.key == "Down" and it.modifiers == Super and it.mode == BindingMode.BindOverview
    )
    check mirroredDown.len == 1
    let mirroredUp = config.keyBindings.filterIt(
      it.key == "Up" and it.modifiers == Super and it.command == "focus-up"
    )
    check mirroredUp.len == 1
    check mirroredUp[0].bypassShortcutsInhibit

  test "Config adds hotkey overlay fallback when key slot is free":
    let path = getCurrentDir() / "test_config_hotkey_fallback.kdl"
    writeFile(
      path,
      """
bindings {
  bind "Super+q" "close-window"
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.hotkeyOverlay.skipAtStartup
    check config.hotkeyOverlay.position == HotkeyOverlayPosition.Top
    check config.hotkeyOverlay.columns == 2
    check config.msgKindForBinding("Slash", Super + Shift) ==
      MsgKind.CmdToggleHotkeyOverlay

    writeFile(
      path,
      """
bindings {
  bind "Super+Shift+Slash" "focus-last"
}
""",
    )
    let occupied = loadConfig(path)
    removeFile(path)

    check occupied.msgKindForBinding("Slash", Super + Shift) == MsgKind.CmdFocusLast

  test "Config clamps hotkey overlay columns and ignores invalid position":
    let path = getCurrentDir() / "test_config_hotkey_overlay_layout.kdl"
    writeFile(
      path,
      """
hotkey-overlay {
  position "left"
  columns 9
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.hotkeyOverlay.position == HotkeyOverlayPosition.Top
    check config.hotkeyOverlay.columns == 4

  test "cursor shake-to-find defaults off and supports explicit false":
    let path = getCurrentDir() / "test_config_cursor_shake.kdl"
    writeFile(
      path,
      """
cursor {
  theme "default"
  size 24
}
""",
    )
    let defaultOff = loadConfig(path)
    removeFile(path)

    check not defaultOff.cursor.shakeToFind

    writeFile(
      path,
      """
cursor {
  theme "default"
  size 24
  shake-to-find #false
}
""",
    )
    let explicitFalse = loadConfig(path)
    removeFile(path)

    check not explicitFalse.cursor.shakeToFind

  test "Default bindings follow Niri-style movement and scratchpad chords":
    let config = loadConfig(getCurrentDir() / "config.default.kdl")

    for i, binding in config.keyBindings:
      for j in (i + 1) ..< config.keyBindings.len:
        let other = config.keyBindings[j]
        check not (
          binding.key == other.key and binding.modifiers == other.modifiers and
          binding.mode == other.mode
        )

    check config.msgKindForBinding("h", Super + Ctrl) == MsgKind.CmdMoveColumnLeft
    check config.msgKindForBinding("Left", Super + Ctrl) == MsgKind.CmdMoveColumnLeft
    check config.msgKindForBinding("j", Super + Ctrl) == MsgKind.CmdMoveWindowDown
    check config.msgKindForBinding("Down", Super + Ctrl) == MsgKind.CmdMoveWindowDown
    check config.msgKindForBinding("k", Super + Ctrl) == MsgKind.CmdMoveWindowUp
    check config.msgKindForBinding("l", Super + Ctrl) == MsgKind.CmdMoveColumnRight
    check config.msgKindForBinding("h", Super + Alt) == MsgKind.CmdMoveWindowLeft
    check config.msgKindForBinding("Right", Super + Alt) == MsgKind.CmdMoveWindowRight
    check config.msgKindForBinding("w", Super) == MsgKind.CmdToggleScratchpad
    check config.msgKindForBinding("w", Super + Shift) == MsgKind.CmdMoveToScratchpad
    check config.msgKindForBinding("r", Super + Shift) == MsgKind.CmdRestoreScratchpad
    check config.spawnForBinding("c", Super) ==
      @["wtype", "-M", "ctrl", "-P", "Insert", "-p", "Insert", "-m", "ctrl"]
    check config.spawnForBinding("v", Super) ==
      @["wtype", "-M", "shift", "-P", "Insert", "-p", "Insert", "-m", "shift"]
    check config.spawnForBinding("x", Super) ==
      @["wtype", "-M", "ctrl", "x", "-m", "ctrl"]
    check config.msgKindForBinding("Print", 0'u32) == MsgKind.CmdScreenshot
    check config.commandForBinding("Print", Ctrl) == "screenshot-screen"
    check config.commandForBinding("Print", Alt) == "screenshot-window"
    check config.commandForBinding("Print", Super) == "screenshot --clipboard-only"
    check config.msgKindForBinding("Slash", Super + Shift) ==
      MsgKind.CmdToggleHotkeyOverlay
    check config.msgKindForBinding("Tab", Alt, BindingMode.BindRecent) ==
      MsgKind.CmdRecentWindowNext
    check config.msgKindForBinding("Tab", Alt + Shift, BindingMode.BindRecent) ==
      MsgKind.CmdRecentWindowPrev
    check config.commandForBinding("Tab", Super) == "focus-last"
    for key in ["c", "v", "x"]:
      let bindings =
        config.keyBindings.filterIt(it.key == key and it.modifiers == Super)
      check bindings.len == 1
      check bindings[0].bypassShortcutsInhibit
    check config.layoutForBinding("c", Super + Ctrl) == LayoutMode.CenterTile
    check config.layoutForBinding("v", Super + Ctrl) == LayoutMode.Deck
    check config.layoutForBinding("x", Super + Ctrl) == LayoutMode.Monocle
    check config.layoutForBinding("c", Super + Shift) == LayoutMode.RightTile
    check parseTextCommand("layout-tgmix").get().newLayout == LayoutMode.TGMix
    let preset = parseTextCommand("switch-proportion-preset -1").get()
    check preset.kind == MsgKind.CmdSwitchProportionPreset
    check preset.proportionPresetDelta == -1

  test "config defaults clamp invalid runtime values":
    var model = Model()
    model.applyConfig(
      Config(
        layout: LayoutConfig(
          gaps: -9,
          centerFocusedColumn: "sideways",
          defaultColumnWidth: 4.0,
          scrollerProportionPresets: @[2.0'f32, 0.5'f32, 0.5'f32, 0.0'f32],
          defaultWindowWidth: -1.0,
          defaultWindowHeight: 0.0,
          defaultMasterCount: 0,
          defaultMasterRatio: 2.0,
          animationSpeed: 5.0,
          animationSnapThreshold: 100.0,
        ),
        workspaces: WorkspaceConfig(defaultCount: 0),
        overview: OverviewConfig(
          outerGap: -1,
          zoom: 99.0,
          hotCorners: OverviewHotCornersConfig(size: 5000, topLeft: true),
        ),
        scratchpad: ScratchpadConfig(widthRatio: 4.0, heightRatio: 0.0),
      )
    )

    check model.outerGaps == 0
    check model.centerFocusedColumn == "never"
    check model.defaultColumnWidth == 1.0'f32
    check model.scrollerProportionPresets == @[0.05'f32, 0.5'f32, 1.0'f32]
    check model.defaultWindowWidth == 0.05'f32
    check model.defaultWindowHeight == 0.05'f32
    check model.defaultMasterCount == 1
    check model.defaultMasterRatio == 0.95'f32
    check model.animationSpeed == 1.0'f32
    check model.animationSnapThreshold == 64.0'f32
    check model.defaultWorkspaceCount == DefaultWorkspaceCount
    check model.defaultWorkspaceLayout == LayoutMode.Scroller
    check model.overviewOuterGap == DefaultOverviewOuterGap
    check model.overviewZoom == 0.75'f32
    check model.overviewHotCorners.size == 1000
    check model.scratchpadWidthRatio == 1.0'f32
    check model.scratchpadHeightRatio == 0.1'f32
