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
    static func elapsed(_ record: ZeSubAgentRecord, now: Date? = nil) -> String {
        let end = record.finishedAt ?? (record.status.isActive ? now : nil) ?? record.updatedAt
        let seconds = max(0, Int(end.timeIntervalSince(record.startedAt ?? record.createdAt)))
        if record.status.isActive { return "\(seconds / 60):\(String(format: "%02d", seconds % 60))" }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
    static func color(_ status: ZeSubAgentStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled, .interrupted, .timedOut: return .yellow
        default: return ZeSubAgentTheme.purple
        }
    }
    static func status(_ record: ZeSubAgentRecord) -> String {
        record.status == .completed ? String(localized: "完成") : record.status.displayName
    }
    static func model(_ record: ZeSubAgentRecord) -> String? {
        record.requestModelName ?? record.requestModelId
    }
    static func compact(_ tokens: Int) -> String {
        if tokens < 1_000 { return String(tokens) }
        if tokens < 10_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        if tokens < 1_000_000 { return "\(Int((Double(tokens) / 1_000).rounded()))k" }
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 0 { return "0s" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let value = Int(seconds.rounded())
        if value < 60 { return "\(value)s" }
        if value < 3600 { return "\(value / 60)m \(String(format: "%02d", value % 60))s" }
        return "\(value / 3600)h \((value % 3600) / 60)m"
    }
    static func tool(_ step: ZeSubAgentStep) -> String {
        guard let name = step.toolName else { return step.title }
        let spaced = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }
    static func icon(_ step: ZeSubAgentStep) -> String {
        switch step.toolName {
        case "shell_execute": return "terminal"
        case "file_read", "read_file": return "doc.text"
        case "file_write", "write_file": return "doc.text.fill"
        case "file_edit", "edit_file": return "square.and.pencil"
        case "browser_use": return "globe"
        case "read_image": return "photo"
        default: return step.icon
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

/// Only the small clock label ticks; tool history and Markdown are not rebuilt each second.
struct ZeSubAgentElapsedLabel: View {
    let record: ZeSubAgentRecord
    var prefix: String = ""
    var body: some View {
        if record.status.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(prefix + ZeSubAgentPresentation.elapsed(record, now: context.date))
            }
        } else { Text(prefix + ZeSubAgentPresentation.elapsed(record)) }
    }
}

/// Matches the compact arc glyph while keeping rotation in Core Animation.
private struct ZeSubAgentSpinner: View {
    let size: CGFloat
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZeSubAgentSpinnerSurface(lineWidth: lineWidth, animates: !reduceMotion && scenePhase == .active)
            .frame(width: size, height: size)
            .accessibilityLabel("运行中")
    }
}
private struct ZeSubAgentSpinnerSurface: UIViewRepresentable {
    let lineWidth: CGFloat
    let animates: Bool
    func makeUIView(context: Context) -> ZeSubAgentSpinnerLayerView { ZeSubAgentSpinnerLayerView() }
    func updateUIView(_ view: ZeSubAgentSpinnerLayerView, context: Context) {
        view.arc.lineWidth = lineWidth
        view.animates = animates
        view.setNeedsLayout()
        view.updateAnimation()
    }
}
private final class ZeSubAgentSpinnerLayerView: UIView {
    let arc = CAShapeLayer()
    var animates = true
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        arc.fillColor = UIColor.clear.cgColor
        arc.lineCap = .round
        arc.strokeEnd = 0.72
        layer.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.path = UIBezierPath(ovalIn: bounds).cgPath
        arc.strokeColor = (traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 0.64, green: 0.52, blue: 1, alpha: 1)
            : UIColor(red: 0.45, green: 0.30, blue: 0.93, alpha: 1)).cgColor
        CATransaction.commit()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); updateAnimation() }
    func updateAnimation() {
        guard animates, window != nil else { arc.removeAnimation(forKey: "spinnerRotation"); return }
        guard arc.animation(forKey: "spinnerRotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 1
        rotation.repeatCount = .infinity
        arc.add(rotation, forKey: "spinnerRotation")
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
                    ZeSubAgentSpinner(size: 15, lineWidth: 2)
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
                            Image(systemName: ZeSubAgentPresentation.icon(step)).font(.system(size: 10, weight: .semibold))
                            Text(ZeSubAgentPresentation.tool(step)).font(.system(size: 11, weight: .semibold))
                        }.foregroundStyle(ZeSubAgentTheme.purple).lineLimit(1).fixedSize()
                        Text(step.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(ZeSubAgentPresentation.status(record)).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ZeSubAgentPresentation.color(record.status)).fixedSize()
                    }
                    if !record.status.isActive, let model = ZeSubAgentPresentation.model(record) {
                        Text(model).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                    }
                    ZeSubAgentElapsedLabel(record: record).font(.system(size: 11, design: .monospaced))
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
                Text("代理任务").font(.system(size: 6, weight: .bold))
            }.foregroundStyle(ZeSubAgentTheme.purple)
            Text(record.shortPrompt).font(.system(size: 7, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(ZeSubAgentPresentation.model(record) == nil ? 2 : 1)
            Spacer(minLength: 0)
            if record.status.isActive {
                if let step = record.steps?.last(where: { $0.state == "running" }) {
                    HStack(spacing: 2) {
                        Image(systemName: ZeSubAgentPresentation.icon(step)).font(.system(size: 6, weight: .bold))
                        Text(ZeSubAgentPresentation.tool(step)).font(.system(size: 6, weight: .semibold))
                    }.foregroundStyle(ZeSubAgentTheme.purple).lineLimit(1)
                    ZeSubAgentElapsedLabel(record: record, prefix: step.title.isEmpty ? "" : step.title + " · ")
                        .font(.system(size: 6)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                } else {
                    Text(ZeSubAgentPresentation.status(record)).font(.system(size: 6)).foregroundStyle(.white.opacity(0.7))
                }
            } else {
                Text("\(ZeSubAgentPresentation.status(record)) · \(ZeSubAgentPresentation.elapsed(record))")
                    .font(.system(size: 6, weight: .semibold)).foregroundStyle(ZeSubAgentPresentation.color(record.status)).lineLimit(1)
            }
            if let model = ZeSubAgentPresentation.model(record) {
                Text(model).font(.system(size: 6, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).truncationMode(.middle)
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
    @FocusState private var focused: Bool
    @State private var confirmStop = false

    var body: some View {
        Group {
            if let record = coordinator.record(id: recordId) {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ZeSubAgentSection(title: LocalizedStringKey(record.shortPrompt), icon: ZeSubAgentTheme.iconName,
                                              status: ZeSubAgentPresentation.status(record), iconTint: ZeSubAgentTheme.purple,
                                              statusTint: ZeSubAgentPresentation.color(record.status), clockRecord: record) {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let requested = record.requestedModel { metadata("配置模型", requested) }
                                    else if let reference = record.modelEntryReference,
                                            let entry = ProviderConfigStore.shared.entry(for: reference) {
                                        metadata("配置模型", entry.model.displayName)
                                    }
                                    if record.modelPinUnavailable == true {
                                        metadata("模型回退", "指定配置已失效，改用当前会话模型")
                                    }
                                    if let model = record.requestModelId {
                                        metadata("实际模型", [record.requestProviderName, record.requestModelName ?? model].compactMap { $0 }.joined(separator: " · "))
                                    }
                                    if let start = record.startedAt { metadata("开始时间", Self.clockFormatter.string(from: start), monospaced: true) }
                                    if let finish = record.finishedAt { metadata("结束时间", Self.clockFormatter.string(from: finish), monospaced: true) }
                                    if let budget = record.budgetMinutes { metadata("时间上限", "\(budget) 分钟") }
                                    if let delivery = record.deliveryState { metadata("送达方式", deliveryLabel(delivery)) }
                                    if let progress = record.progressReport, progress != "none" {
                                        metadata("进度汇报", progress == "frequent" ? "有变化时每 15 秒" : "每 60 秒")
                                    }
                                }
                            }
                            ZeSubAgentRunStats(record: record).padding(.horizontal, 2)
                            ZeSubAgentSection(title: "任务", icon: "text.alignleft") {
                                ZeSubAgentCollapsibleText(text: record.prompt)
                            }
                            if record.status.isActive, let step = record.steps?.last(where: { $0.state == "running" }) {
                                ZeSubAgentSection(title: "当前工具", icon: step.icon) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label(ZeSubAgentPresentation.tool(step), systemImage: ZeSubAgentPresentation.icon(step))
                                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(ZeSubAgentTheme.purple)
                                        if !step.title.isEmpty {
                                            Text(step.title).font(.system(size: 13)).foregroundStyle(.primary).textSelection(.enabled)
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
                                    Text(error).font(.system(size: 13, design: .monospaced)).foregroundStyle(.primary)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if !record.output.isEmpty || !record.status.isActive {
                                ZeSubAgentSection(title: record.status.isActive ? "最新输出" : "结果",
                                                  icon: record.status.isActive ? "text.bubble" : record.output.isEmpty ? "exclamationmark.triangle" : "checkmark.seal") {
                                    if record.status.isActive {
                                        ZeSubAgentCollapsibleText(text: record.output)
                                    } else if record.output.isEmpty {
                                        Text("代理任务没有返回交付内容").font(.system(size: 13)).foregroundStyle(.secondary)
                                    } else {
                                        SelectableMarkdownView(markdown: record.output)
                                    }
                                }
                            }
                            if record.status.isActive { actions(record) }
                        }

            } else {
                Label("子代理不存在", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("停止这个子代理？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停止任务", role: .destructive) { coordinator.cancelRunGroup(id: recordId) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("同一轮启动的其他子代理也会一并停止，已完成的工作会保留。")
        }
    }

    private func deliveryLabel(_ value: String) -> String {
        switch value {
        case "delivered": return "结果已作为新消息发送"
        case "pending": return "结果将作为新消息送达"
        case "inline": return "对话等待结果返回"
        case "suppressed": return "已停止回传"
        default: return "父会话暂不可用"
        }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func metadata(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12))
    }

    private func actions(_ record: ZeSubAgentRecord) -> some View {
        ZeSubAgentSection(title: "操作", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("发送指令调整方向…", text: $followUp, axis: .vertical)
                        .font(.system(size: 13))
                        .lineLimit(1...4)
                        .focused($focused)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    Button {
                        guard coordinator.sendInput(id: recordId, message: followUp) != nil else { return }
                        followUp = ""
                        sent = true
                        focused = false
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color(uiColor: .tertiaryLabel) : ZeSubAgentTheme.purple)
                    }
                    .buttonStyle(.plain)
                    .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || record.status == .cancelling)
                    .accessibilityLabel("发送补充任务")
                }
                if record.status.isActive {
                    Text((record.pendingInputCount ?? 0) > 0
                         ? "已发送，子代理会在下一轮读取。"
                         : sent ? "已发送，子代理会在下一轮读取。" : "子代理会在下一轮读取；正在执行的工具调用不会被打断。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) { confirmStop = true } label: {
                        Label("停止代理任务", systemImage: "stop.circle.fill")
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
    var iconTint: Color = Color(uiColor: .secondaryLabel)
    var statusTint: Color = ZeSubAgentTheme.purple
    var clockRecord: ZeSubAgentRecord? = nil
    @ViewBuilder let content: () -> Content
    private static var barBg: Color { Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.92, alpha: 1) }) }
    private static var cardBg: Color { Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.10, alpha: 1) : UIColor(white: 0.94, alpha: 1) }) }
    private static var stroke: Color { Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.25, alpha: 1) : UIColor(white: 0.82, alpha: 1) }) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(iconTint)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 6)
                if let clockRecord, clockRecord.status.isActive { ZeSubAgentSpinner(size: 11, lineWidth: 1.6) }
                if let status { Text(status).font(.system(size: 11, weight: .semibold)).foregroundStyle(statusTint) }
                if let clockRecord {
                    ZeSubAgentElapsedLabel(record: clockRecord).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
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
            if counts.total > 0 { chip("wrench.and.screwdriver", "\(counts.total) 次工具调用") }
            if counts.success > 0 {
                chip("checkmark.circle.fill", "\(counts.success)", tint: .green)
            }
            if counts.failed > 0 {
                chip("xmark.circle.fill", "\(counts.failed)", tint: .red)
            }
            if let turns = record.turnCount, turns > 0 { chip("arrow.triangle.2.circlepath", "\(turns) 轮") }
            if record.inputTokens > 0 || record.outputTokens > 0 {
                chip("arrow.up.arrow.down", "\(ZeSubAgentPresentation.compact(record.inputTokens)) / \(ZeSubAgentPresentation.compact(record.outputTokens))")
            }
            if record.status.isActive, let budget = record.budgetMinutes {
                if let start = record.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, budget * 60 - Int(context.date.timeIntervalSince(start)))
                        chip("timer", remaining >= 60 ? "剩余 \(remaining / 60) 分钟" : "剩余 \(remaining) 秒",
                             tint: remaining < 60 ? .orange : .secondary)
                    }
                } else { chip("timer", "\(budget) 分钟预算") }
            }
        }
    }

    private func chip(_ icon: String, _ text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.primary).lineLimit(1)
        }
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

    private func orderedToolNames(_ calls: [ZeSubAgentStep], grouped: [String: [ZeSubAgentStep]]) -> [String] {
        var order: [String] = []
        for call in calls {
            let name = call.toolName ?? call.icon
            if !order.contains(name) { order.append(name) }
        }
        return order.enumerated().sorted {
            let left = grouped[$0.element]?.count ?? 0
            let right = grouped[$1.element]?.count ?? 0
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }

    var body: some View {
        let calls = (record.steps ?? []).filter { $0.state != "info" && $0.icon != "brain.head.profile" }
        if !calls.isEmpty {
            ZeSubAgentSection(title: "最近的工具调用", icon: "list.bullet.rectangle", status: calls.count > 8 ? "最近 8 条，共 \(calls.count) 条" : nil) {
                VStack(alignment: .leading, spacing: 10) {
                    let grouped = Dictionary(grouping: calls, by: { $0.toolName ?? $0.icon })
                    if grouped.count > 1 {
                        ZeSubAgentChipLayout {
                            ForEach(orderedToolNames(calls, grouped: grouped), id: \.self) { name in
                                if let sample = grouped[name]?.first {
                                    HStack(spacing: 4) {
                                        Image(systemName: ZeSubAgentPresentation.icon(sample)).font(.system(size: 9, weight: .semibold))
                                        Text("\(ZeSubAgentPresentation.tool(sample)) ×\(grouped[name]?.count ?? 0)")
                                            .font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    }
                                    .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().stroke(Color(uiColor: .separator), lineWidth: 0.5))
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(calls.suffix(8).reversed())) { step in
                            ZeSubAgentToolHistoryRow(step: step)
                        }
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
            Group {
                if step.state == "running" { ZeSubAgentSpinner(size: 11, lineWidth: 1.6) }
                else {
                    Image(systemName: glyph).font(.system(size: 12))
                        .foregroundStyle(step.state == "failed" ? Color.red : step.state == "success" ? Color.green : Color(uiColor: .tertiaryLabel))
                }
            }.frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: ZeSubAgentPresentation.icon(step)).font(.system(size: 10, weight: .semibold))
                    Text(ZeSubAgentPresentation.tool(step)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }.foregroundStyle(step.state == "running" ? ZeSubAgentTheme.purple : Color(uiColor: .label))
                if !step.title.isEmpty {
                    Text(step.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
            Spacer(minLength: 6)
            if let duration = step.duration {
                Text(ZeSubAgentPresentation.duration(duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }.accessibilityElement(children: .combine)
    }
}

private struct ZeSubAgentImagePreview: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZeSubAgentSection(title: "最近截图", icon: "photo") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
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
                            ZeSubAgentElapsedLabel(record: record, prefix: record.status.displayName + " · ")
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
            Text("同一轮启动的其他子代理也会一并停止，已完成的工作会保留。")
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
