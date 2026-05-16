# Config Command Matrix

This document compares Mango, current River, and Triad by user-facing
configuration surface. The main table groups commands by functionality so name
differences are visible. `X` means Triad has a user-facing config key, binding
command, IPC request, or implemented behavior for that feature.

Sources:

- Mango:
  `/home/niltempus/src/mango/docs/configuration`,
  `/home/niltempus/src/mango/docs/bindings`, and
  `/home/niltempus/src/mango/docs/window-management`
- River:
  `/home/niltempus/src/river/doc/river.1.scd`,
  `/home/niltempus/src/river/README.md`, and
  `/home/niltempus/src/river/protocol`
- Triad:
  `src/config/parser.nim`, `src/ipc/commands.nim`,
  `src/ipc/triad_native.nim`, `src/protocols/coverage.nim`,
  `docs/ipc.md`, and `config.default.kdl`

Current River is non-monolithic. It supplies compositor configuration,
startup, and protocol primitives, while window-management policy belongs to the
external window manager.

## Config Work Status

The Niri and Mango config review workstreams are complete. Remaining gaps are
protocol-dependent or tracked in the feature matrix below.

| Priority | Workstream | Target Triad surface | Niri/Mango reference | Current status | First milestone |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Done | Config lifecycle | `include`, `include optional=true`, custom config path, `triad validate-config` | Niri `include` and `validate`; Mango `source`, `source-optional`, `mango -c`, `mango -c ... -p` | Implemented with in-place include expansion, recursion safety, include hot reload watching, `TRIAD_CONFIG`, `--config`, `-c`, and standalone validation. | Keep validating against real configs while future config work expands. |
| Done | Input device config | `input { keyboard; mouse; touchpad; trackpoint; trackball }` | Niri `input`; Mango keyboard, mouse, and trackpad settings | Implemented through River input, XKB, and libinput config protocols for keyboard repeat, XKB keymaps/options, lock state, and basic mouse/touchpad/trackpoint/trackball settings. | Keep validating against live hardware; keyboard layout cycling remains separate command work. |
| Done | Output rules | `output "name" { focus-at-startup; workspaces ... }` | Niri `output`; Mango `monitorrule` | Implemented for startup focus and workspace/output affinity by existing output identity matching. Triad still has no output layout or mode config. | Document which mode/scale/position fields require output-management protocol support before expanding the surface. |
| Done | Session environment | `environment { KEY "value"; KEY #null }` | Niri `environment`; Mango `env` | Implemented for future Triad-spawned user-facing processes; values are literal and `#null` unsets a variable. | Keep documenting that this does not retroactively change external systemd/dbus-launched processes or already-running apps. |
| Done | Binding event types | `switch-events` and gestures | Mango `axisbind`, `gesturebind`, `switchbind`; Niri gestures and switch events | Implemented for key press/release, locked-session keys, pointer buttons, wheel-axis bindings, touchpad swipe gestures, and Linux evdev lid/tablet switch events. | Use evdev switch delivery today; compositor-native switch events remain blocked until River exposes a protocol surface for them. |
| Done | Focused polish | Cursor hiding, config notifications, overview/recent/hotkey overlays, and animation tuning | Niri config notifications, gestures, animations, layer rules; Mango visuals/effects/layer rules | Implemented cursor theme/size/shake/hiding, config reload notification commands, overview controls, recent windows, hotkey overlay layout controls, coarse animation speed, and viewport snap-threshold tuning. | Layer-rule polish remains protocol-blocked; do not add layer-rule config until River exposes enough layer-shell identity/state. |

## Feature Matrix

