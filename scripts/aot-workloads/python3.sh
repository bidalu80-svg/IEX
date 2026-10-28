# Python workload: import and exercise the stdlib modules the agent uses.
# The old workload did one json.dumps loop; this one touches the interpreter's
# hot paths (attribute lookup, allocation, exceptions, string formatting)
# plus the lib-dynload modules that have their own images.
python3 - <<'PY' > /dev/null
import base64, collections, csv, datetime, hashlib, io, itertools, json, math
import os, random, re, socket, struct, sys, time, zlib

data = [{"i": i, "name": f"item-{i}", "tags": ["a", "b"] if i % 2 else ["c"]} for i in range(20000)]
encoded = json.dumps(data)
decoded = json.loads(encoded)
assert len(decoded) == len(data)

counts = collections.Counter(d["name"][:4] for d in data)
assert counts

total = 0.0
for i in range(100000):
    total += math.sin(i * 0.01) * math.cos(i * 0.02)
print(total)

pairs = list(itertools.islice(itertools.product(range(50), repeat=2), 2500))
print(len(pairs))

for _ in range(2000):
    datetime.datetime.now().isoformat()
    struct.pack("<iid", 1, 2, 3.0)
    base64.b64encode(b"x" * 64)

blob = b"x" * 400000
for _ in range(30):
    zlib.decompress(zlib.compress(blob))
for _ in range(100):
    hashlib.sha256(blob).hexdigest()
    hashlib.md5(blob).hexdigest()

buf = io.StringIO()
w = csv.writer(buf)
w.writerows(pairs)
assert buf.tell() > 0

text = encoded[:200000]
print(len(re.findall(r'"item-\d+"', text)))
print(sum(1 for _ in re.finditer(r"\d+", text)))

s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
s.close()

for _ in range(3000):
    try:
        raise ValueError("x")
    except ValueError:
        pass

print(sys.version_info[:2])
PY
