# busybox workload: ash scripting plus the applets the agent actually uses.
# Adapted from the upstream AOJIT training set (busybox_train.sh); the old
# workload only ran `ls` and `cat`, which left every text-processing applet
# untranslated (1566 translations against 6559 upstream).
W=/tmp/aotw-busybox
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

# --- ash: loops, arithmetic, strings, case, functions
fib() { a=0; b=1; i=0; while [ $i -lt $1 ]; do t=$((a + b)); a=$b; b=$t; i=$((i + 1)); done; echo $a; }
s=0; i=0
while [ $i -lt 20000 ]; do
    case $((i % 4)) in 0) s=$((s + i)) ;; 1) s=$((s - 1)) ;; *) s=$((s ^ i)) ;; esac
    v="item-$i"; v=${v#item-}; v=${v%0}; i=$((i + 1))
done
echo $s $(fib 80) > /dev/null
for w in alpha beta gamma delta; do printf '%s:%d\n' "$w" "${#w}"; done > words.txt

# --- data
seq 1 200000 > n.txt
awk 'BEGIN { srand(1); for (i = 0; i < 100000; i++) printf "%d,u%d,%s,%.2f,%s\n", i, int(rand() * 500), (rand() < 0.5 ? "GET" : "POST"), rand() * 900, (rand() < 0.1 ? "ERROR" : "ok") }' > log.csv

# --- text utilities
sort -rn n.txt | head -1 > /dev/null
sort -t, -k4 -n log.csv | tail -1 > /dev/null
sort -u -t, -k2,2 log.csv | wc -l > /dev/null
cut -d, -f2 log.csv | sort | uniq -c | sort -rn | head -3 > /dev/null
tr 'a-z' 'A-Z' < log.csv | tr -d ',' | wc -c > /dev/null
sed -e 's/\([0-9]\)\([0-9]\)/\2\1/g' -e '/ERROR/d' log.csv | wc -l > /dev/null
sed -n '/POST/{s/,/;/g;p}' log.csv | head -2 > /dev/null
awk -F, '{ s[$3] += $4; c[$5]++ } END { for (k in s) printf "%s %.1f\n", k, s[k]; for (k in c) print k, c[k] }' log.csv > /dev/null
awk '{ s += $1 } END { print s }' n.txt > /dev/null
grep -c ERROR log.csv > /dev/null
grep -E 'u(1|2)[0-9],POST' log.csv | wc -l > /dev/null
grep -v ok log.csv | head -1 > /dev/null
grep -n 'u42,' log.csv | tail -1 > /dev/null
head -c 100000 log.csv | wc -w > /dev/null
tail -n 3 log.csv > /dev/null
rev words.txt > /dev/null
paste -d: words.txt words.txt | head -2 > /dev/null
xargs -n 1000 echo < n.txt | wc -l > /dev/null

# --- files and find
mkdir -p tree
for d in a b c d e; do mkdir -p tree/$d; for f in $(seq 1 60); do echo "file $d $f $((f * 7))" > tree/$d/f$f.txt; done; done
find tree -type f | wc -l > /dev/null
find tree -name 'f1*.txt' | sort | head -3 > /dev/null
find tree -type f -exec grep -l ' 4' {} + | wc -l > /dev/null
grep -r 'file c' tree | wc -l > /dev/null
ls -la tree/a | head -3 > /dev/null
du -s tree > /dev/null
cp -r tree tree2
mv tree2 tree3
rm -rf tree3
grep -rc 'def ' /usr/lib/python3.12/json /usr/lib/python3.12/email 2>/dev/null | tail -2 > /dev/null

# --- archives, checksums, misc
tar cf t.tar tree
gzip -c t.tar > t.tar.gz
gunzip -c t.tar.gz | tar tf - | wc -l > /dev/null
tar xzf t.tar.gz -C "$W"
ls "$W/tree" | wc -l > /dev/null
md5sum log.csv n.txt > /dev/null
sha256sum log.csv | cut -c1-16 > /dev/null
cksum n.txt > /dev/null
date +%s > /dev/null
basename /a/b/c.txt .txt > /dev/null
dirname /a/b/c.txt > /dev/null
expr 7 \* 6 > /dev/null
od -c words.txt | head -2 > /dev/null

cd /; rm -rf "$W"
