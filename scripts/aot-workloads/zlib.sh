# zlib workload: compression and decompression at several sizes and levels,
# including the gzip wrapper Python uses for wheels.
python3 - <<'PY' > /dev/null
import gzip, io, os, zlib

blob = os.urandom(1 << 20)
text = (b"the quick brown fox jumps over the lazy dog\n" * 40000)

for _ in range(40):
    for level in (1, 6, 9):
        c = zlib.compress(blob, level)
        zlib.decompress(c)
        c = zlib.compress(text, level)
        zlib.decompress(c)

for _ in range(200):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb") as g:
        g.write(text)
    with gzip.GzipFile(fileobj=io.BytesIO(buf.getvalue()), mode="rb") as g:
        g.read()

for _ in range(2000):
    zlib.crc32(text)
    zlib.adler32(blob)
PY
