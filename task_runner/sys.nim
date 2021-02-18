proc c_malloc*(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc:"free", header: "<stdlib.h>".}

proc toCString*(input: string): cstring =
  result = cast[cstring](c_malloc(csize_t input.len + 1))
  copyMem(result, input.cstring, input.len)
  result[input.len] = '\0'

proc freeCString*(input: cstring) =
  c_free(cast[pointer](input))
