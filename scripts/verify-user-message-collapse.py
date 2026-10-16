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

# [T-ios-user-collapse-smooth] Animated disclosure pass + stable anchoring.
finish_body = v3.split("private func finishUserMessageExpansionToggle", 1)[1].split("private func runUserMessageExpansionLayoutPass", 1)[0]
check("setContentKey" in finish_body and "setPrecalcHeight" in finish_body, "toggle refreshes layout metadata for the post-toggle state")
check("runUserMessageExpansionLayoutPass" in finish_body, "finish routes through the shared animated pass")
check("disclosureAnimationInFlight" in infra and "else if disclosureAnimationInFlight" in infra, "collection view lets the scoped disclosure pass animate")
check("disclosureAnimationInFlight = true" in v3 and "UIView.animate" in v3, "coordinator animates the disclosure pass")
check("scheduleUserMessageExpansionSettles" in v3, "settle probes re-anchor until the disclosure stabilizes")
check(v3.count("solveDisclosureAnchor") >= 3, "one anchoring equation shared by pass and probes")
check("UIAccessibility.isReduceMotionEnabled" in v3, "disclosure animation respects Reduce Motion")
check("scripts/verify-user-message-collapse.py" in workflow, "CI runs the disclosure regression gate")
print(f"Structural checks passed: {checks}")
