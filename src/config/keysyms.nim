import std/[options, strutils]

const ShiftModifier* = 1'u32

type
  KeyName* {.pure.} = enum  ## Dense index; keysym values live in KeySyms.
    Return, Escape, Tab, Backspace, Delete, Space, Slash, Question, Minus, Equal,
    BracketLeft, BracketRight, Backslash, Semicolon, Apostrophe, Comma, Period, Grave,
    Left, Up, Right, Down, PageUp, PageDown, Home, End, Print, Xf86AudioRaiseVolume,
    Xf86AudioLowerVolume, Xf86AudioMute, Xf86MonitorBrightnessUp,
    Xf86MonitorBrightnessDown, Xf86Display, Xf86PowerOff

  KeySpec* = object  ## Carries the sym resolved by parseKeySpec.
    key*: string
    modifiers*: uint32
    keySym*: uint32

  KeySpelling = tuple[text: string, key: KeyName, canonical: bool]

const
  KeySyms: array[KeyName, uint32] = [
    0xff0d'u32, 0xff1b'u32, 0xff09'u32, 0xff08'u32, 0xffff'u32, 0x20'u32,
    0x2f'u32, 0x3f'u32, 0x2d'u32, 0x3d'u32, 0x5b'u32, 0x5d'u32,
    0x5c'u32, 0x3b'u32, 0x27'u32, 0x2c'u32, 0x2e'u32, 0x60'u32,
    0xff51'u32, 0xff52'u32, 0xff53'u32, 0xff54'u32, 0xff55'u32, 0xff56'u32,
    0xff50'u32, 0xff57'u32, 0xff61'u32, 0x1008ff13'u32, 0x1008ff11'u32,
    0x1008ff12'u32, 0x1008ff02'u32, 0x1008ff03'u32, 0x1008ff59'u32, 0x1008ff2a'u32,
  ]

  # Nonzero only where Shift changes the keysym.
  ShiftedSyms: array[KeyName, uint32] = [
    0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0x3f'u32, 0'u32,
    0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32,
    0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32,
    0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32, 0'u32,
    0'u32, 0'u32,
  ]

  # Canonical names and aliases share one table, sorted for one binary search.
  KeySpellings: array[0..46, KeySpelling] = block:
    var rows = [
      (text: "return", key: KeyName.Return, canonical: true),
      (text: "escape", key: KeyName.Escape, canonical: true),
      (text: "tab", key: KeyName.Tab, canonical: true),
      (text: "backspace", key: KeyName.Backspace, canonical: true),
      (text: "delete", key: KeyName.Delete, canonical: true),
      (text: "space", key: KeyName.Space, canonical: true),
      (text: "slash", key: KeyName.Slash, canonical: true),
      (text: "question", key: KeyName.Question, canonical: true),
      (text: "minus", key: KeyName.Minus, canonical: true),
      (text: "equal", key: KeyName.Equal, canonical: true),
      (text: "bracketleft", key: KeyName.BracketLeft, canonical: true),
      (text: "bracketright", key: KeyName.BracketRight, canonical: true),
      (text: "backslash", key: KeyName.Backslash, canonical: true),
      (text: "semicolon", key: KeyName.Semicolon, canonical: true),
      (text: "apostrophe", key: KeyName.Apostrophe, canonical: true),
      (text: "comma", key: KeyName.Comma, canonical: true),
      (text: "period", key: KeyName.Period, canonical: true),
      (text: "grave", key: KeyName.Grave, canonical: true),
      (text: "left", key: KeyName.Left, canonical: true),
      (text: "up", key: KeyName.Up, canonical: true),
      (text: "right", key: KeyName.Right, canonical: true),
      (text: "down", key: KeyName.Down, canonical: true),
      (text: "page_up", key: KeyName.PageUp, canonical: true),
      (text: "page_down", key: KeyName.PageDown, canonical: true),
      (text: "home", key: KeyName.Home, canonical: true),
      (text: "end", key: KeyName.End, canonical: true),
      (text: "print", key: KeyName.Print, canonical: true),
      (text: "xf86audioraisevolume", key: KeyName.Xf86AudioRaiseVolume, canonical: true),
      (text: "xf86audiolowervolume", key: KeyName.Xf86AudioLowerVolume, canonical: true),
      (text: "xf86audiomute", key: KeyName.Xf86AudioMute, canonical: true),
      (text: "xf86monbrightnessup", key: KeyName.Xf86MonitorBrightnessUp, canonical: true),
      (text: "xf86monbrightnessdown", key: KeyName.Xf86MonitorBrightnessDown, canonical: true),
      (text: "xf86display", key: KeyName.Xf86Display, canonical: true),
      (text: "xf86poweroff", key: KeyName.Xf86PowerOff, canonical: true),
      (text: "enter", key: KeyName.Return, canonical: false),
      (text: "esc", key: KeyName.Escape, canonical: false),
      (text: "del", key: KeyName.Delete, canonical: false),
      (text: "equals", key: KeyName.Equal, canonical: false),
      (text: "leftbracket", key: KeyName.BracketLeft, canonical: false),
      (text: "rightbracket", key: KeyName.BracketRight, canonical: false),
      (text: "quote", key: KeyName.Apostrophe, canonical: false),
      (text: "dot", key: KeyName.Period, canonical: false),
      (text: "backtick", key: KeyName.Grave, canonical: false),
      (text: "page-up", key: KeyName.PageUp, canonical: false),
      (text: "prior", key: KeyName.PageUp, canonical: false),
      (text: "page-down", key: KeyName.PageDown, canonical: false),
      (text: "next", key: KeyName.PageDown, canonical: false),
    ]
    for i in 1 ..< rows.len:
      var j = i
      while j > 0 and cmpIgnoreCase(rows[j - 1].text, rows[j].text) > 0:
        swap rows[j - 1], rows[j]
        dec j
    rows

