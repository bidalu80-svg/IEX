import SwiftUI

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
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("子代理")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(records.filter { $0.status.isActive }.count)/\(records.count)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if records.contains(where: { $0.status.isActive }) {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
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
                            .foregroundStyle(.secondary)
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
                Section(String(localized: "任务")) {
                    TextField(String(localized: "任务名称（可选）"), text: $nickname)
                    TextField(String(localized: "描述要并发执行的独立任务"), text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
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

private struct ZeSubAgentRow: View {
    let record: ZeSubAgentRecord

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(record.status.isActive ? Color.accentColor : statusColor)
                .frame(width: 9, height: 9)
                .overlay {
                    if record.status.isActive {
                        Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 5)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.nickname)
                        .font(.body.weight(.semibold))
                    Text(record.status.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(record.status.isActive ? Color.accentColor : .secondary)
                }
                Text(record.output.isEmpty ? record.shortPrompt : record.output)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch record.status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled, .interrupted: return .orange
        default: return .secondary
        }
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
                                    .foregroundStyle(record.status.isActive ? Color.accentColor : .secondary)
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
                            if !record.output.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(String(localized: "最新输出"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(record.output)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                            if let error = record.error, !error.isEmpty {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.red)
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
                            .tint(.orange)
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