| Area | Functionality | Mango name(s) | River surface | Triad name(s) | Triad | Notes |
| :--- | :--- | :--- | :--- | :--- | :---: | :--- |
| Config lifecycle | Default config file | `~/.config/mango/config.conf` | `$XDG_CONFIG_HOME/river/init` or `~/.config/river/init` | `$XDG_CONFIG_HOME/triad/config.kdl` | X | Triad creates a fallback config when missing. |
| Config lifecycle | Custom config on launch | `mango -c` | `river -c` shell command | `TRIAD_CONFIG`, `triad --config`, `triad -c` | X | Triad can start from a non-default root config path. |
| Config lifecycle | Config validation | `mango -c ... -p` | | `triad validate-config` | X | Validates KDL syntax, includes, and strict window-rule regex checks without starting the daemon. |
| Config lifecycle | Config includes | `source`, `source-optional` | Shell script can source files | `include`, `include optional=#true` | X | Includes expand in place, resolve relative to the parent file, reject recursion, and participate in hot reload after a successful load. |
| Config lifecycle | Hot reload | `reload_config`, `exec` | WM process policy | `config-reload`, `triad-reload` | X | Triad reloads config in-process; full Triad reload snapshots state and restarts through the session manager path. |
| Config lifecycle | Reload notifications | | Shell/WM policy | `config-notification` | X | Optional commands run on config reload success, failure, or rollback. |
| Startup | Startup commands | `exec-once`, `exec` | Init script starts long-running programs | `spawn-at-startup` | X | Triad has startup commands, not a reload-time `exec` equivalent. |
| Startup | Environment variables | `env` | Init script environment | `environment` | X | Applies literal set/unset entries to future Triad-spawned user-facing processes. |
| Startup | Spawn command | `spawn`, `spawn_shell`, `spawn_on_empty` | WM policy | `spawn`, `spawn-terminal` | X | Triad spawn uses argv-style text command parsing. Niri-compatible `Spawn` and `SpawnSh` actions map to the same configured-process spawn path for Quickshell clients. |
| Session | Quit manager | `quit` | `river_window_manager_v1.stop` | `stop-manager` | X | Triad also has `exit-session` behind config. |
| Session | Exit compositor session | `quit` | `river_window_manager_v1.exit_session` | `exit-session`, `allow-exit-session` | X | Guarded by explicit config; default configs bind `Ctrl+Alt+Delete` and require Enter confirmation before exit. Niri `Quit` with `skip_confirmation` bypasses the dialog for shell session menus. |
| Session | Lock screen | External bind to `spawn` | Init/WM policy | `screen-lock`, `lock-session` | X | Triad stores a configured lock command. |
| Bindings | Key bindings | `bind`, `bindl`, `binds`, `bindr`, `bindp` | `river_xkb_bindings_v1` | `bindings { bind ... }` | X | Triad supports mode, layout override, inhibit policy, and hotkey overlay titles. |
| Bindings | Key modes/submaps | `keymode`, `setkeymode` | WM policy | `mode="normal"`, `mode="overview"`, or `mode="recent"` | | Triad has fixed binding modes, not arbitrary named modes. Unified overview and recent-windows add modal fallback bindings, including derived direction-key navigation, only when those key slots are free. |
| Bindings | Recent-window switcher | MRU switcher actions | WM policy plus `river_xkb_bindings_v1` | `recent-windows`, `recent-window-*` | X | Niri-style recent window switching with debounce, open delay, scopes, app-id filter, and preview overlay. Defaults are Alt-only so `Super+Tab` remains available for Triad focus commands. |
| Bindings | HJKL/arrow mirroring | Manual binds | WM policy | `mirror-hjkl-arrows` | X | Triad can generate arrow equivalents for HJKL binds. |
| Bindings | Pass/locked/release flags | `bindp`, `bindl`, `bindr` | Protocol has press/release events | `bind ... on-release=#true`, `while-locked=#true` | X | Triad supports release-triggered and locked-session keyboard binds. Pass-through binds remain unsupported. |
| Bindings | Eat next key | | `ensure_next_key_eaten` | `eat-next-key`, `cancel-eat-next-key` | X | Useful for modal shell interactions. |
| Pointer | Mouse button bindings | `mousebind` | `river_seat_v1.get_pointer_binding` | `bindings { pointer-bind ... }` | X | Triad supports configured move/resize pointer bindings. |
| Pointer | Scroll wheel bindings | `axisbind` | Pointer axis from Wayland, policy in WM | `bindings { axis-bind ... }` | X | Triad supports wheel-up/down/left/right command bindings using raw pointer-axis events. |
| Pointer | Touchpad gestures | `gesturebind` | `zwp_pointer_gestures_v1` swipe events | `bindings { gesture-bind ... }` | X | Triad dispatches configured 3- and 4-finger swipe bindings from live touchpad swipe end events when the compositor advertises pointer gestures. |
| Pointer | Lid/switch bindings | `switchbind` | Input events/protocols | `switch-events` | X | Triad stores lid/tablet switch event commands, has a synthetic dispatcher, and reads Linux evdev `EV_SW` lid/tablet events when readable. Compositor-native switch delivery is not exposed yet. |
| Pointer | Pointer warp | `warpcursor` | `river_seat_v1.pointer_warp` | `warp-pointer` | X | Triad exposes explicit IPC. |
| Input | Keyboard repeat | `repeat_rate`, `repeat_delay` | `river_input_device_v1.set_repeat_info` | `input.keyboard.repeat-rate`, `input.keyboard.repeat-delay` | X | Applied to keyboard devices when the River input management protocol is available. |
| Input | XKB rules/layout/options | `xkb_rules_*` | `river_xkb_config_v1` | `input.keyboard.xkb` | X | Triad builds keymaps with libxkbcommon; binds can still set per-binding layout override. |
| Input | Keyboard layout switch | `switch_keyboard_layout` | `set_layout_by_index/name` | `bind ... layout=<index>` | X | Triad binds may override layout, and Niri-compatible `SwitchLayout` cycles configured `input.keyboard.xkb.layout` entries through River XKB config. |
| Input | NumLock/CapsLock | `numlockon` | `numlock_enable`, `capslock_enable` | `input.keyboard.numlock`, `input.keyboard.capslock` | X | Applies requested initial lock state through River XKB config. |
| Input | Pointer acceleration | `mouse_accel_*`, `trackpad_accel_*` | `set_accel_profile`, `set_accel_speed` | `input.mouse/touchpad/trackpoint/trackball.accel-profile`, `accel-speed` | X | Applies only when the device reports matching libinput support. |
| Input | Natural scroll | `mouse_natural_scrolling`, `trackpad_natural_scrolling` | `set_natural_scroll` | `input.*.natural-scroll` | X | Supported for mouse, touchpad, trackpoint, and trackball sections. |
| Input | Tap/click/drag settings | `tap_to_click`, `click_method`, `tap_and_drag`, `drag_lock` | libinput config requests | `input.touchpad.tap`, `click-method`, `drag`, `drag-lock` | X | Touchpad-only settings are gated by libinput capability reports. |
| Input | Left-handed/middle emulation | `left_handed`, `middle_button_emulation` | libinput config requests | `input.*.left-handed`, `input.*.middle-emulation` | X | Supported for pointer class sections. |
| Input | Scroll factor/button/method | `axis_scroll_factor`, `scroll_button`, `scroll_method` | input/libinput config requests | `input.*.scroll-factor`, `scroll-button`, `scroll-method` | X | Scroll method/button uses libinput config; scroll factor uses River input device config. |
| Output | Monitor rules | `monitorrule` | Init script or external tools | `output "name"` | X | Triad supports output startup focus and workspace affinity. Monitor mode, scale, transform, position, and power remain unavailable without output-management protocol support. |
| Output | Monitor power | `disable_monitor`, `enable_monitor`, `toggle_monitor` | External output management | | | Not exposed by Triad. |
| Output | Presentation/tearing | `allow_tearing`, `force_tearing`, `vrr` | `river_output_v1.set_presentation_mode` | `presentation-mode` | X | Triad supports global vsync/async presentation mode. |
| Output | Cursor theme/size/find | | `river_seat_v1.set_xcursor_theme` | `cursor { theme; size; shake-to-find }` | X | Applied through River seat protocol. Shake-to-find temporarily reapplies the configured theme at a larger size. |
| Output | Cursor inactivity hiding | `cursor_hide_timeout` | `wl_pointer.set_cursor`, `wp_cursor_shape_manager_v1`, River seat cursor ownership | `cursor { hide-after-inactive-ms; hide-when-typing }` | X | Triad hides the compositor cursor with a null pointer cursor and restores the default cursor shape when cursor-shape support is advertised. |
| Tags | View tag/workspace | `view`, `viewtoleft`, `viewtoright` | WM policy | `focus-tag`, `focus-tag-left/right`, `focus-workspace` | X | Triad has tags plus derived workspace navigation. |
| Tags | View occupied tag | `viewtoleft_have_client`, `viewtoright_have_client` | WM policy | `focus-occupied-tag-left/right` | X | Triad skips empty tags. |
| Tags | Move window to tag | `tag`, `tagtoleft`, `tagtoright` | WM policy | `move-to-tag`, `move-to-tag-left/right` | X | Triad follows the moved window and also has `move-to-workspace`. |
| Tags | Toggle/multi-tag view | `toggletag`, `toggleview`, `comboview` | WM policy | | | Triad uses canonical tag masks internally but exposes single-target commands. |
| Tags | Rename tags | | WM policy | `rename-tag`, `workspace-rules { workspace ... name=... }` | X | Runtime commands use tags; config uses workspace language. |
| Tags | Tag rules | `tagrule` | WM policy | `workspace-rules { workspace ... }` | X | Triad supports workspace name and default layout rules backed by internal tags. |
| Monitor focus | Focus monitor | `focusmon` | WM policy | `focus-output` | X | Accepts connector/identity targets plus `left`, `right`, `up`, `down`, `next`, and `previous`. |
| Monitor focus | Move workspace to monitor | `tagmon`, `toggletagmon` | WM policy | `move-workspace-to-output` | X | Workspaces keep output affinity and restore to reconnected outputs. |
| Monitor focus | Move window to monitor | `tagmon`, `tagcrossmon`, `viewcrossmon` | WM policy | `move-to-output` | X | Moves the focused window to the workspace currently visible on the target output. |
| Focus | Directional focus | `focusdir` | `river_seat_v1.focus_window` primitive | `focus-left/right/up/down` | X | Triad maps to model focus commands. |
| Focus | Stack/next/previous focus | `focusstack` | WM policy | `focus-next`, `focus-prev` | X | |
| Focus | Last focus | `focuslast` | WM policy | `focus-last` | X | |
| Focus | Column boundary focus | | WM policy | `focus-column-first/last` | X | Triad-specific column navigation. |
| Focus | Focus by window id | | WM policy | `focus-window <id>` | X | Used by shell/overview. |
| Focus | Focus shell UI | | `river_seat_v1.focus_shell_surface` | `focus-shell-ui` | X | Triad shell integration. |
| Window lifecycle | Close focused window | `killclient` | `river_window_v1.close` | `close-window` | X | Optional id argument is supported. |
| Window lifecycle | Minimize | | minimize request/capability | `minimize`, `minimize-window` | X | Client-visible minimize state. Mango's `minimized` dispatcher is mapped under standard scratchpad because it sends windows to the scratchpad pool. |
| Window state | Toggle floating | `togglefloating` | `set_tiled` primitive | `toggle-floating` | X | |
| Window state | Toggle all floating | `toggle_all_floating` | WM policy | | | Not exposed by Triad. |
| Window state | Fullscreen | `togglefullscreen` | fullscreen requests and commands | `fullscreen-window`, `toggle-fullscreen`, `exit-fullscreen` | X | Optional id argument is supported. |
| Window state | Fake fullscreen | `togglefakefullscreen` | WM policy | | | No Triad equivalent. |
| Window state | Maximize column | `set_proportion 1.0` | WM policy | `maximize-column` | X | Full-width column; does not set client maximized state. |
| Window state | Maximize to edges | `togglemaximizescreen` | maximize request/capability | `maximize-window-to-edges`, `toggle-maximized`, `toggle-maximize` | X | Client-visible maximized state. |
| Window state | Sticky/global window | `toggleglobal`, `isglobal` | WM policy | `window-rule open-on-all-workspaces` | X | Exposed as declarative open policy. Triad does not yet expose an imperative toggle command. |
| Window state | Managed overlay | `toggleoverlay`, `isoverlay` | WM policy | `window-rule open-overlay` | X | Declarative managed stacking policy; not floating, sticky, or unmanaged. |
| Window state | Global unmanaged | `isunglobal` | Layer/shell primitives | `window-rule open-unmanaged-global` | X | Triad keeps the surface River-managed but gives it unmanaged-like global render and no workspace placement/focus/occupancy. |
| Window state | Center floating window | `centerwin`, `no_force_center` | WM policy | `window-rule center-floating`, `floating { x-ratio; y-ratio; ... }` | X | Rule-level centering controls generated floating geometry; Triad has no separate center command. |
| Window movement | Swap/move by direction | `exchange_client` | WM policy | `move-window-*`, `swap-window-up/down` | X | Triad separates moves and stack swaps. |
| Window movement | Stack exchange | `exchange_stack_client` | WM policy | `swap-window-up/down` | X | |
| Window movement | Move across workspace | | WM policy | `move-window-up/down-or-to-workspace-*` | X | Triad-specific command pair. |
| Window movement | Floating move/resize | `smartmovewin`, `smartresizewin`, `movewin`, `resizewin` | pointer ops and resize primitives | `move-floating`, `resize-floating` | X | Triad also supports pointer move/resize bindings. |
| Window grouping | Consume/expel/group | `scroller_stack` | WM policy | `consume-window`, `expel-window`, `group-windows`, `ungroup-window` | X | Triad has explicit groups and consume/expel commands. |
| Layouts | Set layout | `setlayout` | WM policy | `layout-*`, native `set-layout`, native action parity | X | Triad supports scroller, tile, grid, monocle, deck, tgmix, and variants. |
| Layouts | Cycle layout | `switch_layout`, `circle_layout` | WM policy | `switch-layout`, `layout-cycle` | X | Triad config controls the cycle order. |
| Layouts | Layout defaults per workspace | `tagrule layout_name` | WM policy | `workspaces default-layout`, `workspace-rules default-layout=...` | X | |
| Layouts | Master count | `incnmaster`, `default_nmaster`, `nmaster` | WM policy | `master-count`, `adjust-master-count`, `layout.master.count` | X | |
| Layouts | Master ratio | `setmfact`, `default_mfact`, `mfact` | WM policy | `master-ratio`, `adjust-master-ratio`, `layout.master.split-ratio` | X | |
| Layouts | Scroller width/proportion | `set_proportion`, `scroller_default_proportion` | WM policy | `set-column-width`, `resize-width`, `default-column-width`, `scroller-proportion`, `scroller-single-proportion` | X | Triad uses column/window width proportions; scroller rule proportions apply at new-window placement time. |
| Layouts | Scroller focus centering | `scroller_focus_center`, `scroller_prefer_center` | WM policy | `scroller-focus-center`, `scroller-prefer-center` | X | |
| Layouts | Proportion presets | `scroller_proportion_preset`, `switch_proportion_preset` | WM policy | `scroller-proportion-presets`, `switch-proportion-preset` | X | Triad cycles focused horizontal or vertical scroller columns through configured clamped presets. |
| Layouts | TGMix layout | `tgmix` | WM policy | `layout-tgmix`, `tgmix` layout id | X | Uses tile for up to three windows, grid after that. |
| Layouts | Gaps | `incgaps`, `togglegaps`, `smartgaps` | WM policy | `adjust-gaps`, `toggle-gaps`, `smart-gaps`, `gaps` | X | |
| Layouts | Border style | `toggle_render_border`, `no_render_border` | `river_window_v1.set_borders` | `border { width; active-color; inactive-color }` | X | Triad has border config, not a runtime toggle. |
| Layouts | Layout switch toast | | WM policy | `layout-switch-toast { enabled; timeout-ms; ring-color }` | X | Native centered toast shown after active-workspace layout commands; follows command bindings rather than a hard-coded key. |
| Overview | Toggle overview | `toggleoverview` | WM policy | `toggle-overview`, `open-overview`, `close-overview` | X | |
| Overview | Overview layout gaps and zoom | `overviewgappi`, `overviewgappo` | WM policy | `overview { inner-gap-multiplier; outer-gap; zoom }` | X | All layouts use the unified workspace-preview overview with Niri-style workspace navigation/camera behavior. See [Niri overview compatibility](./niri-overview-comp.md). |
| Overview | Scroller overflow indicators | | WM policy | `overview { scroller-indicators }` | X | Off by default. When enabled, scroller previews render subtle edge hints if hidden columns extend beyond the preview frame. |
| Overview | Hot corner overview | `enable_hotarea`, `hotarea_size`, `hotarea_corner` | WM policy | `overview { hot-corners { size; top-left; top-right; bottom-left; bottom-right } }` | X | Triad hot corners are opt-in and open overview only. |
| Overview | Overview tab mode | `ov_tab_mode` | WM policy | `overview { tab-mode }` | X | Off by default. Keyboard overview opener bindings with modifiers become hold-to-overview sessions: repeat the opener to cycle windows, release the opener modifier to close overview. |
| Scratchpad | Standard scratchpad | `minimized`, `toggle_scratchpad`, `restore_minimized` | WM policy | `move-to-scratchpad`, `toggle-scratchpad`, `restore-scratchpad` | X | Default chords mirror Mango: `Super+i` sends the focused window, `Alt+z` toggles/cycles standard scratchpad windows, and `Super+Shift+i` restores the window to its previous workspace. |
| Scratchpad | Named scratchpad | `toggle_named_scratchpad`, `isnamedscratchpad` | WM policy | `move-to-named-scratchpad`, `toggle-named-scratchpad` | X | Triad names scratchpads directly. |
| Scratchpad | Scratchpad size | `scratchpad_width_ratio`, `scratchpad_height_ratio` | WM policy | `scratchpad { width-ratio; height-ratio }` | X | |
| Window rules | App/title matching | `windowrule appid/title` | Window metadata events | `window-rule { match app-id=... title=...; exclude ... }` | X | Match and exclude use regex search semantics; repeated `match` children are OR-ed. |
| Window rules | State matching | `windowrule isfloating`, focus/window-state variants | WM policy | `match is-focused=... is-active=... is-active-in-column=... is-floating=...` | X | Opening-time evaluation uses unmapped defaults; existing-window dynamic fields refresh from current runtime state. |
| Window rules | Default workspace | `windowrule tags` | WM policy | `window-rule default-workspace`, `default-workspaces` | X | `default-workspaces` places a matching window on multiple Triad workspace tags; the first target is the primary focus/snapshot target. |
| Window rules | Sticky/global workspace placement | `windowrule global`, global tags | WM policy | `window-rule open-on-all-workspaces` | X | Matching top-level windows are synced to every materialized workspace. Sticky-only occupancy does not keep dynamic workspaces alive, and scratchpad clears sticky state. |
| Window rules | Open floating | `windowrule isfloating` | WM policy | `window-rule open-floating` | X | Explicit `#false` can override parented dialog floating defaults. |
| Window rules | Open focused | `windowrule isopensilent` | WM policy | `window-rule open-focused` | X | Triad uses positive Niri-style naming for Mango's open-silent escape hatch. |
| Window rules | Open fullscreen/maximized | `isfullscreen`, `isfakefullscreen`, `noopenmaximized` | WM policy | `open-fullscreen`, `open-maximized`, `open-maximized-to-edges` | X | `open-maximized` means full-width scroller column; `open-maximized-to-edges` means client-visible maximize. |
| Window rules | Maximize action policy | `force_fakemaximize`, `ignore_maximize` | WM policy | `maximize-policy` | X | `edge` keeps client-visible maximize, `column` maps maximize actions to full-width scroller columns, and `ignore` refuses maximize-on actions. |
| Window rules | Open sizing/output | `width`, `height`, `monitor`, `scroller_proportion`, `scroller_proportion_single` | WM policy | `open-on-output`, `default-column-width`, `scroller-proportion`, `scroller-single-proportion`, `default-window-width`, `default-window-height` | X | `open-on-output` targets a visible output workspace by connector, shell fallback, make/model identity, or description, and with `default-workspace` may silently map a non-primary output to that workspace. `scroller-proportion` overrides `default-column-width` for new scroller columns; `scroller-single-proportion` centers a single scroller column only. |
| Window rules | Open named scratchpad | `isnamedscratchpad`, `single_scratchpad` | WM policy | `open-named-scratchpad`, `toggle-named-scratchpad` | X | New matching windows open hidden and untagged until toggled; live restore wins over the rule. |
| Window rules | Size bounds | `width`, `height`, `isnosizehint` | size-hint policy | `min-width`, `min-height`, `max-width`, `max-height`, `respect-size-hints` | X | Rule bounds constrain geometry without changing placement; `respect-size-hints #false` ignores client hints while keeping explicit Triad bounds. |
| Window rules | Parented float role | `isfloating`, `isoverlay`, app rules | WM policy | `window-rule parented-role` | X | `dialog`, `tool`, and `plain` separate transient dialogs from persistent parented floats without using overlay/global state. |
| Window rules | Dialog viewport jump | Window rule/policy-specific | WM policy | `window-rule dialog-viewport-jump` | X | Matches the parent app rule; opts specific apps out of hide-until-visible dialog focus. |
| Window rules | Forced layout | `windowrule scroller_proportion...` and layout rules | WM policy | `window-rule forced-layout` | X | Triad supports forced layout selection, not every Mango per-window layout parameter. |
| Window rules | Shortcut inhibition | `allow_shortcuts_inhibit` | client inhibit protocol/policy | `keyboard-shortcuts-inhibit`, `toggle-keyboard-shortcuts-inhibit` | X | |
| Window rules | Presentation/tearing policy | `allow_tearing`, `force_tearing`, `vrr` | `river_output_v1.set_presentation_mode` | `presentation-mode` | X | Focused matching window rules can request output-level vsync/async mode; global `presentation-mode` remains the fallback. |
| Window rules | Client tiled hint | `force_tiled_state` | `river_window_v1.set_tiled` | `window-rule tiled-state` | X | Controls the client-visible tiled state only; Triad placement is unchanged. |
| Window rules | Open silent/tag silent | `isopensilent`, `istagsilent` | WM policy | `window-rule open-focused`, `default-workspace` | X | `open-focused #false` covers open-silent; explicit `default-workspace` is the workspace placement escape hatch. |
| Window rules | Geometry offsets | `width`, `height`, `offsetx`, `offsety` | WM policy | `window-rule floating`, `center-floating`, `default-floating-position` | X | Rule-level floating ratios or fixed pixel sizes override global default size; `center-floating` centers generated geometry and `default-floating-position` provides anchored pixel placement. |
| Window rules | Visual effects | `noblur`, `isnoborder`, opacity, animation flags | WM/render policy | `border`, `focus-ring`, `clip-to-geometry`, `enable-animations`, `animation-speed`, `animation-snap-threshold` | | Rule-level border, focused-only focus-ring width/colors, geometry clipping, and global viewport animation tuning are supported; opacity, blur, shadows, radius, and per-window animation policy are not. |
| Window rules | Terminal swallowing | `isterm`, `noswallow` | WM policy and process ancestry | `window-rule terminal`, `window-rule allow-swallow` | X | Explicit rules only: terminal hosts must be marked with `terminal #true`; child windows swallow by default unless `allow-swallow #false`, and missing PID data disables swallowing. |
| Window rules | Global keybinding | `globalkeybinding` | WM policy | | | Not implemented. |
| Layer rules | Layer shell rules | `layerrule` | Layer shell protocols | | | Triad handles shell/layer focus but has no rule config. |
| Shell | Shell integration | External bars/tools | Protocol/shell surfaces | `shells`, `switch-shell`, `cycle-shell`, native state events | X | Triad has config-driven shell profile launch/stop, Niri-compatible profile env, runtime switching, and native events. |
| Shell | Hotkey helper overlay | | WM policy and shell surface | `hotkey-overlay`, `toggle-hotkey-overlay` | X | Native popup generated from configured bindings and per-bind titles; adds a free fallback key when needed. |
| Shell | Window menu | `show_window_menu` request policy | River window menu request | `window-menu-command` | X | Capability is advertised only when configured. |
| Screenshot | Screenshots | External binds to `spawn` | External tools | `screenshot`, `screenshot-screen`, `screenshot-window`, `screenshot` config | X | Triad wraps configured capture tools and emits Niri-compatible events. |
| Portals | XDG portal setup | Portal config docs | External services | | | Not Triad config. |
| Virtual output | Headless output | `create_virtual_output`, `destroy_all_virtual_output` | River compositor/output stack | | | Not exposed by Triad. |

