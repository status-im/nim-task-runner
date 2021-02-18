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
  random, unittest, tables, strutils, os

import # vendor libs
  chronicles, chronos, json_serialization

import # task-runner libs
  ../../task_runner, ../test_helpers, ../../task_runner/sys

# call randomize() once to initialize the default random number generator else
# the same results will occur every time these examples are run
randomize()

procSuite "Task runner short-running synchronous use cases":

  asyncTest "Short-running HTTP experiment":
    # `asyncSleep` is used in this test to provide (additional) non-determism
    # in send/recv timing, and also to demonstrate how `await [chan].send`
    # calls can resolve even when a receiver on another thread is not currently
    # polling the channel with `await [chan].recv`

    const MaxThreadPoolSize = 5

    type
      HttpRequest = object
        id: int
        url: string
      HttpResponse = object
        id: int
        result: string
      ThreadArg = object
        chanRecv: AsyncChannel[ThreadSafeString]
        chanSend: AsyncChannel[ThreadSafeString]
      ThreadTask = object
        request: HttpRequest
      ThreadTaskArg = object
        id: int
        task: ThreadTask
        chanSendToWorker: AsyncChannel[ThreadSafeString]
        chanSendToTest: AsyncChannel[ThreadSafeString]
      ThreadNotification = object
        id: int
        notice: string
      HttpClient = object
    
    proc getContent(httpClient: HttpClient, url: string): string =
      let
        urlSplit = url.split("//")
        id = url[1]

      if id.int mod 2 == 0:
        let ms = rand(500..1000)
        sleep ms

      return "RESPONSE " & id

    proc task(arg: ThreadTaskArg) {.async.} =
      info "[threadpool task] initiating task", url=arg.task.request.url
      let
        client = HttpClient()
        responseStr = client.getContent(arg.task.request.url)
        response = HttpResponse(id: arg.task.request.id, result: responseStr)
        responseEncoded = Json.encode(response)
      info "[threadpool task] received http response for task, sending to test", url=arg.task.request.url, response=responseStr
      await arg.chanSendToTest.send(responseEncoded.safe)
      
      let
        noticeToWorker = ThreadNotification(id: arg.id, notice: "done")
        noticeToWorkerEncode = Json.encode(noticeToWorker)
      info "[threadpool task] sending 'done' notice to worker", threadid=arg.id
      await arg.chanSendToWorker.send(noticeToWorkerEncode.safe)

    proc taskThread(arg: ThreadTaskArg) {.thread.} =
      waitFor task(arg)

    proc worker(arg: ThreadArg) {.async.} =
      let chanRecv = arg.chanRecv
      let chanSend = arg.chanSend
      var threadCounter = 0 # serves as thread id, should never decrement
      var threadsRunning = newTable[int, Thread[ThreadTaskArg]]()
      var taskQueue: seq[ThreadTask] = @[] # FIFO queue
      chanRecv.open()
      chanSend.open()

      # if task received and number running threads == MaxThreadPoolSize,
      # then put the task in a queue

      # if task received and number running threads < MaxThreadPoolSize,
      # create a thread, set up AsyncChannel(s), and run task in that thread

      # if thread "done" received, teardown thread

      info "[threadpool worker] sending 'ready'"
      await chanSend.send("ready".safe)

      while true:
        info "[threadpool worker] waiting for message"
        let
          receivedCStr = await chanRecv.recv()
          received = $receivedCStr
        
        info "[threadpool worker] received message", message=received
        if received == "shutdown":
          info "[threadpool worker] received 'shutdown'"
          info "[threadpool worker] sending 'shutdownSuccess'"
          await chanSend.send("shutdownSuccess".safe)
          info "[threadpool worker] breaking while loop"
          break

        try:
          var task = Json.decode(received, ThreadTask)
          info "[threadpool worker] received task", url=task.request.url

          # do we have available threads in the threadpool?
          if threadsRunning.len < MaxThreadPoolSize:
            # check if we have tasks waiting on queue
            if taskQueue.len > 0:
              # remove first element from the task queue
              taskQueue.add task
              task = taskQueue[0]
              taskQueue = taskQueue[1..taskQueue.len - 1]
            
            # no tasks waiting, setup new thread
            let arg = ThreadTaskArg(task: task, chanSendToWorker: chanRecv, chanSendToTest: chanSend)
            var thr = Thread[ThreadTaskArg]()
            createThread(thr, taskThread, arg)
            threadsRunning.add threadCounter, thr
            threadCounter = threadCounter + 1

          elif threadsRunning.len >= MaxThreadPoolSize:
            # add to queue
            taskQueue.add task
        except: # not a ThreadTask
          try:
            let notification = Json.decode(received, ThreadNotification)
            info "[threadpool worker] received notification", notice=notification.notice, threadid=notification.id
            if notification.notice == "done":
              let thr = threadsRunning[notification.id]
              joinThread(thr)
              threadsRunning.del notification.id
            else:
              error "[threadpool worker] unknown notification", notice=notification.notice
          except:
            warn "[threadpool worker] unknown message", message=received

    proc workerThread(arg: ThreadArg) {.thread.} =
      waitFor worker(arg)

    let chanRecv = newAsyncChannel[ThreadSafeString](-1)
    let chanSend = newAsyncChannel[ThreadSafeString](-1)
    let arg = ThreadArg(chanRecv: chanSend, chanSend: chanRecv)
    var thr = Thread[ThreadArg]()
    var receivedIds: seq[int] = @[]
    let testRuns = 1000

    chanRecv.open()
    chanSend.open()
    createThread(thr, workerThread, arg)

    var shutdown = false
    while true:
      info "[threadpool test] waiting for message"
      # convert cstring back to string to avoid unexpected collection
      let
        receivedCStr = await chanRecv.recv()
        received = $receivedCStr
      info "[threadpool test] received message", messageLen=received.len

      try:
        let response = Json.decode(received, HttpResponse)
        info "[threadpool test] received http response", id=response.id, responseLength=response.result.len
        receivedIds.add response.id
        if receivedIds.len == testRuns:
          info "[threadpool test] sending 'shutdown'"
          await chanSend.send("shutdown".safe)
      except:
        if received == "ready":
          info "[threadpool test] received 'ready'"
          for i in 0..testRuns:
            let
              request = HttpRequest(id: i, url: "https://" & $i)
              task = ThreadTask(request: request)
              taskEncoded = Json.encode(task)
            await chanSend.send(taskEncoded.safe)

        elif received == "shutdownSuccess":
          info "[threadpool test] received 'shutdownSuccess'"
          shutdown = true
          info "[threadpool test] breaking while loop"
          break
        else:
          warn "[threadpool test] unknown message", message=received
    check:
      shutdown == true