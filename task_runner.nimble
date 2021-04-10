mode = ScriptMode.Verbose

version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "General purpose background task runner for Nim programs"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["test"]

requires "nim >= 1.2.0",
  "chronos"

import strutils

const debug_opts =
  " --debugger:native" &
  " --define:chronicles_line_numbers" &
  " --define:debug" &
  " --linetrace:on" &
  " --stacktrace:on"

const release_opts =
    " --define:danger" &
    " --define:strip" &
    " --opt:size" &
    " --passC:-flto" &
    " --passL:-flto"

proc buildAndRun(name: string,
                 srcDir = "test/",
                 outDir = "test/build/",
                 params = "",
                 cmdParams = "",
                 lang = "c") =
  mkDir outDir
  # allow something like "nim test --verbosity:0 --hints:off beacon_chain.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " &
    lang &
    (if getEnv("RELEASE").strip != "false": release_opts else: debug_opts) &
    (if defined(windows): " --define:chronicles_colors:AnsiColors" else: "") &
    (if getEnv("WIN_STATIC").strip != "false": " --passC:\"-static\" --passL:\"-static\"" else: "") &
    # (if getEnv("RLN_STATIC").strip != "false": (if defined(windows): " --dynlibOverride:vendor\\rln\\target\\debug\\rln" else: " --dynlibOverride:vendor/rln/target/debug/librln") else: "") &
    # usually `--dynlibOverride` is used in case of static linking and so would
    # be used conditionally (see commented code above), but because
    # `vendor/nim-waku/waku/v2/protocol/waku_rln_relay/rln.nim` specifies the
    # library with a relative path prefix (which isn't valid relative to root
    # of this repo) it needs to be used in the case of shared or static linking
    (if defined(windows): " --dynlibOverride:vendor\\rln\\target\\debug\\rln" else: " --dynlibOverride:vendor/rln/target/debug/librln") &
    " --define:ssl" &
    " --nimcache:nimcache/" & (if getEnv("RELEASE").strip != "false": "release/" else: "debug/") & name &
    " --out:" & outDir & name &
    (if getEnv("RLN_LDFLAGS").strip != "": " --passL:\"" & getEnv("RLN_LDFLAGS") & "\"" else: "") &
    " --threads:on" &
    " --tlsEmulation:off" &
    " " &
    extra_params &
    " " &
    srcDir & name & ".nim" &
    " " &
    cmdParams
  if getEnv("RUN_AFTER_BUILD").strip != "false":
    exec outDir & name

task tests, "Run all tests":
  rmDir "test/build/"
  buildAndRun "test_all"

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