## Mango Inventory

Configuration keys:

- Lifecycle and startup: `source`, `source-optional`, `env`, `exec-once`,
  `exec`, `mango -c`, `mango -c ... -p`.
- Monitor/output: `monitorrule` with `name`, `make`, `model`, `serial`,
  `width`, `height`, `refresh`, `x`, `y`, `scale`, `vrr`, `rr`, `custom`;
  `allow_tearing`.
- Keyboard input: `repeat_rate`, `repeat_delay`, `numlockon`,
  `xkb_rules_rules`, `xkb_rules_model`, `xkb_rules_layout`,
  `xkb_rules_variant`, `xkb_rules_options`.
- Mouse and touchpad input: `mouse_natural_scrolling`,
  `mouse_accel_profile`, `mouse_accel_speed`, `left_handed`,
  `axis_scroll_factor`, `disable_trackpad`, `tap_to_click`,
  `tap_and_drag`, `trackpad_natural_scrolling`, `trackpad_accel_profile`,
  `trackpad_accel_speed`, `scroll_button`, `scroll_method`,
  `click_method`, `send_events_mode`, `drag_lock`,
  `disable_while_typing`, `middle_button_emulation`,
  `swipe_min_threshold`, `button_map`, `trackpad_scroll_factor`.
- Misc: `xwayland_persistence`, `syncobj_enable`,
  `allow_lock_transparent`, `allow_shortcuts_inhibit`, `focus_on_activate`,
  `sloppyfocus`, `warpcursor`, `cursor_hide_timeout`,
  `drag_tile_to_tile`, `drag_tile_small`, `drag_corner`,
  `drag_warp_cursor`, `axis_bind_apply_timeout`, `focus_cross_monitor`,
  `exchange_cross_monitor`, `focus_cross_tag`, `view_current_to_back`,
  `scratchpad_cross_monitor`, `single_scratchpad`, `circle_layout`,
  `enable_floating_snap`, `snap_distance`, `no_border_when_single`,
  `idleinhibit_ignore_visible`, `drag_tile_refresh_interval`,
  `drag_floating_refresh_interval`.
