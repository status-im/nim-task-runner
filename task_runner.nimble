mode = ScriptMode.Verbose

version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "General purpose background task runner for Nim programs"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["test"]

requires "nim >= 1.2.0",
         "chronicles",
         "https://github.com/michaelsbradleyjr/nim-chronos.git#export-selector-field",
         "json_serialization"

import os

const chronos_preferred =
  " --path:\"" &
  staticExec("nimble path chronos --silent").parentDir /
  "chronos-#export-selector-field\""

task test, "Build and run all tests":
  rmDir "test/build/"
  mkDir "test/build/"
  var commands = [
    "nim c" &
    " --debugger:native" &
    " --define:chronicles_line_numbers" &
    " --define:debug" &
    " --define:ssl" &
    " --linetrace:on" &
    " --out:test/build/" &
    " --stacktrace:on" &
    " --threads:on" &
    " --tlsEmulation:off" &
    chronos_preferred &
    " test/test_all.nim",
    "test/build/test_all"
  ]
  for command in commands:
    exec command

task helgrind_achannels, "Build achannels test and run through helgrind to detect threading or lock errors":
  rmDir "test/build/"
  mkDir "test/build/"
  var commands = [
    "nim c" &
    " --define:useMalloc" &
    " --out:test/build/test_achannels" &
    " --threads:on" &
    " --tlsEmulation:off" &
    chronos_preferred &
    " test/test_achannels.nim",
    "valgrind --tool=helgrind test/build/test_achannels"
  ]
  for command in commands:
    exec command
