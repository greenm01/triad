import std/[options, strutils]

type ProcessMemoryStatus* = object
  available*: bool
  vmPeakKiB*: int
  vmSizeKiB*: int
  vmRssKiB*: int
  rssAnonKiB*: int
  rssFileKiB*: int
  rssShmemKiB*: int
  vmDataKiB*: int
  vmStkKiB*: int
  vmExeKiB*: int
  vmLibKiB*: int
  vmPteKiB*: int
  vmSwapKiB*: int

proc initProcessMemoryStatus(): ProcessMemoryStatus =
  result.vmPeakKiB = -1
  result.vmSizeKiB = -1
  result.vmRssKiB = -1
  result.rssAnonKiB = -1
  result.rssFileKiB = -1
  result.rssShmemKiB = -1
  result.vmDataKiB = -1
  result.vmStkKiB = -1
  result.vmExeKiB = -1
  result.vmLibKiB = -1
  result.vmPteKiB = -1
  result.vmSwapKiB = -1

proc parseMemoryKiB(line: string): Option[int] =
  let parts = line.splitWhitespace()
  if parts.len < 2:
    return none(int)
  try:
    some(parseInt(parts[1]))
  except ValueError:
    none(int)

proc parseProcessMemoryStatus*(content: string): ProcessMemoryStatus =
  result = initProcessMemoryStatus()
  result.available = true
  for line in content.splitLines():
    let value = line.parseMemoryKiB()
    if value.isNone:
      continue
    let parsed = value.get()
    if line.startsWith("VmPeak:"):
      result.vmPeakKiB = parsed
    elif line.startsWith("VmSize:"):
      result.vmSizeKiB = parsed
    elif line.startsWith("VmRSS:"):
      result.vmRssKiB = parsed
    elif line.startsWith("RssAnon:"):
      result.rssAnonKiB = parsed
    elif line.startsWith("RssFile:"):
      result.rssFileKiB = parsed
    elif line.startsWith("RssShmem:"):
      result.rssShmemKiB = parsed
    elif line.startsWith("VmData:"):
      result.vmDataKiB = parsed
    elif line.startsWith("VmStk:"):
      result.vmStkKiB = parsed
    elif line.startsWith("VmExe:"):
      result.vmExeKiB = parsed
    elif line.startsWith("VmLib:"):
      result.vmLibKiB = parsed
    elif line.startsWith("VmPTE:"):
      result.vmPteKiB = parsed
    elif line.startsWith("VmSwap:"):
      result.vmSwapKiB = parsed

proc currentProcessMemoryStatus*(): ProcessMemoryStatus =
  try:
    parseProcessMemoryStatus(readFile("/proc/self/status"))
  except CatchableError:
    initProcessMemoryStatus()
