#!/bin/sh
# Run only in the workflow's separate, unrecorded guest invocation. The ssh
# selector /usr/bin/ssh also matches /usr/bin/ssh-keygen by substring.
set -eu
if [ -n "${ISH_JIT_RECORD:-}" ]; then
    echo 'FAIL ssh: key preparation must run outside recording' >&2
    exit 1
fi

ssh-keygen -A
umask 077
mkdir -p /root/.ssh
for kind in rsa ecdsa ed25519; do
    key="/root/.ssh/id_$kind"
    if [ ! -s "$key" ]; then
        ssh-keygen -q -t "$kind" -N '' -f "$key"
    fi
    public_key=$(ssh-keygen -y -f "$key")
    touch /root/.ssh/authorized_keys
    if ! grep -qxF "$public_key" /root/.ssh/authorized_keys; then
        printf '%s\n' "$public_key" >> /root/.ssh/authorized_keys
    fi
done
chmod 700 /root/.ssh
chmod 600 /root/.ssh/id_* /root/.ssh/authorized_keys
# Alpine locks root with '*'; sshd rejects public keys for a locked account.
# The workload's private sshd config keeps password authentication disabled.
passwd -d root
