type
  ThreadSafeString* = distinct cstring

proc safe*(input: string): ThreadSafeString =
  var res = cast[cstring](allocShared(input.len + 1))
  copyMem(res, input.cstring, input.len)
  res[input.len] = '\0'
  res.ThreadSafeString

proc `$`*(input: ThreadSafeString): string =
  result = $(input.cstring)
  deallocShared input.cstring
