#             Task Runner synchronization primitives
#                          adapted from
#               Chronos synchronization primitives
#           (github.com/status-im/nim-chronos/pull/45)
#
#            (c) Copyright 2018-Present Eugene Kabanov
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#                    Licensed under either of
#         Apache License, version 2.0, (LICENSE-APACHEv2)
#                    MIT license (LICENSE-MIT)
import os

import chronos/[asyncloop, asyncsync, handles, selectors2, timer]
export asyncsync

import ./osapi

when defined(windows):
  from ./asyncloop as extracted_asyncloop import awaitForSingleObject

const hasThreadSupport* = compileOption("threads")

when hasThreadSupport:
  import locks

when defined(windows):
  import winlean
else:
  import posix

type
  AsyncThreadEventImpl = object
    when defined(linux):
      efd: AsyncFD
    elif defined(windows):
      event: Handle
    else:
      when hasThreadSupport:
        # We need this lock to have behavior equal to Windows' event object and
        # Linux' eventfd descriptor. Otherwise our Event becomes Semaphore on
        # BSD/MacOS/Solaris.
        lock: Lock
      flag: bool
      rfd: AsyncFD
      wfd: AsyncFD

  AsyncThreadEvent* = ptr AsyncThreadEventImpl
    ## A primitive event object which can be shared between threads.
    ##
    ## An event manages a flag that can be set to `true` with the ``fire()``
    ## procedure.
    ## The ``wait()`` coroutine blocks until the flag is `false`.
    ## The ``waitSync()`` procedure blocks until the flag is `false`.
    ##
    ## If more than one coroutine blocked in ``wait()`` waiting for event state
    ## to be signalled, when event get fired, only ``ONE`` coroutine proceeds.

  WaitResult* = enum
    WaitSuccess, WaitTimeout, WaitFailed

proc newAsyncThreadEvent*(): AsyncThreadEvent =
  ## Create new AsyncThreadEvent event.
  when defined(linux):
    # On Linux we are using `eventfd`.
    let fd = eventfd(0, 0)
    if fd == -1:
      raiseOSError(osLastError())
    if not(setSocketBlocking(SocketHandle(fd), false)):
      raiseOSError(osLastError())
    result = cast[AsyncThreadEvent](allocShared0(sizeof(AsyncThreadEventImpl)))
    result.efd = AsyncFD(fd)
  elif defined(windows):
    # On Windows we are using kernel Event object.
    let event = osapi.createEvent(nil, DWORD(0), DWORD(0), nil)
    if event == Handle(0):
      raiseOSError(osLastError())
    result = cast[AsyncThreadEvent](allocShared0(sizeof(AsyncThreadEventImpl)))
    result.event = event
  else:
    # On all other posix systems we are using anonymous pipe.
    var (rfd, wfd) = createAsyncPipe()
    # CHANGED :: cast to int32
    if rfd.int32 == asyncInvalidPipe.int32 or wfd.int32 == asyncInvalidPipe.int32:
      raiseOSError(osLastError())
    if not(setSocketBlocking(SocketHandle(wfd), true)):
      raiseOSError(osLastError())
    result = cast[AsyncThreadEvent](allocShared0(sizeof(AsyncThreadEventImpl)))
    # CHANGED :: cast to AsyncFD
    result.rfd = cast[AsyncFD](rfd)
    result.wfd = cast[AsyncFD](wfd)
    result.flag = false
    when hasThreadSupport:
      initLock(result.lock)

proc close*(event: AsyncThreadEvent) =
  ## Close AsyncThreadEvent ``event`` and free all the resources.
  when defined(linux):
    let loop = getThreadDispatcher()
    if event.efd in loop:
      unregister(event.efd)
    discard posix.close(cint(event.efd))
  elif defined(windows):
    discard winlean.closeHandle(event.event)
  else:
    let loop = getThreadDispatcher()
    when hasThreadSupport:
      acquire(event.lock)
    if event.rfd in loop:
      unregister(event.rfd)
    discard posix.close(cint(event.rfd))
    discard posix.close(cint(event.wfd))
    when hasThreadSupport:
      deinitLock(event.lock)
  deallocShared(event)