- Layouts: `scroller_structs`, `scroller_default_proportion`,
  `scroller_focus_center`, `scroller_prefer_center`,
  `scroller_prefer_overspread`, `edge_scroller_pointer_focus`,
  `scroller_proportion_preset`, `scroller_ignore_proportion_single`,
  `scroller_default_proportion_single`, `new_is_master`, `default_mfact`,
  `default_nmaster`, `smartgaps`, `center_master_overspread`,
  `center_when_single_stack`.
- Overview and scratchpad: `hotarea_size`, `enable_hotarea`,
  `hotarea_corner`, `ov_tab_mode`, `overviewgappi`, `overviewgappo`,
  `scratchpad_width_ratio`, `scratchpad_height_ratio`, `scratchpadcolor`.

Bindable dispatchers:

- Window management: `killclient`, `togglefloating`,
  `toggle_all_floating`, `togglefullscreen`, `togglefakefullscreen`,
  `togglemaximizescreen`, `toggleglobal`, `toggle_render_border`,
  `centerwin`, `minimized`, `restore_minimized`, `toggle_scratchpad`,
  `toggle_named_scratchpad`.
- Focus and movement: `focusdir`, `focusstack`, `focuslast`,
  `exchange_client`, `exchange_stack_client`, `zoom`.
- Tags and monitors: `view`, `viewtoleft`, `viewtoright`,
  `viewtoleft_have_client`, `viewtoright_have_client`, `viewcrossmon`,
  `tag`, `tagsilent`, `tagtoleft`, `tagtoright`, `tagcrossmon`,
  `toggletag`, `toggleview`, `comboview`, `focusmon`, `tagmon`.
