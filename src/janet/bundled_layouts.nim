import std/options
import ../core/layout_descriptor_codec
import ../core/layout_selection_codec
from ../types/runtime_values import JanetLayoutConfig, LayoutMode

const BundledLayoutsPathPrefix* = "<triad-bundled-layout:"

const BundledLayoutPreludeSource =
  """
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
"""

const MasterStackLayoutSource =
  """
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
"""

const GridLayoutSource =
  """
(defn triad/layout-grid [ctx vertical]
  (def tag (ctx :tag))
  (def windows (triad/layout-flatten-windows (tag :columns)))
  (def n (length windows))
  (if (= n 0)
    []
    (do
      (def c (triad/layout-common ctx))
      (def cols (if vertical
                  (math/ceil (/ n (math/ceil (math/sqrt n))))
                  (math/ceil (math/sqrt n))))
      (def rows (if vertical
                  (math/ceil (math/sqrt n))
                  (math/ceil (/ n cols))))
      (def win-w (triad/layout-clamp-nonnegative
                   (triad/layout-idiv
                     (- (c :usable-w) (* (- cols 1) (c :inner-gap)))
                     cols)))
      (def win-h (triad/layout-clamp-nonnegative
                   (triad/layout-idiv
                     (- (c :usable-h) (* (- rows 1) (c :inner-gap)))
                     rows)))
      (def instructions @[])
      (for i 0 n
        (def col (if vertical
                   (triad/layout-idiv i rows)
                   (% i cols)))
        (def row (if vertical
                   (% i rows)
                   (triad/layout-idiv i cols)))
        (array/push instructions
          {:window-id (windows i)
           :x (+ (c :usable-x) (* col (+ win-w (c :inner-gap))))
           :y (+ (c :usable-y) (* row (+ win-h (c :inner-gap))))
           :w win-w
           :h win-h}))
      instructions)))
"""

const MonocleLayoutSource =
  """
(defn triad/layout-monocle [ctx]
  (def tag (ctx :tag))
  (def windows (triad/layout-flatten-windows (tag :columns)))
  (def c (triad/layout-common ctx))
  (def instructions @[])
  (each win-id windows
    (array/push instructions
      {:window-id win-id
       :x (c :usable-x)
       :y (c :usable-y)
       :w (c :usable-w)
       :h (c :usable-h)}))
  instructions)
"""

const DeckLayoutSource =
  """
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
"""

const RightTileLayoutSource =
  """
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
"""

const CenterTileLayoutSource =
  """
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
"""

const VerticalTileLayoutSource =
  """
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
"""

proc bundledLayoutPath*(id: string): string =
  BundledLayoutsPathPrefix & id & ">"

proc bundledLayoutSource*(id: string): Option[string] =
  let source =
    case id
    of "tile":
      BundledLayoutPreludeSource & MasterStackLayoutSource &
        "\n(triad/def-layout :tile triad/layout-master-stack)\n"
    of "grid":
      BundledLayoutPreludeSource & GridLayoutSource &
        "\n(triad/def-layout :grid (fn [ctx] (triad/layout-grid ctx false)))\n"
    of "monocle":
      BundledLayoutPreludeSource & MonocleLayoutSource &
        "\n(triad/def-layout :monocle triad/layout-monocle)\n"
    of "deck":
      BundledLayoutPreludeSource & DeckLayoutSource &
        "\n(triad/def-layout :deck (fn [ctx] (triad/layout-deck ctx false)))\n"
    of "center-tile":
      BundledLayoutPreludeSource & CenterTileLayoutSource &
        "\n(triad/def-layout :center-tile triad/layout-center-tile)\n"
    of "right-tile":
      BundledLayoutPreludeSource & RightTileLayoutSource &
        "\n(triad/def-layout :right-tile triad/layout-right-tile)\n"
    of "vertical-tile":
      BundledLayoutPreludeSource & VerticalTileLayoutSource &
        "\n(triad/def-layout :vertical-tile (fn [ctx] (triad/layout-vertical-tile ctx false)))\n"
    of "vertical-grid":
      BundledLayoutPreludeSource & GridLayoutSource &
        "\n(triad/def-layout :vertical-grid (fn [ctx] (triad/layout-grid ctx true)))\n"
    of "vertical-deck":
      BundledLayoutPreludeSource & VerticalTileLayoutSource &
        "\n(triad/def-layout :vertical-deck (fn [ctx] (triad/layout-vertical-tile ctx true)))\n"
    of "tgmix":
      BundledLayoutPreludeSource & MasterStackLayoutSource & GridLayoutSource &
        """
(triad/def-layout :tgmix
  (fn [ctx]
    (def tag (ctx :tag))
    (def n (length (triad/layout-flatten-windows (tag :columns))))
    (if (<= n 3)
      (triad/layout-master-stack ctx)
      (triad/layout-grid ctx false))))
"""
    else:
      ""
  if source.len == 0:
    none(string)
  else:
    some(source)

proc bundledLayoutConfigs*(): seq[JanetLayoutConfig] =
  for id in BundledAlgorithmicLayoutIds:
    result.add(
      JanetLayoutConfig(
        id: janetLayoutId(id), fallback: builtinSelection(LayoutMode.Scroller)
      )
    )
