#!/usr/bin/env python3
"""Check the sandbox accounting boundaries and run a filesystem fixture when Swift is installed."""

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SCANNER = ROOT / "Views/Settings/StorageAccounting.swift"
scanner = SCANNER.read_text(encoding="utf-8")
view = (ROOT / "Views/Settings/StorageManagementView.swift").read_text(encoding="utf-8")
project = (ROOT / "Ze.xcodeproj/project.pbxproj").read_text(encoding="utf-8")

checks = {
    "Documents, Application Support, Caches, remaining Library, tmp and every extra sandbox entry": (
        'primaryRegions = ["Documents", "Library", "tmp"]' in scanner
        and 'separateLibraryRegions = ["Application Support", "Caches"]' in scanner
        and '!separateLibraryRegions.contains($0.name)' in scanner
        and '!primaryRegions.contains($0.name)' in scanner
        and '[documents] + libraryRegions + [remainingLibrary, region("tmp", in: root)] + additionalRegions' in scanner
    ),
    "only the disjoint regions contribute to the total": 'total: .sum(regions.map(\\.usage))' in scanner,
    "the whole rootfs comes from the recursive scan, including hidden entries": (
        'shell: documents.child(named: "alpine-rootfs")?.usage' in scanner
        and 'contentsOfDirectory(at: url, includingPropertiesForKeys: prefetchKeys, options: [])' in scanner
        and 'items.compactMap { try measure($0,' in scanner
        and 'usage: .sum(sorted.map(\\.usage))' in scanner
    ),
    "physical-file paths use logical byte sizes, without following links or changing files": (
        'values.isSymbolicLink == true { return nil }' in scanner
        and scanner.index('values.isSymbolicLink == true') < scanner.index('fm.contentsOfDirectory(')
        and 'values.totalFileSize ?? values.fileSize' in scanner
        and 'values.isRegularFile == true' in scanner
        and not any(operation in scanner for operation in ('removeItem(', 'moveItem(', 'createDirectory(', '.write(to:'))
    ),
    "chat session detail stays tied to the known session IDs and database sidecars are included": (
        'databaseFiles = ["ze.db", "ze.db-wal", "ze.db-shm", "ze.db-journal"]' in scanner
        and 'databaseFiles.map { chat.child(named: $0)?.usage' in scanner
        and 'let chat = region("ZeChat", in: library)' in scanner
        and 'let ze = region("ze", in: chat)' in scanner
        and 'sessionIDs.reduce(into:' in scanner
        and 'sizes[id] = zeSizes[id]' in scanner
    ),
    "an incomplete scan cannot display a complete-looking zero or subtotal": (
        'total.isIncomplete = total.isIncomplete || value.isIncomplete' in scanner
        and 'children == nil && usage.isIncomplete ? .unknown' in scanner
        and '\\(format(usage.bytes))" : "大小未知"' in view
    ),
    "the scan runs off the main actor and expansion uses the measured subtree": (
        'let scan = Task.detached(priority: .utility)' in view
        and 'NSHomeDirectory()' in view
        and 'scan.cancel()' in view
        and 'ForEach(visibleRows(in: snapshot.regions))' in view
        and 'rows.append(contentsOf: visibleRows(in: children, depth: depth + 1))' in view
    ),
    "the accounting source is registered in the Xcode target": (
        project.count('/* StorageAccounting.swift in Sources */') == 2
        and 'path = StorageAccounting.swift;' in project
    ),
}

for label, passed in checks.items():
    assert passed, label
    print(f"PASS: {label}")
print(f"{len(checks)}/{len(checks)} source checks passed")

swiftc = shutil.which("swiftc")
if swiftc:
    with tempfile.TemporaryDirectory() as directory:
        executable = Path(directory) / "storage-accounting"
        subprocess.run([swiftc, SCANNER, ROOT / "scripts/StorageAccountingHarness.swift", "-o", executable], check=True)
        subprocess.run([executable], check=True)
else:
    print("SKIP: Swift filesystem fixture (swiftc not found)")
