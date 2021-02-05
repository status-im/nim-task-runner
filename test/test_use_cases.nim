import unittest

import chronos

import ../task_runner,
       ./test_helpers

type
  ThreadArg = object
    chanRecv: AsyncChannel[string]
    chanSend: AsyncChannel[string]

proc foo(arg: ThreadArg) {.thread.} =
  arg.chanRecv.open()
  arg.chanSend.open()
  let received = arg.chanRecv.recvSync()
  check: received == "hello"
  arg.chanSend.sendSync("world")
  arg.chanRecv.close()
  arg.chanSend.close()

procSuite "Task runner use cases":
  asyncTest "Long-running process":
    var chanRecv = newAsyncChannel[string](-1)
    var chanSend = newAsyncChannel[string](-1)
    var arg = ThreadArg(chanRecv: chanSend, chanSend: chanRecv)
    var thr = Thread[ThreadArg]()
    createThread(thr, foo, arg)
    chanRecv.open()
    chanSend.open()
    await chanSend.send("hello")
    var received = await chanRecv.recv()
    chanRecv.close()
    chanSend.close()

    check:
      received == "world"
