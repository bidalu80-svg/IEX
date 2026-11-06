import SwiftUI
import UIKit

/// Child-agent visual language: purple identity, compact live
/// status treatment, and a black terminal-like preview surface.
enum ZeSubAgentTheme {
    static let purple = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.64, green: 0.52, blue: 1, alpha: 1)
            : UIColor(red: 0.45, green: 0.30, blue: 0.93, alpha: 1)
    })
    static let purpleBright = Color(red: 0.68, green: 0.42, blue: 1.0)
    static let purpleSoft = Color(red: 0.55, green: 0.28, blue: 0.95).opacity(0.14)
    static let blackCard = Color(red: 0.035, green: 0.028, blue: 0.055)
    static let blackCardBorder = Color(red: 0.55, green: 0.28, blue: 0.95).opacity(0.42)
    static let iconName = "person.2.circle.fill"
    static let glyph = "person.2.fill"
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
            }
        }
        .sheet(isPresented: $isPresented) {
            ZeSubAgentPanelView(rootSessionId: rootSessionId, parent: parent)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .animation(.easeOut(duration: 0.18), value: activeRecords.count)
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
                            ZeSubAgentCompactCard(record: record, open: { selectedId = record.id },
                                                  stop: { coordinator.cancelRunGroup(id: record.id) },
                                                  resume: { _ = coordinator.resume(id: record.id) })
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

/// Presentation derived from persisted lifecycle facts, shared by both compact surfaces.
enum ZeSubAgentPresentation {
    static func elapsed(_ record: ZeSubAgentRecord) -> String {
        let seconds = max(0, Int(record.updatedAt.timeIntervalSince(record.createdAt)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
    static func color(_ status: ZeSubAgentStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled, .interrupted: return .orange
        default: return ZeSubAgentTheme.purple
        }
    }
    static func glyph(_ status: ZeSubAgentStatus) -> String {
        switch status {
        case .completed: return "checkmark"
        case .queued: return "pause.fill"
        case .idle: return ZeSubAgentTheme.glyph
        default: return "exclamationmark"
        }
    }
}

struct ZeSubAgentCompactCard: View {
    let record: ZeSubAgentRecord
    var open: () -> Void
    var stop: () -> Void
    var resume: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(ZeSubAgentTheme.purple.opacity(0.15)).frame(width: 34, height: 34)
                if record.status.isActive && record.status != .queued {
                    ProgressView().controlSize(.mini).tint(ZeSubAgentTheme.purple).frame(width: 15, height: 15)
                } else {
                    Image(systemName: ZeSubAgentPresentation.glyph(record.status))
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(ZeSubAgentPresentation.color(record.status))
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(record.nickname).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ZeSubAgentTheme.purple)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(ZeSubAgentTheme.purple.opacity(0.15)).clipShape(Capsule())
                        .lineLimit(1)
                    Text(record.shortPrompt).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if record.status.isActive, let step = record.steps?.last(where: { $0.state == "running" }) {
                        HStack(spacing: 3) {
                            Image(systemName: step.icon).font(.system(size: 10, weight: .semibold))
                            Text(step.title).font(.system(size: 11, weight: .semibold))
                        }.foregroundStyle(ZeSubAgentTheme.purple).lineLimit(1).fixedSize()
                        Text(step.content).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(record.status.displayName).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ZeSubAgentPresentation.color(record.status)).fixedSize()
                    }
                    Text(ZeSubAgentPresentation.elapsed(record)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary).fixedSize()
                }
            }
            Spacer(minLength: 4)
            if record.status.isActive {
                Button(action: stop) {
                    ZStack {
                        Circle().fill(Color.red).frame(width: 24, height: 24)
                        RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 9, height: 9)
                    }.contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel("停止任务")
            } else if record.status == .interrupted {
                Button(action: resume) {
                    ZStack {
                        Circle().fill(ZeSubAgentTheme.purple).frame(width: 24, height: 24)
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }.contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel("继续任务")
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(ZeSubAgentTheme.purple.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ZeSubAgentTheme.purple.opacity(0.35), lineWidth: 0.8))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: open)
    }
}