proc fire*(event: AsyncThreadEvent) =
  ## Set state of AsyncThreadEvent ``event`` to signalled.
  when defined(linux):
    var data = 1'u64
    while true:
      if posix.write(cint(event.efd), addr data, sizeof(uint64)) == -1:
        let err = osLastError()
        if cint(err) == posix.EINTR:
          continue
        raiseOSError(osLastError())
      break
  elif defined(windows):
    if setEvent(event.event) == 0:
      raiseOSError(osLastError())
  else:
    var data = 1'u64
    when hasThreadSupport:
      acquire(event.lock)
      try:
        if not(event.flag):
          while true:
            if posix.write(cint(event.wfd), addr data, sizeof(uint64)) == -1:
              let err = osLastError()
              if cint(err) == posix.EINTR:
                continue
              raiseOSError(osLastError())
            break
          event.flag = true
      finally:
        release(event.lock)
    else:
      if not(event.flag):
        while true:
          if posix.write(cint(event.wfd), addr data, sizeof(uint64)) == -1:
            let err = osLastError()
            if cint(err) == posix.EINTR:
              continue
            raiseOSError(osLastError())
          break
        event.flag = true

when defined(windows):
  proc wait*(event: AsyncThreadEvent,
           timeout: Duration = InfiniteDuration): Future[WaitResult] {.async.} =
    ## Block until the internal flag of ``event`` is `true`. This procedure is
    ## coroutine.
    ##
    ## Procedure returns ``WaitSuccess`` when internal event's state is
    ## signaled. Returns ``WaitTimeout`` when timeout interval elapsed, and the
    ## event's state is nonsignaled. Returns ``WaitFailed`` if error happens
    ## while waiting.
    try:
      let res = await awaitForSingleObject(event.event, timeout)
      if res:
        result = WaitSuccess
      else:
        result = WaitTimeout
    except OSError:
      result = WaitFailed
    except AsyncError:
      result = WaitFailed

  proc waitSync*(event: AsyncThreadEvent,
                 timeout: Duration = InfiniteDuration): WaitResult =
    ## Block until the internal flag of ``event`` is `true`. This procedure is
    ## ``NOT`` coroutine, so it is actually blocks, but this procedure do not
    ## need asynchronous event loop to be present.
    ##
    ## Procedure returns ``WaitSuccess`` when internal event's state is
    ## signaled. Returns ``WaitTimeout`` when timeout interval elapsed, and the
    ## event's state is nonsignaled. Returns ``WaitFailed`` if error happens
    ## while waiting.
    var timeoutWin: DWORD
    if timeout.isInfinite():
      timeoutWin = INFINITE
    else:
      timeoutWin = DWORD(timeout.milliseconds)
    let res = waitForSingleObject(event.event, timeoutWin)
    if res == WAIT_OBJECT_0:
      result = WaitSuccess
    elif res == winlean.WAIT_TIMEOUT:
      result = WaitTimeout
    else:
      result = WaitFailed
