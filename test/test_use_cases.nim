import
  unittest, random, std/[os,options]

import
  chronos, waku/v2/node/[config, wakunode2], waku/v2/protocol/waku_message,
  waku/common/utils/nat, confutils, chronicles, stew/shims/net as stewNet, 
  libp2p/crypto/[crypto,secp], eth/keys, json_rpc/[rpcclient, rpcserver]

import
  ../task_runner,
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

proc initNode(config: WakuNodeConf = WakuNodeConf.load()): WakuNode =
  let
    (extIp, extTcpPort, extUdpPort) = setupNat(config.nat, clientId,
      Port(uint16(config.tcpPort) + config.portsShift),
      Port(uint16(config.udpPort) + config.portsShift))
    node = WakuNode.init(config.nodeKey, config.listenAddress,
      Port(uint16(config.tcpPort) + config.portsShift), extIp, extTcpPort)
  result = node

proc doWakuWork(arg: ThreadArg) {.async.} =
  # do some stuff
  let
    message1 = WakuMessage(payload: cast[seq[byte]]("message1"),
      contentTopic: ContentTopic(1))
    message2 = WakuMessage(payload: cast[seq[byte]]("message2"),
      contentTopic: ContentTopic(1))
    topic = "testing"
  var nodeConfig = WakuNodeConf.load()
  nodeConfig.portsShift = 5432
  let node = initNode(nodeConfig)

  proc handler(topic: Topic, data: seq[byte]) {.async.} =
    let
      message = WakuMessage.init(data).value
      payload = cast[string](message.payload)
    info "message received", topic=topic, payload=payload,
      contentTopic=message.contentTopic
    case payload
      of "message1":
        await arg.chanSend.send("1".cstring)
      of "message2":
        await arg.chanSend.send("2".cstring)

  await node.start()
  node.mountRelay()
  arg.chanRecv.open()
  arg.chanSend.open()

  info ">>> [doWork] sending ready message"
  await arg.chanSend.send("ready".cstring)

  while true:
    let received = $(await arg.chanRecv.recv()) # convert cstring back to string to prevent garbage collection
    case received
      of "subscribe":
        info ">>> [doWakuWork] received message", msg=received
        node.subscribe(topic, handler)
      of "publish1": 
        info ">>> [doWakuWork] received message", msg=received
        await node.publish(topic, message1)
      of "publish2":
        info ">>> [doWakuWork] received message", msg=received
        await node.publish(topic, message2)
      of "shutdown":
        info ">>> [doWakuWork] received message 'shutdown', stopping waku node and sending 'shutdownSuccess' and breaking"
        await node.stop()
        flushFile(stdout)
        await arg.chanSend.send("shutdownSuccess".cstring)
        break
      else: debugEcho ">>> [doWakuWork] ERROR: Unknown task"
  
  arg.chanRecv.close()
  arg.chanSend.close()

proc wakuThread(arg: ThreadArg) {.thread.} =
  waitFor doWakuWork(arg)

procSuite "Task runner use cases":
  asyncTest "Waku long-running process":
    var chanRecv = newAsyncChannel[cstring](-1)
    var chanSend = newAsyncChannel[cstring](-1)
    var arg = ThreadArg(chanRecv: chanSend, chanSend: chanRecv)
    var thr = Thread[ThreadArg]()
    createThread(thr, wakuThread, arg)
    chanRecv.open()
    chanSend.open()

    info ">>> [test] before while loop start"
    while true:
      info ">>> [test] in while loop, waiting for message"
      var received = $(await chanRecv.recv()) # convert cstring back to string to prevent garbage collection
      info ">>> [test] received message: ", received
      case received
        of "ready":
          info ">>> [test] doWork is ready to receive, subscribing to waku messages and sending 'publish1'"
          await chanSend.send("subscribe".cstring)
          await chanSend.send("publish1".cstring)
        of "1":
          info ">>> [test] received message '1', sending 'publish2'"
          await chanSend.send("publish2".cstring)
        of "2":
          info ">>> [test] received message '2', sending 'shutdown'"
          await chanSend.send("shutdown".cstring)
        of "shutdownSuccess":
          info ">>> [test] received message 'shutdownSuccess', breaking"
          break
        else: info ">>> [test] ERROR: Unknown task"

    chanRecv.close()
    chanSend.close()
    # joinThread(thr) # this is not necessary because of explicit termination of the loops
    # Normally, joinThread would block the main thread while the worker thread was doing it's work.
    # Without it, in a normal case, the main thread would exit immediately without waiting for the
    # worker thread to terminate.

    check:
      true == true

# procSuite "Task runner experiments":
#   asyncTest "Long-running process experiment":
#     var chanRecv = newAsyncChannel[cstring](-1)
#     var chanSend = newAsyncChannel[cstring](-1)
#     var arg = ThreadArg(chanRecv: chanSend, chanSend: chanRecv)
#     var thr = Thread[ThreadArg]()
#     createThread(thr, foo, arg)
#     chanRecv.open()
#     chanSend.open()

#     debugEcho ">>> [test] before while loop start"
#     while true:
#       debugEcho ">>> [test] in while loop, waiting for message"
#       var received = $(await chanRecv.recv()) # convert cstring back to string to prevent garbage collection
#       debugEcho ">>> [test] received message: ", received
#       case received
#         of "ready":
#           debugEcho ">>> [test] doWork is ready to receive"
#         of "1":
#           debugEcho ">>> [test] received message '1', sending 'a'"
#           await chanSend.send("a".cstring)
#         of "2":
#           debugEcho ">>> [test] received message '2', sending 'b'"
#           await chanSend.send("b".cstring)
#         of "3": 
#           debugEcho ">>> [test] received message '3', sending 'c'"
#           await chanSend.send("c".cstring)
#         of "4":
#           debugEcho ">>> [test] received message '4', sending 'shutdown'"
#           await chanSend.send("shutdown".cstring)
#         of "shutdownSuccess":
#           debugEcho ">>> [test] received message 'shutdownSuccess', breaking"
#           break
#         else: debugEcho ">>> [test] ERROR: Unknown task"

#     chanRecv.close()
#     chanSend.close()
#     # joinThread(thr) # this is not necessary because of explicit termination of the loops
#     # Normally, joinThread would block the main thread while the worker thread was doing it's work.
#     # Without it, in a normal case, the main thread would exit immediately without waiting for the
#     # worker thread to terminate.

#     check:
#       true == true
