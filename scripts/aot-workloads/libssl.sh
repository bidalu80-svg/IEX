# libssl workload: real handshakes, not just `import ssl`. The old workload
# created a context and printed a version — 886 translations against 7327
# upstream, and almost nothing of the record layer.
python3 - <<'PY' > /dev/null || exit 0
import socket, ssl

def handshake(host):
    ctx = ssl.create_default_context()
    with socket.create_connection((host, 443), timeout=10) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as tls:
            tls.sendall(b"HEAD / HTTP/1.0\r\nHost: " + host.encode() + b"\r\n\r\n")
            tls.recv(64)

for i in range(6):
    for host in ("www.google.com", "www.cloudflare.com", "1.1.1.1"):
        try:
            handshake(host)
        except Exception:
            pass

# The context, cipher and verification paths run even without a network.
for _ in range(400):
    ctx = ssl.create_default_context()
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.set_ciphers("DEFAULT")
    ctx.cert_store_stats()
    ctx.get_ciphers()
PY
