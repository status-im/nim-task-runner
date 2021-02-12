import unittest, random

import chronos

import ../task_runner,
       ./test_helpers

type
  ThreadArg = object
    chanRecv: AsyncChannel[cstring]
    chanSend: AsyncChannel[cstring]

# Call randomize() once to initialize the default random number generator
# If this is not called, the same results will occur every time these
# examples are run
randomize()

proc doWork(arg: ThreadArg) {.async.} =
  
  # do some stuff
  arg.chanRecv.open()
  arg.chanSend.open()
  debugEcho ">>> [doWork] sending ready message"
  await arg.chanSend.send("ready".cstring)
  while true:
    let command = $rand(1..4)
    debugEcho ">>> [doWork] sending random message: ", command
    await arg.chanSend.send(command.cstring)
    let received = $(await arg.chanRecv.recv()) # convert cstring back to string to prevent garbage collection
    debugEcho ">>> [doWork] received message: ", received
    case received
      of "a":
        debugEcho ">>> [doWork] received message 'a'"
      of "b": 
        debugEcho ">>> [doWork] received message 'b'"
      of "c":
        debugEcho ">>> [doWork] received message 'c'"
      of "shutdown":
        debugEcho ">>> [doWork] received message 'shutdown', sending 'shutdownSuccess' and breaking"
        await arg.chanSend.send("shutdownSuccess".cstring)
        break
      else: debugEcho ">>> [doWork] ERROR: Unknown task"
  
  arg.chanRecv.close()
  arg.chanSend.close()

proc foo(arg: ThreadArg) {.thread.} =
  waitFor doWork(arg)

procSuite "Task runner use cases":
  asyncTest "Long-running process":
    var chanRecv = newAsyncChannel[cstring](-1)
    var chanSend = newAsyncChannel[cstring](-1)
    var arg = ThreadArg(chanRecv: chanSend, chanSend: chanRecv)
    var thr = Thread[ThreadArg]()
    createThread(thr, foo, arg)
    chanRecv.open()
    chanSend.open()

    debugEcho ">>> [test] before while loop start"
    while true:
      debugEcho ">>> [test] in while loop, waiting for message"
      var received = $(await chanRecv.recv()) # convert cstring back to string to prevent garbage collection
      debugEcho ">>> [test] received message: ", received
      case received
        of "ready":
          debugEcho ">>> [test] doWork is ready to receive"
        of "1":
          debugEcho ">>> [test] received message '1', sending 'a'"
          await chanSend.send("a".cstring)
        of "2":
          debugEcho ">>> [test] received message '2', sending 'b'"
          await chanSend.send("b".cstring)
        of "3": 
          debugEcho ">>> [test] received message '3', sending 'c'"
          await chanSend.send("c".cstring)
        of "4":
          debugEcho ">>> [test] received message '4', sending 'shutdown'"
          await chanSend.send("shutdown".cstring)
        of "shutdownSuccess":
          debugEcho ">>> [test] received message 'shutdownSuccess', breaking"
          break
        else: debugEcho ">>> [test] ERROR: Unknown task"

    chanRecv.close()
    chanSend.close()
    # joinThread(thr) # this is not necessary because of explicit termination of the loops
    # Normally, joinThread would block the main thread while the worker thread was doing it's work.
    # Without it, in a normal case, the main thread would exit immediately without waiting for the
    # worker thread to terminate.

    check:
      true == true
