# libcrypto workload: the hashing, HMAC and PBKDF paths, at sizes that put
# the block functions on the hot path. The old workload hashed 2000 bytes 300
# times (4623 translations against 19316 upstream, and 16-17% hit rate on
# real HTTPS).
python3 - <<'PY' > /dev/null
import hashlib, hmac, os

blob = os.urandom(1 << 20)
for _ in range(120):
    hashlib.sha256(blob).digest()
    hashlib.sha1(blob).digest()
    hashlib.md5(blob).digest()
    hashlib.sha512(blob).digest()

for _ in range(3000):
    hashlib.sha256(b"x" * 2000).hexdigest()

for _ in range(400):
    hashlib.blake2b(blob).digest()
    hashlib.blake2s(blob[:65536]).digest()

key = b"k" * 64
for _ in range(2000):
    hmac.new(key, blob[:4096], hashlib.sha256).digest()
    hmac.new(key, blob[:4096], hashlib.sha1).digest()

for _ in range(200):
    hashlib.pbkdf2_hmac("sha256", b"password", b"salt", 20000, 32)
    hashlib.scrypt(b"password", salt=b"salt", n=16384, r=8, p=1, dklen=32)
PY
