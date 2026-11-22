#!/usr/bin/env python3
import io
import json
import plistlib
import re
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(source, start, end):
    index = source.index(start)
    return source[index:source.index(end, index)]


checks = 0


def check(condition, label):
    global checks
    assert condition, label
    checks += 1
    print(f"PASS: {label}")


main = plistlib.loads((ROOT / "Info.plist").read_bytes())
document_types = main["CFBundleDocumentTypes"]
check(main["LSSupportsOpeningDocumentsInPlace"] is True and all(
    declaration["LSHandlerRank"] == "Alternate" and declaration["CFBundleTypeRole"] == "Viewer"
    for declaration in document_types
), "document types open in place as alternate viewers")
check({declaration["CFBundleTypeName"]: set(declaration["LSItemContentTypes"])
       for declaration in document_types} == {
    "JSON Document": {"public.json"},
    "Documents": {
        "com.adobe.pdf", "org.openxmlformats.wordprocessingml.document",
        "org.openxmlformats.spreadsheetml.sheet", "org.openxmlformats.presentationml.presentation",
        "com.microsoft.word.doc", "com.microsoft.excel.xls", "com.microsoft.powerpoint.ppt",
        "public.plain-text", "public.comma-separated-values-text", "public.rtf", "public.zip-archive",
    },
    "All Files": {"public.data", "public.content"},
} and len(document_types) == 3, "JSON, specific document types including ZIP, and both All Files root types remain registered")

scene = read("AppDelegate.swift")
app = read("ZeApp.swift")
importer = read("Shared/ExternalFileImporter.swift")
coordinator = read("Shared/ShareCoordinator.swift")
inbox = read("Shared/PendingShare.swift")
container = read("Shared/SharedContainerStore.swift")
home = read("Views/ContentView.swift")
chat = read("Views/Chat/AIChatView.swift")
provider_config = read("Providers/ProviderConfigStore.swift")
attachments = read("Agent/Chat/AIChatViewModel+Attachments.swift")
project = read("Ze.xcodeproj/project.pbxproj")

check(scene.count("Self.handleURLContexts(") >= 2 and "ExternalFileImporter.ingest(url, into: coordinator)" in scene
      and "ExternalFileImporter.ingest(url, into: shareCoordinator)" in app,
      "cold and warm scene delivery and SwiftUI fallback converge on the importer")
can_ingest = section(importer, "static func canIngest(", "static var inbox:")
ingest_gate = section(importer, "static func ingest(", "let access =")
check(re.fullmatch(r"static func canIngest\(_ url: URL\) -> Bool \{\s*(?:return\s+)?url\.isFileURL\s*\}\s*", can_ingest)
      and "guard canIngest(url) else { return }" in ingest_gate,
      "the importer admits file URLs through its entry guard")
check(".applicationSupportDirectory" in importer and "IncomingAttachments" in importer
      and "SharedContainerStore" not in importer and "UserDefaults" not in importer,
      "document-open staging does not depend on a shared group")
check(importer.index("startAccessingSecurityScopedResource()") < importer.index("Task.detached")
      < importer.index("SecurityScopedDocumentAccess.read(from: url)") < importer.index("copyRegularFile")
      and "defer { if access { url.stopAccessingSecurityScopedResource() } }" in importer
      and "named: url.lastPathComponent" in importer
      and "FileManager.default.copyItem" in inbox and "Data(contentsOf:" not in importer,
      "the importer balances scoped access, coordinates the read and copies the named file without loading its bytes into memory")
publish = section(inbox, "private func publish", "private static func isFileName")
check("UUID()" in publish and '".writing-' in publish and "skipsHiddenFiles" in inbox
      and publish.index("try prepare(staging)") < publish.index("JSONEncoder()") < publish.index("moveItem(at: staging, to: final)")
      and "defer { try? fileManager.removeItem(at: staging) }" in publish,
      "complete, independently named receipts publish atomically; failed writes stay invisible")
pending_scan = section(coordinator, "func checkForPendingShare()", "func acknowledge(")
check("let local = ExternalFileImporter.inbox.receipts()" in pending_scan
      and 'guard let container = appGroupContainerURL else { return nil }' in container
      and "let shared = SharedContainerStore.shareInbox?.receipts() ?? []" in pending_scan
      and "var seen = Set(awaitingRemoval.keys)" in pending_scan,
      "the scan reads the private inbox and tolerates an unavailable legacy App Group inbox")
