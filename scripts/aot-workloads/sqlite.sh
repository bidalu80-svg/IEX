#!/bin/sh
# Reference workload; staging fails if the pinned upstream suite is absent.
set -eu
exec /bin/sh /tmp/aojit/net/sqlite_train.sh
