(defn clamp-dim [value]
  (max 1 (math/floor value)))

(defn flatten-tiled-windows [columns]
  (def windows @[])
  (each column columns
    (each win-id (column :windows)
      (array/push windows win-id)))
  windows)

(triad/def-layout :janet-grid
  (fn [ctx]
    (def screen (ctx :screen))
    (def tag (ctx :tag))
    (def windows (flatten-tiled-windows (tag :columns)))
    (def count (length windows))
    (if (= count 0)
      []
      (do
        (def outer-gap (ctx :outer-gap))
        (def inner-gap (ctx :inner-gap))
        (def cols (math/ceil (math/sqrt count)))
        (def rows (math/ceil (/ count cols)))
        (def usable-x (+ (screen :x) outer-gap))
        (def usable-y (+ (screen :y) outer-gap))
        (def usable-w (max 1 (- (screen :w) (* 2 outer-gap))))
        (def usable-h (max 1 (- (screen :h) (* 2 outer-gap))))
        (def cell-w (/ (- usable-w (* inner-gap (- cols 1))) cols))
        (def cell-h (/ (- usable-h (* inner-gap (- rows 1))) rows))
        (def instructions @[])
        (for i 0 count
          (def col (% i cols))
          (def row (math/floor (/ i cols)))
          (array/push instructions
            {:window-id (windows i)
             :x (math/floor (+ usable-x (* col (+ cell-w inner-gap))))
             :y (math/floor (+ usable-y (* row (+ cell-h inner-gap))))
             :w (clamp-dim cell-w)
             :h (clamp-dim cell-h)}))
        instructions))))
