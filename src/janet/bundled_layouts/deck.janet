(defn triad/layout-deck [ctx vertical]
  (def tag (ctx :tag))
  (def windows (triad/layout-focused-first
                 (triad/layout-flatten-windows (tag :columns))
                 (tag :focused-window)))
  (def n (length windows))
  (if (= n 0)
    []
    (do
      (def c (triad/layout-common ctx))
      (def instructions @[])
      (def m-count (min n (tag :master-count)))
      (def s-count (- n m-count))
      (if vertical
        (do
          (def mh (if (> s-count 0)
                    (math/floor (* (c :usable-h)
                                   (triad/layout-clamp-ratio
                                     (tag :master-split-ratio))))
                    (c :usable-h)))
          (def stack-h (max 0 (- (c :usable-h) mh
                                 (if (> s-count 0) (c :inner-gap) 0))))
          (when (> m-count 0)
            (def mw (triad/layout-clamp-nonnegative
                      (triad/layout-idiv
                        (- (c :usable-w) (* (- m-count 1) (c :inner-gap)))
                        m-count)))
            (var x (c :usable-x))
            (for i 0 m-count
              (array/push instructions
                {:window-id (windows i)
                 :x x
                 :y (c :usable-y)
                 :w mw
                 :h mh})
              (set x (+ x mw (c :inner-gap)))))
          (when (> s-count 0)
            (def stack-y (+ (c :usable-y) mh (c :inner-gap)))
            (for i m-count n
              (array/push instructions
                {:window-id (windows i)
                 :x (c :usable-x)
                 :y stack-y
                 :w (c :usable-w)
                 :h stack-h}))))
        (do
          (def mw (if (> s-count 0)
                    (math/floor (* (c :usable-w)
                                   (triad/layout-clamp-ratio
                                     (tag :master-split-ratio))))
                    (c :usable-w)))
          (def stack-w (max 0 (- (c :usable-w) mw
                                 (if (> s-count 0) (c :inner-gap) 0))))
          (when (> m-count 0)
            (def mh (triad/layout-clamp-nonnegative
                      (triad/layout-idiv
                        (- (c :usable-h) (* (- m-count 1) (c :inner-gap)))
                        m-count)))
            (var y (c :usable-y))
            (for i 0 m-count
              (array/push instructions
                {:window-id (windows i)
                 :x (c :usable-x)
                 :y y
                 :w mw
                 :h mh})
              (set y (+ y mh (c :inner-gap)))))
          (when (> s-count 0)
            (def stack-x (+ (c :usable-x) mw (c :inner-gap)))
            (for i m-count n
              (array/push instructions
                {:window-id (windows i)
                 :x stack-x
                 :y (c :usable-y)
                 :w stack-w
                 :h (c :usable-h)})))))
      instructions)))

(triad/def-layout :deck (fn [ctx] (triad/layout-deck ctx false)))
