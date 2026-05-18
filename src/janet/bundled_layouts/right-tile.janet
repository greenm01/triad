(defn triad/layout-right-tile [ctx]
  (def tag (ctx :tag))
  (def windows (triad/layout-flatten-windows (tag :columns)))
  (def n (length windows))
  (if (= n 0)
    []
    (do
      (def c (triad/layout-common ctx))
      (def instructions @[])
      (def m-count (min n (tag :master-count)))
      (def s-count (- n m-count))
      (def mw (if (> s-count 0)
                (math/floor (* (c :usable-w)
                               (triad/layout-clamp-ratio
                                 (tag :master-split-ratio))))
                (c :usable-w)))
      (def sw (max 0 (- (c :usable-w) mw
                        (if (> s-count 0) (c :inner-gap) 0))))
      (when (> s-count 0)
        (def sh (triad/layout-clamp-nonnegative
                  (triad/layout-idiv
                    (- (c :usable-h) (* (- s-count 1) (c :inner-gap)))
                    s-count)))
        (var y (c :usable-y))
        (for i 0 s-count
          (array/push instructions
            {:window-id (windows (+ m-count i))
             :x (c :usable-x)
             :y y
             :w sw
             :h sh})
          (set y (+ y sh (c :inner-gap)))))
      (def master-x (+ (c :usable-x)
                       (if (> s-count 0) (+ sw (c :inner-gap)) 0)))
      (when (> m-count 0)
        (def mh (triad/layout-clamp-nonnegative
                  (triad/layout-idiv
                    (- (c :usable-h) (* (- m-count 1) (c :inner-gap)))
                    m-count)))
        (var y (c :usable-y))
        (for i 0 m-count
          (array/push instructions
            {:window-id (windows i)
             :x master-x
             :y y
             :w mw
             :h mh})
          (set y (+ y mh (c :inner-gap)))))
      instructions)))

(triad/def-layout :right-tile triad/layout-right-tile)
