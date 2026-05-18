# Triad ships `bsp` as a bundled layout. To hack on a custom variant, copy
# this file to ~/.config/triad/layouts/<your-name>.janet and declare:
#
# janet {
#   layout "<your-name>" fallback="bsp-tree"
# }

(defn triad/bsp-node-by-id [nodes id]
  (var found nil)
  (each node nodes
    (when (= (node :id) id)
      (set found node)))
  found)

(defn triad/bsp-root-node [nodes]
  (var root nil)
  (each node nodes
    (when (= (node :parent) 0)
      (set root node)))
  root)

(defn triad/bsp-push-node-rects [nodes node rect gap instructions]
  (when node
    (if (= (node :kind) :leaf)
      (array/push instructions
        {:bsp-node-id (node :id)
         :x (rect :x)
         :y (rect :y)
         :w (rect :w)
         :h (rect :h)})
      (do
        (def ratio (triad/layout-clamp-ratio (node :ratio)))
        (def span-w (max 1 (- (rect :w) gap)))
        (def span-h (max 1 (- (rect :h) gap)))
        (def first (triad/bsp-node-by-id nodes (node :first-child)))
        (def second (triad/bsp-node-by-id nodes (node :second-child)))
        (if (= (node :orientation) :horizontal)
          (do
            (def first-w (triad/layout-clamp-dim (* span-w ratio)))
            (def second-w
              (triad/layout-clamp-dim (- (rect :w) gap first-w)))
            (triad/bsp-push-node-rects nodes first
              {:x (rect :x) :y (rect :y) :w first-w :h (rect :h)}
              gap instructions)
            (triad/bsp-push-node-rects nodes second
              {:x (+ (rect :x) first-w gap)
               :y (rect :y)
               :w second-w
               :h (rect :h)}
              gap instructions))
          (do
            (def first-h (triad/layout-clamp-dim (* span-h ratio)))
            (def second-h
              (triad/layout-clamp-dim (- (rect :h) gap first-h)))
            (triad/bsp-push-node-rects nodes first
              {:x (rect :x) :y (rect :y) :w (rect :w) :h first-h}
              gap instructions)
            (triad/bsp-push-node-rects nodes second
              {:x (rect :x)
               :y (+ (rect :y) first-h gap)
               :w (rect :w)
               :h second-h}
              gap instructions)))))))

(triad/def-layout :bsp
  (fn [ctx]
    (def nodes (ctx :bsp-nodes))
    (def root (triad/bsp-root-node nodes))
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
        (triad/bsp-push-node-rects nodes root usable inner-gap instructions)
        instructions)
      [])))
