import Foundation

@main
struct ScheduledTaskActivityTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
        }
        let now = Date(timeIntervalSince1970: 1_791_360_000)
        var task = ScheduledTaskDefinition()
        task.name = "Example"
        task.nextRunAt = now.addingTimeInterval(3600)
        func descriptors(_ tasks: [ScheduledTaskDefinition], _ runs: [ScheduledTaskRun] = [],
                         suppressed: Set<UUID> = []) -> [ScheduledTaskActivityDescriptor] {
            ScheduledTaskActivityPolicy.descriptors(tasks: tasks, runs: runs, suppressedTaskIDs: suppressed, now: now)
        }
        let waiting = descriptors([task])
        check(waiting.count == 1 && !waiting[0].isRunning, "enabled schedule owns waiting lease")
        check(waiting[0].title == task.name && waiting[0].nextRunAt == task.nextRunAt, "waiting metadata")
        check(waiting[0].activityID.hasPrefix("scheduled-task:"), "independent namespace")
        check(descriptors([]).isEmpty, "no schedules")
        var disabled = task; disabled.isEnabled = false
        check(descriptors([disabled]).isEmpty, "disabled waiting task owns no lease")
        var expired = task; expired.endDate = now.addingTimeInterval(-172800)
        check(descriptors([expired]).isEmpty, "expired schedule removed")
        var missing = task; missing.nextRunAt = nil
        check(descriptors([missing]).isEmpty, "no next occurrence removed")
        var run = ScheduledTaskRun(taskId: task.id, taskName: task.name, scheduledAt: now, startedAt: now)
        run.sessionId = "real-chat"
        let active = descriptors([task], [run])
        check(active.count == 1 && active[0].isRunning, "running schedule owns lease")
        check(active[0].executionSessionID == "real-chat", "links executing chat for deduplication")
        check(ScheduledTaskActivityPolicy.visibleDescriptors(active, activeChatIDs: ["real-chat"]).isEmpty,
              "running chat is not displayed twice")
        check(ScheduledTaskActivityPolicy.visibleDescriptors(active, activeChatIDs: []).count == 1,
              "preflight/background run remains visible before chat publishes")
        check(ScheduledTaskActivityPolicy.visibleDescriptors(waiting, activeChatIDs: ["real-chat"]).count == 1,
              "waiting lease is not hidden by unrelated chat")
        var once = disabled; once.repeatRule = .once; once.nextRunAt = nil
        check(descriptors([once], [run]).count == 1, "claimed one-shot remains visible while running")
        check(descriptors([once], [run], suppressed: [once.id]).isEmpty, "explicit stop removes active one-shot lease")
        check(descriptors([task], [run], suppressed: [task.id]).isEmpty, "explicit stop removes repeating lease")
        check(descriptors([], [run]).isEmpty, "deleted definition cannot be resurrected by active record")
        for state in [ScheduledTaskRunStatus.succeeded, .failed, .interrupted] {
            run.status = state
            check(descriptors([once], [run]).isEmpty, "terminal one-shot ends lease")
            check(descriptors([task], [run]).first?.isRunning == false, "repeating run returns to waiting")
        }
        let union = ScheduledTaskActivityPolicy.activeIDs(chatIDs: ["manual"], descriptors: waiting)
        check(union == Set(["manual", waiting[0].activityID]), "chat and scheduler ownership coexist")
        check(ScheduledTaskActivityPolicy.activeIDs(chatIDs: ["manual"], descriptors: []) == ["manual"],
              "stopping scheduler retains manual chat")
        check(ScheduledTaskActivityPolicy.activeIDs(chatIDs: [], descriptors: waiting).count == 1,
              "chat completion retains scheduler")
        check(ScheduledTaskActivityPolicy.activeIDs(chatIDs: [], descriptors: []).isEmpty,
              "last owner release ends activity")
        var second = task; second.id = UUID()
        check(descriptors([task, second], suppressed: [task.id]).map(\.taskID) == [second.id],
              "disabling one schedule retains the other")
        check(descriptors([disabled], [], suppressed: [task.id]).isEmpty, "clearing history does not enable tasks")
        check(descriptors([task], []).count == 1, "clearing history does not disable waiting tasks")
        check(descriptors([task]).map(\.activityID) == waiting.map(\.activityID), "stable identity")
        let generation = UUID()
        let superseded = UUID()
        func resumes(_ captured: UUID? = nil, current: UUID? = nil,
                     existing: Bool = false, enabled: Bool = true,
                     owners: Bool = true, audio: Bool = false) -> Bool {
            LiveActivityOwnershipPolicy.canResume(capturedGeneration: captured ?? generation,
                currentGeneration: current ?? generation, hasCurrentActivity: existing,
                userEnabled: enabled, hasOwners: owners, audioLoaded: audio)
        }
        check(resumes(), "current renewal may resume")
        check(!resumes(current: superseded), "disable/end generation prevents late resurrection")
        check(!resumes(existing: true), "renewal cannot overwrite a new activity")
        check(!resumes(enabled: false), "global live toggle blocks pending restart")
        check(!resumes(owners: false), "last-owner removal blocks pending restart")
        check(resumes(owners: false, audio: true), "audio-only owner may recover")
        check(!resumes(current: superseded, owners: false, audio: true), "audio does not bypass invalidated generation")
        for hasCurrent in [false, true] {
            for enabled in [false, true] {
                for owners in [false, true] {
                    for audio in [false, true] {
                        for sameGeneration in [false, true] {
                            let actual = resumes(current: sameGeneration ? generation : superseded,
                                existing: hasCurrent, enabled: enabled, owners: owners, audio: audio)
                            check(actual == (sameGeneration && !hasCurrent && enabled && (owners || audio)),
                                  "exhaustive renewal ownership matrix")
                        }
                    }
                }
            }
        }
        print("PASS: \(count) scheduled activity ownership checks")
    }
}
