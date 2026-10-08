"""Static checks for the V3 long-user-message disclosure transaction."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def source(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")

chat = source("Views/Chat/ChatMessageViews.swift")
infra = source("Agent/MessageList/MessageListInfrastructure.swift")
v3 = source("Agent/MessageList/CollectionViewMessageListV3.swift")
workflow = source(".github/workflows/build.yml")
checks = 0

def check(value, label):
    global checks
    assert value, label
    checks += 1
    print("PASS:", label)

check("onToggleUserMessageExpansion" in chat, "row exposes coordinator-owned expansion callback")
check("toggleUserMessageExpansion()" in chat, "tap routes through one toggle helper")
check("onToggleUserMessageExpansion" in infra, "cell bridge carries expansion callback")
check("private func toggleUserMessageExpansion(messageId: UUID)" in v3, "coordinator owns the expansion mutation")
check("vm.messages.first(where: { $0.id == messageId })" in v3, "mutation resolves the canonical VM message")
check(v3.count("userMessageExpansionWillToggle") >= 1 and v3.count("userMessageExpansionToggled") >= 1, "viewport transaction remains synchronous")
check("onToggleUserMessageExpansion: bridge.onToggleUserMessageExpansion" in v3, "whole-message cell wires the callback")
check("bridge.onToggleUserMessageExpansion = message.role == .user && !message.isQueued" in v3, "callback is only enabled for sent user messages")
check("scripts/verify-user-message-collapse.py" in workflow, "CI runs the disclosure regression gate")
print(f"Structural checks passed: {checks}")
