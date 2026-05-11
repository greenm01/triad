import std/strutils

const
  ShiftModifier* = 1'u32

proc keySymForBinding*(key: string; modifiers: uint32 = 0): uint32 =
  if key.len == 1:
    var ch = key[0]
    if (modifiers and ShiftModifier) != 0 and ch in {'a' .. 'z'}:
      ch = ch.toUpperAscii()
    return uint32(ord(ch))

  case key.toLowerAscii()
  of "return", "enter": 0xff0d'u32
  of "escape", "esc": 0xff1b'u32
  of "tab": 0xff09'u32
  of "backspace": 0xff08'u32
  of "space": 0x20'u32
  of "slash":
    if (modifiers and ShiftModifier) != 0: 0x3f'u32 else: 0x2f'u32
  of "question": 0x3f'u32
  of "left": 0xff51'u32
  of "up": 0xff52'u32
  of "right": 0xff53'u32
  of "down": 0xff54'u32
  of "page_up", "page-up", "prior": 0xff55'u32
  of "page_down", "page-down", "next": 0xff56'u32
  of "home": 0xff50'u32
  of "end": 0xff57'u32
  of "print": 0xff61'u32
  else: 0'u32
