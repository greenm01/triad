import std/monotimes

proc monotonicMs*(): int64 =
  getMonoTime().ticks div 1_000_000

proc nextDeadlineMs*(nowMs: int64, candidates: openArray[int64]): int64 =
  var best = high(int64)
  for candidate in candidates:
    if candidate <= 0:
      continue
    if candidate <= nowMs:
      return 0
    let delta = candidate - nowMs
    if delta < best:
      best = delta
  if best == high(int64):
    0
  else:
    best
