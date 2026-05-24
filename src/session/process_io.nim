import std/[os, osproc, posix]

proc ensureParentDir*(path: string) =
  createDir(path.parentDir())

proc redirectProcessStreams*(path: string) =
  ensureParentDir(path)
  let fd = open(path.cstring, O_WRONLY or O_CREAT or O_APPEND, 0o644.cint)
  if fd < 0:
    raiseOSError(osLastError(), path)
  if dup2(fd, 1) < 0 or dup2(fd, 2) < 0:
    let err = osLastError()
    discard close(fd)
    raiseOSError(err, path)
  discard close(fd)

proc startWithLog*(command: string, args: openArray[string], logPath: string): Process =
  ensureParentDir(logPath)
  let logFd = open(logPath.cstring, O_WRONLY or O_CREAT or O_APPEND, 0o644.cint)
  if logFd < 0:
    raiseOSError(osLastError(), logPath)

  let savedOut = dup(1)
  let savedErr = dup(2)
  if savedOut < 0 or savedErr < 0:
    let err = osLastError()
    discard close(logFd)
    if savedOut >= 0:
      discard close(savedOut)
    if savedErr >= 0:
      discard close(savedErr)
    raiseOSError(err, logPath)

  try:
    if dup2(logFd, 1) < 0 or dup2(logFd, 2) < 0:
      raiseOSError(osLastError(), logPath)
    result = startProcess(command, args = args, options = {poUsePath, poParentStreams})
  finally:
    discard dup2(savedOut, 1)
    discard dup2(savedErr, 2)
    discard close(savedOut)
    discard close(savedErr)
    discard close(logFd)
