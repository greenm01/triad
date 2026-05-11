import ../core/defaults as core_defaults
export core_defaults

const
  FallbackConfigContent* = """// Triad Configuration (KDL 2.0)

layout {
    gaps 16
    center-focused-column "on-overflow"
    default-column-width { proportion 0.5; }
    default-window-width { proportion 0.5; }
    default-window-height { proportion 1.0; }
    master {
        count 1
        split-ratio 0.55
    }
    border {
        width 2
        active-color "#ffffff"
        inactive-color "#666666"
    }
    enable-animations #true
    animation-speed 0.15
    smart-gaps #false
    layout-cycle "scroller" "tile" "grid" "monocle" "vertical-scroller"
}

scratchpad {
    width-ratio 0.8
    height-ratio 0.9
}

overview {
    outer-gap 64
    inner-gap-multiplier 2.0
}

floating {
    x-ratio 0.25
    y-ratio 0.25
    width-ratio 0.5
    height-ratio 0.5
    min-width 50
    min-height 50
}

workspaces {
    default-count 3
}

screenshot {
    directory "~/Pictures/Screenshots"
    filename-prefix "triad-screenshot"
    capture-command "grim"
    region-selector-command "slurp"
    clipboard-command "wl-copy --type image/png"
    show-pointer #false
}

tag-rules {
    tag 1 default-layout="scroller"
    tag 2 default-layout="tile"
    tag 3 default-layout="grid"
    tag 4 default-layout="monocle"
}

// Shells, bars, launchers, lock screens, startup services, and app rules are
// intentionally configured outside this fallback.

bindings {
    bind "Super+Shift+Slash" "toggle-hotkey-overlay" allow-inhibiting=#false hotkey-overlay-title="Show Important Hotkeys"
    bind "Super+q" "close-window"
    bind "Super+f" "toggle-fullscreen"
    bind "Super+m" "toggle-maximized"
    bind "Super+i" "minimize"
    bind "Super+n" "switch-layout"
    bind "Super+Ctrl+Escape" "toggle-keyboard-shortcuts-inhibit" allow-inhibiting=#false
    bind "Ctrl+Alt+Escape" "focus-last" allow-inhibiting=#false
    bind "Ctrl+Alt+r" "triad-reload" allow-inhibiting=#false
    bind "Super+t" "spawn-terminal"
    bind "Print" "screenshot"
    bind "Ctrl+Print" "screenshot-screen"
    bind "Alt+Print" "screenshot-window"
    bind "Super+Print" "screenshot --clipboard-only"
    bind "Super+Tab" "focus-next"
    bind "Alt+Left" "focus-left"
    bind "Alt+Right" "focus-right"
    bind "Alt+Up" "focus-up"
    bind "Alt+Down" "focus-down"
    bind "Super+1" "focus-workspace 1"
    bind "Super+2" "focus-workspace 2"
    bind "Super+3" "focus-workspace 3"
    bind "Super+4" "focus-workspace 4"
    pointer-bind "Super+left" "move"
    pointer-bind "Super+right" "resize"
}

window-rule {
    match app-id="qemu"
    keyboard-shortcuts-inhibit #true
}
"""
