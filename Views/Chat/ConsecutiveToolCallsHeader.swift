import Combine
import SwiftUI

extension ConsecutiveToolCallsPolicy {
    /// Shared production mapping: UIKit integrations should reuse this rather
    /// than infer errors from content, or count cancellation as failure.
    static func callState(for status: ToolBlockStatus?) -> CallState {
        switch status {
        case .some(.failed):
            return .failed
        case .none, .some(.streaming), .some(.running):
            return .running
        case .some(.success), .some(.cancelled):
            return .finished
        }
    }
}

/// Observes status values, not objectWillChange + a read of the old property.
/// Main-queue delivery also keeps @Published changes outside SwiftUI rendering.
@MainActor
private final class ConsecutiveToolCallsObserver: ObservableObject {
    @Published private(set) var summary: ConsecutiveToolCallsPolicy.Summary

    @Published private var timings: [ConsecutiveToolCallsPolicy.Timing] = []
    private var observedBlocks: [AssistantBlock] = []
    private var blockIDs: [UUID] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = UUID()

    init(blocks: [AssistantBlock]) {
        summary = ConsecutiveToolCallsPolicy.summary(states: [])
        bind(blocks)
    }

    func bind(_ blocks: [AssistantBlock]) {
        let ids = blocks.map(\.id)
        guard ids != blockIDs else { return }

        // Preserve observed completion times when a streamed group appends a
        // new block. Rebinding must not turn a previously known time unknown.
        let previousTimings = Dictionary(zip(blockIDs, timings), uniquingKeysWith: { _, new in new })
        generation = UUID()
        let currentGeneration = generation
        subscriptions.removeAll()
        observedBlocks = blocks
        blockIDs = ids
        timings = blocks.map { block in
            let state = ConsecutiveToolCallsPolicy.callState(for: block.toolStatus)
            let previous = previousTimings[block.id]
            return ConsecutiveToolCallsPolicy.Timing(
                state: state,
                startedAt: block.toolStartTime?.timeIntervalSinceReferenceDate,
                duration: block.toolDuration,
                finishedAt: state == .running ? nil : previous?.finishedAt
            )
        }
        publishSummary()

        for (index, block) in blocks.enumerated() {
            block.$toolStatus
                .map { (state: ConsecutiveToolCallsPolicy.callState(for: $0),
                        emittedAt: Date().timeIntervalSinceReferenceDate) }
                .removeDuplicates { $0.state == $1.state }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] event in
                    guard let self, self.generation == currentGeneration else { return }
                    var timing = self.timings[index]
                    guard timing.state != event.state else { return }
                    // @Published emits in willSet: use the emitted value ONLY.
                    // Capture the end at emission, not after main-queue delivery.
                    if timing.state == .running && event.state != .running {
                        timing.finishedAt = event.emittedAt
                    } else if event.state == .running {
                        timing.finishedAt = nil
                    }
                    timing.state = event.state
                    self.timings[index] = timing
                    self.publishSummary()
                }
                .store(in: &subscriptions)

            block.$toolDuration
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] duration in
                    guard let self, self.generation == currentGeneration,
                          self.timings[index].duration != duration else { return }
                    // Durations can arrive before OR after the terminal status.
                    // Never read block.toolDuration inside its willSet publisher.
                    self.timings[index].duration = duration
                }
                .store(in: &subscriptions)
        }
    }

    func durationSummary(at date: Date) -> ConsecutiveToolCallsPolicy.DurationSummary {
        let samples = zip(observedBlocks, timings).map { block, snapshot in
            var sample = snapshot
            // This timestamp is not @Published. Reading it on each timer tick
            // also picks up a start assigned after the header was first bound.
            sample.startedAt = block.toolStartTime?.timeIntervalSinceReferenceDate
            return sample
        }
        return ConsecutiveToolCallsPolicy.durationSummary(
            timings: samples, now: date.timeIntervalSinceReferenceDate
        )
    }

    private func publishSummary() {
        let next = ConsecutiveToolCallsPolicy.summary(states: timings.map(\.state))
        if summary != next { summary = next }
    }
}

private struct ConsecutiveToolCallsMenuKey: Equatable {
    let firstID: UUID?
    let hasCopyText: Bool
    let hasCopyScreenshot: Bool
}