check(re.search(r"let receipts\s*=\s*\(\s*local\s*\+\s*shared\s*\)\.filter\s*"
                r"\{\s*seen\.insert\(\$0\.id\)\.inserted\s*\}\.sorted\s*\{", pending_scan)
      and "if pending != receipts { pending = receipts }" in pending_scan,
      "private and legacy receipts are merged, deduplicated and published to the pending queue")
check('".received-\\(id.uuidString)"' in inbox and "moveItem(at: directory, to: retired)" in inbox
      and "pending.removeAll { $0.id == receipt.id }" in coordinator
      and "cleanSharedFiles" not in coordinator + container + chat and "bufferTTL" not in coordinator,
      "acknowledgement retires only the delivered ID and no timeout purges the queue")
check("shareCoordinator.checkForPendingShare()" in section(app, "case .active:", "case .inactive:")
      and "coordinator.documentImportFinished()" in importer
      and "checkForPendingShare()" in section(coordinator, "func documentImportFinished()", "func checkForPendingShare()"),
      "foreground activation and completion of a document import scan the queue without an extension redirect")
check(section(read("Shared/DeepLinkRouter.swift"), 'case "share":', 'case "views":').split()
      == ['case', '"share":', 'shareCoordinator.checkForPendingShare()'],
      "legacy ze://share remains a queue scan only")
check("else if shareCoordinator.hasIncomingShares" in home and "lastLocalShareSessionID" in home
      and "let target = shareLaunchSessionID" in home and "incomingShareTargetID == nil" in home
      and 'Button("New Chat") { openSession(Self.makeNewSessionId()) }' in home,
      "cold launch restores a known local conversation or offers session selection and a new draft")
target = section(chat, "private var canReceiveIncomingShares", "private func injectPendingShareIfNeeded")
check(all(marker in target for marker in ("receivesIncomingShares", "isChatViewVisible", "scenePhase == .active",
                                           "!isReadOnly", "!lockStore.appIsLocked", "vm.hasCompletedInitialLoad"))
      and home.count("incomingShareTargetID == id)") == 2,
      "only the visible, loaded, unlocked local chat is eligible in each pane layout")
delivery = section(chat, "private func injectPendingShareIfNeeded", "// MARK: - Pending Transfer Injection")
check("vm.inputText +=" in delivery and "vm.inputText = " not in delivery and "sendMessage" not in delivery
      and "attachments.removeAll" not in delivery
      and delivery.index("guard vm.addFileAttachment(from: fileURL") < delivery.index("shareCoordinator.acknowledge(receipt)", delivery.index("guard vm.addFileAttachment")),
      "draft is appended without sending and files are acknowledged only after add succeeds")
check(".append(InputAttachment(fileName: fileName" in attachments and "let fileName = sourceURL.lastPathComponent" in attachments
      and "try fm.linkItem(at: sourceURL, to: destURL)" in attachments
      and "try fm.copyItem(at: sourceURL, to: destURL)" in attachments,
      "attachment keeps the filename and links or copies its bytes to the existing cache")
check("pendingProviderImport = PendingProviderImport(receipt: receipt" in delivery
      and "if let label = configStore.importInstanceJSON(item.json)" in delivery
      and "onAttach: { item in _ = attachPendingShare(item.receipt) }" in chat,
      "Provider JSON uses the same receipt for the import or attach choice")
recognition = section(chat, "static func providerExportJSON(at url: URL)", "private static func hasProviderExportHeader")
sniffer = section(chat, "private static func hasProviderExportHeader", "private var canReceiveIncomingShares")
prefix_reader = section(sniffer, "private struct ProviderExportPrefix", "mutating func readThroughModels")
prefix_scan = section(sniffer, "mutating func readThroughModels", "@discardableResult")
sniff_dispatch = sniffer[:sniffer.index("private struct ProviderExportPrefix")]
refill = sniffer[sniffer.index("private mutating func peekByte"):]
provider_choice = """if let fileURL = receipt.fileURL, let json = Self.providerExportJSON(at: fileURL) {
                    promptedShareIDs.insert(receipt.id)
                    pendingProviderImport = PendingProviderImport(receipt: receipt, json: json)
                    break receipts
                }
                if !attachPendingShare(receipt)"""
