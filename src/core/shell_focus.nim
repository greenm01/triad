import ../types/shell_snapshot

proc focusedWindowId*(snapshot: ShellSnapshot): uint32 =
  if snapshot.activeScratchpadWindow != 0'u32:
    return snapshot.activeScratchpadWindow

  for workspace in snapshot.workspaces:
    if workspace.isActive:
      return workspace.focusedWindow

  for win in snapshot.windows:
    if win.isFocused:
      return win.id

  0'u32
