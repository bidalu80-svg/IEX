#!/bin/sh
# Start the guest sshd the ssh/scp training workloads connect to at
# 127.0.0.1:2222. The workflow installs openssh-server; a bare test rootfs has
# no service manager, so create the state sshd expects and run it in the
# background here, before the reference workload makes its first connection.
# Source this file so the wrapper owns the daemon and its cleanup trap.
set -eu

# sshd privilege-separation chroot and unprivileged account. The Alpine
# openssh-server package may leave these to its service manager. On macOS
# realfs, the workflow creates /var/empty with host uid 0 before recording.
mkdir -p /var/empty /run/sshd /etc/ssh
if [ "$(stat -c %u:%g /var/empty)" != 0:0 ]; then
    chown root:root /var/empty
fi
if [ "$(stat -c %a /var/empty)" != 755 ]; then
    chmod 755 /var/empty
fi
if ! grep -q '^sshd:' /etc/group; then
    addgroup -S sshd
fi
if ! grep -q '^sshd:' /etc/passwd; then
    adduser -S -D -H -h /var/empty -s /sbin/nologin -G sshd -g sshd sshd
fi

# Generate the host keys on first use.
ssh-keygen -A

# The training client uses root's standard identities, including id_rsa.
# Keep existing keys and authorize the corresponding public keys locally.
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
# Alpine's minirootfs locks root with '*'; sshd rejects even public keys for
# a locked account. Password login remains disabled in this private config.
passwd -d root

cat > /tmp/aojit/ssh/sshd_config <<'CONFIG'
Port 2222
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /run/sshd-aot.pid
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthenticationMethods publickey
AuthorizedKeysFile /root/.ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
# realfs exposes the macOS runner's uid for the guest's home/key files.
StrictModes no
UseDNS no
Subsystem sftp internal-sftp
CONFIG
/usr/sbin/sshd -t -f /tmp/aojit/ssh/sshd_config
/usr/sbin/sshd -D -e -f /tmp/aojit/ssh/sshd_config >/tmp/aojit/ssh/sshd.log 2>&1 &
sshd_pid=$!
trap 'kill "$sshd_pid" 2>/dev/null || true; wait "$sshd_pid" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# An authenticated command checks listening, host keys and client credentials.
sshd_ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$sshd_pid" 2>/dev/null || break
    if ssh -p 2222 -i /root/.ssh/id_rsa -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 -o ConnectionAttempts=1 -o LogLevel=ERROR \
        root@127.0.0.1 ':' >/tmp/aojit/ssh/ready.log 2>&1; then
        sshd_ready=1
        break
    fi
    sleep 1
done
if [ "$sshd_ready" != 1 ] || ! kill -0 "$sshd_pid" 2>/dev/null; then
    echo 'FAIL ssh: guest sshd is not ready on 127.0.0.1:2222' >&2
    cat /tmp/aojit/ssh/sshd.log /tmp/aojit/ssh/ready.log >&2 2>/dev/null || true
    exit 1
fi
