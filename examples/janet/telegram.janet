(def fallback-chat-tag 4)

(def telegram-app-ids
  ["telegram-desktop"
   "TelegramDesktop"
   "org.telegram.desktop"])

(defn value-in? [needle values]
  (var found false)
  (each value values
    (when (= needle value)
      (set found true)))
  found)

(defn telegram-app? [app-id]
  (value-in? app-id telegram-app-ids))

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

(triad/on :window-ready
  (fn [ev]
    (let [window (ev :window)]
      (when (telegram-app? (window :app-id))
        (let [target-tag (chat-tag)
              dialog (dialog-window? window)]
          (triad/command "move-window-to-tag" (window :id) target-tag true)
          (triad/command "set-layout-for-workspace" target-tag "deck")
          (if dialog
            (place-dialog-window window)
            (place-main-window window)))))))
