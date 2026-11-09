"""Static checks for model-created scheduled task integration and the reference dot-cube glyph."""
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
glyph=anim[anim.index('// MARK: - Typing Indicator'):anim.index('// MARK: - Thinking Level Sheet')]
check('TimelineView(.animation(minimumInterval: 1.0 / 60.0' in glyph and 'paused: reduceMotion || scenePhase != .active' in glyph,'glyph requests a 60Hz animation schedule and pauses for reduced motion or an inactive scene')
check('globalRotationDegrees(elapsed:' in glyph and 'loopStartFrameIndex' in glyph and 'frameIndex(elapsed:' in glyph,'local dot turns and continuous global rotation use independent time sampling')
check('Canvas {' in glyph and 'ThinkingCubeAtlas' in glyph and 'NSCache<NSString, CubeThinkingGlyphFrames>' in glyph and 'didReceiveMemoryWarningNotification' in glyph and 'spectrum' not in glyph,'bounded transparent dot atlas is drawn natively with a purgeable shared cache')
check('private struct CubeThinkingGlyph' in anim and 'HStack(spacing: 4)' in anim,'glyph is placed before Chinese thinking label')
check('scripts/verify-agent-scheduled-tools.py' in source('.github/workflows/build.yml'),'CI runs integration gate')
print(f'Structural checks passed: {checks}')
