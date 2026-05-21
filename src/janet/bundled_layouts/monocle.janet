(defn triad/layout-monocle [ctx]
  (def tag (ctx :tag))
  (def windows (triad/layout-focused-first
                 (triad/layout-flatten-windows (tag :columns))
                 (tag :focused-window)))
  (def c (triad/layout-common ctx))
  (if (= (length windows) 0)
    []
    [{:window-id (windows 0)
      :x (c :usable-x)
      :y (c :usable-y)
      :w (c :usable-w)
      :h (c :usable-h)}]))

(triad/def-layout :monocle triad/layout-monocle)
