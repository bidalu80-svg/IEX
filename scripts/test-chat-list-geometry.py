#!/usr/bin/env python3
"""Run numerical cases against the extracted production Swift target function."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Views/Chat/ChatKeyboardViewport.swift').read_text()
start = source.index('enum ChatListScrollTarget {')
end = source.index('/// Per-chat UIKit geometry.', start)
production = source[start:end]
checks = (root / 'scripts/ChatListGeometryChecks.swift').read_text()
swiftc = shutil.which('swiftc')
if not swiftc:
    print('SKIP: swiftc is unavailable; no numerical Swift assertions ran.')
else:
    with tempfile.TemporaryDirectory(prefix='chat-list-geometry-') as work:
        work = Path(work)
        (work / 'main.swift').write_text('import Foundation\n' + production + checks)
        subprocess.run([swiftc, str(work / 'main.swift'), '-o', str(work / 'checks')], check=True)
        subprocess.run([str(work / 'checks')], check=True)
