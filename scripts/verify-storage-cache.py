#!/usr/bin/env python3
"""Check the storage cache category and deletion boundaries without an iOS SDK."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
passed = 0


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def check(condition, label):
    global passed
    assert condition, label
    passed += 1
    print(f"PASS: {label}")


def body(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


cleaner = source("Views/Settings/StorageCacheCleaner.swift")
files = source("Views/Settings/StorageCacheFiles.swift")
view = source("Views/Settings/StorageManagementView.swift")
categories = re.search(r"^    case (\w+(?:, \w+)+)$", cleaner, re.M)[1].split(", ")
measure = body(cleaner, "private func measure(", "private func clearCategory(")
clear = body(cleaner, "private func clearCategory(", "private func diskFiles(")
check(categories == ["browser", "network", "media", "visualization", "metadata"], "expected five cache rows")
for label, text in (("measurement", measure), ("cleanup", clear)):
    check(re.findall(r"case \.(\w+):", text) == categories, f"every category has a {label} backend")
check("ForEach(StorageCacheCategory.allCases)" in view and
      "case .all: return StorageCacheCategory.allCases" in cleaner, "UI and clear-all share the category table")
check(".task { await caches.load() }" in view and "await caches.refresh(selection)" in view and
      '"当前缓存总大小"' in view and "let size = usage.label(format: vm.format)" in view,
      "async initial scan and fresh confirmation size")
check(clear not in view and "result.inUse" in view and "result.failed" in view and "remaining.label" in view,
      "result reports a measured remainder, retained files and failures")
clear_operation = body(cleaner, "func clear(_ selection:", "private func measure(")
check(clear_operation.index("await clearCategory(category)") < clear_operation.index("await measure(category)"),
      "single and all cleanups rescan the selected backends")

webkit = re.search(r"browserCacheTypes: Set<String> = \[([^\]]+)\]", cleaner)[1]
check(set(webkit.split(", ")) == {"WKWebsiteDataTypeDiskCache", "WKWebsiteDataTypeMemoryCache"} and
      "allWebsiteDataTypes()" not in cleaner, "WebKit deletes only HTTP disk/memory cache types")
check("WKWebsiteDataStore.default()" in cleaner and "fetchAllDataStoreIdentifiers" in cleaner and
      "WKWebsiteDataStore(forIdentifier:" in cleaner and ".nonPersistent()" not in cleaner,
      "default and isolated persistent WebKit stores only")
check("removeData(ofTypes: Self.browserCacheTypes" in clear and
      "fetchDataRecords(ofTypes: Self.browserCacheTypes" in cleaner and "isPartial: true, websiteRecords:" in measure,
      "WebKit uses public eviction API and never invents a byte count")
check("currentDiskUsage" in measure and "currentMemoryUsage" in measure and
      measure.count("URLCache.shared") == clear.count("URLCache.shared") == 1 and
      "URLCache.shared.removeAllCachedResponses()" in clear, "shared HTTP cache measured and cleared once")
check("ZeVisualizationCache.shared.statistics.cost" in measure and
      all(call in clear for call in ("ZeVisualizationCache.shared.clear()", "SelectableMarkdownView.clearVisualizationCaches()")),
      "reuses visualization statistics and existing eviction")
estimate_init = body(cleaner, "init(estimatedBytes:", "var canClear:")
usage_label = body(cleaner, "func label(", "@MainActor")
usage_total = body(cleaner, "func usage(for selection:", "func load()")
visualization_measure = body(measure, "case .visualization:", "case .metadata:")
check("StorageCacheUsage(estimatedBytes: Int64(ZeVisualizationCache.shared.statistics.cost))" in visualization_measure and
      "measuredBytes = 0" in estimate_init and "self.estimatedBytes = estimatedBytes" in estimate_init and
      'if let estimatedBytes { return "估算 \\(format(estimatedBytes))" }' in usage_label and
      '"至少 \\(format(measuredBytes))"' in usage_label and
      "StorageCacheUsage(measuredBytes: values.reduce(0) { $0 + $1.measuredBytes }," in usage_total and
      "estimatedBytes" not in usage_total and "总计只含实测大小，不含可视化估算" in view,
      "visualization cost is labeled as an estimate and never contributes to measured totals or lower bounds")

locations = body(files, "static let modelDirectories", "var groupsFiles")
allowed_paths = {
    "ZeChat", "browser_favicons", "simple-audio", "RemoteDiskPreviews", "AOJIT",
    "com.ze.app.antigravity-models-cache", "com.ze.app.gemini-models-cache", "com.ze.app.models-cache",
    "com.ze.app.openai-models-cache", "com.ze.app.openrouter-models-cache", "com.ze.app.models-dev-cache",
}
check(set(re.findall(r'"([^"\n]+)"', locations)) == allowed_paths,
      "disk roots match the fixed allowlist, not a common user-data directory")
check(set(re.findall(r"urls\(for: (\.\w+),", locations)) == {".applicationSupportDirectory", ".cachesDirectory"} and
      locations.count("fm.temporaryDirectory") == 1 and '["simple-audio"]' in locations,
      "does not enumerate Documents, Library, tmp or App Group roots")
file_rules = body(files, "func permitsFile(", "static func process(")
check(set(re.findall(r'lastPathComponent == "([^"]+\.json)"', file_rules)) == {"api.json", "probe.json"} and
      'length: 64' in file_rules and 'length: 16' in file_rules and
      all(marker in file_rules for marker in ('hasSuffix("-i")', 'hasSuffix("-l")')),
      "disk leaf rules exclude non-cache neighbors such as AOJIT recordings and browser history")
check("UUID(uuidString: name) != nil" in files and "isHex(name, length: 64)" in files and
      "where area.permitsGroup(name)" in files and "where area.permitsFile(directory.appendingPathComponent(name), in: directory)" in files,
      "only generated preview and audio folders and approved sibling filenames are visited")
remove_file = body(files, "private static func removeFile(", "private static func isHex(")
check("openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)" in remove_file and
      "fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW)" in remove_file and "mode_t(S_IFREG)" in remove_file and
      "unlinkat(directory, name, 0)" in remove_file and "removeItem(" not in files,
      "rejects symlinks and deletes only individual files, never directories")
scan_root = body(files, "private static func withCacheDirectory(", "private static func openCacheSubdirectory(")
open_root = body(files, "private static func removeFile(", "for component in components")
check('while basePath.count > 1, basePath.last == "/" { basePath.removeLast() }' in scan_root and
      "open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)" in scan_root and
      "if status == ENOENT { return }" in scan_root and "throw POSIXError(" in scan_root and
      "while basePath.count > 1, basePath.last == \"/\" { basePath.removeLast() }" in open_root and
      "open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)" in open_root and
      "guard directory >= 0 else { return errno }" in open_root and
      "guard status == 0 || status == ENOENT else { throw POSIXError(" in files and
      '"部分缓存未能清理"' in view,
      "linked base directories are counted and skipped, and the deletion open also refuses to follow them")
scan = body(files, "static func process(", "private static func removeFile(")
enumerate_entries = body(scan, "private static func directoryEntries(", "private static func visit(")
measure_entry = scan.split("private static func visit(", 1)[1]
check("try withCacheDirectory(base, components: location.components) { descriptor in" in scan and
      "try openCacheSubdirectory(component, in: descriptor)" in scan_root and
      "openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)" in scan and
      "try directoryEntries(in: descriptor)" in scan and
      "try openCacheSubdirectory(name, in: descriptor)" in scan and "try directoryEntries(in: groupDescriptor)" in scan and
      "dup(descriptor)" in enumerate_entries and "fdopendir(streamDescriptor)" in enumerate_entries and
      "readdir(stream)" in enumerate_entries and "closedir(stream)" in enumerate_entries and
      "visit(file, in: groupDescriptor" in scan and "visit(name, in: descriptor" in scan and
      "fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW)" in measure_entry and
      "mode_t(S_IFREG)" in measure_entry and "result.bytes += Int64(info.st_size)" in measure_entry and
      all(token not in files for token in ("contentsOfDirectory(", "attributesOfItem(", ".enumerator(")),
      "statistics enumerate validated directory descriptors and measure only regular entries relative to those descriptors")
check("guard clear else { return }" in files and "guard counts[folder.path] == nil else { return false }" in files and
      "lock.lock()\n        defer { lock.unlock() }" in files, "measure is read-only and delete checks leases under a lock")

audio_tiles = source("Views/Chat/ZeMediaViews.swift")
audio_player = source("Views/Chat/Media/AudioPlayback.swift")
audio_preview = source("Views/Chat/Media/AudioPreview.swift")
audio_fetch = body(audio_tiles, "            let lease: StorageMediaFileLease?", "        default:")
check(audio_fetch.index("lease = reservation") < audio_fetch.index("URLSession.shared.download") and
      "cacheLease: lease" in audio_fetch and "audioPreview = resource" in audio_tiles and
      "cacheLease = StorageMediaFileLease.audio(for: fileURL)" in audio_preview and
      audio_player.index("let lease = StorageMediaFileLease.audio(for: loadURL)") < audio_player.index("Task.detached") and
      "self.cacheLease = lease" in audio_player and "cacheLease = nil" in audio_player,
      "leases span audio download, view/preview and independent player lifetime")
remote = source("Views/Servers/RemoteDiskBrowserView.swift")
check(remote.index("StorageMediaFileLease.remotePreview()") < remote.index("RemoteDiskService.shared.cache(") and
      "in: lease.folder" in remote and "let lease: StorageMediaFileLease" in remote and
      "Coordinator(file: file)" in remote and "deinit { try? FileManager.default.removeItem(at: file.lease.folder) }" in remote,
      "remote preview is reserved before download and kept through Quick Look teardown")
favicon = source("Agent/BrowserUse/FaviconDiskCache.swift")
check("actor FaviconDiskCache" in favicon and "StorageCacheFiles.process(.favicons, clear: clear)" in favicon and
      "await diskCache.storageCacheFiles(clear: clear)" in source("Agent/BrowserUse/FaviconService.swift"),
      "favicon disk measurement/eviction runs on its existing actor")

project = source("Ze.xcodeproj/project.pbxproj")
for filename in ("StorageCacheCleaner.swift", "StorageCacheFiles.swift"):
    check(project.count(f"/* {filename} in Sources */") == 2 and f"path = {filename};" in project,
          f"{filename} registered in Xcode sources")

print(f"{passed}/{passed} checks passed")
