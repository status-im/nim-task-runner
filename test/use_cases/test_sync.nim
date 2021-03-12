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
  os, random, sequtils, strutils, tables, unittest

import # vendor libs
  chronicles, chronos, json_serialization

import # task-runner libs
  ../../task_runner, ../test_helpers

# call randomize() once to initialize the default random number generator else
# the same results will occur every time these examples are run
randomize()

procSuite "Task runner synchronous use cases":

  asyncTest "Synchronous HTTP requests":

    # `sleep` and `sleepAsync` are used in this test to provide (additional)
    # non-determinism in send/recv timing, and also to demonstrate how `await
    # [chan].send` calls can resolve even when a receiver on another thread is
    # not currently polling the channel with `await [chan].recv`

    const MaxThreadPoolSize = 16

    type
      HttpClient = object
      HttpRequest = object
        id: int
        url: string
      HttpResponse = object
        id: int
        content: string
      ThreadArg = object
        chanRecv: AsyncChannel[ThreadSafeString]
        chanSend: AsyncChannel[ThreadSafeString]
      ThreadNotification = object
        id: int
        notice: string
      ThreadTask = object
        request: HttpRequest
      ThreadTaskArg = object
        id: int
        chanControlRecv: AsyncChannel[ThreadSafeString]
        chanSendToTest: AsyncChannel[ThreadSafeString]
        chanSendToWorker: AsyncChannel[ThreadSafeString]

    proc getContent(httpClient: HttpClient, url: string): string =
      let
        urlSplit = url.split("://")
        id = urlSplit[1]

      let ms = rand(10..250)
      info "[http client] sleeping", duration=($ms & "ms"), id=id, url=url
      sleep ms

      let response = "RESPONSE " & id
      info "[http client] responding", id=id, response=response
      return response

    proc task(arg: ThreadTaskArg) {.async.} =
      arg.chanControlRecv.open()
      arg.chanSendToTest.open()
      arg.chanSendToWorker.open()

      let
        noticeToWorker = ThreadNotification(id: arg.id, notice: "ready")
        noticeToWorkerEncode = Json.encode(noticeToWorker)
      info "[threadpool task thread] sending 'ready'", threadid=arg.id
      await arg.chanSendToWorker.send(noticeToWorkerEncode.safe)

      while true:
        info "[threadpool task thread] waiting for message"
        let received = $(await arg.chanControlRecv.recv())

        try:
          var task = Json.decode(received, ThreadTask)
          info "[threadpool task thread] received task", url=task.request.url

          info "[threadpool task thread] initiating task", url=task.request.url,
            threadid=arg.id

          try:
            let
              client = HttpClient()
              responseStr = client.getContent(task.request.url)
              response = HttpResponse(id: task.request.id, content: responseStr)
              responseEncoded = Json.encode(response)
            info "[threadpool task thread] received response for task",
              url=task.request.url, response=responseStr
            info "[threadpool task thread] sending response", id=response.id,
              encoded=responseEncoded
            await arg.chanSendToTest.send(responseEncoded.safe)

            let
              noticeToWorker = ThreadNotification(id: arg.id, notice: "done")
              noticeToWorkerEncode = Json.encode(noticeToWorker)
            info "[threadpool task thread] sending 'done' notice to worker",
              threadid=arg.id
            await arg.chanSendToWorker.send(noticeToWorkerEncode.safe)
          except Exception as e:
            error "[threadpool task thread] exception", error=e.msg
        except Exception as e: # not a ThreadTask
          if received == "shutdown":
            info "[threadpool task thread] received 'shutdown'"
            info "[threadpool task thread] breaking while loop"
            break

          else:
            error "[threadpool task thread] unknown message", message=received, error=e.msg

      arg.chanControlRecv.close()
      arg.chanSendToTest.close()
      arg.chanSendToWorker.close()

    proc taskThread(arg: ThreadTaskArg) {.thread.} =
      waitFor task(arg)

    proc worker(arg: ThreadArg) {.async.} =
      let chanRecv = arg.chanRecv
      let chanSend = arg.chanSend
      var threadsBusy = newTable[int, tuple[thr: Thread[ThreadTaskArg],
        chanControlRecv: AsyncChannel[ThreadSafeString]]]()
      var threadsIdle = newSeq[tuple[id: int, thr: Thread[ThreadTaskArg],
        chanControlRecv: AsyncChannel[ThreadSafeString]]](MaxThreadPoolSize)
      var taskQueue: seq[ThreadTask] = @[] # FIFO queue
      var allReady = 0
      chanRecv.open()
      chanSend.open()

      for i in 0..<MaxThreadPoolSize:
        let id = i + 1
        let chanControlRecv = newAsyncChannel[ThreadSafeString](-1)
        chanControlRecv.open()
        info "[threadpool worker] adding to threadsIdle", threadid=id
        threadsIdle[i].id = id
        createThread(
          threadsIdle[i].thr,
          taskThread,
          ThreadTaskArg(id: id, chanControlRecv: chanControlRecv,
            chanSendToTest: chanSend, chanSendToWorker: chanRecv
          )
        )
        threadsIdle[i].chanControlRecv = chanControlRecv

      # when task received and number of busy threads == MaxThreadPoolSize,
      # then put the task in a queue

      # when task received and number of busy threads < MaxThreadPoolSize, pop
      # a thread from threadsIdle, track that thread in threadsBusy, and run
      # task in that thread

      # if "done" received from a thread, remove thread from threadsBusy, and
      # push thread into threadsIdle

      info "[threadpool worker] sending 'ready'"
      await chanSend.send("ready".safe)

      while true:
        info "[threadpool worker] waiting for message"
        let received = $(await chanRecv.recv())

        if received == "shutdown":
          info "[threadpool worker] received 'shutdown'"
          info "[threadpool work] sending 'shutdown' to all task threads"
          for tpl in threadsIdle:
            await tpl.chanControlRecv.send("shutdown".safe)
          for tpl in threadsBusy.values:
            await tpl.chanControlRecv.send("shutdown".safe)
          info "[threadpool worker] breaking while loop"
          break

        try:
          var task = Json.decode(received, ThreadTask)
          info "[threadpool worker] received task", url=task.request.url

          if allReady < MaxThreadPoolSize or threadsBusy.len == MaxThreadPoolSize:
            # add to queue
            info "[threadpool worker] adding to taskQueue",
              newlength=(taskQueue.len + 1)
            taskQueue.add task

          # do we have available threads in the threadpool?
          elif threadsBusy.len < MaxThreadPoolSize:
            # check if we have tasks waiting on queue
            if taskQueue.len > 0:
              # remove first element from the task queue
              info "[threadpool worker] adding to taskQueue",
                newlength=(taskQueue.len + 1)
              taskQueue.add task
              info "[threadpool worker] removing from taskQueue",
                newlength=(taskQueue.len - 1)
              task = taskQueue[0]
              taskQueue.delete 0, 0

            info "[threadpool worker] removing from threadsIdle",
              newlength=(threadsIdle.len - 1)
            let tpl = threadsIdle[0]
            threadsIdle.delete 0, 0
            info "[threadpool worker] adding to threadsBusy",
              newlength=(threadsBusy.len + 1), threadid=tpl.id
            threadsBusy.add tpl.id, (tpl.thr, tpl.chanControlRecv)
            await tpl.chanControlRecv.send(received.safe)
        except Exception as e: # not a ThreadTask
          try:
            let notification = Json.decode(received, ThreadNotification)
            info "[threadpool worker] received notification",
              notice=notification.notice, threadid=notification.id
            if notification.notice == "ready":
              info "[threadpool worker] received 'ready' from a task thread"
              allReady = allReady + 1
            elif notification.notice == "done":
              let tpl = threadsBusy[notification.id]
              info "[threadpool worker] adding to threadsIdle",
                  newlength=(threadsIdle.len + 1)
              threadsIdle.add (notification.id, tpl.thr, tpl.chanControlRecv)
              info "[threadpool worker] removing from threadsBusy",
                newlength=(threadsBusy.len - 1), threadid=notification.id
              threadsBusy.del notification.id

              if taskQueue.len > 0:
                info "[threadpool worker] removing from taskQueue",
                  newlength=(taskQueue.len - 1)
                let task = taskQueue[0]
                taskQueue.delete 0, 0

                info "[threadpool worker] removing from threadsIdle",
                  newlength=(threadsIdle.len - 1)
                let tpl = threadsIdle[0]
                threadsIdle.delete 0, 0
                info "[threadpool worker] adding to threadsBusy",
                  newlength=(threadsBusy.len + 1), threadid=tpl.id
                threadsBusy.add tpl.id, (tpl.thr, tpl.chanControlRecv)
                await tpl.chanControlRecv.send(Json.encode(task).safe)

            else:
              error "[threadpool worker] unknown notification", notice=notification.notice
          except Exception as e:
            warn "[threadpool worker] unknown message", message=received, error=e.msg

      var allTaskThreads: seq[Thread[ThreadTaskArg]] = @[]

      for tpl in threadsIdle:
        tpl.chanControlRecv.close()
        allTaskThreads.add tpl.thr
      for tpl in threadsBusy.values:
        tpl.chanControlRecv.close()
        allTaskThreads.add tpl.thr

      chanRecv.close()
      chanSend.close()

      joinThreads(allTaskThreads)

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
        let
          request = HttpRequest(id: i, url: "https://" & $i)
          task = ThreadTask(request: request)
          taskEncoded = Json.encode(task)
        info "[threadpool test sender] sending request", id=request.id,
          url=request.url
        await chanSend.send(taskEncoded.safe)

        let ms = rand(1..25)
        info "[threadpool test sender] sleeping", duration=($ms & "ms")
        await sleepAsync ms.milliseconds

    let testRuns = 100
    var receivedCount = 0
    var shutdown = false

    while true:
      info "[threadpool test] waiting for message"
      let received = $(await chanRecv.recv())

      try:
        let response = Json.decode(received, HttpResponse)
        receivedCount = receivedCount + 1
        info "[threadpool test] received response", id=response.id,
          content=response.content, count=receivedCount
        if receivedCount == testRuns:
          info "[threadpool test] sending 'shutdown'"
          await chanSend.send("shutdown".safe)
          shutdown = true
          info "[threadpool test] breaking while loop"
          break
      except Exception as e:
        if received == "ready":
          info "[threadpool test] received 'ready'"
          discard sender(testRuns)

        else:
          warn "[threadpool test] unknown message", message=received,
            error=e.msg

    chanRecv.close()
    chanSend.close()

    joinThread(thr)

    check:
      shutdown == true
