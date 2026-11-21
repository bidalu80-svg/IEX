#!/usr/bin/env python3
import io
import json
import plistlib
import re
from pathlib import Path
from typing import NamedTuple

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
extension = plistlib.loads((ROOT / "ShareExtension/Info.plist").read_bytes())
document_types = {identifier for declaration in main["CFBundleDocumentTypes"]
                  if declaration["LSHandlerRank"] == "Alternate" and declaration["CFBundleTypeRole"] == "Viewer"
                  for identifier in declaration["LSItemContentTypes"]}
check(main["LSSupportsOpeningDocumentsInPlace"] and {
    "public.json", "com.adobe.pdf", "org.openxmlformats.wordprocessingml.document",
    "org.openxmlformats.spreadsheetml.sheet", "org.openxmlformats.presentationml.presentation", "public.plain-text",
} <= document_types, "app is an alternate document handler and retains JSON")
check("public.zip-archive" in document_types, "app registers ZIP as an alternate viewer")
check(any(declaration["CFBundleTypeName"] == "All Files"
          and declaration["CFBundleTypeRole"] == "Viewer" and declaration["LSHandlerRank"] == "Alternate"
          and set(declaration["LSItemContentTypes"]) == {"public.data", "public.content"}
          for declaration in main["CFBundleDocumentTypes"]),
      "app registers both root types in one All Files alternate viewer entry")
