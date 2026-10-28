# Node workload. The old one was a 200k-iteration arithmetic loop; V8 spends
# its time in startup and the module loader, so this one loads fs/path/os/
# json/http and does string and JSON work.
node - <<'JS' > /dev/null 2>&1 || exit 0
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

let acc = 0;
for (let i = 0; i < 500000; i++) acc += Math.sqrt(i) % 7;
const data = [];
for (let i = 0; i < 20000; i++) data.push({ i, name: `item-${i}`, tags: ['a', 'b'] });

const text = JSON.stringify(data);
const back = JSON.parse(text);
if (back.length !== data.length) throw new Error('json');

let n = 0;
for (const d of back) if (d.name.startsWith('item-1')) n++;
console.log(n, acc, os.cpus().length, path.basename('/a/b/c.txt'));

for (let i = 0; i < 200; i++) crypto.createHash('sha256').update(text).digest('hex');

fs.writeFileSync('/tmp/aotw-node.json', text.slice(0, 100000));
fs.readFileSync('/tmp/aotw-node.json');
fs.unlinkSync('/tmp/aotw-node.json');
JS
