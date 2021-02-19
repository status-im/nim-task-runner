# proc c_malloc*(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
# proc c_free(p: pointer) {.importc:"free", header: "<stdlib.h>".}

type
  ThreadSafeString* = distinct cstring

# proc safe*(input: string): ThreadSafeString =
#   var res = cast[cstring](c_malloc(csize_t input.len + 1))
#   copyMem(res, input.cstring, input.len)
#   res[input.len] = '\0'
#   res.ThreadSafeString

# proc `$`*(input: ThreadSafeString): string =
#   result = $(input.cstring)
#   c_free(cast[pointer](input))

proc safe*(input: string): ThreadSafeString =
  var res = cast[cstring](createShared(cstring, input.len + 1))
  copyMem(res, input.cstring, input.len)
  res[input.len] = '\0'
  res.ThreadSafeString

proc `$`*(input: ThreadSafeString): string =
  result = $(input.cstring)
  freeShared(cast[ptr cstring](input))
