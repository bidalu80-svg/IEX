#!/bin/sh
# Reference workload; staging fails if the pinned upstream suite is absent.
set -eu
. /tmp/aojit/ssh/sshd_setup.sh
/bin/sh /tmp/aojit/ssh/ssh_train.sh
