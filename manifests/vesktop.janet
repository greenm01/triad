(def fallback-chat-tag 4)

(def vesktop-app-ids
  ["vesktop"
   "Vesktop"
   "dev.vencord.Vesktop"])

(defn value-in? [needle values]
  (var found false)
  (each value values
    (when (= needle value)
      (set found true)))
  found)

(defn vesktop-app? [app-id]
  (value-in? app-id vesktop-app-ids))

(defn chat-tag []
  (let [tag (triad/find-tag-by-name "chat")]
    (if tag
      (tag :tag-id)
      fallback-chat-tag)))

(defn dialog-window? [window]
  (> (window :parent-id) 0))

(defn place-main-window [window]
  (triad/command "set-window-floating" (window :id) false)
  (triad/command "set-window-maximized" (window :id) true))

(defn place-dialog-window [window]
  (triad/command "set-window-floating" (window :id) true))

(let [window triad/current-window]
  (when (and window (vesktop-app? (window :app-id)))
    (let [target-tag (chat-tag)
          dialog (dialog-window? window)]
      (triad/command "move-window-to-tag" (window :id) target-tag true)
      (triad/command "set-layout-for-workspace" target-tag "deck")
      (if dialog
        (place-dialog-window window)
        (place-main-window window)))))
