# Package

version       = "0.1.0"
author        = "Mason Green"
description   = "Dynamic window management client for River"
license       = "MIT"
srcDir        = "src"
bin           = @["triad"]


# Dependencies

requires "nim >= 2.0.0"
requires "nimkdl >= 2.1.0"
requires "wayland >= 0.1.0"
requires "fsnotify >= 0.1.6"
