(defn triad/layout-center-tile [ctx]
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
      (def side-left (triad/layout-idiv s-count 2))
      (def side-right (- s-count side-left))
      (def master-w (if (> s-count 0)
                      (math/floor (* (c :usable-w)
                                     (triad/layout-clamp-ratio
                                       (tag :master-split-ratio))))
                      (c :usable-w)))
      (def side-total
        (max 0 (- (c :usable-w) master-w
                  (if (> side-left 0) (c :inner-gap) 0)
                  (if (> side-right 0) (c :inner-gap) 0))))
      (def left-w (if (and (> side-left 0) (> side-right 0))
                    (triad/layout-idiv side-total 2)
                    (if (> side-left 0) side-total 0)))
      (def right-w (if (> side-right 0) (- side-total left-w) 0))
      (def master-x (+ (c :usable-x)
                       (if (> side-left 0) (+ left-w (c :inner-gap)) 0)))
      (defn add-stack [ids x w]
        (when (> (length ids) 0)
          (def h (triad/layout-clamp-nonnegative
                   (triad/layout-idiv
                     (- (c :usable-h) (* (- (length ids) 1) (c :inner-gap)))
                     (length ids))))
          (var y (c :usable-y))
          (each win-id ids
            (array/push instructions
              {:window-id win-id :x x :y y :w w :h h})
            (set y (+ y h (c :inner-gap))))))
      (def left-ids @[])
      (def right-ids @[])
      (for i 0 s-count
        (if (= (% i 2) 0)
          (array/push left-ids (windows (+ m-count i)))
          (array/push right-ids (windows (+ m-count i)))))
      (add-stack left-ids (c :usable-x) left-w)
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
             :w master-w
             :h mh})
          (set y (+ y mh (c :inner-gap)))))
      (add-stack right-ids
                 (+ master-x master-w (if (> side-right 0) (c :inner-gap) 0))
                 right-w)
      instructions)))

(triad/def-layout :center-tile triad/layout-center-tile)
(triad/def-layout-movement :center-tile triad/layout-movement-vertical-order)
