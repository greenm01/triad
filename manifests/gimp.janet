(def default-workspace-count 3)

(defn window-on-workspace? [window workspace]
  (or (= (window :workspace-idx) (workspace :workspace-idx))
      (= (window :tag-id) (workspace :tag-id))))

(defn workspace-empty-for-window? [workspace current-id]
  (var occupied false)
  (each window (triad/snapshot :windows)
    (when (and (not= (window :id) current-id)
               (window-on-workspace? window workspace))
      (set occupied true)))
  (not occupied))

(defn next-empty-workspace [current-id]
  (var target 0)
  (each workspace (triad/snapshot :workspaces)
    (let [idx (workspace :workspace-idx)]
      (when (and (workspace-empty-for-window? workspace current-id)
                 (or (= target 0) (< idx target)))
        (set target idx))))
  (if (= target 0)
    (+ default-workspace-count 1)
    target))

(def gimp-app-ids
  ["gimp"
   "gimp-3.2"
   "org.gimp.GIMP"])

(def palette-title-fragments
  ["Toolbox"
   "Tool Options"
   "Layers"
   "Channels"
   "Paths"
   "Brushes"
   "Patterns"
   "Gradients"
   "Palettes"
   "Fonts"
   "Buffers"
   "Images"
   "History"])

(def dialog-title-fragments
  ["Preferences"
   "Export"
   "Open Image"
   "New Image"
   "Scale Image"
   "Save"
   "Quit"
   "Welcome"
   "About"
   "Error"
   "Color"])

(defn value-in? [needle values]
  (var found false)
  (each value values
    (when (= needle value)
      (set found true)))
  found)

(defn gimp-app? [app-id]
  (value-in? app-id gimp-app-ids))

(defn title-matches? [title fragments]
  (var matched false)
  (each fragment fragments
    (when (string/find fragment title)
      (set matched true)))
  matched)

(defn palette-window? [window]
  (title-matches? (window :title) palette-title-fragments))

(defn dialog-window? [window]
  (or (title-matches? (window :title) dialog-title-fragments)
      (> (window :parent-id) 0)))

(defn window-kind [window]
  (cond
    (palette-window? window) :palette
    (dialog-window? window) :dialog
    :else :main))

(defn other-gimp-window? [window current-id]
  (and (not= (window :id) current-id)
       (gimp-app? (window :app-id))))

(defn has-other-gimp-window? [current-id]
  (var found false)
  (each window (triad/snapshot :windows)
    (when (other-gimp-window? window current-id)
      (set found true)))
  found)

(defn existing-gimp-workspace [current-id]
  (var target 0)
  (each window (triad/snapshot :windows)
    (when (and (other-gimp-window? window current-id)
               (> (window :workspace-idx) 0)
               (or (= target 0) (< (window :workspace-idx) target)))
      (set target (window :workspace-idx))))
  target)

(defn target-workspace [window]
  (let [existing (existing-gimp-workspace (window :id))]
    (if (= existing 0)
      (next-empty-workspace (window :id))
      existing)))

(defn should-follow? [kind window]
  (or (= kind :main)
      (= kind :dialog)
      (not (has-other-gimp-window? (window :id)))))

(defn place-main-window [window]
  (triad/command "set-window-floating" (window :id) false)
  (triad/command "set-window-maximized" (window :id) true))

(defn place-floating-window [window]
  (triad/command "set-window-floating" (window :id) true))

(let [window triad/current-window]
  (when (and window (gimp-app? (window :app-id)))
    (let [kind (window-kind window)
          follow (should-follow? kind window)
          target-workspace (target-workspace window)]
      (triad/command "move-window-to-tag" (window :id) target-workspace follow)
      (triad/command "set-layout-for-workspace" target-workspace "scroller")
      (if (= kind :main)
        (place-main-window window)
        (place-floating-window window)))))
