import ../core/defaults as core_defaults
export core_defaults

const FallbackConfigContent* =
  """// Triad Configuration (KDL 2.0)

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
    frame-tabs {
        active-color "#3f7fd5"
        active-unfocused-color "#303846"
        inactive-color "#161a22ee"
        active-line-color "#ffffff"
        active-unfocused-line-color "#62a8ff"
        empty-background-color "#00000001"
    }
    enable-animations #true
    animation-speed 0.15
    animation-snap-threshold 0.5
    frame-rate "auto"
    smart-gaps #false
    layout-cycle "scroller" "tile" "grid" "spiral" "monocle" "vertical-scroller"
}

scratchpad {
    width-ratio 0.8
    height-ratio 0.9
}

overview {
    outer-gap 64
    inner-gap-multiplier 2.0
    zoom 0.5
    scroller-indicators #false
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
    default-layout "scroller"
}

screenshot {
    directory "~/Pictures/Screenshots"
    filename-prefix "triad-screenshot"
    capture-command "grim"
    region-selector-command "slurp"
    clipboard-command "wl-copy --type image/png"
    show-pointer #false
}

janet {
    enabled #true
    automation-dir "~/.config/triad/automation"
    layout-dir "~/.config/triad/layouts"
    fuel-limit 500000
}

// output "HDMI-A-1" {
//     focus-at-startup
//     workspaces 2 4
// }

workspace-rules {
    workspace 1 name="term"
    workspace 2 name="web"
    workspace 3 name="files"
    workspace 4 name="chat" default-layout="monocle" open-on-output="HDMI-A-1"
}

// cursor {
//     theme "default"
//     size 24
//     shake-to-find #true
// }

// Shells, bars, launchers, lock screens, startup services, and app rules are
// intentionally configured outside this fallback.
// When shell profiles are configured, their watchdog defaults to enabled with
// a 30000 ms exclusive layer focus timeout.

allow-exit-session #true

recent-windows {
    debounce-ms 750
    open-delay-ms 150
    highlight {
        active-color "#999999"
        urgent-color "#ff9999"
        padding 30
        corner-radius 0
    }
    previews {
        max-height 480
        max-scale 0.5
    }
    binds {
        bind "Alt+Tab" "recent-window-next"
        bind "Alt+Shift+Tab" "recent-window-prev"
        bind "Alt+grave" "recent-window-next --filter app-id"
        bind "Alt+Shift+grave" "recent-window-prev --filter app-id"
    }
}

hotkey-overlay {
    skip-at-startup #false
    hide-not-bound
    position "center"
}

layout-switch-toast {
    enabled #true
    timeout-ms 900
    ring-color "#ff3b30"
}

// environment {
//     GTK_THEME "Adwaita:dark"
//     SSH_AUTH_SOCK #null
// }

bindings {
    bind "Ctrl+Alt+Delete" "exit-session" allow-inhibiting=#false hotkey-overlay-title="Exit Triad"
    bind "Super+?" "toggle-hotkey-overlay" allow-inhibiting=#false hotkey-overlay-title="Show Important Hotkeys"
    bind "Super+q" "close-window"
    bind "Super+f" "maximize-window-to-edges"
    bind "Super+Shift+f" "fullscreen-window"
    bind "Super+m" "maximize-column"
    bind "Super+Shift+b" "minimize"
    bind "Super+i" "move-to-scratchpad"
    bind "Alt+z" "toggle-scratchpad"
    bind "Super+Shift+i" "restore-scratchpad"
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
    bind "Super+Page_Up" "frame-tab-prev"
    bind "Super+Page_Down" "frame-tab-next"
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
    // axis-bind "Super+wheel-up" "focus-left"
    // axis-bind "Super+wheel-down" "focus-right"
}

window-rule {
    match app-id="qemu"
    keyboard-shortcuts-inhibit #true
}
"""
