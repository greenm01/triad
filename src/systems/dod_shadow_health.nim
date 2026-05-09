import ../types/dod_shadow_health
import dod_shadow_runtime

export dod_shadow_health

proc initDodShadowHealth*(): DodShadowHealth =
  DodShadowHealth(initialized: true, readHealthy: true)

proc shadowSyncEnabled*(health: DodShadowHealth): bool =
  health.initialized

proc shadowProjectionReadsEnabled*(health: DodShadowHealth): bool =
  health.initialized and health.readHealthy

proc shouldLogShadowDivergence*(divergenceCount: int): bool =
  divergenceCount <= 10 or divergenceCount mod 100 == 0

proc applyShadowReport*(
    health: var DodShadowHealth; report: DodShadowReport):
    DodShadowHealthDecision =
  result.reportOk = report.ok
  result.divergenceCount = health.divergenceCount
  if report.ok:
    return

  let readsWereHealthy = health.readHealthy
  health.readHealthy = false
  inc health.divergenceCount

  result.divergenceRecorded = true
  result.readsDisabled = readsWereHealthy
  result.divergenceCount = health.divergenceCount
  result.shouldLogDivergence =
    shouldLogShadowDivergence(health.divergenceCount)
