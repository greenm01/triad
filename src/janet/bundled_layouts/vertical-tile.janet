(defn triad/layout-vertical-tile [ctx deck?]
  (def tag (ctx :tag))
  (def windows (if deck?
                 (triad/layout-focused-first
                   (triad/layout-flatten-windows (tag :columns))
                   (tag :focused-window))
                 (triad/layout-flatten-windows (tag :columns))))
  (def n (length windows))
  (if (= n 0)
    []
    (do
      (def c (triad/layout-common ctx))
      (def instructions @[])
      (def m-count (min n (tag :master-count)))
      (def s-count (- n m-count))
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
        (if deck?
          (for i m-count n
            (array/push instructions
              {:window-id (windows i)
               :x (c :usable-x)
               :y stack-y
               :w (c :usable-w)
               :h stack-h}))
          (do
            (def sw (triad/layout-clamp-nonnegative
                      (triad/layout-idiv
                        (- (c :usable-w) (* (- s-count 1) (c :inner-gap)))
                        s-count)))
            (var x (c :usable-x))
            (for i 0 s-count
              (array/push instructions
                {:window-id (windows (+ m-count i))
                 :x x
                 :y stack-y
                 :w sw
                 :h stack-h})
              (set x (+ x sw (c :inner-gap)))))))
      instructions)))

(triad/def-layout :vertical-tile
  (fn [ctx] (triad/layout-vertical-tile ctx false)))
(triad/def-layout-movement :vertical-tile triad/layout-movement-horizontal-order)
