import # task_runner libs
  ../achannels, ../tasks

export achannels, tasks

type
  WorkerChannel* = AsyncChannel[ThreadSafeString]

  WorkerKind* = enum pool, thread

  ThreadArg* = ref object of RootObj
    awaitTasks*: bool
    chanRecvFromHost*: WorkerChannel
    chanSendToHost*: WorkerChannel
    context*: Context
    contextArg*: ContextArg
    running*: pointer

  Worker* = ref object of RootObj
    awaitTasks*: bool
    chanRecvFromWorker*: WorkerChannel
    chanSendToWorker*: WorkerChannel
    context*: Context
    contextArg*: ContextArg
    name*: string
    running*: pointer

proc newWorkerChannel*(): WorkerChannel =
  newAsyncChannel[ThreadSafeString](-1)