else:
  proc wait*(event: AsyncThreadEvent,
             timeout: Duration = InfiniteDuration): Future[WaitResult] =
    ## Block until the internal flag of ``event`` is `true`.
    ##
    ## Procedure returns ``WaitSuccess`` when internal event's state is
    ## signaled. Returns ``WaitTimeout`` when timeout interval elapsed, and the
    ## event's state is nonsignaled. Returns ``WaitFailed`` if error happens
    ## while waiting.
    var moment: Moment
    var retFuture = newFuture[WaitResult]("mtevent.wait")
    let loop = getThreadDispatcher()

    when defined(linux):
      let fd = AsyncFD(event.efd)
    else:
      let fd = AsyncFD(event.rfd)

    proc contiunuation(udata: pointer) {.gcsafe, raises: [Defect].} =
      try:
        if not(retFuture.finished()):
          var data: uint64 = 0
          if isNil(udata):
            removeReader(fd)
            retFuture.complete(WaitTimeout)
          else:
            while true:
              if posix.read(cint(fd), addr data,
                            sizeof(uint64)) != sizeof(uint64):
                let err = osLastError()
                if cint(err) == posix.EINTR:
                  # This error happens when interrupt signal was received by
                  # process so we need to repeat `read` syscall.
                  continue
                elif cint(err) == posix.EAGAIN or
                     cint(err) == posix.EWOULDBLOCK:
                  # This error happens when there already pending `read` syscall
                  # in different thread for this descriptor. This is race
                  # condition, so to avoid it we will wait for another `read`
                  # event from system queue.
                  break
                else:
                  # All other errors
                  removeReader(fd)
                retFuture.complete(WaitFailed)
              else:
                removeReader(fd)
                when not(defined(linux)):
                  when hasThreadSupport:
                    acquire(event.lock)
                  event.flag = false
                  when hasThreadSupport:
                    release(event.lock)
                retFuture.complete(WaitSuccess)
              break
      except IOSelectorsException, ValueError:
        raise newException(Defect, getCurrentExceptionMsg())

    proc cancellation(udata: pointer) {.gcsafe, raises: [Defect].} =
      try:
        if not(retFuture.finished()):
          removeTimer(moment, contiunuation, nil)
          removeReader(fd)
      except IOSelectorsException, ValueError:
        raise newException(Defect, getCurrentExceptionMsg())

    if fd notin loop:
      register(fd)
    addReader(fd, contiunuation, cast[pointer](retFuture))
    if not(timeout.isInfinite()):
      moment = Moment.fromNow(timeout)
      addTimer(moment, contiunuation, nil)

    retFuture.cancelCallback = cancellation
    return retFuture

  proc waitReady(fd: int, timeout: var Duration): WaitResult {.inline.} =
    var tv: Timeval
    var ptv: ptr Timeval = addr tv
    var rset: TFdSet
    posix.FD_ZERO(rset)
    posix.FD_SET(SocketHandle(fd), rset)
    if timeout.isInfinite():
      ptv = nil
    else:
      tv = timeout.toTimeval()
    while true:
      let nfd = fd + 1
      var smoment = Moment.now()
      let res = posix.select(cint(nfd), addr rset, nil, nil, ptv)
      var emoment = Moment.now()
      if res == 1:
        result = WaitSuccess
        if not(timeout.isInfinite()):
          timeout = timeout - (emoment - smoment)
        break
      elif res == 0:
        result = WaitTimeout
        if not(timeout.isInfinite()):
          timeout = ZeroDuration
        break
      elif res == -1:
        let err = osLastError()
        if int(err) == EINTR:
          if not(timeout.isInfinite()):
            tv = (emoment - smoment).toTimeval()
          continue

  proc waitSync*(event: AsyncThreadEvent,
                 timeout: Duration = InfiniteDuration): WaitResult =
    ## Block until the internal flag of ``event`` is `true`. This procedure is
    ## ``NOT`` coroutine, so it is actually blocks, but this procedure do not
    ## need asynchronous event loop to be present.
    ##
    ## Procedure returns ``WaitSuccess`` when internal event's state is
    ## signaled. Returns ``WaitTimeout`` when timeout interval elapsed, and the
    ## event's state is nonsignaled. Returns ``WaitFailed`` if error happens
    ## while waiting.
    var data = 0'u64

    when defined(linux):
      var fd = int(event.efd)
    else:
      var fd = int(event.rfd)

    var curtimeout = timeout

    while true:
      var repeat = false
      let res = waitReady(fd, curtimeout)
      if res == WaitSuccess:
        # Updating timeout value for next iteration.
        when defined(linux):
          while true:
            if posix.read(cint(fd), addr data,
                          sizeof(uint64)) != sizeof(uint64):
              let err = osLastError()
              if cint(err) == posix.EINTR:
                continue
              elif cint(err) == posix.EAGAIN or
                   cint(err) == posix.EWOULDBLOCK:
                # This error happens when there already pending `read` syscall
                # in different thread for this descriptor.
                repeat = true
                break
              result = WaitFailed
            else:
              result = WaitSuccess
            break
        else:
          when hasThreadSupport:
            acquire(event.lock)

          while true:
            if posix.read(cint(fd), addr data,
                          sizeof(uint64)) != sizeof(uint64):
              let err = osLastError()
              if cint(err) == posix.EINTR:
                continue
              elif cint(err) == posix.EAGAIN or
                   cint(err) == posix.EWOULDBLOCK:
                # This error happens when there already pending `read` syscall
                # in different thread for this descriptor.
                repeat = true
                break
              else:
                result = WaitFailed
            else:
              result = WaitSuccess
            break

          if repeat:
            when hasThreadSupport:
              release(event.lock)
            discard
          else:
            event.flag = false
            when hasThreadSupport:
              release(event.lock)
      else:
        result = res

      if not(repeat):
        break
