"""Static checks for model-created scheduled task integration and the small jelly glyph."""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def source(p):return (ROOT/p).read_text(encoding='utf-8-sig')
checks=0
def check(v,n):
 global checks
 assert v,n;checks+=1;print('PASS:',n)
tool=source('Agent/Chat/AIChatViewModel+ScheduledTaskTools.swift')
defs=source('Agent/Chat/AIChatViewModel+ToolDefinitions.swift')
handler=source('Agent/Chat/AIChatViewModel+ConcurrentTools.swift')
store=source('Agent/Background/ScheduledTaskStore.swift')
view=source('Views/Settings/ScheduledTasksView.swift')
anim=source('Views/Chat/AssistantBlockView.swift')
project=source('Ze.xcodeproj/project.pbxproj')
check('scheduledTaskAgentToolDefinitions()' in defs and 'scheduled_task_create' in tool,'model sees create tool')
check(all(x in tool for x in ['scheduled_task_list','scheduled_task_set_enabled','scheduled_task_delete']),'model sees task lifecycle tools')
check('case "scheduled_task_create", "scheduled_task_list", "scheduled_task_set_enabled", "scheduled_task_delete"' in handler,'tool dispatcher handles all scheduler tools')
check('try store.save(task)' in tool and 'task.modelEntryId = entry.id' in tool,'creation uses current/configured model and durable scheduler store')
check('task.sessionId = task.runMode == .currentConversation ? sessionId : nil' in tool,'tool respects current/new conversation mode')
check('parseDate(arguments["scheduled_at"] as? String)' in tool and 'ScheduledTaskRepeat(rawValue' in tool,'tool parses repeat and one-time scheduling inputs')
check('try store.setEnabled' in tool and 'try store.delete(id: id)' in tool,'model can disable or delete its own task by returned UUID')
check('Settings > Scheduled Tasks' in tool and '当前没有定时任务' in tool,'tool responses guide Chinese UI')
check(project.count('/* AIChatViewModel+ScheduledTaskTools.swift in Sources */')==2 and 'path = "Agent/Chat/AIChatViewModel+ScheduledTaskTools.swift"' in project,'new tool file is in app source membership')
check('TimelineView(.animation(minimumInterval: 1.0 / 60.0' in anim,'glyph uses a 60fps timeline')
check('private let size: CGFloat = 12' in anim and 'private let holdDuration: TimeInterval = 0.25' in anim and 'rotationDegrees' in anim,'glyph stays small, pauses 0.25s, and rotates only during morphs')
check('Color.cyan' in anim and 'purpleGradient' in anim and 'corner = size * (0.5 - 0.25 * morph)' in anim and 'if elapsed < holdDuration' in anim and '.strokeBorder' in anim,'pale-blue circle and paused light-purple rounded-square jelly transition')
check('private struct JellyThinkingGlyph' in anim and 'HStack(spacing: 4)' in anim,'glyph is placed before Chinese thinking label')
check('scripts/verify-agent-scheduled-tools.py' in source('.github/workflows/build.yml'),'CI runs integration gate')
print(f'Structural checks passed: {checks}')
