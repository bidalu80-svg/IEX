import SwiftUI

/// Child-agent visual language: purple identity, compact live
/// status treatment, and a black terminal-like preview surface.
enum ZeSubAgentTheme {
    static let purple = Color(red: 0.55, green: 0.28, blue: 0.95)
    static let purpleBright = Color(red: 0.68, green: 0.42, blue: 1.0)
    static let purpleSoft = Color(red: 0.55, green: 0.28, blue: 0.95).opacity(0.14)
    static let blackCard = Color(red: 0.035, green: 0.028, blue: 0.055)
    static let blackCardBorder = Color(red: 0.55, green: 0.28, blue: 0.95).opacity(0.42)
    static let iconName = "person.3.fill"
}

/// Compact, native iOS dock for child agents. It stays hidden until a session
/// has at least one non-closed child, so idle conversations pay no layout cost.
struct ZeSubAgentDockView: View {
    let rootSessionId: String
    let parent: AIChatViewModel
    @ObservedObject private var coordinator = ZeSubAgentCoordinator.shared
    @State private var isPresented = false

    private var records: [ZeSubAgentRecord] {
        coordinator.records(for: rootSessionId).filter { $0.status != .closed }
    }

    /// The top dock is a live-running indicator, not a history list. Keep the
    /// full records available to the sheet while automatically removing the
    /// floating bar once the last child reaches a terminal state.
    private var activeRecords: [ZeSubAgentRecord] {
        records.filter { $0.status.isActive }
    }

