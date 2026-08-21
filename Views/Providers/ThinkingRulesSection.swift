import SwiftUI

/// Per-provider overrides for OpenAI-compatible thinking request fields.
/// They are intentionally ordered: the first scope matching the model is used.
struct ThinkingRulesSection: View {
    let instanceId: String
    @Binding var editorRequest: ThinkingRuleEditorRequest?
    @ObservedObject private var store = ProviderConfigStore.shared
    @State private var rules: [ThinkingRule] = []
    @State private var builtInRules: [BuiltInThinkingRule] = []
    @State private var showBuiltInRules = false

    var body: some View {
        Section {
            ForEach(rules) { rule in
                Button { editorRequest = ThinkingRuleEditorRequest(rule: rule, isNew: false) } label: {
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

            DisclosureGroup(isExpanded: $showBuiltInRules) {
                ForEach(builtInRules) { rule in
                    Button { editorRequest = ThinkingRuleEditorRequest(rule: rule.template, isNew: true) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.label).foregroundStyle(.primary)
                                Text("\(rule.scope.displayName) · \(rule.summary)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } label: {
                Label("默认规则（\(builtInRules.count)）", systemImage: "lock.shield")
            }

            Button { editorRequest = ThinkingRuleEditorRequest(rule: nil, isNew: true) } label: {
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
                Text("规则按从上到下的顺序匹配。自定义规则优先于 Ze 的默认请求格式，适用于使用非标准思考参数的 OpenAI 兼容服务。")
                if let preview = matchingPreview {
                    Label(preview, systemImage: "scope")
                        .foregroundStyle(.blue)
                }
                Text("默认规则内置于 Ze，不能直接删除。点按默认规则可复制为自定义规则，再按服务商要求修改。")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .task { await reload() }
        .onChange(of: editorRequest) { request in
            if request == nil { Task { await reload() } }
        }
    }

    private func reload() async {
        rules = await ProviderConfigStore.shared.thinkingRules(for: instanceId)
        builtInRules = ThinkingRuleResolver.builtInRulesForDisplay(instanceId: instanceId)
    }

    private var matchingPreview: String? {
        guard let modelId = store.modelEntries.first(where: {
            $0.providerInstanceId == instanceId && !$0.isHidden
        })?.model.id,
        if let rule = rules.first(where: { $0.scope.matches(modelId) }) {
            return "模型 \(modelId) 将使用自定义规则“\(rule.label)”"
        }
        if let rule = builtInRules.first(where: { $0.scope.matches(modelId) }) {
            return "模型 \(modelId) 将使用默认规则“\(rule.label)”"
        }
        return nil
    }
}

struct ThinkingRuleEditorRequest: Identifiable, Equatable {
    let rule: ThinkingRule?
    let isNew: Bool
    var id: String { "\(rule?.id ?? "new"):\(isNew ? "new" : "edit")" }
}

struct ThinkingRuleEditor: View {
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
                Section {
                    Picker("格式", selection: $format) {
                        ForEach(ThinkingRule.WireFormat.allCases) { Text($0.title).tag($0) }
                    }
                    Text(format.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if format == .booleanToggle || format == .customPath {
                        TextField("字段路径", text: $path)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if format == .reasoningEffort || format == .nestedReasoningEffort || format == .customPath {
                        Toggle("关闭思考时仍发送一个值", isOn: Binding(
                            get: { !offValue.isEmpty },
                            set: { if !$0 { offValue = "" } else if offValue.isEmpty { offValue = "none" } }
                        ))
                        if !offValue.isEmpty {
                            TextField("关闭时的值（例如：none）", text: $offValue)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                } header: {
                    Text("请求格式")
                } footer: {
                    Text("字段路径使用点分隔，例如 extra_body.thinking.enabled。关闭思考时的值留空，即不发送该字段。")
                }
                Section("请求预览") {
                    Text(ThinkingRuleResolver.requestPreview(for: previewRule))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
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

    private var previewRule: ThinkingRule {
        ThinkingRule(label: label.isEmpty ? "示例规则" : label,
                     scope: allModels ? .allModels : .modelPattern(pattern),
                     format: format,
                     path: path,
                     offValue: offValue.isEmpty ? nil : offValue)
    }
}