check(" ".join(recognition.split()) == " ".join("""static func providerExportJSON(at url: URL) -> String? {
          guard url.pathExtension.lowercased() == "json",
                hasProviderExportHeader(at: url),
                let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let providerTypeRaw = dict["providerType"] as? String,
                ProviderType(rawValue: providerTypeRaw) != nil,
                dict["credentialType"] is String,
                dict["models"] is [Any] else { return nil }
          return String(data: data, encoding: .utf8)
      }""".split()) and provider_choice in delivery,
      "valid Provider JSON, including over 16 MiB, reaches the choice before the attachment fallback")
export = section(provider_config, "func exportInstanceJSON(", "func importInstanceJSON(")
export_keys = sorted(set(re.findall(r'^            "(\w+)":', export, re.M)) | set(re.findall(r'dict\["(\w+)"\] =', export)))
prefix_fields = re.findall(r'\("(\w+)", \.(\w+), (true|false)\)', prefix_scan)
check('options: [.prettyPrinted, .sortedKeys]' in export
      and [field for field, _, _ in prefix_fields] == export_keys[:export_keys.index("models") + 1]
      and [field for field, _, optional in prefix_fields if optional == "false"] == ["credentialType", "label", "models"]
      and prefix_fields[-1] == ("models", "arrayStart", "false")
      and 'dict["apiKey"] = Data(key.utf8).base64EncodedString()' in export
      and 'dict["appendV1Suffix"] = false' in export
      and '"credentialType": instance.credentialType.rawValue' in export,
      "ordered prefix fields follow the exporter through its required top-level models array")
check('FileHandle(forReadingFrom: url)' in sniff_dispatch and 'defer { try? handle.close() }' in sniff_dispatch
      and ('var header = ProviderExportPrefix(handle: handle) do { try header.readThroughModels() return true } '
           'catch ProviderExportPrefix.ScanError.limitReached { return true } catch { return false }') in ' '.join(sniff_dispatch.split())
      and sniffer.count('handle.read(') == 1
      and not any(token in sniffer for token in ('Data(contentsOf:', 'readToEnd', 'JSONSerialization', 'fileSizeKey'))
      and 'let chunkSize = 4 * 1024' in prefix_reader and 'let scanLimit = 256 * 1024' in prefix_reader
      and ('while offset + ahead >= bytes.count { guard bytesRead < Self.scanLimit else { throw ScanError.limitReached } '
           'let count = min(Self.chunkSize, Self.scanLimit - bytesRead) '
           'guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { throw ScanError.endOfFile } '
           'bytesRead += chunk.count bytes.removeFirst(offset) offset = 0 bytes.append(contentsOf: chunk) } '
           'return bytes[offset + ahead]') in ' '.join(refill.split()),
      "the production scanner refills bounded chunks on demand until it decides, hits EOF or exhausts the scan budget")
check('enum ScanError: Error { case endOfFile, mismatch, limitReached }' in prefix_reader
      and 'try take("{")' in prefix_scan and 'for field in fields' in prefix_scan
      and r'guard try take("\"\(field.key)\"", optional: field.optional) else { continue }' in prefix_scan
      and 'try take(":")' in prefix_scan and 'try take(",")' in prefix_scan
      and 'case .arrayStart: try take("["); return' in prefix_scan
      and ('for (ahead, byte) in token.utf8.enumerated() { if try peekByte(ahead: ahead) != byte { '
           'if optional { return false } throw ScanError.mismatch } } offset += token.utf8.count') in ' '.join(sniffer.split())
      and 'let byte = try peekByte()\n            offset += 1\n            return byte' in sniffer,
      "tokens and string escapes can resume across chunk boundaries without consuming a mismatching optional token")
chunk_size = 4 * 1024
scan_limit = 256 * 1024


class IncompletePrefix(Exception):
    pass


class InvalidPrefix(Exception):
    pass


credential_values = [value.encode() for value in re.findall(r'take\(#"("\w+")"#', prefix_scan)]
string_units = {
    "base64": re.compile(rb'(?:[A-Za-z0-9+/=]|\\/)*'),
    "string": re.compile(rb'(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9A-Fa-f]{4}))*'),
}
partial_escape = {"base64": re.compile(rb'\\'), "string": re.compile(rb'\\(?:u[0-9A-Fa-f]{0,3})?')}


