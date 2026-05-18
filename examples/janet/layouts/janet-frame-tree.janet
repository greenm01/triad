(defn clamp-dim [value]
  (max 1 (math/floor value)))

(defn leaf-frames [frames]
  (def leaves @[])
  (each frame frames
    (when (= (frame :kind) :leaf)
      (array/push leaves frame)))
  leaves)

(triad/def-layout :janet-frame-tree
  (fn [ctx]
    (def frames (leaf-frames (ctx :frames)))
    (def count (length frames))
    (if (= count 0)
      []
      (do
        (def screen (ctx :screen))
        (def outer-gap (ctx :outer-gap))
        (def inner-gap (ctx :inner-gap))
        (def usable-x (+ (screen :x) outer-gap))
        (def usable-y (+ (screen :y) outer-gap))
        (def usable-w (max 1 (- (screen :w) (* 2 outer-gap))))
        (def usable-h (max 1 (- (screen :h) (* 2 outer-gap))))
        (def frame-w (/ (- usable-w (* inner-gap (- count 1))) count))
        (def instructions @[])
        (for i 0 count
          (def frame (frames i))
          (array/push instructions
            {:frame-id (frame :id)
             :x (math/floor (+ usable-x (* i (+ frame-w inner-gap))))
             :y usable-y
             :w (clamp-dim frame-w)
             :h usable-h}))
        instructions))))
