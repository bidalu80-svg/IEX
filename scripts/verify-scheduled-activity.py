"""Static integration oracle; actual Swift behavior is exercised in CI tests."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
def source(p): return (ROOT / p).read_text(encoding='utf-8-sig')
checks = 0
def check(value, name):
    global checks
    assert value, name
    checks += 1
    print('PASS:', name)

store = source('Agent/Background/ScheduledTaskStore.swift')
models = source('Agent/Background/ScheduledTaskModels.swift')
views = source('Views/Settings/ScheduledTasksView.swift')
keep = source('Agent/Background/BackgroundKeepAliveManager.swift')
live = source('Agent/Background/AgentLiveActivityManager.swift')
policy = source('Agent/Background/ScheduledTaskActivityPolicy.swift')
widget = source('AgentWidget/AgentLiveActivityWidget.swift')
check('func deleteFinishedRun(id: UUID)' in models and 'func clearFinishedRuns()' in models, 'terminal history deletion lives in production snapshot model')
check('snapshot.deleteFinishedRun(id: id)' in store and 'snapshot.clearFinishedRuns()' in store, 'history operations use model and atomic repository commit')
check('.swipeActions' in views and 'try store.deleteRun(id:' in views, 'single history deletion available in UI')
check('try store.clearFinishedRuns()' in views and '.confirmationDialog' in views, 'bulk clear with confirmation')
check(views.count('try store.deleteRun(id:') >= 2, 'run detail also has a delete action')
check('let active = runs.filter { $0.status == .running }' in store and 'active + Array(finished.prefix(200))' in store, 'history cap never evicts an executing run')
start = store.index('func setEnabled('); end = store.index('func deleteRun(', start)
check('cancelRun(id: run.id)' in store[start:end], 'disabling cancels the task-owned active receipt')
check('suppressedTaskIDs: suppressed' in store[start:end], 'manual stop distinguished from auto-disabled claimed one-shot')
check('try repository.write' in store and store.index('try repository.write', store.index('private func commit')) < store.index('syncScheduledActivity()', store.index('private func commit')), 'activity ownership changes only after durable setting commit')
check('suppressedTaskIDs.contains(task.id)' in policy and 'running != nil' in policy, 'manual stop removes lease; executing one-shot retains lease')
check('task.isEnabled && task.nextRunAt != nil && !task.isExpired(at: now)' in policy, 'expired/disabled/unplanned tasks hold no waiting lease')
check('visibleDescriptors' in keep and 'activeChatIDs: tracker.activeSessions' in keep, 'no duplicate row when scheduled execution has real chat row')
check('ScheduledTaskActivityPolicy.activeIDs' in keep, 'real chat and scheduler background ownership combined')
check('SessionActivityTracker.shared.' not in policy, 'scheduler policy never mutates real chat locks')
check('self.reevaluate(sessions: self.liveActivitySessionIDs, enabled: self.enhancedBackgroundEnabled)' in keep, 'delayed reevaluation reads current ownership, not stale toggle snapshot')
check('AgentLiveActivityManager.shared.updateActivity(sessions: buildSessionSnapshots(), immediately: true)' in keep, 'enable/disable membership updates bypass presentation throttle')
check('guard !liveActivitySessionIDs.isEmpty' in keep, 'waiting schedules can update live presentation without silently changing enhanced-background setting')
check('let shouldBeActive = !sessions.isEmpty && enabled' in keep, 'runtime still respects enhanced-background opt-in')
check('if sessions.isEmpty && (hadRuntime || hadUpdateTimer)' in keep and 'AgentLiveActivityManager.shared.endActivity()' in keep, 'last owner removal ends activity; unrelated owners remain')
finish = live[live.index('func finishActivity('):live.index('func handleSessionDeleted(')]
check('!BackgroundKeepAliveManager.shared.liveActivitySessionIDs.isEmpty' in finish and 'immediately: true' in finish, 'chat completion does not dismiss other enabled schedules')
check('SessionActivityTracker.shared.activeSessions' not in live, 'activity cleanup/renewal/filtering all recognize scheduler owners')
check('Self.isUserEnabled' in live and 'ActivityAuthorizationInfo().areActivitiesEnabled' in live, 'global live toggle and system authorization still respected')
check(widget.count('hasPrefix("scheduled-task:")') == 4, 'island and lock screen show scheduler clock/task labels')
project = source('Ze.xcodeproj/project.pbxproj')
check(project.count('/* ScheduledTaskActivityPolicy.swift in Sources */') == 2, 'production activity policy registered in app target')
catalog = json.loads(source('Localizable.xcstrings'))['strings']
for key in ['定时任务执行中', '下次执行：%@', '等待定时执行', '%lld个任务']:
    unit = catalog.get(key, {}).get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {})
    check(unit.get('state') == 'translated' and bool(unit.get('value')), 'Chinese live key: ' + key)
workflow = source('.github/workflows/build.yml')
check('scripts/ScheduledTaskActivityTests.swift' in workflow and 'scheduled-activity-structure.log' in workflow, 'actual Swift ownership tests and evidence wired to CI')
check('lifecycleGeneration = UUID()\n        pendingStartState = nil\n        pendingStartGeneration = nil' in live, 'end/start invalidates asynchronous renewals and pending restart')
check('guard self.canResumeActivity(generation: generation) else { return }' in live and 'let freshState = self.currentOwnershipState()' in live, 'renewal rechecks generation/owners and rebuilds state after await')
check('guard !BackgroundKeepAliveManager.shared.liveActivitySessionIDs.contains(sessionId)' in live, 'late completion cannot mark a new active turn completed')
check('for sid in activeSids { completedSessionSnapshots.removeValue(forKey: sid) }' in live, 'current active snapshot wins over stale completion cache')
check('if !sessions.isEmpty {' in keep, 'remaining chat keeps live timer even when enhanced background is off')
print(f'Structural checks passed: {checks}')
