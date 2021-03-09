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
  random, strutils, unittest

import # vendor libs
  chronicles, chronos, json_serialization

import # task-runner libs
  ../../task_runner, ../test_helpers

# call randomize() once to initialize the default random number generator else
# the same results will occur every time these examples are run
randomize()

procSuite "Task runner asynchronous use cases":

  asyncTest "Asynchronous HTTP requests":

    # `sleepAsync` is used in this test to provide (additional) non-determinism
    # in send/recv timing, and also to demonstrate how `await [chan].send`
    # calls can resolve even when a receiver on another thread is not currently
    # polling the channel with `await [chan].recv`

    type
      AsyncHttpClient = object
      HttpRequest = object
        id: int
        url: string
      HttpResponse = object
        id: int
        content: string
      ThreadArg = object
        chanRecv: AsyncChannel[ThreadSafeString]
        chanSend: AsyncChannel[ThreadSafeString]

    proc getContent(httpClient: AsyncHttpClient, url: string):
                   Future[string] {.async.} =
      let
        urlSplit = url.split("://")
        id = urlSplit[1]

      let ms = rand(10..250)
      info "[http client] sleeping", duration=($ms & "ms"), id=id, url=url
      await sleepAsync ms.milliseconds

      let response = "RESPONSE " & id
      info "[http client] responding", id=id, response=response
      return response

    proc worker(arg: ThreadArg) {.async.} =
      let chanRecv = arg.chanRecv
      let chanSend = arg.chanSend
      chanRecv.open()
      chanSend.open()

      let client = AsyncHttpClient()

      proc sendRequest(request: HttpRequest) {.async.} =
        info "[http client worker] sending request", id=request.id,
          url=request.url
        let responseStr = await client.getContent(request.url)
        info "[http client worker] received response for request",
          id=request.id, response=responseStr
        let response = HttpResponse(id: request.id, content: responseStr)
        let responseEncoded = Json.encode(response)
        info "[http client worker] sending response", id=request.id,
          encoded=responseEncoded
        await chanSend.send(responseEncoded.safe)

      info "[http client worker] sending 'ready'"
      await chanSend.send("ready".safe)

      while true:
        info "[http client worker] waiting for message"
        let received = $(await chanRecv.recv())

        try:
          let request = Json.decode(received, HttpRequest)
          info "[http client worker] received request", id=request.id,
            url=request.url
          # do not await as we don't want to park the while loop, so we can
          # handle additional concurrent requests
          discard sendRequest(request)

        except Exception as e:
          if received == "shutdown":
            info "[http client worker] received 'shutdown'"
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

    chanRecv.open()
    chanSend.open()
    createThread(thr, workerThread, arg)

    proc sender(n: int) {.async.} =
      for i in 1..n:
        let request = HttpRequest(id: i, url: "https://" & $i)
        let requestEncode = Json.encode(request)
        info "[http client test sender] sending request", id=request.id,
          url=request.url
        await chanSend.send(requestEncode.safe)

        let ms = rand(1..25)
        info "[http client test sender] sleeping", duration=($ms & "ms")
        await sleepAsync ms.milliseconds

    let testRuns = 100
    var receivedCount = 0
    var shutdown = false

    while true:
      info "[http client test] waiting for message"
      let received = $(await chanRecv.recv())

      try: # try to decode HttpResponse
        let response = Json.decode(received, HttpResponse)
        receivedCount = receivedCount + 1
        info "[http client test] received response", id=response.id,
          content=response.content, count=receivedCount
        if receivedCount == testRuns:
          info "[http client test] sending 'shutdown'"
          await chanSend.send("shutdown".safe)
          shutdown = true
          info "[http client test] breaking while loop"
          break
      except Exception as e:
        if received == "ready":
          info "[http client test] http client worker is ready"
          discard sender(testRuns)

        else:
          warn "[http client test] unknown message", message=received

    chanRecv.close()
    chanSend.close()

    joinThread(thr)

    check:
      shutdown == true
