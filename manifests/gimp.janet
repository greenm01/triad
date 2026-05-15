(def target-workspace 8)

(def utility-title-fragments
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
   "History"
   "Preferences"
   "Export"
   "Open Image"
   "Save"
   "Quit"
   "About"])

(defn gimp-app? [app-id]
  (or (= app-id "gimp")
      (= app-id "gimp-3.2")
      (= app-id "org.gimp.GIMP")))

(defn title-matches? [title fragments]
  (var matched false)
  (each fragment fragments
    (when (string/find fragment title)
      (set matched true)))
  matched)

(defn other-gimp-window? [window current-id]
  (and (not= (window :id) current-id)
       (gimp-app? (window :app-id))))

(defn has-other-gimp-window? [current-id]
  (var found false)
  (each window (triad/snapshot :windows)
    (when (other-gimp-window? window current-id)
      (set found true)))
  found)

(defn utility-window? [window]
  (or (> (window :parent-id) 0)
      (title-matches? (window :title) utility-title-fragments)))

(defn main-window? [window]
  (not (utility-window? window)))

(let [window triad/current-window]
  (when (and window (gimp-app? (window :app-id)))
    (let [follow (or (main-window? window)
                     (not (has-other-gimp-window? (window :id))))]
      (triad/move-window-to-tag (window :id) target-workspace follow)
      (triad/set-layout-for-workspace target-workspace "scroller")
      (if (main-window? window)
        (triad/set-window-maximized (window :id) true)
        (triad/set-window-floating (window :id) true)))))
