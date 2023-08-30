# Package

version       = "0.2.0"
author        = "Rupus Reinefjord, 46elks AB"
description   = "SMS-to-plotter service"
license       = "0BSD"
srcDir        = "src"
bin           = @["elkplotter"]


# Dependencies

requires "nim >= 2.0"
requires "db_connector"
requires "mummy >= 0.3.4"
requires "webby >= 0.1.9"
