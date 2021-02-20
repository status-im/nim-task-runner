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

  asyncTest "Ping-pong":

    # `sleepAsync` is used in this test to provide (additional) non-determinism
    # in send/recv timing, and also to demonstrate how `await [chan].send`
    # calls can resolve even when a receiver on another thread is not currently
    # polling the channel with `await [chan].recv`

    type
      ThreadArg = object
        chanRecv: AsyncChannel[ThreadSafeString]
        chanSend: AsyncChannel[ThreadSafeString]

    proc worker(arg: ThreadArg) {.async.} =
      let chanRecv = arg.chanRecv
      let chanSend = arg.chanSend
      chanRecv.open()
      chanSend.open()

      info "[ping-pong worker] sending 'ready'"
      await chanSend.send("ready".safe)

      while true:
        info "[ping-pong worker] waiting for message"
        let received = $(await chanRecv.recv())

        case received
          of "shutdown":
            info "[ping-pong worker] received 'shutdown'"
            info "[ping-pong worker] breaking while loop"
            break
          else:
            info "[ping-pong worker] received message", message=received
            info "[ping-pong worker] sending message", message=received
            await chanSend.send(received.safe)

        let ms = rand(10..100)
        info "[ping-pong worker] sleeping", duration=($ms & "ms")
        await sleepAsync ms.milliseconds

      chanRecv.close()
      chanSend.close()

    proc workerThread(arg: ThreadArg) {.thread.} =
      waitFor worker(arg)

    let chanRecv = newAsyncChannel[ThreadSafeString](-1)
    let chanSend = newAsyncChannel[ThreadSafeString](-1)
    let arg = ThreadArg(chanRecv: chanSend, chanSend: chanRecv)
    var thr = Thread[ThreadArg]()

    chanRecv.open()
    chanSend.open()
    createThread(thr, workerThread, arg)

    let testRuns = 100
    var receivedCount = 0
    var shutdown = false

    while true:
      info "[ping-pong test] waiting for message"
      let received = $(await chanRecv.recv())

      case received
        of "ready":
          info "[ping-pong test] ping-pong worker is ready"
        else:
          receivedCount = receivedCount + 1
          info "[ping-pong test] received message", message=received,
            count=receivedCount
          if receivedCount == testRuns:
            info "[ping-pong test] sending 'shutdown'"
            await chanSend.send("shutdown".safe)
            shutdown = true
            info "[ping-pong test] breaking while loop"
            break

      let message = $rand(0..testRuns)
      info "[ping-pong test] sending random message", message=message
      await chanSend.send(message.safe)

      let ms = rand(10..100)
      info "[ping-pong test] sleeping", duration=($ms & "ms")
      await sleepAsync ms.milliseconds

    joinThread(thr)

    chanRecv.close()
    chanSend.close()

    check:
      shutdown == true


  asyncTest "Waku v2 node":

    # `counter` procs are used in this test to demonstrate concurrency within
    # independent event loops running on different threads

    # `sleepAsync` is used in this test to provide (additional) non-determinism
    # in send/recv timing and counter operations, and also to demonstrate how
    # `await [chan].send` calls can resolve even when a receiver on another
    # thread is not currently polling the channel with `await [chan].recv`

    type
      ThreadArg = object
        chanRecv: AsyncChannel[ThreadSafeString]
        chanSend: AsyncChannel[ThreadSafeString]

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
          await chanSend.send("counted".safe)

          let ms = rand(100..1000)
          info "[waku worker counter] sleeping", duration=($ms & "ms")
          await sleepAsync ms.milliseconds

      proc handler(topic: Topic, data: seq[byte]) {.async.} =
        let message = WakuMessage.init(data).value
        let payload = cast[string](message.payload)

        info "[waku handler] received message", topic=topic, payload=payload,
          contentTopic=message.contentTopic
        info "[waku handler] sending message", message=payload
        await chanSend.send(payload.safe)

      proc makeMessage(s: string): WakuMessage =
        WakuMessage(payload: cast[seq[byte]](s), contentTopic: ContentTopic(1))

      let topic = "testing"

      info "[waku worker] sending ready message"
      await chanSend.send("ready".safe)
      info "[waku worker] starting worker counter"
      discard counter()

      while true:
        info "[waku worker] waiting for message"
        let received = $(await chanRecv.recv())

        case received
          of "subscribe":
            info "[waku worker] received 'subscribe'"
            node.subscribe(topic, handler)
          of "counted":
            info "[waku worker] waku test counted"
          of "shutdown":
            info "[waku worker] received 'shutdown'"
            info "[waku worker] stopping waku node"
            await node.stop()
            info "[waku worker] breaking while loop"
            break
          else:
            info "[waku worker] publishing message", message=received
            await node.publish(topic, makeMessage(received))

        let ms = rand(10..100)
        info "[waku worker] sleeping", duration=($ms & "ms")
        await sleepAsync ms.milliseconds

      chanRecv.close()
      chanSend.close()

    proc workerThread(arg: ThreadArg) {.thread.} =
      waitFor worker(arg)

    let chanRecv = newAsyncChannel[ThreadSafeString](-1)
    let chanSend = newAsyncChannel[ThreadSafeString](-1)
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
        await chanSend.send("counted".safe)

        let ms = rand(100..1000)
        info "[waku test counter] sleeping", duration=($ms & "ms")
        await sleepAsync ms.milliseconds

    let testRuns = 100
    var receivedCount = 0
    var shutdown = false

    while true:
      info "[waku test] waiting for message"
      let received = $(await chanRecv.recv())

      case received
        of "ready":
          info "[waku test] waku worker is ready"
          info "[waku test] starting test counter"
          discard counter()
          info "[waku test] sending 'subscribe'"
          await chanSend.send("subscribe".safe)
          let message = $rand(0..testRuns)
          info "[waku test] sending random message", message=message
          await chanSend.send(message.safe)
        of "counted":
          info "[waku test] waku worker counted"
        else:
          receivedCount = receivedCount + 1
          info "[waku test] received message", message=received,
            count=receivedCount

          if receivedCount == testRuns:
            info "[waku test] sending 'shutdown'"
            await chanSend.send("shutdown".safe)
            shutdown = true
            info "[waku test] breaking while loop"
            break

          let message = $rand(0..testRuns)
          info "[waku test] sending random message", message=message
          await chanSend.send(message.safe)

      let ms = rand(10..100)
      info "[waku test] sleeping", duration=($ms & "ms")
      await sleepAsync ms.milliseconds

    joinThread(thr)

    chanRecv.close()
    chanSend.close()

    check:
      shutdown == true
