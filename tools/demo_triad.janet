#!/usr/bin/env janet

(var workspace 9)
(var pace 1.2)
(var terminal "kitty")
(var dry-run false)
(var notify false)

(def env-triad-bin (os/getenv "TRIAD_BIN" ""))
(def triad-bin
  (if (> (length env-triad-bin) 0)
    env-triad-bin
    (if (os/stat "./triad")
      "./triad"
      "triad")))

(defn usage []
  (print "usage: janet tools/demo_triad.janet [options]")
  (print "")
  (print "Options:")
  (print "  --workspace <n>   Workspace used for the demo windows. Default: 9")
  (print "  --pace <seconds>  Pause between visible actions. Default: 1.2")
  (print "  --terminal <cmd>  Terminal used for demo windows. Default: kitty")
  (print "  --notify          Send scene titles through notify-send when available")
  (print "  --dry-run         Print commands without changing the live session")
  (print "  --help            Show this help"))

(defn die [message]
  (eprint "demo_triad: " message)
  (os/exit 1))

(defn value-after [args idx option]
  (if (< (+ idx 1) (length args))
    (args (+ idx 1))
    (die (string option " requires a value"))))

(defn parse-positive-number [value option]
  (def parsed (scan-number value))
  (if (and parsed (> parsed 0))
    parsed
    (die (string option " must be a positive number"))))

(defn parse-positive-int [value option]
  (def parsed (parse-positive-number value option))
  (if (= parsed (math/floor parsed))
    parsed
    (die (string option " must be a positive integer"))))

(defn parse-args [args]
  (var idx 0)
  (while (< idx (length args))
    (def arg (args idx))
    (cond
      (= arg "--help")
        (do
          (usage)
          (os/exit 0))
      (= arg "--dry-run")
        (set dry-run true)
      (= arg "--notify")
        (set notify true)
      (= arg "--workspace")
        (do
          (def value (value-after args idx arg))
          (set workspace (parse-positive-int value arg))
          (set idx (+ idx 1)))
      (= arg "--pace")
        (do
          (def value (value-after args idx arg))
          (set pace (parse-positive-number value arg))
          (set idx (+ idx 1)))
      (= arg "--terminal")
        (do
          (def value (value-after args idx arg))
          (when (= value "")
            (die "--terminal cannot be empty"))
          (set terminal value)
          (set idx (+ idx 1)))
      :else
        (die (string "unknown option: " arg)))
    (set idx (+ idx 1))))

(defn command-line-args []
  (def raw (dyn :args))
  (if (> (length raw) 0)
    (array/slice raw 1)
    @[]))

(defn command-text [cmd]
  (string/join cmd " "))

(defn run-command [cmd]
  (print "+ " (command-text cmd))
  (unless dry-run
    (def status (os/execute cmd :p))
    (when (not= status 0)
      (die (string "command failed with status " status ": " (command-text cmd))))))

(defn run-detached [cmd]
  (print "+ " (command-text cmd))
  (unless dry-run
    (os/spawn cmd :pd)))

(defn run-shell-quiet [script]
  (unless dry-run
    (def status (os/execute @["sh" "-lc" script] :p))
    (= status 0)))

(defn command-available? [name]
  (if dry-run
    true
    (run-shell-quiet (string "command -v " name " >/dev/null 2>&1"))))

(defn triad-ready? []
  (if dry-run
    true
    (run-shell-quiet
      (string triad-bin " msg dump-live-restore-state >/dev/null 2>&1"))))

(defn preflight []
  (unless (triad-ready?)
    (die (string "Triad IPC is not reachable through " triad-bin)))
  (unless (command-available? terminal)
    (die (string "terminal command is not available: " terminal))))

(defn pause []
  (unless dry-run
    (ev/sleep pace)))

(defn maybe-notify [title]
  (when (and notify (command-available? "notify-send"))
    (run-command @["notify-send" "Triad demo" title])))

(defn announce [title]
  (print "")
  (print "== " title " ==")
  (maybe-notify title)
  (pause))

