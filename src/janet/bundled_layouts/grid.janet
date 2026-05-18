(defn triad/layout-grid [ctx vertical]
  (def tag (ctx :tag))
  (def windows (triad/layout-flatten-windows (tag :columns)))
  (def n (length windows))
  (if (= n 0)
    []
    (do
      (def c (triad/layout-common ctx))
      (def cols (if vertical
                  (math/ceil (/ n (math/ceil (math/sqrt n))))
                  (math/ceil (math/sqrt n))))
      (def rows (if vertical
                  (math/ceil (math/sqrt n))
                  (math/ceil (/ n cols))))
      (def win-w (triad/layout-clamp-nonnegative
                   (triad/layout-idiv
                     (- (c :usable-w) (* (- cols 1) (c :inner-gap)))
                     cols)))
      (def win-h (triad/layout-clamp-nonnegative
                   (triad/layout-idiv
                     (- (c :usable-h) (* (- rows 1) (c :inner-gap)))
                     rows)))
      (def instructions @[])
      (for i 0 n
        (def col (if vertical
                   (triad/layout-idiv i rows)
                   (% i cols)))
        (def row (if vertical
                   (% i rows)
                   (triad/layout-idiv i cols)))
        (array/push instructions
          {:window-id (windows i)
           :x (+ (c :usable-x) (* col (+ win-w (c :inner-gap))))
           :y (+ (c :usable-y) (* row (+ win-h (c :inner-gap))))
           :w win-w
           :h win-h}))
      instructions)))

(triad/def-layout :grid (fn [ctx] (triad/layout-grid ctx false)))
