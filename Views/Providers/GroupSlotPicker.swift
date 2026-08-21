import SwiftUI

// MARK: - GroupSlotPicker
//
// A single "slot → model group" selector used for Default Primary / Default Sub
// / Voice Input / Voice Output. Shows the current group via a Menu listing all
// groups + None, plus a "Create new group from models…" action that opens the
// unified model picker in multi-select mode, builds a ModelGroup from the chosen
// entries, and assigns it to this slot.

struct GroupSlotPicker: View {
    @ObservedObject private var store = ProviderConfigStore.shared
    let label: LocalizedStringKey
    @Binding var selection: String?
    var voiceDirection: VoiceDirection? = nil
    var isVision: Bool = false

    @State private var showCreate = false

    private var selectedName: String {
        if let id = selection, let g = store.group(for: id) { return g.name }
        return String(localized: "无", comment: "No group selected")
    }

    private var selectedVisionMemberCount: Int {
        guard isVision, let id = selection, let group = store.group(for: id) else { return 0 }
        return group.memberEntryIds.reduce(into: 0) { count, entryId in
            guard let entry = store.entry(for: entryId),
                  !entry.isHidden,
                  store.instance(for: entry.providerInstanceId)?.isEnabled == true,
                  entry.model.capabilities.supportedModalities.contains(.imageInput) else { return }
            count += 1
        }
    }

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                Text("无", comment: "No group selected").tag(String?.none)
                ForEach(store.modelGroups) { group in
                    Text(group.name).tag(Optional(group.id))
                }
            } label: { EmptyView() }

            Divider()
            Button {
                showCreate = true
            } label: {
                Label("从模型创建分组…", systemImage: "plus.rectangle.on.folder")
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label)
                        .foregroundStyle(Color(UIColor.label))
                    Spacer()
                    Text(selectedName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if isVision, selection != nil {
                    Label(
                        selectedVisionMemberCount == 0
                            ? "此分组没有已启用的图片识别模型"
                            : "当前可用 \(selectedVisionMemberCount) 个图片识别模型",
                        systemImage: selectedVisionMemberCount == 0 ? "exclamationmark.triangle.fill" : "eye.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(selectedVisionMemberCount == 0 ? .orange : .secondary)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                UnifiedModelPicker(config: createGroupConfig())
            }
        }
    }

    @MainActor
    private func createGroupConfig() -> ModelPickerConfig {
        let dir = voiceDirection
        let assign: (String) -> Void = { selection = $0 }
        return ModelPickerConfig(
            title: isVision ? "创建视觉分组" : "创建分组",
            mode: .multi,
            explicitPreferModality: isVision
                ? [.imageInput]
                : dir.map { $0 == .input ? [.audioInput] : [.audioOutput] },
            groupScope: .none,
            headerNote: isVision
                ? String(localized: "仅显示支持图片输入的模型。", comment: "Vision group picker filter note")
                : dir?.filterNote,
            onAddMulti: { ids in
                guard !ids.isEmpty else { return }
                let name = Self.suggestedName(for: dir, isVision: isVision, store: ProviderConfigStore.shared)
                let group = ModelGroup(name: name, memberEntryIds: ids.sorted())
                ProviderConfigStore.shared.addGroup(group)
                assign(group.id)
            }
        )
    }

    private static func suggestedName(for dir: VoiceDirection?, isVision: Bool = false, store: ProviderConfigStore) -> String {
        let base: String
        if isVision {
            base = String(localized: "视觉输入", comment: "Default vision group name")
        } else {
            switch dir {
            case .input:  base = String(localized: "语音输入", comment: "Default voice input group name")
            case .output: base = String(localized: "语音输出", comment: "Default voice output group name")
            case nil:     base = String(localized: "新建分组", comment: "Default group name")
            }
        }
        let existing = Set(store.modelGroups.map(\.name))
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