def fixture_matches_prefix(header):
    remaining = header

    def take(*tokens, optional=False):
        nonlocal remaining
        trimmed = remaining.lstrip(b" \t\n\r")
        if len(remaining) - len(trimmed) > 8:
            raise InvalidPrefix
        remaining = trimmed
        for token in tokens:
            if remaining.startswith(token):
                remaining = remaining[len(token):]
                return True
        if any(token.startswith(remaining) for token in tokens):
            raise IncompletePrefix
        if optional:
            return False
        raise InvalidPrefix

    try:
        take(b"{")
        for field, kind, optional in prefix_fields:
            if not take(json.dumps(field).encode(), optional=optional == "true"):
                continue
            take(b":")
            if kind == "arrayStart":
                return take(b"[")
            if kind == "flag":
                take(b"false")
            elif kind == "credential":
                take(*credential_values)
            else:
                take(b'"')
                remaining = remaining[string_units[kind].match(remaining).end():]
                if remaining.startswith(b'"'):
                    remaining = remaining[1:]
                elif not remaining or partial_escape[kind].fullmatch(remaining):
                    raise IncompletePrefix
                else:
                    raise InvalidPrefix
            take(b",")
    except InvalidPrefix:
        return False
    return False


class ShareFixture(io.BytesIO):
    def __init__(self, payload):
        super().__init__(payload)
        self.read_limits = []
        self.returned_bytes = []

    def read(self, limit=-1):
        self.read_limits.append(limit)
        chunk = super().read(limit)
        self.returned_bytes.append(len(chunk))
        return chunk


def fixture_has_header(file):
    prefix = bytearray()
    while len(prefix) < scan_limit:
        chunk = file.read(min(chunk_size, scan_limit - len(prefix)))
        if not chunk:
            return False
        prefix.extend(chunk)
        try:
            return fixture_matches_prefix(prefix)
        except IncompletePrefix:
            continue
    return True


def fixture_recognition(file):
    if not fixture_has_header(file):
        return None
    file.seek(0)
    return json.loads(file.read())


def has_export_header(data):
    return fixture_has_header(ShareFixture(data))


def export_fixture(**fields):
    return json.dumps(fields, indent=2, sort_keys=True, separators=(",", " : ")).replace("/", r"\/").encode("utf-8")


large_value = "x" * (17 * 1024 * 1024)
large_export = export_fixture(providerType="openAI", credentialType="apiKey", label="Fixture",
                              models=[{"displayName": large_value}])
large_attachment = export_fixture(content=large_value, credentialType="apiKey", label="Ordinary JSON")
export_file = ShareFixture(large_export)
for label, expected_chunks in (("dataset", 1), ("x" * 5000, 2)):
    payload = export_fixture(credentialType="apiKey", label=label, rows=[large_value])
    lookalike_file = ShareFixture(payload)
    check(fixture_recognition(lookalike_file) is None and lookalike_file.read_limits == [chunk_size] * expected_chunks
          and sum(lookalike_file.returned_bytes) == chunk_size * expected_chunks < len(payload) / 100,
          f"17 MiB lookalike with {len(label)}-character label reads {sum(lookalike_file.returned_bytes)} bytes (<1%) and never parses the whole file")
check(fixture_recognition(export_file)["providerType"] == "openAI" and export_file.read_limits == [chunk_size, -1]
      and not has_export_header(large_attachment)
      and not has_export_header(export_fixture(payload={"credentialType": "apiKey", "label": large_value}))
      and not has_export_header(export_fixture(apiKey="c2hvcnQ=", content=large_value))
      and not has_export_header(export_fixture(credentialType="apiKey", label="dataset", models={"rows": large_value})),
      "chosen export fixture reaches full parsing; ordinary, nested-marker and non-array models do not")
