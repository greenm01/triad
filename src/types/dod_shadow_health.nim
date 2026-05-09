type
  DodShadowHealth* = object
    initialized*: bool
    readHealthy*: bool
    divergenceCount*: int

  DodShadowHealthDecision* = object
    reportOk*: bool
    divergenceRecorded*: bool
    readsDisabled*: bool
    shouldLogDivergence*: bool
    divergenceCount*: int
