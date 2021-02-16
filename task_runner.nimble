mode = ScriptMode.Verbose

version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "General purpose background task runner for Nim programs"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["test"]

requires "nim >= 1.2.0",
  "chronos"

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
    " --define:ssl" &
    " --linetrace:on" &
    " --nimcache:nimcache/test/" & name &
    " --out:" & outDir & name &
    " --stacktrace:on" &
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
  buildAndRunTest "test_all"

task achannels_helgrind, "Run channel implementation through helgrind to detect threading or lock errors":
  rmDir "test/build/"
  mkDir "test/build/"
  var commands = [
    "nim c" &
    " --define:useMalloc" &
    " --nimcache:nimcache/test/achannels_helgrind" &
    " --out:test/build/test_achannels" &
    " --threads:on" &
    " --tlsEmulation:off" &
    " test/test_achannels.nim",
    "valgrind --tool=helgrind test/build/test_achannels"
  ]
  echo "\n" & commands[0]
  exec commands[0]
  echo "\n" & commands[1]
  exec commands[1]

task use_cases_helgrind, "Run use cases through helgrind to detect threading or lock errors":
  rmDir "test/build/"
  mkDir "test/build/"
  var commands = [
    "nim c" &
      " --define:useMalloc" &
      " --nimcache:nimcache/test/use_cases_helgrind" &
      " --out:test/build/test_use_cases" &
      " --threads:on" &
      " --tlsEmulation:off" &
      " test/use_cases/test_all.nim",
    "valgrind --tool=helgrind test/build/test_use_cases"
  ]
  echo "\n" & commands[0]
  exec commands[0]
  echo "\n" & commands[1]
  exec commands[1]
