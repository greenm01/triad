const JanetHelperPreludeSource =
  """
(defn triad/spawn [cmd & args]
  (apply triad/command "spawn" cmd args))

(defn triad/spawn-sh [command]
  (triad/command "spawn" "sh" "-lc" command))

(defn triad/volume-up [& amount]
  (triad/command
    "spawn"
    "wpctl"
    "set-volume"
    "@DEFAULT_AUDIO_SINK@"
    (string (if (> (length amount) 0) (amount 0) "5%") "+")))

(defn triad/volume-down [& amount]
  (triad/command
    "spawn"
    "wpctl"
    "set-volume"
    "@DEFAULT_AUDIO_SINK@"
    (string (if (> (length amount) 0) (amount 0) "5%") "-")))

(defn triad/volume-toggle-mute []
  (triad/command "spawn" "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"))

(defn triad/mic-toggle-mute []
  (triad/command "spawn" "wpctl" "set-mute" "@DEFAULT_AUDIO_SOURCE@" "toggle"))

(defn triad/media-play-pause []
  (triad/command "spawn" "playerctl" "play-pause"))

(defn triad/media-next []
  (triad/command "spawn" "playerctl" "next"))

(defn triad/media-prev []
  (triad/command "spawn" "playerctl" "previous"))

(defn triad/media-stop []
  (triad/command "spawn" "playerctl" "stop"))

(defn triad/media-seek [offset]
  (triad/command "spawn" "playerctl" "position" offset))

(defn triad/screenshot [& args]
  (apply triad/command "screenshot" args))

(defn triad/screenshot-screen [& args]
  (apply triad/command "screenshot-screen" args))

(defn triad/screenshot-window [& args]
  (apply triad/command "screenshot-window" args))

(defn triad/record-screen [path]
  (triad/command "spawn" "wf-recorder" "-f" path))

(defn triad/record-region [path]
  (triad/command
    "spawn"
    "sh"
    "-c"
    "geom=$(slurp) && exec wf-recorder -g \"$geom\" -f \"$1\""
    "triad-record-region"
    path))

(defn triad/record-stop []
  (triad/command "spawn" "pkill" "-INT" "wf-recorder"))
"""

const JanetPreludeSource* =
  """
(defn triad/on [event handler]
  (when (and triad/current-event (= event (triad/current-event :kind)))
    (handler triad/current-event)))
""" &
  JanetHelperPreludeSource

const JanetPersistentPreludeSource* = JanetHelperPreludeSource