# Lookup is case-sensitive, so spellings must already be lowercase.
static:
  for i in 1 ..< KeySpellings.len:
    doAssert cmpIgnoreCase(KeySpellings[i - 1].text, KeySpellings[i].text) < 0,
      "duplicate key spelling: " & KeySpellings[i].text
  for row in KeySpellings:
    doAssert row.text == row.text.toLowerAscii(),
      "key spelling must be lowercase: " & row.text
  for name in KeyName:
    var canonicalRows = 0
    for row in KeySpellings:
      if row.key == name and row.canonical:
        inc canonicalRows
    doAssert canonicalRows == 1, "missing canonical spelling for " & $name

const MaxKeySpellingLen = block:
  var longest = 0
  for row in KeySpellings:
    longest = max(longest, row.text.len)
  longest

# Reused to avoid allocating per lookup; threadvar keeps it per-thread.
var normalizedKey {.threadvar.}: string

proc foldKey(key: string): int =
  if key.len > MaxKeySpellingLen:
    return -1
  if normalizedKey.capacity < MaxKeySpellingLen:
    normalizedKey = newStringOfCap(MaxKeySpellingLen)
  normalizedKey.setLen(key.len)
  for i in 0 ..< key.len:
    normalizedKey[i] = key[i].toLowerAscii()
  key.len

proc spellingIndex(key: string): int =
  if foldKey(key) <= 0:
    return -1
  var lo = 0
  var hi = KeySpellings.high
  while lo <= hi:
    let mid = lo + (hi - lo) div 2
    let order = cmp(normalizedKey, KeySpellings[mid].text)
    if order == 0:
      return mid
    if order < 0:
      hi = mid - 1
    else:
      lo = mid + 1
  -1

proc parseKeyName*(key: string): Option[KeyName] =
  let index = spellingIndex(key)
  if index >= 0:
    some KeySpellings[index].key
  else:
    none KeyName

proc keySymForBinding*(key: KeyName, modifiers: uint32 = 0): uint32 =
  let shifted = ShiftedSyms[key]
  if shifted != 0'u32 and (modifiers and ShiftModifier) != 0:
    shifted
  else:
    KeySyms[key]

proc keySymForBinding*(key: string, modifiers: uint32 = 0): uint32 =
  if key.len == 1:
    return uint32(ord(key[0].toLowerAscii()))
  let index = spellingIndex(key)
  if index < 0:
    return 0'u32
  keySymForBinding(KeySpellings[index].key, modifiers)