check(all(has_export_header(export_fixture(providerType="openAI", credentialType=credential, label="Fixture",
                                          models=[], **extra))
          for credential in ("apiKey", "oauth", "chatGPTWeb")
          for extra in ({}, {"appendV1Suffix": False}, {"apiKey": "////", "customBaseURL": "https://example.invalid"},
                        {"customUserAgent": "fixture"}, {"manualOAuthToken": "YWJj"}))
      and all(has_export_header(export_fixture(apiKey="A" * length, appendV1Suffix=False, credentialType="apiKey",
                                              label="Fixture", models=[], providerType="openAI"))
              for length in range(chunk_size - 128, chunk_size + 4, 4))
      and has_export_header(export_fixture(apiKey="////" * chunk_size, credentialType="apiKey", label="Fixture",
                                           models=[], providerType="openAI"))
      and has_export_header(export_fixture(credentialType="apiKey", label="\U0001f600\n\"" * chunk_size,
                                           models=[], providerType="openAI"))
      and not has_export_header(export_fixture(apiKey="A" * (chunk_size - 100), credentialType="apiKey",
                                               label="Fixture", rows=[large_value])),
      "large strings, escapes and API keys can span chunks, but a visible rows key still fails")
truncated_payload = b'{"credentialType":"apiKey","label":"' + b"x" * 5000
truncated_file = ShareFixture(truncated_payload)
check(fixture_recognition(truncated_file) is None and truncated_file.read_limits == [chunk_size] * 3
      and sum(truncated_file.returned_bytes) == len(truncated_payload),
      "a plausible prefix truncated at EOF is not a candidate for full parsing")
over_budget = export_fixture(apiKey="A" * scan_limit, credentialType="apiKey", label="Fixture",
                             models=[], providerType="openAI")
over_budget_file = ShareFixture(over_budget)
check(fixture_recognition(over_budget_file)["providerType"] == "openAI"
      and over_budget_file.read_limits == [chunk_size] * (scan_limit // chunk_size) + [-1]
      and sum(over_budget_file.returned_bytes[:-1]) == scan_limit,
      "a still-plausible prefix reaches full validation only after the 256 KiB budget is exhausted")


def project_object(identifier):
    match = re.search(rf"^\t\t{identifier}\b[^\n]*= \{{(.*?)^\t\t\}};", project, re.M | re.S)
    assert match, f"missing project object {identifier}"
    return match.group(1)


check(not re.search(r"\b(?:fileRef|productRef)\s*=\s*E5E000010\b", project),
      "no build phase references the ZeShare.appex product")
check(not re.search(r"\b(?:target|remoteGlobalIDString)\s*=\s*E5E000040\b", project)
      and not re.search(r"\bE5E0000(?:80|81)\b", project),
      "no target dependency or proxy builds ZeShare")
scheme = ElementTree.parse(ROOT / "Ze.xcodeproj/xcshareddata/xcschemes/Ze.xcscheme")
check(not any(reference.get("BlueprintIdentifier") == "E5E000040"
              or reference.get("BuildableName") == "ZeShare.appex"
              for reference in scheme.iter("BuildableReference")),
      "the Ze scheme does not build ZeShare explicitly")
share_target = project_object("E5E000040")
share_sources = project_object("E5E000041")
check("productReference = E5E000010" in share_target
      and 'productType = "com.apple.product-type.app-extension"' in share_target
      and "E5E000041 /* Sources */" in share_target and "E5E000042 /* Resources */" in share_target
      and "E5E000010 /* ZeShare.appex */" in section(project, "/* Begin PBXFileReference section */", "/* End PBXFileReference section */")
      and all(f"{name}.swift in Sources" in share_sources and (ROOT / f"ShareExtension/{name}.swift").is_file()
              for name in ("ShareViewController", "ShareViewModel")),
      "ZeShare target, product, phase wiring and source files remain available")
app_target = project_object("E51000040")
embed = project_object("E5E000060")
check("E5E000060 /* Embed Foundation Extensions */" in app_target and "dstSubfolderSpec = 13;" in embed
      and all(f"{product}.appex in Embed Foundation Extensions" in embed and dependency in app_target
              for product, dependency in (("AgentWidgetExtension", "E5H000080"), ("ZeFileProvider", "E5FP00080"))),
      "Ze still embeds and builds the widget and File Provider")
app_sources = project_object("E51000041")
check(all(f"{name}.swift in Sources" in app_sources and f"{name}.swift in Sources" in share_sources
          for name in ("PendingShare", "SharedContainerStore"))
      and "ExternalFileImporter.swift in Sources" in app_sources and "ExternalFileImporter.swift in Sources" not in share_sources,
      "receipt code remains in both targets and the direct importer stays app-only")

print(f"Incoming share structure checks passed: {checks}")
