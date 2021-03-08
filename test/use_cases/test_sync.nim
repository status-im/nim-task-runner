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

    # `sleep` is used in this test to provide (additional) non-determinism in
    # send/recv timing, and also to demonstrate how `await [chan].send` calls
    # can resolve even when a receiver on another thread is not currently
    # polling the channel with `await [chan].recv`

    const MaxThreadPoolSize = 5

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
        task: ThreadTask

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

      info "[threadpool task] initiating task", url=arg.task.request.url,
        threadid=arg.id

      try:
        let
          client = HttpClient()
          responseStr = client.getContent(arg.task.request.url)
          response = HttpResponse(id: arg.task.request.id, content: responseStr)
          responseEncoded = Json.encode(response)
        info "[threadpool task] received response for task",
          url=arg.task.request.url, response=responseStr
        info "[threadpool task] sending response", id=response.id,
          encoded=responseEncoded
        arg.chanSendToTest.sendSync(responseEncoded.safe)

        let
          noticeToWorker = ThreadNotification(id: arg.id, notice: "done")
          noticeToWorkerEncode = Json.encode(noticeToWorker)
        info "[threadpool task] sending 'done' notice to worker",
          threadid=arg.id
        arg.chanSendToWorker.sendSync(noticeToWorkerEncode.safe)
      except Exception as e:
        error "[threadpool task] exception", error=e.msg

      discard arg.chanControlRecv.recvSync()

      arg.chanControlRecv.close()
      arg.chanSendToTest.close()
      arg.chanSendToWorker.close()

    proc taskThread(arg: ThreadTaskArg) {.thread.} =
      waitFor task(arg)

    proc worker(arg: ThreadArg) {.async.} =
      let chanRecv = arg.chanRecv
      let chanSend = arg.chanSend
      var threadCounter = 0 # serves as thread id, should never decrement
      var threadsRunning = newTable[int, tuple[thr: Thread[ThreadTaskArg],
        chanControlRecv: AsyncChannel[ThreadSafeString]]]()
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
        let received = $(await chanRecv.recv())

        if received == "shutdown":
          info "[threadpool worker] received 'shutdown'"
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
              info "[threadpool worker] adding to taskQueue",
                newlength=(taskQueue.len + 1)
              taskQueue.add task
              info "[threadpool worker] removing from taskQueue",
                newlength=(taskQueue.len - 1)
              task = taskQueue[0]
              taskQueue.delete 0, 0

            try:
              let chanControlRecv = newAsyncChannel[ThreadSafeString](-1)
              let arg = ThreadTaskArg(task: task, chanSendToWorker: chanRecv,
                chanSendToTest: chanSend, chanControlRecv: chanControlRecv,
                id: threadCounter)
              var thr = Thread[ThreadTaskArg]()
              createThread(thr, taskThread, arg)
              info "[threadpool worker] adding to threadsRunning",
                newlength=(threadsRunning.len + 1), threadid=arg.id
              threadsRunning.add threadCounter, (thr, chanControlRecv)
              threadCounter = threadCounter + 1
            except Exception as e:
              error "[threadpool worker] exception during thread creation",
                error=e.msg

          elif threadsRunning.len >= MaxThreadPoolSize:
            # add to queue
            info "[threadpool worker] adding to taskQueue",
              newlength=(taskQueue.len + 1)
            taskQueue.add task
        except Exception as e: # not a ThreadTask
          try:
            let notification = Json.decode(received, ThreadNotification)
            info "[threadpool worker] received notification",
              notice=notification.notice, threadid=notification.id
            if notification.notice == "done":
              let tpl = threadsRunning[notification.id]
              tpl.chanControlRecv.open()
              tpl.chanControlRecv.sendSync("shutdown".safe)
              joinThread(tpl.thr)
              tpl.chanControlRecv.close()
              info "[threadpool worker] removing from threadsRunning",
                newlength=(threadsRunning.len - 1), threadid=notification.id
              threadsRunning.del notification.id

              if taskQueue.len > 0:
                info "[threadpool worker] removing from taskQueue",
                  newlength=(taskQueue.len - 1)
                let task = taskQueue[0]
                taskQueue.delete 0, 0

                # Can run into problems related to max file descriptors
                # allowed: https://wilsonmar.github.io/maximum-limits/
                # Check with: `ulimit -n` / `launchctl limit maxfiles`

                # When running e.g. `newAsyncChannel` if the max number is
                # exceeded then the instantiation will fail and it seems as if
                # old/closed ones aren't getting cleaned up, at least w/
                # respect to their file descriptors, so waiting and trying
                # again doesn't help

                try:
                  let chanControlRecv = newAsyncChannel[ThreadSafeString](-1)
                  let arg = ThreadTaskArg(task: task,
                    chanSendToWorker: chanRecv, chanSendToTest: chanSend,
                    chanControlRecv: chanControlRecv, id: threadCounter)
                  var thr = Thread[ThreadTaskArg]()
                  createThread(thr, taskThread, arg)
                  info "[threadpool worker] adding to threadsRunning",
                    newlength=(threadsRunning.len + 1), threadid=arg.id
                  threadsRunning.add threadCounter, (thr, chanControlRecv)
                  threadCounter = threadCounter + 1
                except Exception as e:
                  error "[threadpool worker] exception during thread creation", error=e.msg

            else:
              error "[threadpool worker] unknown notification", notice=notification.notice
          except Exception as e:
            warn "[threadpool worker] unknown message", message=received, error=e.msg

      chanRecv.close()
      chanSend.close()

    proc workerThread(arg: ThreadArg) {.thread.} =
      waitFor worker(arg)

    let chanRecv = newAsyncChannel[ThreadSafeString](-1)
    let chanSend = newAsyncChannel[ThreadSafeString](-1)
    let arg = ThreadArg(chanRecv: chanSend, chanSend: chanRecv)
    var thr = Thread[ThreadArg]()
    var receivedIds: seq[int] = @[]
    # if `testRuns` is large enough (also related to `MaxThreadPoolSize` and
    # maybe FDs not being cleaned up from previous tests) then will run into
    # problem involving "Too many open files" FD limit
    let testRuns = 100

    chanRecv.open()
    chanSend.open()
    createThread(thr, workerThread, arg)

    var shutdown = false

    while true:
      info "[threadpool test] waiting for message"
      let received = $(await chanRecv.recv())

      try:
        let response = Json.decode(received, HttpResponse)
        info "[threadpool test] received http response", id=response.id, response=response.content
        receivedIds.add response.id
        if receivedIds.len == testRuns + 1:
          info "[threadpool test] sending 'shutdown'"
          await chanSend.send("shutdown".safe)
          shutdown = true
          info "[threadpool test] breaking while loop"
          break
      except Exception as e:
        error "[threadpool test] exception", error=e.msg
        if received == "ready":
          info "[threadpool test] received 'ready'"
          for i in 0..testRuns:
            let
              request = HttpRequest(id: i, url: "https://" & $i)
              task = ThreadTask(request: request)
              taskEncoded = Json.encode(task)
            await chanSend.send(taskEncoded.safe)

        else:
          warn "[threadpool test] unknown message", message=received

    joinThread(thr)

    chanRecv.close()
    chanSend.close()

    check:
      shutdown == true
