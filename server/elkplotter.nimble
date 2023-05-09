# Package

version       = "0.1.0"
author        = "Rupus Reinefjord"
description   = "SMS-to-plotter service"
license       = "Proprietary"
srcDir        = "src"
bin           = @["elkplotter"]


# Dependencies

requires "nim >= 1.6.12"
requires "mummy == 0.2.16"
requires "webby >= 0.1.9"
