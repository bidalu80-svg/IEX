#!/usr/bin/env python3
"""Verify the storage page wiring; run the cleanup fixture on macOS."""

from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
source = root / "Views/Settings/StorageMaintenance.swift"
maintenance = source.read_text()
view = (root / "Views/Settings/StorageManagementView.swift").read_text()
project = (root / "Ze.xcodeproj/project.pbxproj").read_text()
favorites = (root / "Shared/MediaFavoritesStore.swift").read_text()
favorites_view = (root / "Views/Settings/MediaFavoritesView.swift").read_text()
share_sheet = (root / "Views/Chat/ZeShareSheet.swift").read_text()

deleted = ("StorageAccounting.swift", "StorageCacheCleaner.swift", "StorageCacheFiles.swift")
assert all(not (source.parent / name).exists() and name not in project for name in deleted)
assert all(not (root / "scripts" / name).exists() for name in (
    "StorageAccountingHarness.swift", "verify-storage-accounting.py", "verify-storage-cache.py"
))
assert project.count("StorageMaintenance.swift in Sources") == 2
assert re.findall(r'Section\("([^"]+)"\)', view.split("private func usageRow")[0]) == ["存储占用", "清理", "会话"]
assert re.findall(r'usageRow\("([^"]+)"', view) == ["总占用", "Documents", "Library", "tmp", "草稿附件（不清理）"]
assert "case temporary, caches, browser" in view
assert all(label not in view for label in ("至少", "估算", "大小未知", "概览", "DisclosureGroup"))
assert "values.totalFileAllocatedSize ?? values.fileAllocatedSize" in maintenance
assert all(key not in maintenance for key in (".fileSizeKey", ".totalFileSizeKey", "st_size"))
assert 'self == .caches && name.caseInsensitiveCompare(StorageMaintenance.inputAttachments)' in maintenance
assert 'static let inputAttachments = "InputAttachments"' in maintenance
sweep = maintenance.split("static func sweep(")[1].split("private static func withDirectory")[0]
assert sweep.index("let before = usage") < sweep.index("removeEntry(") < sweep.index("let after = usage")
assert sweep.rindex("clearURLCache()") < sweep.index("let after = usage")
assert "for name in try directoryEntries(in: descriptor)" in sweep and "if area.excludes(name)" in sweep
assert "O_NOFOLLOW" in maintenance and "AT_SYMLINK_NOFOLLOW" in maintenance and "unlinkat(parent, name, flags)" in maintenance
assert "[WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]" in maintenance
assert "store.removeData(ofTypes: types" in maintenance and "guard (exists || allowMissing), scan.usage.failed == 0 else { return nil }" in maintenance
assert "清理前：" in view and "清理后：" in view and "result.skips.excluded" in view


def verify_review_fixes(maintenance, view, favorites):
    delta = maintenance.split("var netReduction: Int64?")[1].split("static func occupancy")[0]
    assert "guard let before, let after, before.failed == 0, after.failed == 0 else { return nil }" in delta, "complete readings gate"
    result = view.split("case .cleanupResult(let target, let result):")[1]
    assert re.search(r"\breturn before\.bytes - after\.bytes\b", delta) and "max(" not in delta, "signed storage delta"
    assert "if let netReduction = result.netReduction" in result and "if netReduction > 0" in result and (
        "期间有新文件写入，占用未减少" in result and '"已释放：\\(vm.format(netReduction))"' in result
    ), "only positive reductions are displayed as released"
    locations = maintenance.split("private static func locations(")[1].split("private static func measure(")[0]
    assert 'caches.appendingPathComponent("WebKit/NetworkCache", isDirectory: true)' in locations, "default WebKit cache path"
    assert r'WebKit/WebsiteDataStore/\($0.uuidString.lowercased())/NetworkCache' in locations, "isolated WebKit cache path"

    scanner = maintenance.split("private struct AllocationScan")[1].split("enum Area:")[0]
    occupancy = maintenance.split("static func occupancy(")[1].split("static func measure(")[0]
    entry = maintenance.split("private static func measureEntry(")[1].split("private static func removeEntry(")[0]
    assert all(marker in scanner for marker in (
        "[FileIdentity: Int64]", "FileIdentity(device: info.st_dev, inode: info.st_ino)",
        "guard linkedFiles[identity] == nil else { return }", "usage.bytes -= bytes"
    )) and entry.count("scan: &scan") == 1 and "scan.record(Int64(bytes), for: current)" in entry and (
        "var total = AllocationScan()" in occupancy and "total.merge(area)" in occupancy
    ), "inode deduplication within a tree and across top-level directories"

    export = favorites.split("func makeZip(")[1].split("private var indexIsReadable")[0]
    assert "let lease = StorageMediaFileLease(folder: workspace)" in export and all(marker in export for marker in (
        "let stageURL = workspace.appendingPathComponent(", "let archiveURL = workspace.appendingPathComponent(",
        "defer { withExtendedLifetime(lease) {} }", "return ShareItem(url: archiveURL, lease: lease)"
    )) and export.index("StorageMediaFileLease(folder: workspace)") < export.index("try fm.createDirectory("), "leased favorites export workspace"
    assert "ZeShareSheet(url: item.url, fileLease: item.lease)" in favorites_view and (
        "controller.completionWithItemsHandler = { _, _, _, _ in withExtendedLifetime(fileLease) {} }" in share_sheet
    ), "favorites export lease survives UIKit handoff"


sources = (maintenance, view, favorites)
verify_review_fixes(*sources)
print("PASS: storage redo source checks")

mutations = (
    (0, ", before.failed == 0", "", "complete readings gate"),
    (0, ", after.failed == 0", "", "complete readings gate"),
    (0, '"WebKit/NetworkCache"', '"WebKit/RenamedCache"', "default WebKit cache path"),
    (0, "guard linkedFiles[identity] == nil else { return }", "", "inode deduplication within a tree and across top-level directories"),
    (0, "total.merge(area)", "total.usage.merge(area.usage)", "inode deduplication within a tree and across top-level directories"),
    (2, "let lease = StorageMediaFileLease(folder: workspace)", "", "leased favorites export workspace"),
    (0, "return before.bytes - after.bytes", "return max(0, before.bytes - after.bytes)", "signed storage delta"),
    (1, "if netReduction > 0", "if netReduction >= 0", "only positive reductions are displayed as released"),
)
for index, original, replacement, expected in mutations:
    modified = list(sources)
    assert original in modified[index], f"mutation anchor missing: {original}"
    modified[index] = modified[index].replace(original, replacement, 1)
    try:
        verify_review_fixes(*modified)
    except AssertionError as error:
        assert str(error) == expected, f"wrong assertion for {original}: {error}"
    else:
        raise AssertionError(f"mutation not rejected: {original}")
    print(f"PASS: rejected mutation: {original}")

if platform.system() == "Darwin" and shutil.which("swiftc"):
    with tempfile.TemporaryDirectory() as folder:
        executable = Path(folder) / "storage-maintenance"
        subprocess.run(["swiftc", source, root / "scripts/StorageMaintenanceChecks.swift", "-o", executable], check=True)
        subprocess.run([executable], check=True)
else:
    print("SKIP: macOS Swift filesystem fixture")
