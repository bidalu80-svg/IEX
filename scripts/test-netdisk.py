#!/usr/bin/env python3
"""Prepare/run real production address and wire-parser fixtures; no iOS build claim."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--prepare-only', action='store_true', help='extract sources only; does not execute Swift')
args = p.parse_args()

def source(path):
    return (ROOT / path).read_text(encoding='utf-8')

models = source('Shared/RemoteServers/RemoteServerModels.swift')
wire = source('Shared/RemoteServers/RemoteStorageWireSupport.swift')
store = source('Shared/RemoteServers/RemoteDiskStore.swift')
clients = source('Shared/RemoteServers/RemoteStorageClients.swift')
# Exact production declarations; exclude the HTTP transport, SwiftUI store and
# protocol adapters, whose tests need Apple frameworks/dependency resolution.
chunks = [
    models[models.index('enum RemoteStorageProtocol:'):models.index('/// Common contract')],
    models[models.index('struct RemoteSFTPEntry:'):models.index('enum RemoteServerError:')],
    clients[clients.index('enum RemoteStorageClientError:'):clients.index('/// Minimal WebDAV')],
    store[store.index('struct RemoteDisk:'):store.index('@MainActor\nfinal class RemoteDiskStore')],
    wire[wire.index('enum RemoteStorageEndpoint'):wire.index('enum RemoteStorageHTTP')],
    wire[wire.index('/// NSLock protects'):],
]
with tempfile.TemporaryDirectory(prefix='netdisk-wire-') as temporary:
    out = Path(temporary)
    production = out / 'Production.swift'
    production.write_text('import Foundation\n#if canImport(FoundationXML)\nimport FoundationXML\n#endif\n' + '\n'.join(chunks), encoding='utf-8')
    manifest = {'production_chunks_sha256': [hashlib.sha256(c.encode()).hexdigest() for c in chunks],
                'fixture_sha256': hashlib.sha256((ROOT/'scripts/RemoteDiskWireChecks.swift').read_bytes()).hexdigest(),
                'swift_executed': False}
    if args.prepare_only:
        print(json.dumps(manifest, indent=2))
        print('PASS: extracted production sources and fixtures; Swift NOT compiled or executed (--prepare-only).')
    else:
        compiler = shutil.which('swiftc')
        if not compiler:
            raise SystemExit('ERROR: swiftc unavailable. Use --prepare-only for source preparation; it is not an execution test.')
        executable = out / 'wire-checks'
        subprocess.run([compiler, '-swift-version', '5', '-parse-as-library', str(production),
                        str(ROOT/'scripts/RemoteDiskWireChecks.swift'), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=60)
