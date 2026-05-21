+++
title = "Input"
weight = 50
+++

# Input

Configure keyboards, mice, touchpads, and the cursor inside the `input` block.
Changes reload on save.

## Keyboard

```kdl
input {
  keyboard {
    xkb {
      layout  "us"
      variant ""
      options "ctrl:nocaps"
    }
    repeat-rate  40
    repeat-delay 300
  }
}
```

| Setting | Format | Description |
|---|---|---|
| `xkb.layout` | String | XKB layout name, e.g. `"us"`, `"de"`, `"us,ru"`. |
| `xkb.variant` | String | Layout variant, e.g. `"dvorak"`, `"colemak"`. |
| `xkb.options` | String | XKB options, e.g. `"ctrl:nocaps"`, `"compose:ralt"`. |
| `xkb.model` | String | Keyboard model. Usually not needed. |
| `xkb.rules` | String | XKB rules file. Usually not needed. |
| `repeat-rate` | Hz | Keys repeated per second while held. |
| `repeat-delay` | ms | Delay before key repeat starts. |

To list available layouts, variants, and options:

```bash
localectl list-x11-keymap-layouts
localectl list-x11-keymap-variants us
localectl list-x11-keymap-options | grep ctrl
```

## Mouse

```kdl
input {
  mouse {
    natural-scroll #false
    accel-speed    0.0
  }
}
```

| Setting | Values | Description |
|---|---|---|
| `natural-scroll` | Bool | Reverse scroll direction. |
| `accel-speed` | -1.0..1.0 | Pointer acceleration. `0.0` is the default. |
| `accel-profile` | `"flat"`, `"adaptive"` | Acceleration profile. |
| `off` | Bool | Disable the device entirely. |

## Touchpad

```kdl
input {
  touchpad {
    tap            #true
    natural-scroll #true
    dwt            #true
    accel-speed    0.2
  }
}
```

| Setting | Values | Description |
|---|---|---|
| `tap` | Bool | Enable tap-to-click. |
| `tap-button-map` | `"lrm"`, `"lmr"` | Map 1/2/3-finger tap to left/right/middle or left/middle/right. |
| `natural-scroll` | Bool | Reverse scroll direction. |
| `dwt` | Bool | Disable touchpad while typing. |
| `accel-speed` | -1.0..1.0 | Pointer acceleration. |
| `scroll-factor` | Float | Scroll speed multiplier. |
| `off` | Bool | Disable the touchpad entirely. |

## Cursor

```kdl
input {
  cursor {
    theme         "Adwaita"
    size          24
    shake-to-find #true
  }
}
```

| Setting | Format | Description |
|---|---|---|
| `theme` | String | Cursor theme name. Must be installed on the system. |
| `size` | Pixels | Base cursor size. |
| `shake-to-find` | Bool | Temporarily enlarge the cursor when you shake the mouse — useful on high-DPI or multi-monitor setups. |

## Targeting a Specific Device

Name a device block to apply settings only to a specific input device. Use
`libinput list-devices` to find the device name:

```kdl
input {
  device "ACME Gaming Mouse" {
    accel-speed    -0.5
    accel-profile  "flat"
  }
}
```
