"""Source wiring regression gate. Complements (not replaces) Swift/physical UI tests."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[1]
checks = 0

def source(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")

def check(condition, name):
    global checks
    assert condition, name
    checks += 1
    print("PASS:", name)

v3 = source("Agent/MessageList/CollectionViewMessageListV3.swift")
models = source("Agent/Chat/ChatModels.swift")
settings = source("Views/ContentView.swift")
header = source("Views/Chat/ConsecutiveToolCallsHeader.swift")
fallback = source("Views/Chat/ChatMessageViews.swift")
tools = source("Views/Chat/AssistantBlockView.swift")
policy = source("Shared/ConsecutiveToolCallsPolicy.swift")
project = source("Ze.xcodeproj/project.pbxproj")
catalog = json.loads(source("Localizable.xcstrings"))["strings"]

check('Text("工具调用")' in settings and 'Text("折叠连续的工具调用")' in settings, "Chinese native settings section/toggle")
check('collapseConsecutiveToolCallsToggle' in settings and '.tint(.blue)' in settings, "accessible native toggle and blue tint")
check(all("ConsecutiveToolCallsPolicy.preferenceKey" in s for s in [settings, v3, fallback]), "same persisted preference across settings and both renderers")
check('case .text, .thinking, .info: return false' in models, "text/thinking/info are strict boundaries, including empty text")
check('ConsecutiveToolCallsPolicy.ranges(isTool: blocks.map' in models, "grouping projects every block without filtering source")
check('enabled: collapseConsecutiveToolCalls && !forceUncollapsedToolsForScreenshot' in v3, "screenshot always renders original blocks")
check('if first.isToolGroupExpanded' in v3 and 'segment.blocks.map { .assistantBlock' in v3, "expansion uses original tool cells")
check('@ObservedObject var message: ChatMessage' in v3 and 'tools(startingAt: firstBlock.id, in: message.blocks)' in v3, "collapsed header observes streaming membership without snapshot ID changes")
check('@Published var isToolGroupExpanded: Bool = false' in models, "per-group disclosure survives cell reuse")
check('newY - oldY' in v3 and 'caller: "tool-group-toggle"' in v3, "tap expansion restores header viewport anchor")
check('InlineConsecutiveToolCalls' in fallback and 'if firstBlock.isToolGroupExpanded { content() }' in fallback, "fallback renderer preserves original expanded children")
check('Button(action: onToggle)' in header and '.contextMenu' in header, "native tap/long-press separation")
check('highPriorityGesture' not in header and '.onLongPressGesture' not in header, "no competing custom gestures on group header")
check('onCopyScreenshot: bridge.onCopyScreenshot' in v3 and 'onCopyText:' in v3, "group menu routes text and screenshot callbacks")
check(tools.count('toolSnapshots: toolSnapshots, onCopyScreenshot: onCopyScreenshot, detailBlock: $detailBlock') == 7, "all seven tool capsule kinds forward screenshot callback")
check('Copy Tool Details' in tools and 'Re-run From Here' in tools and 'Button(action: onCopyScreenshot)' in tools, "tool long-press retains existing actions and screenshot")
check('hasCopyScreenshot: onCopyScreenshot != nil' in tools, "tool menu equatable key includes screenshot availability")

start = v3.index('func captureUncollapsedScrollingTurnScreenshot(')
start = v3.index('{', start)
original_body = v3[start:v3.index('\n        private func renderer(', start)]
check(hashlib.sha256(original_body.encode()).hexdigest() == 'f83289e196b277a0bea63a6e6cca29c80b6fd7a9efbb46fa440f7e552382a8e4', "original scrolling/stitching screenshot body byte-identical to baseline")
wrapper = v3[v3.index('func captureScrollingTurnScreenshot('):v3.index('private func captureUncollapsedScrollingTurnScreenshot(')]
check('defer {' in wrapper and 'forceUncollapsedToolsForScreenshot = false' in wrapper, "screenshot always restores grouping on every return")
check(all(x in wrapper for x in ['scrollMode = savedMode', 'clampAfterSessionLoad = savedClamp', 'savedOffset.y', 'screenshot-restore-tool-groups']), "screenshot restores viewport and scrolling state")
check('isToolGroupExpanded =' not in wrapper and 'UserDefaults' not in wrapper, "screenshot never changes user preference or disclosure state")
check('guard !forceUncollapsedToolsForScreenshot' in wrapper, "nested screenshot capture guarded")

for path in ['Shared/ConsecutiveToolCallsPolicy.swift', 'Views/Chat/ConsecutiveToolCallsHeader.swift']:
    name = Path(path).name
    check(project.count(f'/* {name} in Sources */') == 2 and f'path = "{path}";' in project, f'Xcode source membership: {name}')
check(set(re.findall(r'CURRENT_PROJECT_VERSION = ([^;]+);', project)) == {'5'}, "all target build numbers are 5")
keys = ['工具调用', '折叠连续的工具调用', '连续的工具调用会合并为一行显示。轻点即可查看每次调用。']
# Localized header strings use integer counts and formatted seconds strings.
for literal in re.findall(r'String\(localized: "((?:[^"\\]|\\.)*)"\)', header):
    key = re.sub(r'\\\([^)]*\)', lambda m: '%lld' if 'summary.' in m.group() else '%@', literal)
    keys.append(key)
for key in set(keys):
    unit = catalog.get(key, {}).get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {})
    assert unit.get('state') == 'translated' and unit.get('value'), key
    assert sorted(re.findall(r'%(?:@|lld)', key)) == sorted(re.findall(r'%(?:@|lld)', unit['value'])), key
check(True, f'all {len(set(keys))} new settings/header keys translated into simplified Chinese')
workflow = source('.github/workflows/build.yml')
check('scripts/ConsecutiveToolCallsTests.swift' in workflow and 'consecutive-tool-tests.log' in workflow, "real Swift policy tests and evidence wired into CI")
print(f'Structural checks passed: {checks}')