struct ZeSubAgentThumbnail: View {
    let record: ZeSubAgentRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: ZeSubAgentTheme.glyph).font(.system(size: 7, weight: .bold))
                Text("Agent").font(.system(size: 6, weight: .bold))
            }.foregroundStyle(ZeSubAgentTheme.purple)
            Text(record.shortPrompt).font(.system(size: 7, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
            Spacer(minLength: 0)
            if record.status.isActive {
                if let step = record.steps?.last(where: { $0.state == "running" }) {
                    HStack(spacing: 2) {
                        Image(systemName: step.icon).font(.system(size: 6, weight: .bold))
                        Text(step.title).font(.system(size: 6, weight: .semibold))
                    }.foregroundStyle(ZeSubAgentTheme.purple).lineLimit(1)
                    Text([step.content, ZeSubAgentPresentation.elapsed(record)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 6)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                } else {
                    Text(record.status.displayName).font(.system(size: 6)).foregroundStyle(.white.opacity(0.7))
                }
            } else {
                Text("\(record.status.displayName) · \(ZeSubAgentPresentation.elapsed(record))")
                    .font(.system(size: 6, weight: .semibold)).foregroundStyle(ZeSubAgentPresentation.color(record.status)).lineLimit(1)
            }
        }
        .padding(5)
        .frame(width: 100, height: 65, alignment: .topLeading)
        .background(Color(white: 0.12))
    }
}

/// A compositor-driven rim. No per-frame SwiftUI invalidation or text layout.
struct ZeSubAgentAnimatedRim: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZeSubAgentRimSurface(cornerRadius: cornerRadius,
                             animates: !reduceMotion && scenePhase == .active)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ZeSubAgentRimSurface: UIViewRepresentable {
    let cornerRadius: CGFloat
    let animates: Bool

    func makeUIView(context: Context) -> ZeSubAgentRimLayerView { ZeSubAgentRimLayerView() }
    func updateUIView(_ view: ZeSubAgentRimLayerView, context: Context) {
        view.cornerRadius = cornerRadius
        view.animates = animates
        view.setNeedsLayout()
        view.updateAnimation()
    }
}

private final class ZeSubAgentRimLayerView: UIView {
    var cornerRadius: CGFloat = 17
    var animates = true
    private let gradient = CAGradientLayer()
    private let outline = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = [UIColor(red: 0.55, green: 0.28, blue: 0.95, alpha: 0.35).cgColor,
                           UIColor(red: 0.68, green: 0.42, blue: 1, alpha: 1).cgColor,
                           UIColor.systemPink.cgColor,
                           UIColor(red: 0.55, green: 0.28, blue: 0.95, alpha: 0.35).cgColor]
        layer.addSublayer(gradient)
        outline.fillColor = UIColor.clear.cgColor
        outline.strokeColor = UIColor.white.cgColor
        outline.lineWidth = 2
        layer.mask = outline
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        outline.frame = bounds
        outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                    cornerRadius: max(0, cornerRadius - 1)).cgPath
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    func updateAnimation() {
        guard animates, window != nil else {
            gradient.removeAnimation(forKey: "rimRotation")
            return
        }
        guard gradient.animation(forKey: "rimRotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 3.2
        rotation.repeatCount = .infinity
        gradient.add(rotation, forKey: "rimRotation")
    }
}

struct ZeSubAgentDetailView: View {
    let recordId: String
    @ObservedObject private var coordinator = ZeSubAgentCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showTranscript = false

