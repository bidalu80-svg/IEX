# PCRE2 workload. The old one ran `git grep -P` once and produced 13
# translations — effectively no image. pcre2grep (pcre2-tools) exercises the
# library directly: compile, JIT-less match, capture groups, lookarounds.
W=/tmp/aotw-pcre2
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

seq 1 200000 | awk '{ printf "line %d: user%d id=%d value=%.3f %s\n", $1, $1 % 500, $1 * 7, $1 * 0.5, ($1 % 13 ? "ok" : "ERROR") }' > data.txt

if command -v pcre2grep > /dev/null 2>&1; then
    for i in $(seq 40); do
        pcre2grep -c 'user(1|2)[0-9]{2}' data.txt > /dev/null
        pcre2grep -o 'id=[0-9]+' data.txt | wc -l > /dev/null
        pcre2grep '(?<=user)42\d' data.txt > /dev/null
        pcre2grep -i 'error' data.txt | wc -l > /dev/null
        pcre2grep 'value=\d+\.\d{3}' data.txt | head -5 > /dev/null
        pcre2grep -M 'line 1000:\n.*' data.txt > /dev/null
    done
fi

# git grep -P as the agent uses it (git links libpcre2 on Alpine).
rm -rf repo && git init -q repo && cd repo || exit 0
git config user.email a@b.c
git config user.name a
cp ../data.txt f
git add f
git commit -qm x
for i in $(seq 20); do
    git grep -P -c 'user(1|2)[0-9]{2}' > /dev/null
    git grep -P -o 'id=\d+' | wc -l > /dev/null
done

cd /; rm -rf "$W"
