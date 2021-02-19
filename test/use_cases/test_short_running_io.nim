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
  random, unittest, strutils

import # vendor libs
  chronicles, chronos, json_serialization

import # task-runner libs
  ../../task_runner, ../test_helpers, ../../task_runner/sys

# call randomize() once to initialize the default random number generator else
# the same results will occur every time these examples are run
randomize()

procSuite "Task runner short-running IO use cases":

  asyncTest "Short-running HTTP experiment":
    # `sleepAsync` is used in this test to provide (additional) non-determism
    # in send/recv timing, and also to demonstrate how `await [chan].send`
    # calls can resolve even when a receiver on another thread is not currently
    # polling the channel with `await [chan].recv`

    type
      ThreadArg = object
        chanRecv: AsyncChannel[ThreadSafeString]
        chanSend: AsyncChannel[ThreadSafeString]
      HttpRequest = object
        id: int
        url: string
      HttpResponse = object
        id: int
        result: string
      AsyncHttpClient = object

    proc getContent(httpClient: AsyncHttpClient, url: string): Future[string] {.async.} =
      let
        urlSplit = url.split("://")
        id = urlSplit[1]

      if id.parseInt mod 2 == 0:
        let ms = rand(100..2500)
        info "[http client worker] sleeping", duration=($ms & "ms")
        await sleepAsync ms.milliseconds

      return "RESPONSE " & id

    proc worker(arg: ThreadArg) {.async.} =
      let chanRecv = arg.chanRecv
      let chanSend = arg.chanSend
      chanRecv.open()
      chanSend.open()

      let client = AsyncHttpClient()

      proc sendRequest(request: HttpRequest) {.async.} =
        # fire off http request
        # info "[http client worker] sending request to url", id=request.id, url=request.url
        let responseStr = await client.getContent(request.url)
        # info "[http client worker] received response for request", id=request.id, response=responseStr
        # send response back on the channel
        let response = HttpResponse(id: request.id, result: responseStr)
        let responseEncoded = Json.encode(response)
        await chanSend.send(responseEncoded.safe)

      info "[http client worker] sending 'ready'"
      await chanSend.send("ready".safe)

      while true:
        info "[http client worker] waiting for message"
        # convert cstring back to string to avoid unexpected collection
        let
          receivedCStr = await chanRecv.recv()
          received = $receivedCStr

        try:
          let request = Json.decode(received, HttpRequest)
          info "[http client worker] received request for URL", url=request.url
          # do not await as we don't want to park the while loop, so we can
          # handle additional concurrent requests
          discard sendRequest(request)

        except:
          if received == "shutdown":
            info "[http client worker] received 'shutdown'"
            info "[http client worker] sending 'shutdownSuccess'"
            await chanSend.send("shutdownSuccess".safe)
            info "[http client worker] breaking while loop"
            break

          else: warn "[http client worker] unknown message", message=received

      chanRecv.close()
      chanSend.close()

    proc workerThread(arg: ThreadArg) {.thread.} =
      waitFor worker(arg)

    let chanRecv = newAsyncChannel[ThreadSafeString](-1)
    let chanSend = newAsyncChannel[ThreadSafeString](-1)
    let arg = ThreadArg(chanRecv: chanSend, chanSend: chanRecv)
    var thr = Thread[ThreadArg]()
    var receivedIds: seq[int] = @[]
    let testRuns = 10000

    chanRecv.open()
    chanSend.open()
    createThread(thr, workerThread, arg)

    var shutdown = false
    while true:
      info "[http client test] waiting for message"
      # convert cstring back to string to avoid unexpected collection
      let
        receivedCStr = await chanRecv.recv()
        received = $receivedCStr

      info "[http client test] received message", message=received

      try: # try to decode HttpResponse
        let response = Json.decode(received, HttpResponse)
        info "[http client test] received http response", id=response.id, responseLength=response.result.len
        receivedIds.add response.id
        if receivedIds.len == testRuns:
          info "[http client test] sending 'shutdown'"
          await chanSend.send("shutdown".safe)
      except:
        if received == "ready":
          info "[http client test] http client worker is ready"
          info "[http client test] sending requests"

          for i in 0..testRuns:
            let request = HttpRequest(id: i, url: "https://" & $i)
            let requestEncode = Json.encode(request)
            await chanSend.send(requestEncode.safe)

        elif received == "shutdownSuccess":
          info "[http client test] received 'shutdownSuccess'"
          shutdown = true
          info "[http client test] breaking while loop"
          break
        else:
          warn "[http client test] unknown message", message=received

    chanRecv.close()
    chanSend.close()

    check:
      shutdown == true
