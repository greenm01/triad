(defn triad/layout-master-stack [ctx]
  (def tag (ctx :tag))
  (def windows (triad/layout-flatten-windows (tag :columns)))
  (def n (length windows))
  (if (= n 0)
    []
    (do
      (def c (triad/layout-common ctx))
      (def instructions @[])
      (if (= n 1)
        [{:window-id (windows 0)
          :x (c :usable-x)
          :y (c :usable-y)
          :w (c :usable-w)
          :h (c :usable-h)}]
        (do
          (def m-count (min n (tag :master-count)))
          (def s-count (- n m-count))
          (def inner-half (triad/layout-idiv (c :inner-gap) 2))
          (def mw (if (and (> m-count 0) (> s-count 0))
                    (math/floor (* (c :usable-w)
                                   (triad/layout-clamp-ratio
                                     (tag :master-split-ratio))))
                    (c :usable-w)))
          (def sw (- (c :usable-w) mw))
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
                 :w (max 0 (- mw (if (> s-count 0) inner-half 0)))
                 :h mh})
              (set y (+ y mh (c :inner-gap)))))
          (when (> s-count 0)
            (def sh (triad/layout-clamp-nonnegative
                      (triad/layout-idiv
                        (- (c :usable-h) (* (- s-count 1) (c :inner-gap)))
                        s-count)))
            (var y (c :usable-y))
            (def start-x (+ (c :usable-x) mw inner-half))
            (for i 0 s-count
              (array/push instructions
                {:window-id (windows (+ m-count i))
                 :x start-x
                 :y y
                 :w (max 0 (- sw inner-half))
                 :h sh})
              (set y (+ y sh (c :inner-gap)))))
          instructions)))))

(triad/def-layout :tile triad/layout-master-stack)
