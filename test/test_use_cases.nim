import unittest

import chronos

import ../task_runner,
       ./test_helpers

type
  ThreadArg = object
    chanRecv: AsyncChannel[cstring]
    chanSend: AsyncChannel[cstring]

# proc fooSync(arg: ThreadArg) {.thread, async.} =
#   arg.chanRecv.open()
#   arg.chanSend.open()
#   let received = arg.chanRecv.recvSync()
#   check: received == "hello"
#   arg.chanSend.sendSync("world")
#   arg.chanRecv.close()
#   arg.chanSend.close()

proc doWork(arg: ThreadArg) {.async.} =
  # do some stuff
  arg.chanRecv.open()
  arg.chanSend.open()
  let received = $(await arg.chanRecv.recv()) # convert cstring back to string to prevent garbage collection
  echo ">>> received: ", received
  check: received == "hello"
  await arg.chanSend.send("world".cstring)
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
    # chanSend.sendSync("hello".cstring)
    await chanSend.send("hello".cstring)
    var received = await chanRecv.recv()
    # var received = chanRecv.recvSync()
    # var received = await receive(arg) #"world"
    echo ">>> [test case] received: ", received
    chanRecv.close()
    chanSend.close()
    joinThread(thr)

    check:
      received == "world"
