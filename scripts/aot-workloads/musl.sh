# musl workload: libc is underneath every dynamically linked program, so the
# way to cover it is to run a broad mix of them in one go — the busybox
# applets, a Python process (libpython links libc) and a shell loop.
#
# The old workload was `for i in $(seq 300); do /bin/true; done`, which only
# covered the process startup path: 1379 translations, against 4807 for the
# upstream training set. Everything below is ordinary shell work the agent
# does anyway, so the recorded blocks are the ones a real command hits.
W=/tmp/aotw-musl
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

seq 1 50000 > n.txt
awk 'BEGIN { srand(1); for (i = 0; i < 20000; i++) printf "%d,%s,%.2f\n", i, (i % 3 ? "GET" : "POST"), i * 0.5 }' > l.csv

sort -rn n.txt | head -1 > /dev/null
sort -t, -k3 -n l.csv | tail -1 > /dev/null
cut -d, -f2 l.csv | sort | uniq -c | sort -rn | head -3 > /dev/null
tr 'a-z' 'A-Z' < l.csv | wc -c > /dev/null
sed -e 's/GET/X/g' l.csv | wc -l > /dev/null
grep -c POST l.csv > /dev/null
grep -E '2[0-9]{3},POST' l.csv | wc -l > /dev/null
head -c 50000 l.csv | wc -w > /dev/null
tail -n 5 l.csv > /dev/null
find /usr/lib/python3.12 -name '*.py' 2>/dev/null | head -500 | xargs grep -l 'import os' 2>/dev/null | wc -l > /dev/null

tar cf t.tar n.txt l.csv
gzip -c t.tar > t.tar.gz
gunzip -c t.tar.gz | tar tf - > /dev/null
md5sum l.csv > /dev/null
sha256sum n.txt | cut -c1-16 > /dev/null

python3 -c "import json, re, zlib, hashlib, sqlite3
d = json.dumps(list(range(20000))).encode()
print(hashlib.sha256(zlib.decompress(zlib.compress(d))).hexdigest()[:8], len(re.findall(rb'\d+', d)))" > /dev/null

for i in $(seq 200); do /bin/true; done
sh -c 'i=0; while [ $i -lt 2000 ]; do i=$((i + 1)); done'

cd /; rm -rf "$W"