/// The Equatable gate intentionally ignores changing closure identities. Keep
/// actions behind a stable reference so copying uses the latest appended group.
@MainActor
private final class ConsecutiveToolCallsMenuActions: ObservableObject {
    var copyText: (() -> Void)?
    var copyScreenshot: (() -> Void)?
}

/// Header only. The caller owns expansion and renders the original block views.
/// Supply one consecutive tool range from one message, without filtering blocks.
@MainActor
struct ConsecutiveToolCallsHeader: View {
    let blocks: [AssistantBlock]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onCopyScreenshot: (() -> Void)?
    let onCopyText: (() -> Void)?

    @StateObject private var observer: ConsecutiveToolCallsObserver
    @StateObject private var menuActions = ConsecutiveToolCallsMenuActions()

    init(
        blocks: [AssistantBlock],
        isExpanded: Bool,
        onToggle: @escaping () -> Void,
        onCopyScreenshot: (() -> Void)? = nil,
        onCopyText: (() -> Void)? = nil
    ) {
        self.blocks = blocks
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self.onCopyScreenshot = onCopyScreenshot
        self.onCopyText = onCopyText
        _observer = StateObject(wrappedValue: ConsecutiveToolCallsObserver(blocks: blocks))
    }

    private var blockIDs: [UUID] { blocks.map(\.id) }
    private var title: String { String(localized: "工具调用 \(observer.summary.total) 次") }
    private var failureTitle: String { String(localized: "报错 \(observer.summary.failed) 次") }
    private var expansionTitle: String {
        isExpanded ? String(localized: "已展开") : String(localized: "已折叠")
    }
    private var accessibilityState: String {
        if observer.summary.running > 0 {
            return [expansionTitle, String(localized: "执行中")].joined(separator: ", ")
        }
        return expansionTitle
    }

    var body: some View {
        let actions = currentMenuActions()
        return Button(action: onToggle) {
            // Timer updates are restricted to the label, never the context menu.
            TimelineView(.animation(minimumInterval: 1, paused: observer.summary.running == 0)) { context in
                headerLabel(at: context.date)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(accessibilityState))
        .accessibilityHint(Text(isExpanded
            ? String(localized: "轻点折叠工具调用")
            : String(localized: "轻点展开工具调用")))
        .contextMenu {
            EquatableMenuGate(key: ConsecutiveToolCallsMenuKey(
                firstID: blocks.first?.id,
                hasCopyText: onCopyText != nil,
                hasCopyScreenshot: onCopyScreenshot != nil
            )) {
                if onCopyText != nil {
                    Button { actions.copyText?() } label: {
                        Label(String(localized: "复制全部"), systemImage: "doc.on.doc")
                    }
                }
                if onCopyScreenshot != nil {
                    Button { actions.copyScreenshot?() } label: {
                        Label(String(localized: "复制截图"), systemImage: "photo.on.rectangle")
                    }
                }
            }
            .equatable()
        }
        .onAppear { observer.bind(blocks) }
        .onChange(of: blockIDs) { _ in observer.bind(blocks) }
    }

    private func currentMenuActions() -> ConsecutiveToolCallsMenuActions {
        // Non-published closure slots: synchronizing callbacks does not emit
        // objectWillChange or start another SwiftUI render / menu diff.
        menuActions.copyText = onCopyText
        menuActions.copyScreenshot = onCopyScreenshot
        return menuActions
    }

    private func durationTitle(at date: Date) -> String {
        let duration = observer.durationSummary(at: date)
        let seconds = duration.seconds.formatted(.number.precision(.fractionLength(1)))
        return duration.hasUnknownDuration
            ? String(localized: "累计至少 \(seconds) 秒")
            : String(localized: "累计 \(seconds) 秒")
    }

    private func headerLabel(at date: Date) -> some View {
        let duration = durationTitle(at: date)
        return HStack(spacing: 8) {
            // One row at ordinary sizes; adapt without truncation at large
            // Dynamic Type sizes or in a narrow chat column.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Text(title)
                    Text(failureTitle).foregroundStyle(.secondary)
                    Text(duration).monospacedDigit().foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Text(title)
                            Text(failureTitle).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                            Text(failureTitle).foregroundStyle(.secondary)
                        }
                    }
                    Text(duration).monospacedDigit().foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if observer.summary.running > 0 {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([title, failureTitle, duration].joined(separator: ", ")))
    }
}