check(extension["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.share-services",
      "existing Share Extension stays independent of document registration")

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
extension_vm = read("ShareExtension/ShareViewModel.swift")
extension_view = read("ShareExtension/ShareViewController.swift")
project = read("Ze.xcodeproj/project.pbxproj")

check(scene.count("Self.handleURLContexts(") >= 2 and "ExternalFileImporter.ingest(url, into: coordinator)" in scene
      and "ExternalFileImporter.ingest(url, into: shareCoordinator)" in app,
      "cold and warm scene delivery and SwiftUI fallback converge on the importer")
check(".applicationSupportDirectory" in importer and "IncomingAttachments" in importer
      and "SharedContainerStore" not in importer and "UserDefaults" not in importer,
      "document-open staging does not depend on a shared group")
check(importer.index("startAccessingSecurityScopedResource()") < importer.index("Task.detached")
      < importer.index("copyRegularFile") and "named: url.lastPathComponent" in importer
      and "FileManager.default.copyItem" in inbox and "Data(contentsOf:" not in importer,
      "the importer holds access and copies the named file without loading its bytes into memory")
publish = section(inbox, "private func publish", "private static func isFileName")
check("UUID()" in publish and '".writing-' in publish and "skipsHiddenFiles" in inbox
      and publish.index("try prepare(staging)") < publish.index("JSONEncoder()") < publish.index("moveItem(at: staging, to: final)")
      and "defer { try? fileManager.removeItem(at: staging) }" in publish,
      "complete, independently named receipts publish atomically; failed writes stay invisible")
check('guard let container = appGroupContainerURL else { return nil }' in container
      and "ExternalFileImporter.inbox.receipts()" in coordinator and "SharedContainerStore.shareInbox?.receipts() ?? []" in coordinator
      and "seen.insert($0.id).inserted" in coordinator and "awaitingRemoval" in coordinator,
      "both inboxes converge and scans deduplicate by persisted ID")
check('".received-\\(id.uuidString)"' in inbox and "moveItem(at: directory, to: retired)" in inbox
      and "pending.removeAll { $0.id == receipt.id }" in coordinator
      and "cleanSharedFiles" not in coordinator + container + chat and "bufferTTL" not in coordinator,
      "acknowledgement retires only the delivered ID and no timeout purges the queue")
check("shareCoordinator.checkForPendingShare()" in section(app, "case .active:", "case .inactive:")
      and "checkForPendingShare()" in read("Shared/DeepLinkRouter.swift"),
      "manual foreground return checks the disk queue without needing an extension redirect")
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
check("provider.registeredTypeIdentifiers" in extension_vm and "provider.suggestedName" in extension_vm
      and "provider.loadFileRepresentation(forTypeIdentifier: identifier)" in extension_vm
      and "copyRegularFile(at: url" in extension_vm and "jpegData" not in extension_vm and "UIImage" not in extension_vm,
      "extension loads actual file representations and does not re-encode photos")
extension_receive = section(extension_vm, "private func receive(_ provider", "private func loadFile")
explicit_file_url = section(extension_receive, "type: .fileURL", "let generic")
copy_url = section(extension_vm, "private static func copyFileURL", "private static func representedURL")
load_file = section(extension_vm, "private func loadFile", "private func loadItem")
load_item = section(extension_vm, "private func loadItem", "private static func copyFileURL")
named_url_copy = "Self.copyFileURL(url, suggestedFileName: suggestedFileName, into: inbox)"
check("let suggestedName = provider.suggestedName.map { ($0 as NSString).lastPathComponent }" in extension_receive
      and "canLoadPlainText || !(name as NSString).pathExtension.isEmpty ? name : nil" in extension_receive
      and named_url_copy in explicit_file_url
      and extension_receive.count(named_url_copy) == extension_receive.count("Self.copyFileURL(") == 4
      and "inbox.storeFile(named: suggestedFileName ?? url.lastPathComponent)" in copy_url
      and "let name = suggestedFileName ?? url.lastPathComponent" in load_file
      and "inbox.storeFile(named: name)" in load_file,
      "suggested name with an extension (e.g. \u5408\u540c.pdf) wins over a temporary basename on every file URL route")
file_types = section(extension_receive, "let generic", "let rankedFileTypes")
text_commit_start = extension_receive.rfind("\n", 0, extension_receive.index("case .text(let text, let isLink)? = deferredText"))
file_then_text = extension_receive[extension_receive.index("for identifier in rankedFileTypes"):text_commit_start]
check(("if record(await loadFile(from: provider, identifier: identifier, suggestedFileName: suggestedFileName, "
       "onFailure: fileFailure(for: identifier), into: inbox)) { return true }") in " ".join(file_then_text.split())
      and file_then_text.index("await loadFile(") < file_then_text.index("type: .plainText"),
      "plain text with a file representation and a suggested filename is staged as an attachment before inline text")
check(".flatMap { $0.isEmpty ? nil : $0 }" in extension_receive
      and "let canLoadPlainText = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)" in extension_receive
      and "canLoadPlainText || !(name as NSString).pathExtension.isEmpty ? name : nil" in extension_receive
      and "let name = suggestedFileName ?? url.lastPathComponent" in load_file
      and "try PendingShareInbox.copyRegularFile(at: url, to: destination)" in load_file
      and "continuation.resume(returning: saved != nil ? .file(saved: true) : onFailure)" in load_file
      and "guard !fileFailed, case .text(let text, let isLink)? = deferredText else { return false }" in extension_receive,
      "a saved README keeps its exact name; only an evidenced file failure blocks the named text fallback")
check("record(await loadItem(from: provider, type: .fileURL, onFailure: .file(saved: false)" in extension_receive
      and 'guard let url = Self.representedURL(item), url.isFileURL else { return .file(saved: false) }' in explicit_file_url
      and 'identifier: type.identifier, onFailure: onFailure, receive: receive' in load_item
      and 'continuation.resume(returning: error == nil ? receive(item) : onFailure)' in load_item,
      "a declared file URL load error or invalid item records failure instead of allowing a short text substitute")
file_failure = section(extension_receive, "func fileFailure(", "for identifier in rankedFileTypes")
check('Set(provider.registeredTypeIdentifiers(fileOptions: .openInPlace))' in file_types
      and 'if openInPlaceIdentifiers.contains(identifier) { return true }' in file_types
      and '.file(' not in file_types and '.offered' not in extension_vm
      and ' '.join(file_failure.split()) == ('func fileFailure(for identifier: String) -> LoadedItem? '
                                            '{ openInPlaceIdentifiers.contains(identifier) ? .file(saved: false) : nil }'),
      "type and filename only schedule probes; only the in-place registration supplies their failure token")
check(('guard error == nil, let url, url.isFileURL else { continuation.resume(returning: onFailure) return }') in ' '.join(load_file.split())
      and 'continuation.resume(returning: saved != nil ? .file(saved: true) : onFailure)' in load_file
      and 'let onFailure = fileFailure(for: identifier)' in file_then_text
      and 'identifier: identifier, onFailure: onFailure, receive:' in file_then_text
      and 'return saved != nil ? .file(saved: true) : onFailure' in file_then_text
      and 'type: .plainText, receive:' in file_then_text and 'onFailure: LoadedItem? = nil' in load_item,
      "optional callback and materialization failures emit no blocking outcome, including when a coerced file URL exists")
check(all(token not in extension_vm for token in ('NSItemProviderError', 'as NSError', 'error.domain', 'error.code')),
      "unverified callback error codes are not used as file registration evidence")
url_routes = [explicit_file_url, section(extension_receive, "type: .url,", "if canLoadPlainText,"),
              section(extension_receive, "type: .plainText,", "for identifier in rankedFileTypes"),
              file_then_text[file_then_text.index("identifier: identifier, onFailure: onFailure, receive:"):]]
text_commit = extension_receive[text_commit_start:]
check(extension_receive.index("var fileFailed = false") < extension_receive.index("type: .fileURL")
      and all(f"return .file(saved: (try? {named_url_copy}) != nil)" in route for route in url_routes)
      and extension_receive.count("record(await loadItem(") == 4
      and "case .file(let saved): if !saved { fileFailed = true } return saved" in " ".join(extension_receive.split())
      and "if deferredText == nil { deferredText = item }" in extension_receive
      and "storeText(" not in extension_receive[:text_commit_start]
      and "if isLink || text.count <= 1000 { return (try? inbox.storeText(text)) != nil }" in text_commit
      and 'inbox.storeFile(named: "Shared Text.txt")' in text_commit
      and "result.failed += 1" in extension_vm,
      "all delivered file routes record failures before text can be committed; string-only routing and failure totals are preserved")


class RegistrationFixture(NamedTuple):
    identifier: str
    kind: str
    outcome: str


def expected_provider_route(registered, suggested_name, text, *, file_url=None, fallback=None):
    file_failed = file_url is not None
    if file_url == "saved":
        return "file", suggested_name
    for registration in registered:
        if registration.outcome == "saved":
            return "file", suggested_name
        if registration.kind in {"file-url", "in-place"} or registration.outcome == "actual-url-copy-failed":
            file_failed = True
    if fallback == "saved":
        return "file", suggested_name
    if file_failed or fallback == "actual-url-copy-failed" or not text:
        return "failed", None
    if len(text) <= 1000:
        return "text", text
    return "file", "Shared Text.txt"


plain_text = "public.utf8-plain-text"
tsv = "public.utf8-tab-separated-values-text"
csv = "public.comma-separated-values-text"
custom_plain_text = "com.example.custom-plain-text-without-preferred-extension"
pdf = "com.adobe.pdf"
summary = "Short summary"
plain_probe = RegistrationFixture(plain_text, kind="data", outcome="no-url")
for identifier, name in ((plain_text, "README"), (custom_plain_text, "report.xyz")):
    textual = RegistrationFixture(identifier, kind="data", outcome="error")
    copied_file = textual._replace(kind="copy-file")
    in_place = textual._replace(kind="in-place")
    check(expected_provider_route([textual, plain_probe], name, summary) == ("text", summary)
          and expected_provider_route([copied_file, plain_probe], name, summary) == ("text", summary)
          and expected_provider_route([in_place, plain_probe], name, summary) == ("failed", None),
          f"provider policy fixture: {name}, ordinary copy and data failures are unresolved; in-place failure blocks text")
for identifier, name in ((tsv, "report.tsv"), (csv, "report.csv"), (custom_plain_text, "report.xyz"), (pdf, "report.pdf")):
    check(all(expected_provider_route([RegistrationFixture(identifier, kind=kind, outcome=outcome), plain_probe],
                                      suggested_name, summary) == ("failed", None)
              for kind in ("in-place", "file-url") for suggested_name in (name, None) for outcome in ("error", "no-url"))
          and expected_provider_route([RegistrationFixture(identifier, "copy-file", "error")], name, "") == ("failed", None),
          f"provider policy fixture: {name}, explicit file evidence suppresses summaries and no usable payload still fails")
check(expected_provider_route([plain_probe], None, "a" * 1000) == ("text", "a" * 1000),
      "provider contract fixture: 1,000 characters of plain text remain inline")
check(expected_provider_route([plain_probe], None, "a" * 1001) == ("file", "Shared Text.txt"),
      "provider contract fixture: 1,001 characters of plain text become Shared Text.txt")
check(expected_provider_route([plain_probe, RegistrationFixture("public.data", "data", "no-url")], "README", summary) == ("text", summary)
      and expected_provider_route([plain_probe], "summary.txt", "a" * 1001) == ("file", "Shared Text.txt"),
      "provider contract fixture: optional probe failures do not strand named text")
check(expected_provider_route([plain_probe], "report.txt", summary, file_url="error") == ("failed", None)
      and expected_provider_route([plain_probe._replace(outcome="actual-url-copy-failed")], "README", summary) == ("failed", None)
      and expected_provider_route([plain_probe._replace(outcome="temporary-copy-failed")], "README", summary) == ("text", summary),
      "provider policy fixture: explicit URL failure blocks text; failed temporary coercion alone does not")
check(all(expected_provider_route([RegistrationFixture(identifier, kind="copy-file", outcome="saved")], name, summary) == ("file", name)
          for identifier, name in ((tsv, "report.tsv"), (csv, "report.csv"), (custom_plain_text, "report.xyz"), (plain_text, "README")))
      and expected_provider_route([RegistrationFixture(pdf, "in-place", "error"), plain_probe._replace(outcome="saved")],
                                  "report.pdf", summary) == ("file", "report.pdf")
      and expected_provider_route([RegistrationFixture(pdf, "in-place", "error")], "report.pdf", summary,
                                  file_url="error", fallback="saved") == ("file", "report.pdf"),
      "provider contract fixture: any later successful file route wins and keeps the original filename")

check(extension_view.count("canOpenZe: false") == 2 and "Use Open in Ze" in extension_view
      and extension_view.index("guard result.saved > 0") < extension_view.index('"Received by Ze"')
      and "if canOpenZe" in extension_view and "context.open(url)" in extension_view
      and "UIApplication" not in extension_view,
      "extension reports commit results; an optional jump is offered only after a successful write")
check(project.count("/* PendingShare.swift in Sources */") == 4
      and project.count("/* SharedContainerStore.swift in Sources */") == 4
      and project.count("/* ExternalFileImporter.swift in Sources */") == 2,
      "receipt code compiles into both existing targets and the direct importer stays app-only")

print(f"Incoming share structure checks passed: {checks}")
