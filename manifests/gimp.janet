(def target-workspace 8)

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
          follow (should-follow? kind window)]
      (triad/command "move-window-to-tag" (window :id) target-workspace follow)
      (triad/command "set-layout-for-workspace" target-workspace "scroller")
      (if (= kind :main)
        (place-main-window window)
        (place-floating-window window)))))
