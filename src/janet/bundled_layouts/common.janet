(defn triad/layout-clamp-dim [value]
  (max 1 (math/floor value)))

(defn triad/layout-clamp-nonnegative [value]
  (max 0 (math/floor value)))

(defn triad/layout-clamp-ratio [value]
  (min 0.95 (max 0.05 value)))

(defn triad/layout-idiv [a b]
  (math/floor (/ a b)))

(defn triad/layout-flatten-windows [columns]
  (def windows @[])
  (each column columns
    (each win-id (column :windows)
      (array/push windows win-id)))
  windows)

(defn triad/layout-focused-first [windows focused]
  (var focused-idx -1)
  (for i 0 (length windows)
    (when (= (windows i) focused)
      (set focused-idx i)))
  (if (<= focused-idx 0)
    windows
    (do
      (def ordered @[(windows focused-idx)])
      (for i 0 (length windows)
        (when (not= i focused-idx)
          (array/push ordered (windows i))))
      ordered)))

(defn triad/layout-movement-vertical-order [ctx direction]
  (if (= direction :up)
    {:op :move-order :delta -1}
    (if (= direction :down)
      {:op :move-order :delta 1}
      {:op :noop})))

(defn triad/layout-movement-horizontal-order [ctx direction]
  (if (= direction :left)
    {:op :move-order :delta -1}
    (if (= direction :right)
      {:op :move-order :delta 1}
      {:op :noop})))

(defn triad/layout-common [ctx]
  (def screen (ctx :screen))
  (def outer-gap (ctx :outer-gap))
  (def inner-gap (ctx :inner-gap))
  {:screen screen
   :outer-gap outer-gap
   :inner-gap inner-gap
   :usable-x (+ (screen :x) outer-gap)
   :usable-y (+ (screen :y) outer-gap)
   :usable-w (max 0 (- (screen :w) (* 2 outer-gap)))
   :usable-h (max 0 (- (screen :h) (* 2 outer-gap)))})
