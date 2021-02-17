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
  random, unittest, strutils, httpclient

import # vendor libs
  chronicles, chronos, json_serialization

import # task-runner libs
  ../../task_runner, ../test_helpers

# call randomize() once to initialize the default random number generator else
# the same results will occur every time these examples are run
randomize()

procSuite "Task runner short-running IO use cases":

  asyncTest "Short-running HTTP experiment":
    # `asyncSleep` is used in this test to provide (additional) non-determism
    # in send/recv timing, and also to demonstrate how `await [chan].send`
    # calls can resolve even when a receiver on another thread is not currently
    # polling the channel with `await [chan].recv`

    type
      ThreadArg = object
        chanRecv: AsyncChannel[cstring]
        chanSend: AsyncChannel[cstring]
      HttpRequest = object
        id: int
        url: string
      HttpResponse = object
        id: int
        result: string


    proc worker(arg: ThreadArg) {.async.} =
      let chanRecv = arg.chanRecv
      let chanSend = arg.chanSend
      chanRecv.open()
      chanSend.open()

      let client = newHttpClient()

      proc sendRequest(request: HttpRequest) {.async.} =
        # fire off http request
        let responseStr = client.getContent(request.url)
        # send response back on the channel
        let response = HttpResponse(id: request.id, result: responseStr)
        let responseEncoded = Json.encode(response)
        await chanSend.send(responseEncoded.cstring)

      info "[http client worker] sending 'ready'"
      await chanSend.send("ready".cstring)

      while true:
        info "[http client worker] waiting for message"
        # convert cstring back to string to avoid unexpected collection
        let received = $(await chanRecv.recv())

        if received == "shutdown":
          info "[http client worker] received 'shutdown'"
          info "[http client worker] sending 'shutdownSuccess'"
          await chanSend.send("shutdownSuccess".cstring)
          info "[http client worker] breaking while loop"
          break

        elif received.contains("http"): # handle HTTP URL
          let request = Json.decode(received, HttpRequest)
          info "[http client worker] received request for URL", url=request.url
          # do not await as we don't want to park the while loop, so we can
          # handle additional concurrent requests
          discard sendRequest(request)

        else: warn "[http client worker] unknown message", message=received
      
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
      info "[http client worker] waiting for message"
      # convert cstring back to string to avoid unexpected collection
      let received = $(await chanRecv.recv())

      if received == "ready":
        info "[http client worker] ping-pong worker is ready"
        info "[http client worker] sending requests"

        let request1 = HttpRequest(id: 1, url: "https://media1.tenor.com/images/ecce84a28465a81b09d4068e313a9d8b/tenor.gif")
        let request1Encode = Json.encode(request1)
        await chanSend.send(request1Encode.cstring)

        let request2 = HttpRequest(id: 2, url: "https://media1.tenor.com/images/d3f81205421989931d4986d796271c71/tenor.gif")
        let request2Encode = Json.encode(request2)
        await chanSend.send(request2Encode.cstring)

        let request3 = HttpRequest(id: 3, url: "https://media.tenor.com/images/5d792745433307e6a6236ccff8237f62/tenor.gif")
        let request3Encode = Json.encode(request3)
        await chanSend.send(request3Encode.cstring)


      elif received.contains("id:"): # http response
        let response = Json.decode(received, HttpResponse)
        info "[http client worker] received http response", id=response.id, responseLength=response.result.len

        if response.id == 3:
          info "[http client worker] sending 'shutdown'"
          await chanSend.send("shutdown".cstring)
      elif received == "shutdownSuccess":
        info "[http client worker] received 'shutdownSuccess'"
        shutdown = true
        info "[http client worker] breaking while loop"
        break
      else:
        warn "[http client worker] unknown message", message=received
