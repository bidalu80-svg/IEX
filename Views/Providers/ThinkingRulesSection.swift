import SwiftUI

/// Per-provider overrides for OpenAI-compatible thinking request fields.
/// They are intentionally ordered: the first scope matching the model is used.
struct ThinkingRulesSection: View {
    let instanceId: String
    @ObservedObject private var store = ProviderConfigStore.shared
    @State private var rules: [ThinkingRule] = []
    @State private var editing: ThinkingRule?
    @State private var creating = false

    var body: some View {
        Section {
            if rules.isEmpty {
                Label("当前使用 Ze 内建的思考参数规则", systemImage: "checkmark.shield")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                Button { editing = rule } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.label).foregroundStyle(.primary)
                            Text("\(rule.scope.displayName) · \(rule.format.title)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                let ids = offsets.map { rules[$0].id }
                Task {
                    for id in ids { _ = await ProviderConfigStore.shared.deleteThinkingRule(id: id, instanceId: instanceId) }
                    await reload()
                }
            }
            .onMove { source, destination in
                rules.move(fromOffsets: source, toOffset: destination)
                let ids = rules.map(\.id)
                Task { _ = await ProviderConfigStore.shared.reorderThinkingRules(instanceId: instanceId, orderedIds: ids) }
            }
            Button { creating = true } label: {
                Label("添加思考规则", systemImage: "plus.circle")
            }
        } header: {
            HStack {
                Text("思考规则")
                Spacer()
                if !rules.isEmpty { EditButton().font(.caption) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("规则按从上到下的顺序匹配。匹配成功的规则会覆盖 Ze 的内建请求格式，适用于使用非标准思考参数的 OpenAI 兼容中转服务。")
                if let preview = matchingPreview {
                    Label(preview, systemImage: "scope")
                        .foregroundStyle(.blue)
                } else if !rules.isEmpty {
                    Text("没有自定义规则匹配此 Provider 当前可见的模型。")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .task { await reload() }
        .sheet(item: $editing) { rule in
            ThinkingRuleEditor(rule: rule, isNew: false) { saved in await save(saved, replacing: rule.id) }
        }
        .sheet(isPresented: $creating) {
            ThinkingRuleEditor(rule: nil, isNew: true) { saved in await save(saved, replacing: nil) }
        }
    }

    private func reload() async { rules = await ProviderConfigStore.shared.thinkingRules(for: instanceId) }

    private var matchingPreview: String? {
        guard let modelId = store.modelEntries.first(where: {
            $0.providerInstanceId == instanceId && !$0.isHidden
        })?.model.id,
        let rule = rules.first(where: { $0.scope.matches(modelId) }) else { return nil }
        return "模型 \(modelId) 将使用“\(rule.label)”"
    }
    private func save(_ rule: ThinkingRule, replacing oldId: String?) async {
        let order = oldId.flatMap { oldId in rules.firstIndex { existing in existing.id == oldId } } ?? rules.count
        _ = await ProviderConfigStore.shared.saveThinkingRule(rule, instanceId: instanceId, sortOrder: order)
        await reload()
    }
}

private struct ThinkingRuleEditor: View {
    let rule: ThinkingRule?
    let isNew: Bool
    let onSave: (ThinkingRule) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var allModels = true
    @State private var pattern = ""
    @State private var format: ThinkingRule.WireFormat = .reasoningEffort
    @State private var path = ""
    @State private var offValue = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    TextField("规则名称", text: $label)
                    Toggle("适用于全部模型", isOn: $allModels)
                    if !allModels {
                        TextField("模型匹配模式（例如：qwen*）", text: $pattern)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Section("请求格式") {
                    Picker("格式", selection: $format) {
                        ForEach(ThinkingRule.WireFormat.allCases) { Text($0.title).tag($0) }
                    }
                    if format == .booleanToggle || format == .customPath {
                        TextField("字段路径", text: $path)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if format == .reasoningEffort || format == .nestedReasoningEffort || format == .customPath {
                        TextField("关闭思考时的值（可选）", text: $offValue)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } footer: {
                    Text("字段路径使用点分隔，例如 extra_body.thinking.enabled。关闭思考时的值留空，即不发送该字段。")
                }
                Section("生效方式") {
                    Label("当模型匹配范围时，此规则会优先于 Ze 的内建请求映射。", systemImage: "arrow.up.to.line")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isNew ? "新建思考规则" : "编辑思考规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let scope: ThinkingRule.Scope = allModels ? .allModels : .modelPattern(pattern)
                        let saved = ThinkingRule(id: isNew ? UUID().uuidString : (rule?.id ?? UUID().uuidString), label: label, scope: scope, format: format, path: path, offValue: offValue.isEmpty ? nil : offValue)
                        Task { await onSave(saved); dismiss() }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!allModels && pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .onAppear {
                guard let rule else { return }
                label = rule.label; format = rule.format; path = rule.path; offValue = rule.offValue ?? ""
                if case .modelPattern(let value) = rule.scope { allModels = false; pattern = value }
            }
        }
    }
}
