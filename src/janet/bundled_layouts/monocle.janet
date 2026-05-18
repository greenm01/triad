(defn triad/layout-monocle [ctx]
  (def tag (ctx :tag))
  (def windows (triad/layout-flatten-windows (tag :columns)))
  (def c (triad/layout-common ctx))
  (def instructions @[])
  (each win-id windows
    (array/push instructions
      {:window-id win-id
       :x (c :usable-x)
       :y (c :usable-y)
       :w (c :usable-w)
       :h (c :usable-h)}))
  instructions)

(triad/def-layout :monocle triad/layout-monocle)
