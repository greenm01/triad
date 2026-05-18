(defn triad/spiral-side-order [main-pane clockwise]
  (def clockwise-order ["left" "top" "right" "bottom"])
  (def anticlockwise-order ["left" "bottom" "right" "top"])
  (def source (if clockwise clockwise-order anticlockwise-order))
  (var start 0)
  (for i 0 (length source)
    (when (= (source i) main-pane)
      (set start i)))
  (def order @[])
  (for i 0 (length source)
    (array/push order (source (% (+ start i) (length source)))))
  order)

(defn triad/spiral-split-horizontal [rect ratio gap left?]
  (def available (max 1 (- (rect :w) gap)))
  (def first-w
    (if (<= available 1)
      1
      (min (- available 1) (max 1 (math/floor (* available ratio))))))
  (def second-w (max 1 (- available first-w)))
  (if left?
    [{:x (rect :x) :y (rect :y) :w first-w :h (rect :h)}
     {:x (+ (rect :x) first-w gap) :y (rect :y) :w second-w :h (rect :h)}]
    [{:x (+ (rect :x) second-w gap) :y (rect :y) :w first-w :h (rect :h)}
     {:x (rect :x) :y (rect :y) :w second-w :h (rect :h)}]))

(defn triad/spiral-split-vertical [rect ratio gap top?]
  (def available (max 1 (- (rect :h) gap)))
  (def first-h
    (if (<= available 1)
      1
      (min (- available 1) (max 1 (math/floor (* available ratio))))))
  (def second-h (max 1 (- available first-h)))
  (if top?
    [{:x (rect :x) :y (rect :y) :w (rect :w) :h first-h}
     {:x (rect :x) :y (+ (rect :y) first-h gap) :w (rect :w) :h second-h}]
    [{:x (rect :x) :y (+ (rect :y) second-h gap) :w (rect :w) :h first-h}
     {:x (rect :x) :y (rect :y) :w (rect :w) :h second-h}]))

(defn triad/spiral-split [rect side ratio gap]
  (if (or (= side "left") (= side "right"))
    (triad/spiral-split-horizontal rect ratio gap (= side "left"))
    (triad/spiral-split-vertical rect ratio gap (= side "top"))))

(defn triad/layout-spiral [ctx]
  (def tag (ctx :tag))
  (def windows (triad/layout-flatten-windows (tag :columns)))
  (def n (length windows))
  (if (= n 0)
    []
    (do
      (def c (triad/layout-common ctx))
      (def options ((ctx :layout-options) :spiral))
      (def ratio (triad/layout-clamp-ratio (options :ratio)))
      (def main-ratio
        (triad/layout-clamp-ratio
          (if (options :main-pane-ratio-set)
            (options :main-pane-ratio)
            ratio)))
      (def order
        (triad/spiral-side-order (options :main-pane) (options :clockwise)))
      (def instructions @[])
      (var rect
        {:x (c :usable-x)
         :y (c :usable-y)
         :w (max 1 (c :usable-w))
         :h (max 1 (c :usable-h))})
      (for i 0 n
        (if (= i (- n 1))
          (array/push instructions
            {:window-id (windows i)
             :x (rect :x)
             :y (rect :y)
             :w (rect :w)
             :h (rect :h)})
          (do
            (def split-ratio (if (= i 0) main-ratio ratio))
            (def split
              (triad/spiral-split rect (order (% i (length order)))
                split-ratio (c :inner-gap)))
            (def window-rect (split 0))
            (set rect (split 1))
            (array/push instructions
              {:window-id (windows i)
               :x (window-rect :x)
               :y (window-rect :y)
               :w (window-rect :w)
               :h (window-rect :h)}))))
      instructions)))

(triad/def-layout :spiral triad/layout-spiral)