    var body: some View {
        Group {
            if !activeRecords.isEmpty {
                Button {
                    isPresented = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: ZeSubAgentTheme.iconName)
                            .foregroundStyle(ZeSubAgentTheme.purple)
                            .font(.system(size: 13, weight: .semibold))
                        Text("子代理")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(records.filter { $0.status.isActive }.count)/\(records.count)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        if let latest = activeRecords.first,
                           let step = latest.steps?.last {
                            Text(step.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if records.contains(where: { $0.status.isActive }) {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(ZeSubAgentTheme.purple)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(ZeSubAgentTheme.purpleSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(ZeSubAgentTheme.purple.opacity(0.28), lineWidth: 0.7)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "打开子代理面板"))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .transition(.move(edge: .top).combined(with: .opacity))
                .sheet(isPresented: $isPresented) {
                    ZeSubAgentPanelView(rootSessionId: rootSessionId, parent: parent)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: records)
    }
}

private struct ZeSubAgentPanelView: View {
    let rootSessionId: String
    let parent: AIChatViewModel
    @ObservedObject private var coordinator = ZeSubAgentCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: String?
    @State private var showingNewAgent = false

    private var records: [ZeSubAgentRecord] {
        coordinator.records(for: rootSessionId).filter { $0.status != .closed }
    }

    var body: some View {
        NavigationStack {
            List {
                if records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3.sequence")
                            .font(.system(size: 28))
                            .foregroundStyle(ZeSubAgentTheme.purple)
                        Text(String(localized: "暂无子代理"))
                            .font(.headline)
                        Text(String(localized: "模型可以使用 spawn_agent 并发拆分独立任务。"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    Section {
                        ForEach(records) { record in
                            Button {
                                selectedId = record.id
                            } label: {
                                ZeSubAgentRow(record: record)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                    } header: {
                        Text("\(records.count) 个子代理 · 最多同时运行 \(ZeSubAgentCoordinator.maxAgentsPerRoot) 个")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "子代理调度"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingNewAgent = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(String(localized: "新建子代理"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
            .sheet(isPresented: $showingNewAgent) {
                ZeSubAgentComposerView(parent: parent)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: Binding<ZeSubAgentRecord?>(
                get: { selectedId.flatMap { coordinator.record(id: $0) } },
                set: { selectedId = $0?.id }
            )) { record in
                ZeSubAgentDetailView(recordId: record.id)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct ZeSubAgentComposerView: View {
    let parent: AIChatViewModel
    @ObservedObject private var coordinator = ZeSubAgentCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var nickname = ""
    @State private var forkContext = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "任务名称（可选）"), text: $nickname)
                    TextField(String(localized: "描述要并发执行的独立任务"), text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text(String(localized: "任务"))
                }
                Section {
                    Toggle(String(localized: "复制当前对话上下文"), isOn: $forkContext)
                } footer: {
                    Text(String(localized: "适合把研究、文件处理或验证拆成互不冲突的并发工作。"))
                }
            }
            .navigationTitle(String(localized: "新建子代理"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "开始")) {
                        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        _ = coordinator.spawn(from: parent, message: text, forkContext: forkContext, nickname: nickname)
                        dismiss()
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Clock-driven purple/pink rim, reused by the black cards and floating preview.
struct ZeSubAgentAnimatedRim: View {
    let cornerRadius: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let angle = (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2) * 360
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    AngularGradient(colors: [ZeSubAgentTheme.purple.opacity(0.35), ZeSubAgentTheme.purpleBright, .pink.opacity(0.88), ZeSubAgentTheme.purple.opacity(0.35)], center: .center, angle: .degrees(angle)),
                    lineWidth: 2
                )
                .shadow(color: ZeSubAgentTheme.purple.opacity(0.6), radius: 7)
        }
    }
}

/// Shared live black-card treatment for both the panel preview and full details.
/// The animated border is driven by wall clock time, not by coordinator updates,
/// so a tool that runs for a long time still has a visibly moving purple rim.
struct ZeSubAgentBlackCard: View {
    let record: ZeSubAgentRecord
    var compact = false

    private var visibleSteps: [ZeSubAgentStep] {
        // Filter persisted records too, so agents created before this fix do
        // not reintroduce the high-frequency reasoning card after reload.
        let steps = (record.steps ?? []).filter {
            $0.icon != "brain.head.profile" && $0.title != "正在思考"
        }
        return compact ? Array(steps.suffix(3)) : steps
    }

    private var cardHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: ZeSubAgentTheme.iconName)
                .font(.system(size: compact ? 15 : 18, weight: .semibold))
                .foregroundStyle(ZeSubAgentTheme.purpleBright)
            Text(record.nickname)
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 2)
            if record.status.isActive { ProgressView().tint(ZeSubAgentTheme.purpleBright) }
            Text(record.status.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(ZeSubAgentTheme.purpleBright)
        }
    }

    @ViewBuilder
    private var cardSteps: some View {
        if visibleSteps.isEmpty {
            Text(record.status.isActive ? String(localized: "正在准备子代理任务…") : record.shortPrompt)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.63))
                .lineLimit(compact ? 2 : 5)
        } else {
            ForEach(visibleSteps) { step in
                ZeSubAgentStepRow(step: step, compact: compact)
                if step.id != visibleSteps.last?.id {
                    Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 13) {
            cardHeader
            cardSteps
            if !compact, let error = record.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(compact ? 13 : 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZeSubAgentTheme.blackCard, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            if record.status.isActive {
                ZeSubAgentAnimatedRim(cornerRadius: 17)
            } else {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(ZeSubAgentTheme.blackCardBorder, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ZeSubAgentStepRow: View {
    let step: ZeSubAgentStep
    let compact: Bool

    private var stateIcon: String {
        switch step.state {
        case "failed": return "exclamationmark.circle.fill"
        case "success": return "checkmark.circle.fill"
        default: return step.icon
        }
    }

    private var stateLabel: String {
        switch step.state {
        case "running": return "进行中"
        case "failed": return "失败"
        case "success": return "完成"
        case "cancelled": return "已停止"
        default: return ""
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: stateIcon)
                .font(.system(size: 13))
                .foregroundStyle(step.state == "failed" ? Color.orange : ZeSubAgentTheme.purpleBright)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(stateLabel)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                if !step.content.isEmpty {
                    Text(step.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(compact ? 2 : 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct ZeSubAgentRow: View {
    let record: ZeSubAgentRecord

    var body: some View {
        ZeSubAgentBlackCard(record: record, compact: true)
            .contentShape(RoundedRectangle(cornerRadius: 17))
    }
}

private struct ZeSubAgentDetailView: View {
    let recordId: String
    @ObservedObject private var coordinator = ZeSubAgentCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var followUp = ""
    @State private var interrupt = false

    private var record: ZeSubAgentRecord? { coordinator.record(id: recordId) }

    var body: some View {
        NavigationStack {
            Group {
                if let record {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Label(record.status.displayName, systemImage: statusIcon(for: record.status))
                                    .foregroundStyle(record.status.isActive ? ZeSubAgentTheme.purple : .secondary)
                                Spacer()
                                Text("层级 \(record.depth)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                Text(String(localized: "任务"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(record.prompt)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                            ZeSubAgentBlackCard(record: record)
                            if !record.output.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(String(localized: "最新输出"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(record.output)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "子代理不存在"))
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(record?.nickname ?? String(localized: "子代理"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let record, record.status != .closed {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if record.status.isActive {
                                Button(role: .destructive) {
                                    coordinator.cancel(id: recordId)
                                } label: {
                                    Label(String(localized: "停止任务"), systemImage: "stop.fill")
                                }
                            } else if record.status == .cancelled || record.status == .interrupted || record.status == .failed {
                                Button {
                                    _ = coordinator.resume(id: recordId)
                                } label: {
                                    Label(String(localized: "准备继续"), systemImage: "arrow.clockwise")
                                }
                            }
                            Button(role: .destructive) {
                                coordinator.close(id: recordId)
                                dismiss()
                            } label: {
                                Label(String(localized: "关闭代理"), systemImage: "xmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(String(localized: "子代理操作"))
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let record, record.status != .closed {
                    VStack(spacing: 8) {
                        if record.status.isActive {
                            Toggle(isOn: $interrupt) {
                                Label(String(localized: "中断当前任务后发送"), systemImage: "bolt.slash")
                                    .font(.subheadline)
                            }
                            .tint(ZeSubAgentTheme.purple)
                            .padding(.horizontal, 4)
                        }
                        HStack(alignment: .bottom, spacing: 8) {
                            TextField(String(localized: "给子代理补充任务…"), text: $followUp, axis: .vertical)
                                .lineLimit(1...4)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .accessibilityLabel(String(localized: "给子代理补充任务"))
                            Button {
                                guard let result = coordinator.sendInput(id: recordId, message: followUp, interrupt: record.status.isActive && interrupt),
                                      result.status == .queued else { return }
                                followUp = ""
                                interrupt = false
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(ZeSubAgentTheme.purple)
                                    .font(.system(size: 30))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (record.status.isActive && !interrupt))
                            .accessibilityLabel(String(localized: "发送补充任务"))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .onChange(of: record?.status.isActive) { isActive in
                if isActive != true { interrupt = false }
            }
        }
    }

    private func statusIcon(for status: ZeSubAgentStatus) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled, .interrupted, .cancelling: return "stop.circle.fill"
        case .idle: return "circle.dotted"
        case .closed: return "xmark.circle.fill"
        case .queued, .running, .awaitingApproval: return "bolt.fill"
        }
    }
}


// MARK: - Settings / Shared-workspace entry point

/// Settings page for the global child-agent switch, model pin, and direct task
/// dispatch. Tasks submitted here use the stable settings root and are routed
/// through /var/ze/shared by explicit prompt contract while retaining the same
/// file/shell/browser tools as chat-created child agents.
struct SubAgentSettingsView: View {
    @AppStorage(ZeSubAgentPreferences.enabledKey) private var enabled: Bool = true
    @AppStorage(ZeSubAgentPreferences.modelEntryKey) private var modelEntryReference: String = ""
    @ObservedObject private var store = ProviderConfigStore.shared
    @ObservedObject private var coordinator = ZeSubAgentCoordinator.shared
    @State private var taskText = ""
    @State private var selectedRecordId: String?

    private var records: [ZeSubAgentRecord] {
        coordinator.records(for: ZeSubAgentPreferences.settingsRootSessionId)
            .filter { $0.status != .closed }
    }

    private var selectedEntry: ModelEntry? {
        guard !modelEntryReference.isEmpty else { return nil }
        return store.entry(for: modelEntryReference)
    }

    var body: some View {
        List {
            Section {
                Toggle(String(localized: "启用子代理功能"), isOn: $enabled)
            } footer: {
                Text(String(localized: "关闭后，模型不会再看到 spawn_agent、send_input、wait_agent 等子代理工具；已经运行的任务仍可在此页查看和停止。"))
            }

            Section {
                NavigationLink {
                    ZeSubAgentModelPickerView(selection: $modelEntryReference)
                } label: {
                    HStack {
                        Label(String(localized: "执行模型"), systemImage: "cpu.fill")
                        Spacer()
                        Text(selectedEntry?.model.displayName ?? String(localized: "跟随当前对话"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text(String(localized: "子代理模型"))
            } footer: {
                Text(String(localized: "选择已配置服务商中的具体模型。留空时，聊天内创建的子代理跟随当前用户对话模型；本页直接提交的任务使用当前默认模型组。"))
            }

            Section {
                TextEditor(text: $taskText)
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if taskText.isEmpty {
                            Text(String(localized: "描述要交给子代理完成的任务…"))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                Button {
                    submitTask()
                } label: {
                    Label(String(localized: "发送给子代理执行"), systemImage: "person.3.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ZeSubAgentTheme.purple)
                .disabled(!enabled || taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(String(localized: "添加任务"))
            } footer: {
                Text(String(localized: "子代理可在 /var/ze/shared 中读取、创建、修改和执行文件；请在任务中写清楚输入、输出和验收条件。"))
            }

            Section {
                if records.isEmpty {
                    Text(String(localized: "暂无设置页任务"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records) { record in
                        Button {
                            selectedRecordId = record.id
                        } label: {
                            ZeSubAgentRow(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(String(localized: "任务列表"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "子代理"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding<ZeSubAgentRecord?>(
            get: { selectedRecordId.flatMap { coordinator.record(id: $0) } },
            set: { selectedRecordId = $0?.id }
        )) { record in
            ZeSubAgentDetailView(recordId: record.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func submitTask() {
        let text = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !text.isEmpty else { return }
        let prompt = """
        Work in the shared directory /var/ze/shared. You may use the shell and file tools to inspect, create, modify, and execute files there. Keep temporary files outside /var/ze/shared. Complete this task and report the exact files changed, commands run, and verification results:

        \(text)
        """
        let record = coordinator.spawnFromSettings(message: prompt)
        if record.error == nil {
            taskText = ""
        }
    }
}

private struct ZeSubAgentModelPickerView: View {
    @Binding var selection: String
    @ObservedObject private var store = ProviderConfigStore.shared

    private var entries: [ModelEntry] {
        store.modelEntries.filter { entry in
            guard !entry.isHidden,
                  let instance = store.instance(for: entry.providerInstanceId) else { return false }
            return instance.isEnabled && instance.hasAnyCredential
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    selection = ""
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "跟随当前对话"))
                            Text(String(localized: "不固定子代理模型"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }

            Section {
                if entries.isEmpty {
                    Text(String(localized: "暂无可用的已配置模型"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        Button {
                            selection = entry.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "cpu")
                                    .foregroundStyle(ZeSubAgentTheme.purple)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.model.displayName)
                                        .foregroundStyle(.primary)
                                    Text(providerLabel(for: entry))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == entry.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(String(localized: "已配置服务商模型"))
            }
        }
        .navigationTitle(String(localized: "子代理模型"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func providerLabel(for entry: ModelEntry) -> String {
        store.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
    }
}
