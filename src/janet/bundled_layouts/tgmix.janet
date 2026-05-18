(triad/def-layout :tgmix
  (fn [ctx]
    (def tag (ctx :tag))
    (def n (length (triad/layout-flatten-windows (tag :columns))))
    (if (<= n 3)
      (triad/layout-master-stack ctx)
      (triad/layout-grid ctx false))))