    var body: some View {
        NavigationStack {
            ScrollView { ZeSubAgentDetailContent(recordId: recordId).padding(12) }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(coordinator.record(id: recordId)?.nickname ?? String(localized: "子代理"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showTranscript = true } label: { Image(systemName: "bubble.left.and.bubble.right") }
                            .accessibilityLabel("打开子代理对话")
                    }
                }
                .sheet(isPresented: $showTranscript) {
                    ZeSubAgentTranscriptPage(recordId: recordId)
                        .presentationDetents([.fraction(0.35), .medium, .large])
                        .presentationDragIndicator(.visible)
                        .interactiveDismissDisabled()
                        .modifier(ZeSubAgentTranscriptScrollStyle())
                }
        }
    }
}

/// Embedded directly in the tool sheet; the transcript is a separate destination.
struct ZeSubAgentDetailContent: View {
    let recordId: String
    @ObservedObject private var coordinator = ZeSubAgentCoordinator.shared
    @State private var followUp = ""
    @State private var sent = false
    @State private var confirmStop = false

    var body: some View {
        Group {
            if let record = coordinator.record(id: recordId) {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ZeSubAgentSection(title: LocalizedStringKey(record.shortPrompt), icon: ZeSubAgentTheme.iconName, status: record.status.displayName) {
                                VStack(alignment: .leading, spacing: 8) {
                                    metadata("代理", record.nickname)
                                    metadata("状态", record.status.displayName)
                                    if let reference = record.modelEntryReference,
                                       let entry = ProviderConfigStore.shared.entry(for: reference) {
                                        metadata("配置模型", entry.model.displayName)
                                    }
                                    metadata("用时", ZeSubAgentPresentation.elapsed(record))
                                }
                            }
                            ZeSubAgentRunStats(record: record)
                            ZeSubAgentSection(title: "任务", icon: "text.alignleft") {
                                ZeSubAgentCollapsibleText(text: record.prompt)
                            }
                            if record.status.isActive, let step = record.steps?.last(where: { $0.state == "running" }) {
                                ZeSubAgentSection(title: "当前工具", icon: step.icon) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(step.title).font(.system(size: 13, weight: .medium))
                                        if !step.content.isEmpty {
                                            Text(step.content).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                                        }
                                    }
                                }
                            }
                            ZeSubAgentToolHistory(record: record)
                            if let path = record.steps?.last(where: { $0.imageFilePath != nil })?.imageFilePath {
                                ZeSubAgentImagePreview(path: path)
                            }
                            if let error = record.error, !error.isEmpty {
                                ZeSubAgentSection(title: "错误", icon: "exclamationmark.octagon") {
                                    ZeSubAgentCollapsibleText(text: error)
                                }
                            }
                            if !record.output.isEmpty {
                                ZeSubAgentSection(title: record.status.isActive ? "最新输出" : "结果", icon: "text.bubble") {
                                    if record.status.isActive {
                                        ZeSubAgentCollapsibleText(text: record.output)
                                    } else {
                                        SelectableMarkdownView(markdown: record.output)
                                    }
                                }
                            }
                            if record.status != .closed { actions(record) }
                        }

            } else {
                Label("子代理不存在", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("停止这个子代理？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停止任务", role: .destructive) { coordinator.cancelRunGroup(id: recordId) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("同一轮创建的子代理也会停止，已完成的工作和工具记录会保留。")
        }
    }

    private func metadata(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12))
    }

    private func actions(_ record: ZeSubAgentRecord) -> some View {
        ZeSubAgentSection(title: "操作", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(record.status.isActive ? "补充指令或调整方向…" : "给子代理补充任务…", text: $followUp, axis: .vertical)
                        .font(.system(size: 13))
                        .lineLimit(1...4)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    Button {
                        guard coordinator.sendInput(id: recordId, message: followUp) != nil else { return }
                        followUp = ""
                        sent = true
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(ZeSubAgentTheme.purple)
                    }
                    .buttonStyle(.plain)
                    .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || record.status == .cancelling)
                    .accessibilityLabel("发送补充任务")
                }
                if record.status.isActive {
                    Text((record.pendingInputCount ?? 0) > 0
                         ? "补充指令已排队，将在下一轮读取。"
                         : sent ? "指令已发送。" : "子代理在下一轮读取补充指令，正在执行的工具会继续完成。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) { confirmStop = true } label: {
                        Label("停止任务", systemImage: "stop.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                } else if sent {
                    Text("补充任务已发送").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ZeSubAgentSection<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    var status: String? = nil
    @ViewBuilder let content: () -> Content
    private static var barBg: Color { Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.92, alpha: 1) }) }
    private static var cardBg: Color { Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.10, alpha: 1) : UIColor(white: 0.94, alpha: 1) }) }
    private static var stroke: Color { Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25, alpha: 1) : UIColor(white: 0.82, alpha: 1) }) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 6)
                if let status { Text(status).font(.system(size: 11)).foregroundStyle(ZeSubAgentTheme.purple) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10).background(Self.barBg)
            Divider()
            content().frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .background(Self.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.stroke, lineWidth: 0.5))
    }
}

