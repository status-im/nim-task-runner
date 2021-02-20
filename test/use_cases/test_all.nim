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

# For now it's important to run `test_long_running` last because of a waku
# issue re: deletion of port mappings: github.com/status-im/nim-waku/issues/239.
# If it's run before other tests then there is a consistent hang when exiting
# whatever test follows the waku test.

import
  ./test_async_io.nim,
  ./test_short_running_sync,
  ./test_long_running
