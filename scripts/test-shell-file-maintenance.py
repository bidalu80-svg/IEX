#!/usr/bin/env python3
"""Compile the actual shell file-maintenance worker and exercise a temporary fakefs.
--prepare-only is source/fixture preparation, not a Swift execution claim.
"""
from pathlib import Path
import hashlib, json, os, re, sqlite3, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[1]
out = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'ze-shell-file-maintenance-tests'
out.mkdir(parents=True, exist_ok=True)
source = (root / 'Agent/Chat/AIChatViewModel+FileTools.swift').read_text(encoding='utf-8')
worker = source.split('// MARK: - Shell file maintenance worker (Foundation + SQLite only)', 1)[1]
(out / 'ShellFileMaintenance.swift').write_text('import Foundation\nimport SQLite3\n' + worker, encoding='utf-8')
callsite = (root / 'Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text(encoding='utf-8')
assert 'let preSnapshot = await fileMaintenance.snapshot()' in callsite
assert 'await fileMaintenance.scanAndRegisterChanges(since: preSnapshot)' in callsite
assert 'snapshotZeFiles()' not in callsite
assert 'ensureParentDirsInMetaDB(for: path)' not in callsite
producer = (root / 'Vendor/ZeNative/ish/tools/fakefs.c').read_text(encoding='utf-8')
schema = producer.split('static const char *schema = Q(', 1)[1].split('\n);', 1)[0]
schema = re.sub(r'//[^\n]*', '', schema)
database = out / 'fixture-meta.db'
if database.exists(): database.unlink()
db = sqlite3.connect(database)
db.execute('PRAGMA journal_mode=WAL')
db.executescript(schema)
db.close()
(out / 'source-manifest.json').write_text(json.dumps({
    'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'worker_sha256': hashlib.sha256(worker.encode()).hexdigest(),
    'schema_sha256': hashlib.sha256(schema.encode()).hexdigest()
}, indent=2))
harness = root / 'scripts/ShellFileMaintenanceTests.swift'
print('Prepared real production worker and bundled fakefs schema:', out)
if '--prepare-only' not in sys.argv:
    exe = out / 'shell-file-maintenance-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(out / 'ShellFileMaintenance.swift'), str(harness), '-o', str(exe)], check=True)
    subprocess.run([str(exe), str(database)], check=True, timeout=90)