private struct ZeSubAgentCollapsibleText: View {
    let text: String
    var markdown = false
    @State private var expanded = false

    var body: some View {
        let long = text.count > 220 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 4
        VStack(alignment: .leading, spacing: 6) {
            if markdown && (expanded || !long) {
                SelectableMarkdownView(markdown: text)
            } else {
                Text(expanded ? text : String(text.prefix(600)))
                    .font(.system(size: 13))
                    .lineLimit(long && !expanded ? 4 : nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if long {
                Button(expanded ? "收起" : "展开全文") { expanded.toggle() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ZeSubAgentTheme.purple)
                    .buttonStyle(.plain)
            }
        }
    }
}

private struct ZeSubAgentRunStats: View {
    let record: ZeSubAgentRecord

    var body: some View {
        let counts = (record.steps ?? []).reduce(into: (total: 0, success: 0, failed: 0)) { counts, step in
            guard step.state != "info", step.icon != "brain.head.profile" else { return }
            counts.total += 1
            if step.state == "success" { counts.success += 1 }
            if step.state == "failed" { counts.failed += 1 }
        }
        ZeSubAgentChipLayout {
            chip("wrench.and.screwdriver", "\(counts.total) 次工具调用")
            if counts.success > 0 {
                chip("checkmark.circle.fill", "\(counts.success) 成功", tint: .green)
            }
            if counts.failed > 0 {
                chip("xmark.circle.fill", "\(counts.failed) 失败", tint: .red)
            }
            if let turns = record.turnCount, turns > 0 { chip("arrow.triangle.2.circlepath", "\(turns) 轮") }
            if record.inputTokens > 0 || record.outputTokens > 0 {
                chip("arrow.up.arrow.down", "\(record.inputTokens) / \(record.outputTokens) tokens")
            }
            if let cached = record.cacheReadTokens, cached > 0 { chip("archivebox", "\(cached) 缓存读取") }
            chip("square.stack.3d.up", "层级 \(record.depth)")
            if let ref = record.modelEntryReference,
               let entry = ProviderConfigStore.shared.entry(for: ref) { chip("cpu", entry.model.displayName) }
        }
    }

    private func chip(_ icon: String, _ text: String, tint: Color = .secondary) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(uiColor: .secondarySystemFill), in: Capsule())
    }
}

private struct ZeSubAgentChipLayout: Layout {
    private func arrangement(_ width: CGFloat, _ subviews: Subviews) -> (CGSize, [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width.isFinite ? max(0, width) : nil, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += height + 6; height = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + 6
            height = max(height, size.height)
            widest = max(widest, x - 6)
        }
        return (CGSize(width: widest, height: y + height), points)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(proposal.width ?? .infinity, subviews).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrangement(bounds.width, subviews).1.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: max(0, bounds.width - point.x), height: nil))
        }
    }
}

