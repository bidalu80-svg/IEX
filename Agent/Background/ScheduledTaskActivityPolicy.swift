import Foundation

/// A scheduler lease is separate from a running chat session. Never put its ID
/// into SessionActivityTracker: that tracker also owns conversation busy locks.
struct ScheduledTaskActivityDescriptor: Equatable {
    let taskID: UUID
    let title: String
    let nextRunAt: Date?
    let isRunning: Bool
    let executionSessionID: String?

    var activityID: String { "scheduled-task:" + taskID.uuidString }
}

enum ScheduledTaskActivityPolicy {
    static func descriptors(tasks: [ScheduledTaskDefinition], runs: [ScheduledTaskRun],
                            suppressedTaskIDs: Set<UUID> = [], now: Date) -> [ScheduledTaskActivityDescriptor] {
        tasks.compactMap { task in
            guard !suppressedTaskIDs.contains(task.id) else { return nil }
            let running = runs.first { $0.taskId == task.id && $0.status == .running }
            let waiting = task.isEnabled && task.nextRunAt != nil && !task.isExpired(at: now)
            // claim() disables one-shot definitions before sending. Its active
            // occurrence still owns a lease until it finishes (or is stopped).
            guard waiting || running != nil else { return nil }
            return ScheduledTaskActivityDescriptor(taskID: task.id, title: task.displayName,
                nextRunAt: waiting ? task.nextRunAt : nil, isRunning: running != nil,
                executionSessionID: running?.sessionId)
        }
    }

    /// Once execution has its own ordinary chat live row, don't show a second
    /// scheduler row for the same operation. The scheduler still owns its lease.
    static func visibleDescriptors(_ descriptors: [ScheduledTaskActivityDescriptor],
                                   activeChatIDs: Set<String>) -> [ScheduledTaskActivityDescriptor] {
        descriptors.filter { descriptor in
            guard descriptor.isRunning, let sid = descriptor.executionSessionID else { return true }
            return !activeChatIDs.contains(sid)
        }
    }

    static func activeIDs(chatIDs: Set<String>, descriptors: [ScheduledTaskActivityDescriptor]) -> Set<String> {
        chatIDs.union(descriptors.map(\.activityID))
    }
}

/// Generation/ownership checks used after ActivityKit suspension points. Keep
/// this pure so enable/disable and superseded-renewal races are regression tested.
enum LiveActivityOwnershipPolicy {
    static func canResume(capturedGeneration: UUID, currentGeneration: UUID,
                          hasCurrentActivity: Bool, userEnabled: Bool,
                          hasOwners: Bool, audioLoaded: Bool) -> Bool {
        capturedGeneration == currentGeneration && !hasCurrentActivity && userEnabled && (hasOwners || audioLoaded)
    }
}
