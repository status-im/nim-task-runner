#              Task Runner Test Suite
#               adapted in parts from
#                Chronos Test Suite
#
#            (c) Copyright 2018-Present
#        Status Research & Development GmbH
#
#             Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#             MIT license (LICENSE-MIT)
import # nim libs
  options, os, random, unittest

import # vendor libs
  confutils, chronicles, chronos, eth/keys, json_rpc/[rpcclient, rpcserver],
  libp2p/crypto/[crypto, secp], waku/common/utils/nat, waku/v2/node/[config,
  wakunode2], waku/v2/protocol/waku_message, stew/shims/net as stewNet

import # task-runner libs
  ../../task_runner, ../test_helpers

# call randomize() once to initialize the default random number generator else
# the same results will occur every time these examples are run
randomize()

procSuite "Task runner long-running use cases":

  asyncTest "Long-running ping-pong experiment":

    # `asyncSleep` is used in this test to provide (additional) non-determism
    # in send/recv timing, and also to demonstrate how `await [chan].send`
    # calls can resolve even when a receiver on another thread is not currently
    # polling the channel with `await [chan].recv`

    type
      ThreadArg = object
        chanRecv: AsyncChannel[cstring]
        chanSend: AsyncChannel[cstring]

    proc worker(arg: ThreadArg) {.async.} =
      let chanRecv = arg.chanRecv
      let chanSend = arg.chanSend
      chanRecv.open()
      chanSend.open()

      info "[ping-pong worker] sending 'ready'"
      await chanSend.send("ready".cstring)

      while true:
        info "[ping-pong worker] waiting for message"
        # convert cstring back to string to avoid unexpected collection
        let received = $(await chanRecv.recv())

        case received
          of "a":
            info "[ping-pong worker] received 'a'"
          of "b":
            info "[ping-pong worker] received 'b'"
          of "c":
            info "[ping-pong worker] received 'c'"
          of "shutdown":
            info "[ping-pong worker] received 'shutdown'"
            info "[ping-pong worker] sending 'shutdownSuccess'"
            await chanSend.send("shutdownSuccess".cstring)
            info "[ping-pong worker] breaking while loop"
            break
          else: warn "[ping-pong worker] unknown message", message=received

        let message = $rand(1..10)
        info "[ping-pong worker] sending random message", message=message
        await chanSend.send(message.cstring)

        let ms = rand(100..250)
        info "[ping-pong worker] sleeping", duration=($ms & "ms")
        await sleepAsync ms.milliseconds

      chanRecv.close()
      chanSend.close()

    proc workerThread(arg: ThreadArg) {.thread.} =
      waitFor worker(arg)

    let chanRecv = newAsyncChannel[cstring](-1)
    let chanSend = newAsyncChannel[cstring](-1)
    let arg = ThreadArg(chanRecv: chanSend, chanSend: chanRecv)
    var thr = Thread[ThreadArg]()

    chanRecv.open()
    chanSend.open()
    createThread(thr, workerThread, arg)

    var shutdown = false

    while true:
      info "[ping-pong test] waiting for message"
      # convert cstring back to string to avoid unexpected collection
      let received = $(await chanRecv.recv())

      case received
        of "ready":
          info "[ping-pong test] ping-pong worker is ready"
          info "[ping-pong test] sending 'a'"
          await chanSend.send("a".cstring)
        of "1":
          info "[ping-pong test] received '1'"
          info "[ping-pong test] sending 'a'"
          await chanSend.send("a".cstring)
        of "2":
          info "[ping-pong test] received '2'"
          info "[ping-pong test] sending 'b'"
          await chanSend.send("b".cstring)
        of "3":
          info "[ping-pong test] received '3'"
          info "[ping-pong test] sending 'c'"
          await chanSend.send("c".cstring)
        of "4":
          info "[ping-pong test] received '4'"
          info "[ping-pong test] sending 'shutdown'"
          await chanSend.send("shutdown".cstring)
        of "shutdownSuccess":
          info "[ping-pong test] received 'shutdownSuccess'"
          shutdown = true
          info "[ping-pong test] breaking while loop"
          break
        else:
          warn "[ping-pong test] unknown message", message=received
          info "[ping-pong test] sending 'unknown'"
          await chanSend.send("unknown".cstring)

      let ms = rand(100..250)
      info "[ping-pong test] sleeping", duration=($ms & "ms")
      await sleepAsync ms.milliseconds

    chanRecv.close()
    chanSend.close()

    # joinThread(thr)

    # `joinThread` is not necessary here because the `while` loop `break` above
    # coincides with worker termination, i.e.  we don't need it to prevent the
    # main thread from exiting while the worker thread is running

    check:
      shutdown == true


  asyncTest "Long-running Waku v2 node":

    # `counter` procs are used in this test to demonstrate concurrency within
    # independent event loops running on different threads

    # `asyncSleep` is used in this test to provide (additional) non-determism
    # in send/recv timing and counter operations, and also to demonstrate how
    # `await [chan].send` calls can resolve even when a receiver on another
    # thread is not currently polling the channel with `await [chan].recv`

    type
      ThreadArg = object
        chanRecv: AsyncChannel[cstring]
        chanSend: AsyncChannel[cstring]

    proc initNode(config: WakuNodeConf = WakuNodeConf.load()): WakuNode =
      let
        (extIp, extTcpPort, extUdpPort) = setupNat(config.nat, clientId,
          Port(uint16(config.tcpPort) + config.portsShift),
          Port(uint16(config.udpPort) + config.portsShift))
        node = WakuNode.init(config.nodeKey, config.listenAddress,
          Port(uint16(config.tcpPort) + config.portsShift), extIp, extTcpPort)
      result = node

    proc worker(arg: ThreadArg) {.async.} =
      let chanRecv = arg.chanRecv
      let chanSend = arg.chanSend
      chanRecv.open()
      chanSend.open()

      var nodeConfig = WakuNodeConf.load()
      nodeConfig.portsShift = 5432
      let node = initNode(nodeConfig)
      await node.start()
      node.mountRelay()

      proc counter() {.async.} =
        var count = 0
        while true:
          count = count + 1
          info "[waku worker counter] counting", count=count
          await chanSend.send("counted".cstring)

          let ms = rand(100..250)
          info "[waku worker counter] sleeping", duration=($ms & "ms")
          await sleepAsync ms.milliseconds

      info "[waku worker] sending ready message"
      await chanSend.send("ready".cstring)
      info "[waku worker] starting worker counter"
      discard counter()

      proc handler(topic: Topic, data: seq[byte]) {.async.} =
        let
          message = WakuMessage.init(data).value
          payload = cast[string](message.payload)

        case payload
          of "message1":
            info "[waku handler] received message", topic=topic,
              payload=payload, contentTopic=message.contentTopic
            info "[waku handler] sending '1'"
            await chanSend.send("1".cstring)
          of "message2":
            info "[waku handler] received message", topic=topic,
              payload=payload, contentTopic=message.contentTopic
            info "[waku handler] sending '2'"
            await chanSend.send("2".cstring)
          else: warn "[waku handler] unknown message", topic=topic,
                  payload=payload, contentTopic=message.contentTopic

      let
        message1 = WakuMessage(payload: cast[seq[byte]]("message1"),
          contentTopic: ContentTopic(1))
        message2 = WakuMessage(payload: cast[seq[byte]]("message2"),
          contentTopic: ContentTopic(1))
        topic = "testing"

      while true:
        info "[waku worker] waiting for message"
        # convert cstring back to string to avoid unexpected collection
        let received = $(await chanRecv.recv())

        case received
          of "subscribe":
            info "[waku worker] received 'subscribe'"
            node.subscribe(topic, handler)
          of "publish1":
            info "[waku worker] received 'publish1'"
            await node.publish(topic, message1)
          of "publish2":
            info "[waku worker] received 'publish2'"
            await node.publish(topic, message2)
          of "shutdown":
            info "[waku worker] received 'shutdown'"
            info "[waku worker] stopping waku node"
            await node.stop()
            info "[waku worker] sending 'shutdownSuccess'"
            await chanSend.send("shutdownSuccess".cstring)
            info "[waku worker] breaking while loop"
            break
          else:
            if received == "counted":
              info "[waku worker] waku test counted"
            else:
              warn "[waku worker] unknown message", message=received

        let ms = rand(100..250)
        info "[waku worker] sleeping", duration=($ms & "ms")
        await sleepAsync ms.milliseconds

      chanRecv.close()
      chanSend.close()

    proc workerThread(arg: ThreadArg) {.thread.} =
      waitFor worker(arg)

    let chanRecv = newAsyncChannel[cstring](-1)
    let chanSend = newAsyncChannel[cstring](-1)
    let arg = ThreadArg(chanRecv: chanSend, chanSend: chanRecv)
    var thr = Thread[ThreadArg]()

    chanRecv.open()
    chanSend.open()
    createThread(thr, workerThread, arg)

    proc counter() {.async.} =
      var count = 0
      while true:
        count = count + 1
        info "[waku test counter] counting", count=count
        await chanSend.send("counted".cstring)

        let ms = rand(100..250)
        info "[waku test counter] sleeping", duration=($ms & "ms")
        await sleepAsync ms.milliseconds

    var shutdown = false

    while true:
      info "[waku test] waiting for message"
      # convert cstring back to string to avoid unexpected collection
      let received = $(await chanRecv.recv())

      case received
        of "ready":
          info "[waku test] waku worker is ready"
          info "[waku test] starting test counter"
          discard counter()
          info "[waku test] sending 'subscribe'"
          await chanSend.send("subscribe".cstring)
          info "[waku test] sending 'publish1'"
          await chanSend.send("publish1".cstring)
        of "1":
          info "[waku test] received message '1'"
          info "[waku test] sending 'publish2'"
          await chanSend.send("publish2".cstring)
        of "2":
          info "[waku test] received message '2'"
          info "[waku test] sending 'shutdown'"
          await chanSend.send("shutdown".cstring)
        of "shutdownSuccess":
          info "[waku test] received 'shutdownSuccess'"
          shutdown = true
          info "[waku test] breaking while loop"
          break
        else:
          if received == "counted":
            info "[waku test] waku worker counted"
          else:
            warn "[waku test] unknown message", message=received

      let ms = rand(100..250)
      info "[waku test] sleeping", duration=($ms & "ms")
      await sleepAsync ms.milliseconds

    chanRecv.close()
    chanSend.close()

    # joinThread(thr)

    # `joinThread` is not necessary here because the `while` loop `break` above
    # coincides with worker termination, i.e.  we don't need it to prevent the
    # main thread from exiting while the worker thread is running

    check:
      shutdown == true