(defn triad-msg [& parts]
  (var cmd @[triad-bin "msg"])
  (each part parts
    (array/push cmd (string part)))
  (run-command cmd))

(defn demo-body [title]
  (string
    "export TERM=${TRIAD_DEMO_TERM:-xterm-256color}; "
    "printf '\\033]0;" title "\\007'; "
    "clear; "
    "printf 'Triad demo window: " title "\\n\\n'; "
    "printf 'Keep this window open while recording.\\n'; "
    "exec sh"))

(defn terminal-argv [title]
  (def body (demo-body title))
  (cond
    (= terminal "kitty")
      @[terminal "--title" title "sh" "-c" body]
    (= terminal "foot")
      @[terminal "--title" title "sh" "-c" body]
    (= terminal "alacritty")
      @[terminal "--title" title "-e" "sh" "-c" body]
    (= terminal "wezterm")
      @[terminal "start" "--always-new-process" "--" "sh" "-c" body]
    :else
      @[terminal "sh" "-c" body]))

(defn spawn-demo-window [title]
  (run-detached (terminal-argv title))
  (pause))

(defn scene-setup []
  (announce "Setup workspace")
  (triad-msg "focus-workspace" workspace)
  (triad-msg "layout-scroller")
  (spawn-demo-window "triad-demo-1")
  (spawn-demo-window "triad-demo-2")
  (spawn-demo-window "triad-demo-3")
  (triad-msg "focus-workspace" workspace)
  (pause))

(defn scene-layouts []
  (announce "Layouts")
  (each layout ["layout-scroller"
                "layout-tile"
                "layout-grid"
                "layout-monocle"
                "layout-deck"
                "layout-center-tile"
                "layout-vertical-grid"
                "layout-tgmix"]
    (triad-msg layout)
    (pause)))

(defn scene-navigation []
  (announce "Focus navigation")
  (each action ["focus-next"
                "focus-prev"
                "focus-right"
                "focus-left"
                "focus-column-first"
                "focus-column-last"]
    (triad-msg action)
    (pause)))

(defn scene-window-state []
  (announce "Floating, maximize, fullscreen")
  (triad-msg "toggle-floating")
  (pause)
  (triad-msg "move-floating" 80 40)
  (pause)
  (triad-msg "resize-floating" 80 60)
  (pause)
  (triad-msg "toggle-floating")
  (pause)
  (triad-msg "maximize-window-to-edges")
  (pause)
  (triad-msg "maximize-window-to-edges")
  (pause)
  (triad-msg "fullscreen-window")
  (pause)
  (triad-msg "toggle-fullscreen")
  (pause))

(defn scene-scratchpad []
  (announce "Scratchpad")
  (triad-msg "move-to-scratchpad")
  (pause)
  (triad-msg "toggle-scratchpad")
  (pause)
  (triad-msg "toggle-scratchpad")
  (pause)
  (triad-msg "toggle-scratchpad")
  (pause)
  (triad-msg "restore-scratchpad")
  (pause))

(defn scene-overview-recent []
  (announce "Overview and recent windows")
  (triad-msg "open-overview")
  (pause)
  (triad-msg "focus-right")
  (pause)
  (triad-msg "focus-left")
  (pause)
  (triad-msg "close-overview")
  (pause)
  (triad-msg "recent-window-next")
  (pause)
  (triad-msg "recent-window-next")
  (pause)
  (triad-msg "recent-window-cancel")
  (pause))

(defn scene-grouping []
  (announce "Grouping")
  (triad-msg "layout-tile")
  (pause)
  (triad-msg "group-windows")
  (pause)
  (triad-msg "focus-next-in-group")
  (pause)
  (triad-msg "ungroup-window")
  (pause))

(defn scene-finish []
  (announce "Finish")
  (triad-msg "focus-workspace" workspace)
  (triad-msg "layout-scroller")
  (print "")
  (print "Triad demo sequence complete."))

(parse-args (command-line-args))
(preflight)
(scene-setup)
(scene-layouts)
(scene-navigation)
(scene-window-state)
(scene-scratchpad)
(scene-overview-recent)
(scene-grouping)
(scene-finish)