private struct ZeSubAgentToolHistory: View {
    let record: ZeSubAgentRecord

    var body: some View {
        let calls = (record.steps ?? []).filter { $0.state != "info" && $0.icon != "brain.head.profile" }
        if !calls.isEmpty {
            ZeSubAgentSection(title: "工具调用", icon: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 10) {
                    let grouped = Dictionary(grouping: calls, by: \.icon)
                    if grouped.count > 1 {
                        ZeSubAgentChipLayout {
                            ForEach(grouped.keys.sorted(), id: \.self) { icon in
                                Label("\(grouped[icon]?.count ?? 0)", systemImage: icon)
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                            }
                        }
                    }
                    ForEach(Array(calls.suffix(8).reversed())) { step in
                        ZeSubAgentToolHistoryRow(step: step)
                    }
                }
            }
        }
    }
}

private struct ZeSubAgentToolHistoryRow: View {
    let step: ZeSubAgentStep
    private var glyph: String {
        switch step.state {
        case "success": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "cancelled": return "minus.circle.fill"
        default: return "clock"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: glyph).font(.system(size: 11))
                .foregroundStyle(step.state == "failed" ? Color.red : step.state == "success" ? Color.green : ZeSubAgentTheme.purple)
            Image(systemName: step.icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(step.title).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let duration = step.duration {
                Text(String(format: "%.1fs", duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ZeSubAgentImagePreview: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZeSubAgentSection(title: "最新截图", icon: "photo") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("子代理最新截图")
                }
            }
        }
        .task(id: path) {
            image = nil
            let loaded = await ThumbnailCache.shared.thumbnail(for: path, maxSize: 1200)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct ZeSubAgentTranscriptScrollStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) { content.presentationContentInteraction(.scrolls) }
        else { content }
    }
}

struct ZeSubAgentTranscriptPage: View {
    let recordId: String
    @Environment(\.dismiss) private var dismiss
    @State private var child: AIChatViewModel?
    @State private var loading = true
    @ObservedObject private var coordinator = ZeSubAgentCoordinator.shared

    var body: some View {
        NavigationStack {
            ZStack {
                if let child {
                    ZeSubAgentTranscriptContent(recordId: recordId, child: child)
                        .environmentObject(child)
                        .environment(\.chatSessionId, child.sessionId)
                } else if loading {
                    ProgressView()
                } else {
                    Text("暂未找到子代理对话记录").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(coordinator.record(id: recordId)?.shortPrompt ?? String(localized: "子代理对话"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    if let record = coordinator.record(id: recordId) {
                        VStack(spacing: 3) {
                            Text(record.shortPrompt).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text("\(record.status.displayName) · \(ZeSubAgentPresentation.elapsed(record))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task {
            child = await ZeSubAgentCoordinator.shared.transcriptViewModel(id: recordId)
            loading = false
        }
    }
}

private struct ZeSubAgentTranscriptContent: View {
    let recordId: String
    @ObservedObject var child: AIChatViewModel
    @State private var confirmStop = false
    var body: some View {
        GeometryReader { geometry in
            CollectionViewMessageListV3(vm: child, inputFocused: false,
                                        maxContentWidth: geometry.size.width, floatingBarHeight: 0, inputBarHeight: 0,
                                        scrollMemoryKey: child.sessionId)
        }
        .toolbar {
            if child.isProcessing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("停止任务", role: .destructive) { confirmStop = true }
                }
            }
        }
        .confirmationDialog("停止这个子代理？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停止任务", role: .destructive) { ZeSubAgentCoordinator.shared.cancelRunGroup(id: recordId) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("同一轮创建的子代理也会停止，已完成的工作和工具记录会保留。")
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
                        ZeSubAgentCompactCard(record: record, open: { selectedRecordId = record.id },
                                              stop: { coordinator.cancelRunGroup(id: record.id) },
                                              resume: { _ = coordinator.resume(id: record.id) })
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
