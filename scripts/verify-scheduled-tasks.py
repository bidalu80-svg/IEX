"""Cross-platform structural gate; not a substitute for the CI Swift compiler."""
from pathlib import Path
import json
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
checks = 0

def check(condition, name):
    global checks
    assert condition, name
    checks += 1
    print("PASS:", name)

def source(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")

catalog = json.loads(source("Localizable.xcstrings"))["strings"]
paths = ["Agent/Background/ScheduledTaskModels.swift", "Agent/Background/ScheduledTaskStore.swift", "Views/Settings/ScheduledTasksView.swift"]
keys = set()
for path in paths:
    text = source(path)
    for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', text):
        if not re.search(r"[\u4e00-\u9fff]", literal):
            continue
        key = re.sub(r"\\\((?:[^()]|\([^()]*\))*\)",
                     lambda match: "%lld" if match.group() == r"\(task.monthDay)" or literal == r"\(day)日" else "%@", literal)
        keys.add(key)
        translated = catalog.get(key, {}).get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
        assert translated.get("state") == "translated" and translated.get("value"), (path, key)
        assert sorted(re.findall(r"%(?:@|lld)", key)) == sorted(re.findall(r"%(?:@|lld)", translated["value"])), key
check(len(keys) >= 100, f"all {len(keys)} Chinese UI/runtime keys translated with matching placeholders")

plist = plistlib.loads((ROOT / "Info.plist").read_bytes())
check("com.ze.app.scheduled-tasks" in plist["BGTaskSchedulerPermittedIdentifiers"], "background identifier declared")
check("processing" in plist["UIBackgroundModes"], "processing background mode declared")
project = source("Ze.xcodeproj/project.pbxproj")
versions = re.findall(r"MARKETING_VERSION = ([^;]+);", project)
check(len(versions) == 12 and set(versions) == {"1.0.9"}, "all 12 app/extension/test configurations use v1.0.9")
check(set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", project)) == {"4"}, "all build numbers are 4")
for path in paths:
    name = Path(path).name
    check(project.count(f"/* {name} in Sources */") == 2 and f'path = "{path}";' in project, f"Xcode source membership: {name}")
workflow = source(".github/workflows/build.yml")
check('= "1.0.9"' in workflow and '= "1.0.8"' not in workflow, "IPA version audit upgraded")
check("scripts/ScheduledTaskTests.swift" in workflow and "scheduled-task-tests.log" in workflow, "Swift tests and uploaded evidence wired into CI")
check("ScheduledTaskStore.shared.registerBackgroundTask()" in source("AppDelegate.swift"), "register background task during launch")
check("ScheduledTaskStore.shared.start()" in source("ZeApp.swift"), "scheduler starts with application")
check('Label("定时任务", systemImage: "clock")' in source("Views/ContentView.swift"), "settings uses native clock symbol")
persistence = source("Agent/Chat/AIChatViewModel+Persistence.swift")
check("func loadSession(activate: Bool = true)" in persistence and "func ensureSessionReturningId(activate: Bool = true)" in persistence, "background sessions do not steal foreground selection")
store = source(paths[1])
check(store.index("snapshot.claim(taskID:") < store.index("executor.send()"), "claim precedes send")
check("executor.ensureSessionReturningId(activate: false)" in store and "cached.loadSession(activate: false)" in store, "scheduler uses background-safe session APIs")
check("vm.editingMessageIndex == nil" in store and "vm.attachments.isEmpty" in store, "draft/edit/attachment guards present")
check("scheduled-task-tests" in workflow and "swiftc -frontend -parse" in workflow, "real Swift compiler gate configured")
check(store.index("guard isConversationIdle(cached)") < store.index("await cached.loadSession"), "draft guard precedes background reload")
check("backgroundLoadStillIdle()" in persistence, "background reload rechecks after suspension")
check("ScheduledTaskExecutionReceipt" in store and "receipt.result == nil" in store, "per-turn receipt owns cancellation and completion")
check("needsFinalizationRetry = true" in store, "terminal persistence failures retry without replay")
chat = source("Agent/Chat/AIChatViewModel.swift")
check("scheduledCompletion?()\n            await self.drainQueuedPrompts()" in chat, "scheduled turn completes before user queue drains")
check("ScheduledTaskReceiptTests.swift" in workflow, "real Combine cancellation race tests wired into CI")
print(f"Structural checks passed: {checks}")
