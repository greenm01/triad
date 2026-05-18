# Configure with:
# janet {
#   layout "notion" fallback="frame-tree"
# }

(defn clamp-ratio [value]
  (min 0.95 (max 0.05 value)))

(defn clamp-dim [value]
  (max 1 (math/floor value)))

(defn frame-by-id [frames id]
  (var found nil)
  (each frame frames
    (when (= (frame :id) id)
      (set found frame)))
  found)

(defn root-frame [frames]
  (var root nil)
  (each frame frames
    (when (= (frame :parent) 0)
      (set root frame)))
  root)

(defn push-frame-rects [frames frame rect gap instructions]
  (when frame
    (if (= (frame :kind) :leaf)
      (array/push instructions
        {:frame-id (frame :id)
         :x (rect :x)
         :y (rect :y)
         :w (rect :w)
         :h (rect :h)})
      (do
        (def ratio (clamp-ratio (frame :ratio)))
        (def span-w (max 1 (- (rect :w) gap)))
        (def span-h (max 1 (- (rect :h) gap)))
        (def first (frame-by-id frames (frame :first-child)))
        (def second (frame-by-id frames (frame :second-child)))
        (if (= (frame :orientation) :horizontal)
          (do
            (def first-w (clamp-dim (* span-w ratio)))
            (def second-w (clamp-dim (- (rect :w) gap first-w)))
            (push-frame-rects frames first
              {:x (rect :x) :y (rect :y) :w first-w :h (rect :h)}
              gap instructions)
            (push-frame-rects frames second
              {:x (+ (rect :x) first-w gap) :y (rect :y) :w second-w :h (rect :h)}
              gap instructions))
          (do
            (def first-h (clamp-dim (* span-h ratio)))
            (def second-h (clamp-dim (- (rect :h) gap first-h)))
            (push-frame-rects frames first
              {:x (rect :x) :y (rect :y) :w (rect :w) :h first-h}
              gap instructions)
            (push-frame-rects frames second
              {:x (rect :x) :y (+ (rect :y) first-h gap) :w (rect :w) :h second-h}
              gap instructions)))))))

(triad/def-layout :notion
  (fn [ctx]
    (def frames (ctx :frames))
    (def root (root-frame frames))
    (if root
      (do
        (def screen (ctx :screen))
        (def outer-gap (max 0 (ctx :outer-gap)))
        (def inner-gap (max 0 (ctx :inner-gap)))
        (def usable
          {:x (+ (screen :x) outer-gap)
           :y (+ (screen :y) outer-gap)
           :w (max 1 (- (screen :w) (* 2 outer-gap)))
           :h (max 1 (- (screen :h) (* 2 outer-gap)))})
        (def instructions @[])
        (push-frame-rects frames root usable inner-gap instructions)
        instructions)
      [])))
