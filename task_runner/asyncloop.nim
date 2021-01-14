#                           Task Runner
#                          adapted from
#                             Chronos
#           (github.com/status-im/nim-chronos/pull/45)
#
#               (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#                    Licensed under either of
#         Apache License, version 2.0, (LICENSE-APACHEv2)
#                    MIT license (LICENSE-MIT)
import os, selectors

import chronos/asyncloop
export asyncloop

when defined(windows):
  import winlean, sets, hashes

when defined(windows) or defined(nimdoc):
  type
    RwfsoOverlapped* = object of CustomOverlapped
      ioPort*: Handle
      handle*: Handle
      waitFd*: Handle
      timerOrWait*: WINBOOL

    RefRwfsoOverlapped* = ref RwfsoOverlapped

when defined(windows):

  {.push stackTrace:off.}
  proc waitCallback(param: pointer,
                    timerOrWaitFired: WINBOOL): void {.stdcall.} =
    var p = cast[RefRwfsoOverlapped](param)
    p.timerOrWait = timerOrWaitFired
    discard postQueuedCompletionStatus(p.ioPort, DWORD(timerOrWaitFired),
                                       ULONG_PTR(p.handle),
                                       cast[pointer](p))
  {.pop.}

  proc awaitForSingleObject*(handle: Handle, timeout: Duration): Future[bool] =
    ## Wait for Windows' waitable handle (handle which can be waited via
    ## WaitForSingleObject API call) in asynchronous way.
    ## Procedure returns ``true`` if state of handle ``handle`` become
    ## signalled, and ``false`` if timeout ``timeout`` was expired before
    ## handle ``handle`` become signaled.
    ##
    ## ``handle`` can be one of the listed types: Change notification,
    ## Console input, Event, Memory resource notification, Mutex, Process,
    ## Semaphore, Thread, Waitable timer.
    ##
    ## If timeout ``timeout`` is ``ZeroDuration`` procedure will check if
    ## handle is signalled and return immediately.
    var retFuture = newFuture[bool]("chronos.awaitForSingleObject")
    var loop = getThreadDispatcher()

    var povl: RefRwfsoOverlapped
    var flags = DWORD(WT_EXECUTEONLYONCE)
    var timems: ULONG

    if timeout == ZeroDuration:
      let res = waitForSingleObject(handle, 0)
      if res == WAIT_TIMEOUT:
        retFuture.complete(false)
        return retFuture
      elif res == WAIT_OBJECT_0:
        retFuture.complete(true)
        return retFuture
      else:
        retFuture.fail(newException(AsyncError,
                       "Mutex object was not released"))
        return retFuture
    else:
      if timeout == InfiniteDuration:
        timems = INFINITE
      else:
        timems = ULONG(timeout.milliseconds)

    povl = RefRwfsoOverlapped()
    GC_ref(povl)

    proc handleContinuation(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        loop.handles.excl(AsyncFD(handle))
        if unregisterWait(povl.waitFd) == 0:
          let err = osLastError()
          if int(err) != ERROR_IO_PENDING:
            GC_unref(povl)
            retFuture.fail(newException(OSError, osErrorMsg(err)))
            return

        if povl.timerOrWait != 0:
          GC_unref(povl)
          retFuture.complete(false)
        else:
          GC_unref(povl)
          retFuture.complete(true)

    proc cancel(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        loop.handles.excl(AsyncFD(handle))
        discard unregisterWait(povl.waitFd)
        GC_unref(povl)

    povl.data = CompletionData(fd: AsyncFD(handle), cb: handleContinuation)
    povl.ioPort = loop.getIoHandler()
    povl.handle = handle
    loop.handles.incl(AsyncFD(handle))
    if not registerWaitForSingleObject(addr povl.waitFd, povl.handle,
                                       cast[WAITORTIMERCALLBACK](waitCallback),
                                       cast[pointer](povl), timems, flags):
      let err = osLastError()
      GC_unref(povl)
      loop.handles.excl(AsyncFD(handle))
      retFuture.fail(newException(OSError, osErrorMsg(err)))

    retFuture.cancelCallback = cancel
    return retFuture

else:

  proc getFd*(event: SelectEvent): cint =
    type
      EventType = object
        fd: cint
      PEventType = ptr EventType
    var e = cast[PEventType](event)
    result = e.fd

  proc awaitForSelectEvent*(event: SelectEvent,
                            timeout: Duration): Future[bool] =
    ## Wait for Selectors' event SelectEvent in asynchronous way.
    ##
    ## Procedure returns ``true`` if state of event ``event`` become
    ## signalled, and ``false`` if timeout ``timeout`` occurs before
    ## event ``event`` become signaled.
    var retFuture = newFuture[bool]("chronos.awaitForSelectEvent")
    let loop = getThreadDispatcher()
    var data: SelectorData
    var moment: Moment

    proc handleContinuation(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        loop.selector.unregister(event)
        if isNil(udata):
          retFuture.complete(false)
        else:
          retFuture.complete(true)

    proc cancel(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        loop.selector.unregister(event)
        if timeout != InfiniteDuration:
          removeTimer(moment, handleContinuation, nil)

    if timeout != InfiniteDuration:
      moment = Moment.fromNow(timeout)
      addTimer(moment, handleContinuation, nil)

    let fd = event.getFd()
    loop.selector.registerEvent(event, data)

    withData(loop.selector, int(fd), adata) do:
      adata.reader = AsyncCallback(function: handleContinuation,
                                   udata: addr adata.rdata)
      adata.rdata.fd = AsyncFD(fd)
      adata.rdata.udata = nil
    do:
      retFuture.fail(newException(ValueError,
                     "Event descriptor not registered."))

    retFuture.cancelCallback = cancel
    return retFuture