- Layouts: `setlayout`, `switch_layout`, `incnmaster`, `setmfact`,
  `set_proportion`, `switch_proportion_preset`, `scroller_stack`,
  `incgaps`, `togglegaps`.
- System: `spawn`, `spawn_shell`, `spawn_on_empty`, `reload_config`,
  `quit`, `toggleoverview`, `create_virtual_output`,
  `destroy_all_virtual_output`, `toggleoverlay`, `toggle_trackpad_enable`,
  `setkeymode`, `switch_keyboard_layout`, `setoption`,
  `disable_monitor`, `enable_monitor`, `toggle_monitor`.
- Floating movement: `smartmovewin`, `smartresizewin`, `movewin`,
  `resizewin`.
- Pointer and hardware bindings: `mousebind`, `axisbind`, `gesturebind`,
  `switchbind`.

Rules:

- `windowrule`: `appid`, `title`, `isfloating`, `isfullscreen`,
  `isfakefullscreen`, `isglobal`, `isoverlay`, `isopensilent`,
  `istagsilent`, `force_fakemaximize`, `ignore_maximize`,
  `ignore_minimize`, `force_tiled_state`, `noopenmaximized`,
  `single_scratchpad`, `allow_shortcuts_inhibit`,
  `indleinhibit_when_focus`, `width`, `height`, `offsetx`, `offsety`,
  `monitor`, `tags`, `no_force_center`, `isnosizehint`, `noblur`,
  `isnoborder`, `isnoshadow`, `isnoradius`, `isnoanimation`,
  `focused_opacity`, `unfocused_opacity`, `allow_csd`,
  `scroller_proportion`, `scroller_proportion_single`,
  `animation_type_open`, `animation_type_close`, `nofadein`,
  `nofadeout`, `isterm`, `noswallow`, `globalkeybinding`,
  `isunglobal`, `isnamedscratchpad`, `force_tearing`.
