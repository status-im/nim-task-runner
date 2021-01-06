mode = ScriptMode.Verbose

version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "General purpose background task runner for Nim programs"
license       = "MIT"
skipDirs      = @["test"]

requires "nim >= 1.2.0",
  "chronos"

import strutils

proc buildAndRunTest(name: string,
                     srcDir = "test/",
                     outDir = "test/build/",
                     params = "",
                     cmdParams = "",
                     lang = "c") =
  rmDir outDir
  mkDir outDir
  # allow something like "nim test --verbosity:0 --hints:off beacon_chain.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " &
    lang &
    " --debugger:native" &
    " --define:chronicles_line_numbers" &
    " --define:debug" &
    " --nimcache:nimcache/test/" & name &
    " --out:" & outDir & name &
    " --threads:on" &
    " --tlsEmulation:off" &
    " " &
    extra_params &
    " " &
    srcDir & name & ".nim" &
    " " &
    cmdParams
  exec outDir & name

task tests, "Run all tests":
  buildAndRunTest "all_tests"
