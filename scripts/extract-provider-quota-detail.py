"""Compile the real provider detail quota section and its exact helpers in UI fixtures."""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
source = root / "Views/Providers/ProviderInstanceDetailView.swift"
text = source.read_text(encoding="utf-8")
start = text.index("    // MARK: - API Key Quota")
end = text.index("    // MARK: - Manual OAuth Token", start)
section = text[start:end]
assert "private func apiKeyQuotaSection" in section
assert "private func formatQuotaAmount" in section
output = pathlib.Path(sys.argv[1])
picker_source = root / "Views/Providers/UnifiedModelPicker.swift"
picker_text = picker_source.read_text(encoding="utf-8")
picker_section = picker_text[picker_text.index("    // MARK: - Instance Section"):picker_text.index("    // MARK: - Entry Row")]
output.write_text("""import SwiftUI
struct ProductionDetailQuota: View {
    let instance: ProviderInstance
    @ObservedObject var quotaStore: ProviderAPIQuotaStore
    var body: some View { Form { apiKeyQuotaSection(instance) } }
""" + section + "\n}\n" + """
// Provider section + balance binding below are exact production source.
// Model catalog/store data and the surrounding navigation shell are fixtures.
struct ModelEntry: Identifiable { let id: String }
enum VoiceProviderResolver { static func isSystemEntry(_ id: String) -> Bool { false } }
struct ProductionPickerQuota: View {
    let instance: ProviderInstance
    @ObservedObject var quotaStore: ProviderAPIQuotaStore
    @State private var searchText = ""
    @State private var collapsedInstanceIds: Set<String> = []
    @State private var lastEditedProviderID: String?
    @State private var editingProvider: ProviderInstance?
    private let isMulti = false
    private struct Config {
        let currentGroupId: (() -> String?)? = nil
        let currentEntryId: (() -> String?)? = nil
    }
    private let config = Config()
    private struct Store {
        let value: ProviderInstance
        var authRevision: Int { 0 }
        func instance(for id: String) -> ProviderInstance? { value }
    }
    private var store: Store { Store(value: instance) }
    private static func systemRowKey(_ value: String) -> String { value }
    private func entryRow(_ entry: ModelEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "circle").font(.system(size: 20)).foregroundStyle(.tertiary)
            Image(systemName: "circle.fill").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto").font(.subheadline)
                Text(entry.id).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "bolt.badge.checkmark").foregroundStyle(.blue)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                instanceSection((instance: instance, entries: [ModelEntry(id: "auto")]))
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索模型")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") {} } }
        }
    }
""" + picker_section + "\n}\n", encoding="utf-8")
manifest = {
    "source": str(source.relative_to(root)),
    "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
    "extractedSectionSHA256": hashlib.sha256(section.encode()).hexdigest(),
    "extractedWithoutModification": True,
    "container": "Real Form in UIHostingController; production section and all formatting helpers unchanged",
    "pickerSource": str(picker_source.relative_to(root)),
    "pickerSourceSHA256": hashlib.sha256(picker_source.read_bytes()).hexdigest(),
    "pickerSectionSHA256": hashlib.sha256(picker_section.encode()).hexdigest(),
    "pickerSectionExtractedWithoutModification": True,
    "scope": "Two separate page fixtures: exact production provider section / exact production detail quota section; fixture model row and navigation shells; not full application captures",
}
output.with_suffix(".sources.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