- `tagrule`: `id`, `monitor_name`, `monitor_make`, `monitor_model`,
  `monitor_serial`, `layout_name`, `no_render_border`,
  `open_as_floating`, `no_hide`, `nmaster`, `mfact`.
- `layerrule`: `layer_name`, `animation_type_open`,
  `animation_type_close`, `noblur`, `noanim`, `noshadow`.

## River Inventory

River command-line and startup surface:

- `river -h`
- `river -version`
- `river -c <shell_command>`
- `river -log-level error|warning|info|debug`
- `river -no-xwayland`
- Startup init executable at `$XDG_CONFIG_HOME/river/init` or
  `~/.config/river/init`.

Window-management protocol requests used as the comparable River surface:

- Manager: `stop`, `manage_finish`, `manage_dirty`, `render_finish`,
  `get_shell_surface`, `exit_session`.
- Window: `close`, `get_node`, `propose_dimensions`, `hide`, `show`,
  `use_csd`, `use_ssd`, `set_borders`, `set_tiled`,
  `get_decoration_above`, `get_decoration_below`,
  `inform_resize_start`, `inform_resize_end`, `set_capabilities`,
  `inform_maximized`, `inform_unmaximized`, `inform_fullscreen`,
  `inform_not_fullscreen`, `fullscreen`, `exit_fullscreen`,
  `set_clip_box`, `set_content_clip_box`, `set_dimension_bounds`.
- Node/output/seat: `set_position`, `place_top`, `place_bottom`,
  `place_above`, `place_below`, `set_presentation_mode`,
  `focus_window`, `focus_shell_surface`, `clear_focus`,
  `op_start_pointer`, `op_end`, `get_pointer_binding`,
  `set_xcursor_theme`, `pointer_warp`.
- Pointer and key binding protocols: `enable`, `disable`,
  `get_xkb_binding`, `set_layout_override`, `ensure_next_key_eaten`,
  `cancel_ensure_next_key_eaten`, `modifiers_watch`.
- Input management: `create_seat`, `destroy_seat`, `assign_to_seat`,
  `set_repeat_info`, `set_scroll_factor`, `map_to_output`,
  `map_to_rectangle`.
- XKB/libinput config: `create_keymap`, `set_keymap`,
  `set_layout_by_index`, `set_layout_by_name`, `capslock_enable`,
  `capslock_disable`, `numlock_enable`, `numlock_disable`,
  `set_send_events`, `set_tap`, `set_tap_button_map`, `set_drag`,
  `set_drag_lock`, `set_three_finger_drag`, `set_calibration_matrix`,
  `set_accel_profile`, `set_accel_speed`, `apply_accel_config`,
  `set_natural_scroll`, `set_left_handed`, `set_click_method`,
  `set_clickfinger_button_map`, `set_middle_emulation`,
  `set_scroll_method`, `set_scroll_button`, `set_scroll_button_lock`,
  `set_dwt`, `set_dwtp`, `set_rotation`.

## Triad Inventory

KDL config nodes and fields:

- `include`: required and optional in-place config includes.
- `layout`: `gaps`, `center-focused-column`, `default-column-width`,
  `default-window-width`, `default-window-height`, `master.count`,
  `master.split-ratio`, `border.width`, `border.active-color`,
  `border.inactive-color`, `scroller-focus-center`,
  `scroller-prefer-center`, `enable-animations`, `animation-speed`,
  `animation-snap-threshold`,
  `smart-gaps`, `layout-cycle`.
- `workspaces`: `default-count`, `default-layout`.
- `output`: `focus-at-startup`, `workspaces`.
- `workspace-rules`: `workspace <id> name=... default-layout=...
  open-on-output=...`.
- `window-rule`: `match app-id=... title=... is-focused=... is-active=...
  is-active-in-column=... is-floating=... at-startup=...`, matching `exclude` properties,
  `default-workspace`, `default-workspaces`,
  `open-on-output`, `default-column-width`, `scroller-proportion`,
  `scroller-single-proportion`, `default-window-width`, `default-window-height`,
  `open-named-scratchpad`, `open-on-all-workspaces`, `open-overlay`,
  `terminal`, `allow-swallow`,
  `min-width`, `min-height`, `max-width`, `max-height`,
  `open-floating`, `open-focused`, `open-fullscreen`, `open-maximized`,
  `open-maximized-to-edges`, `maximize-policy`, `parented-role`,
  `dialog-viewport-jump`, `keyboard-shortcuts-inhibit`, `idle-inhibit`,
  `presentation-mode`, `border`, `focus-ring`, `clip-to-geometry`,
  `tiled-state`, `forced-layout`, nested `floating` with ratio or fixed pixel
  size fields, and `default-floating-position`.
- `environment`, `spawn-at-startup`, `window-menu-command`.
- `bindings`: `mirror-hjkl-arrows`, `bind`, `pointer-bind`, `axis-bind`,
  `gesture-bind`, plus `layout`, `mode`, `allow-inhibiting`,
  `on-release`, `while-locked`, `hotkey-overlay-title`, and gesture `fingers`
  properties.
- `switch-events`: `lid-close`, `lid-open`, `tablet-mode-on`,
  `tablet-mode-off`.
- `shells`: `enabled`, `active`, `cycle`, `watchdog`, `fallback`,
  `exclusive-focus-timeout-ms`, `profile`, `launch`, `stop`, `niri-compat`.
- `quickshell`: legacy fallback accepted when `shells` is absent.
- `janet`: `enabled`, `manifest-dir`, `system-manifest-dir`, `fuel-limit`,
  `manifest-alias`.
  Manifests receive `triad/snapshot` and `triad/current-window`, and can emit
  every registered user command through `triad/command`.
- `terminal`: `command`.
- `screen-lock`: `command`.
- `scratchpad`: `width-ratio`, `height-ratio`.
- `layout-switch-toast`: `enabled`, `timeout-ms`, `ring-color`.
- `overview`: `outer-gap`, `inner-gap-multiplier`, `zoom`, `tab-mode`,
  `scroller-indicators`, `hot-corners`.
- `recent-windows`: `off`, `debounce-ms`, `open-delay-ms`, `highlight`,
  `previews`, `binds`.
- `hotkey-overlay`: `skip-at-startup`, `hide-not-bound`, `position`, and
  `columns`; generated default configs show the centered helper at startup,
  while omitted fields keep `skip-at-startup` on and `position` top. While open
  it captures the next non-modifier key and dismisses without running bound
  commands.
- `config-notification`: `reload-succeeded`, `reload-failed`,
  `reload-rolled-back`.
- `input`: `keyboard`, `mouse`, `touchpad`, `trackpoint`, `trackball`,
  including keyboard repeat, XKB, lock-state, and libinput pointer fields.
- `floating`: `x-ratio`, `y-ratio`, `width-ratio`, `height-ratio`,
  `min-width`, `min-height`.
- `screenshot`: `directory`, `filename-prefix`, `capture-command`,
  `region-selector-command`, `clipboard-command`, `show-pointer`.
- `cursor`: `theme`, `size`, `shake-to-find`, `hide-when-typing`,
  `hide-after-inactive-ms`.
- Top-level: `presentation-mode`, `allow-exit-session`,
  `protocol-surfaces.enabled`, `protocol-surfaces.visible-debug`.

Text IPC and bind commands:

- Focus: `focus-next`, `focus-prev`, `focus-left`, `focus-right`,
  `focus-up`, `focus-down`, `focus-last`, `focus-tag-left`,
  `focus-tag-right`, `focus-occupied-tag-left`,
  `focus-occupied-tag-right`, `focus-column-first`,
  `focus-column-last`, `focus-window-or-workspace-up`,
  `focus-window-or-workspace-down`, `focus-window`,
  `focus-workspace`, `focus-tag`, `focus-output`, `focus-shell-ui`,
  `recent-window-next`, `recent-window-prev`, `recent-window-confirm`,
  `recent-window-cancel`, `recent-window-first`, `recent-window-last`,
  `recent-window-scope`, `recent-window-cycle-scope`,
  `recent-window-close-current`.
- Window and session: `close-window`, `toggle-floating`,
  `fullscreen-window`, `toggle-fullscreen`, `exit-fullscreen`,
  `maximize-window-to-edges`, `toggle-maximized`, `toggle-maximize`,
  `minimize`, `minimize-window`, `spawn`,
  `spawn-terminal`, `lock-session`, `warp-pointer`, `eat-next-key`,
  `cancel-eat-next-key`, `toggle-keyboard-shortcuts-inhibit`,
  `keyboard-shortcuts-inhibit`, `stop-manager`, `triad-reload`,
  `exit-session`, `config-reload`, `screenshot`, `screenshot-screen`,
  `screenshot-window`, `show-hotkey-overlay`, `hide-hotkey-overlay`,
  `toggle-hotkey-overlay`.
- Layout: `layout-scroller`, `layout-vertical-scroller`,
  `layout-tile`, `layout-grid`, `layout-monocle`, `layout-deck`,
  `layout-center-tile`, `layout-right-tile`, `layout-vertical-tile`,
  `layout-vertical-grid`, `layout-vertical-deck`, `layout-tgmix`,
  `switch-layout`,
  `master-count`, `adjust-master-count`, `master-ratio`,
  `adjust-master-ratio`, `maximize-column`, `resize-width`, `resize-height`,
  `set-column-width`, `adjust-gaps`, `toggle-gaps`, `zoom`.
- Tags, movement, and groups: `move-to-tag-left`, `move-to-tag-right`,
  `move-to-tag`, `move-to-workspace`, `move-workspace-to-output`,
  `move-to-output`, `swap-to-tag`, `rename-tag`, `move-floating`,
  `resize-floating`, `consume-window`,
  `expel-window`, `move-column-left`, `move-column-right`,
  `move-column-to-first`, `move-column-to-last`, `move-window-left`,
  `move-window-right`, `move-window-up`, `move-window-down`,
  `move-window-up-or-to-workspace-up`,
  `move-window-down-or-to-workspace-down`, `swap-window-up`,
  `swap-window-down`, `group-windows`, `ungroup-window`,
  `focus-next-in-group`.
- Overview and scratchpad: `toggle-overview`, `open-overview`,
  `close-overview`, `select-window`, `move-to-scratchpad`,
  `move-to-named-scratchpad`, `toggle-scratchpad`,
  `toggle-named-scratchpad`, `restore-scratchpad`.

Native JSON IPC requests:

- `state`
- `layout-state`
- `set-layout`
- `switch-layout`
- `event-stream`

CLI and environment:

- `TRIAD_CONFIG`, `triad --config <path>`, and `triad -c <path>` select a
  non-default root config path.
- `triad validate-config [--config <path>]` checks config syntax, includes, and
  strict window-rule regex validation without starting the daemon.
