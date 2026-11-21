#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text()


def section(text, start, end):
    offset = text.index(start)
    return text[offset:text.index(end, offset + len(start))]


def check(description, condition):
    assert condition, description
    print(f"PASS: {description}")


gateway = source("Shared/RemoteServers/RemoteServerAIToolGateway.swift")
gate = section(gateway, "final class RemoteServerAIConfirmationGate", "enum RemoteServerAIToolGateway")
vm = source("Agent/Chat/AIChatViewModel.swift")
delegate = source("Agent/Intents/SendPromptIntent.swift")
ask = source("Agent/Intents/AskZeIntent.swift")
home = source("Views/ContentView.swift")
chat = source("Views/Chat/AIChatView.swift")
settings = source("Views/Settings/EnhancedBackgroundSettingsView.swift")
request = section(gate, "func request(", "func resolve(")
resolve = section(gate, "func resolve(", "func openNotification(")

check("the common gate captures the dispatching session and still admits only one request",
      re.search(r"AIApprovalContext\.\$sessionID\.withValue\(self\.sessionId\) \{\s*await self\.executeSingleToolUse\(", vm)
      and "@TaskLocal static var sessionID: String?" in gateway
      and "id: UUID(), sessionID: AIApprovalContext.sessionID" in request
      and "guard pending == nil, !Task.isCancelled else { return false }" in request
      and re.search(r"self\.pending = request\s*notifyIfBackgrounded\(\)", request))
check("only the current request resolves once and cancellation also settles by UUID",
      "self.resolve(id: request.id, allowed: false)" in request
      and re.search(r"guard pending\?\.id == id, let continuation else \{ return \}\s*"
                    r"self\.continuation = nil\s*pending = nil\b.*?removeNotification\(id: id\).*?"
                    r"continuation\.resume\(returning: allowed\)", resolve, re.S))
eligibility = section(gate, "private func canNotify", "private func notifyIfBackgrounded")
scheduling = section(gate, "private func notifyIfBackgrounded", "private func sendNotification")
sending = section(gate, "private func sendNotification", "private func removeNotification")
check("admission or background entry can schedule at most one reminder per UUID and background stay",
      re.search(r"forName: UIApplication\.didEnterBackgroundNotification[^\n]*\n\s*MainActor\.assumeIsolated \{\s*"
                r"self\?\.isInBackground = true\s*self\?\.notifyIfBackgrounded\(\)", gate)
      and all(marker in eligibility for marker in ("pending?.id == id", "isInBackground", "applicationState == .background",
          "backgroundGeneration == generation", "BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled"))
      and re.search(r"guard let id = pending\?\.id, canNotify\(id: id, generation: generation\),\s*"
                    r"notifiedID != id, !isAddingNotification else \{ return \}\s*notifiedID = id\s*isAddingNotification = true", scheduling))
check("delivery revalidates after authorization lookup and removes stale async adds",
      re.search(r"let settings = await center\.notificationSettings\(\)\s*guard canNotify\(id: id, generation: generation\) else \{ return \}", sending)
      and "case .authorized, .provisional, .ephemeral: break" in sending
      and re.search(r"await center\.add\(notification\)\s*if !canNotify\(id: id, generation: generation\) \{ removeNotification\(id: id\) \}", sending)
      and "requestAuthorization" not in sending)
check("the lock-screen notification has only generic copy and an approval-specific identifier",
      'static let notificationPrefix = "ai-approval-"' in gate
      and re.search(r'let content = UNMutableNotificationContent\(\)\s*content\.body = "Ze 有一项操作等你审核"\s*'
                    r'let notification = UNNotificationRequest\(identifier: Self\.notificationPrefix \+ id\.uuidString, content: content, trigger: nil\)', sending))
foreground = section(gate, "private func returnToForeground", "private func canNotify")
cleanup = section(gate, "private func removeNotification", "static func enableNotificationsFromSettings")
check("foreground return resets the background stay and cleanup removes only this approval ID",
      "forName: UIApplication.willEnterForegroundNotification" in gate and "self?.returnToForeground()" in gate
      and all(marker in foreground for marker in ("isInBackground = false", "backgroundGeneration &+= 1",
          "notifiedID = nil", "removeNotification(id: id)"))
      and "let identifier = Self.notificationPrefix + id.uuidString" in cleanup
      and "center.removePendingNotificationRequests(withIdentifiers: [identifier])" in cleanup
      and "center.removeDeliveredNotifications(withIdentifiers: [identifier])" in cleanup
      and "removeAll" not in cleanup and "Badge" not in cleanup)
tap = section(delegate, "let identifier = response.notification.request.identifier", "let userInfo = response.notification")
opening = section(gate, "func openNotification", "func presentationReady")
navigation = section(delegate, "func navigate(to target: Target)", "private func setPending(_ target: Target)")
ask_navigation = section(ask, "if !sid.isEmpty", "return .result(dialog: \"On it")
check("Siri sends an ordinary typed navigation target through the shared buffer and broadcast",
      re.search(r"if !sid\.isEmpty \{\s*NotificationNavigationStore\.shared\.navigate\(to: \.init\(sessionId: sid, approvalID: nil\)\)\s*\}", ask_navigation)
      and "private func setPending(_ target: Target)" in delegate
      and "setPending(target)" in navigation and navigation.index("setPending(target)") < navigation.index("NotificationCenter.default.post"))
check("approval taps validate UUID and navigate to the originating session without settling the request",
      "response.actionIdentifier == UNNotificationDefaultActionIdentifier" in tap
      and "UUID(uuidString: String(identifier.dropFirst(prefix.count)))" in tap
      and "RemoteServerAIConfirmationGate.shared.openNotification(id: id)" in tap
      and "let sessionId = request.sessionID" in tap
      and "NotificationNavigationStore.shared.navigate(to: .init(sessionId: sessionId, approvalID: id))" in tap
      and re.search(r"guard let request = pendingRequest\(forNotification: id\) else \{ return nil \}\s*notificationPresentationID = id", opening)
      and re.search(r"guard let pending, pending\.id == id else \{\s*showsExpiredNotice = true\s*return nil\s*\}", opening)
      and "resolve(" not in tap + opening
      and 'userInfo["approvalID"] = id.uuidString' in navigation and "name: .openSessionFromIntent" in navigation
      and re.search(r"guard approvalTargetIsCurrent\(approvalID\), approvalID == nil \|\| navigationPath\.isEmpty else \{ return \}\s*openSession\(sessionId\)", home)
      and "approvalTargetIsCurrent(notificationTarget.approvalID)" in home)
check("only approval banners are suppressed in the foreground",
      re.search(r"if notification\.request\.identifier\.hasPrefix\(RemoteServerAIConfirmationGate\.notificationPrefix\) \{\s*"
                r"completionHandler\(\[\]\)\s*return\s*\}\s*completionHandler\(\[\.banner, \.sound\]\)", delegate))
dialog = section(chat, "struct AIApprovalDialogModifier", "struct AIApprovalExpiredNoticeModifier")
check("a ready unlocked host presents only the intended pending UUID and settles by captured IDs",
      "hostReady: isChatViewVisible && !vm.isLoadingSession && !titleIsVisuallyLocked" in chat
      and ".modifier(AIApprovalDialogModifier(sessionID: nil," in home
      and "request.sessionID == nil || request.sessionID == sessionID" in dialog
      and "gate.notificationPresentationID == nil || gate.notificationPresentationID == request.id" in dialog
      and "gate.pending?.id == request.id && canPresent" in dialog and "!lockStore.appIsLocked" in dialog
      and "scenePhase == .active" in dialog and "!gate.showsExpiredNotice" in dialog
      and "presenting: request" in dialog and ".id(request.id)" in dialog
      and "reject(id: request.id)" in dialog and "reject(id: shown.id)" in dialog
      and "gate.resolve(id: shown.id, allowed: true)" in dialog and "gate.resolve(id: id, allowed: false)" in dialog
      and '.alert("此审核已失效"' in chat and ".modifier(AIApprovalExpiredNoticeModifier())" in home)
entry = section(dialog, ".overlay(alignment: .top)", "private var pendingNavigationTarget")
target = section(dialog, "private var pendingNavigationTarget", "private var canPresent")
check("the foreground review banner is reachable in chat and root, and hidden in the originating session",
      re.search(r"AIApprovalDialogModifier\(sessionID: nil,\s*hostReady: isWideLayout \? selectedSessionId == nil : navigationPath\.isEmpty\)", home)
      and "AIApprovalDialogModifier(sessionID: vm.sessionId," in chat
      and "if let target = pendingNavigationTarget" in entry and "Button {" in entry
      and 'SessionNoticeBanner(text: String(localized: "Review pending operation")' in entry
      and 'SessionNoticeBanner(text: toast, systemImage: "icloud.and.arrow.up")' in home
      and "let origin = request.sessionID, origin != sessionID else { return nil }" in target
      and "guard canPresent," in target)
check("the review banner follows live pending state and a stale tap cannot resolve or route a different request",
      "@ObservedObject private var gate = RemoteServerAIConfirmationGate.shared" in dialog
      and "@Published private(set) var pending: RemoteServerAIConfirmationRequest?" in gate
      and "let request = gate.pending" in target and "return .init(sessionId: origin, approvalID: request.id)" in target
      and "pending = nil" in resolve and "self.resolve(id: request.id, allowed: false)" in request
      and re.search(r"guard let current = pendingNavigationTarget, current\.approvalID == target\.approvalID else \{ return \}\s*"
                    r"NotificationNavigationStore\.shared\.navigate\(to: current\)", entry)
      and "resolve(" not in entry)

with tempfile.TemporaryDirectory(prefix="ze-feedback-probe-") as directory:
    output = Path(directory) / "FeedbackProbe.swift"
    subprocess.run(["bash", "scripts/test-feedback-ui.sh", "--generate-probe", str(output)], cwd=ROOT, check=True)
    probe = output.read_text()
infrastructure = source("Agent/MessageList/MessageListInfrastructure.swift")
completion = section(vm, "    private func notifyCompletionFeedback(", "    private func runAgentLoop(").strip()
glow = section(infrastructure, "struct ReplyCompletionGlowEvent {", "@MainActor enum SimpleTranscript").strip()
row = section(infrastructure, "    static func row(for block:", "    static func hasText(").strip()
has_text = section(infrastructure, "    static func hasText(", "    static func showsWaiting(").strip()
probe_block = section(probe, "struct FeedbackProbeBlock {", "@MainActor enum SimpleTranscript")
check("the CI feedback probe still runs the original production completion body",
      completion.replace("private func", "func", 1) in probe
      and re.search(r'xcrun swiftc[^\n]*[\s\S]*?scripts/FeedbackUIHarness.swift "\$PROBE"', source("scripts/test-feedback-ui.sh"))
      and "bash scripts/test-feedback-ui.sh" in source(".github/workflows/build.yml"))
check("the generated feedback probe includes block UUIDs and the production row and glow dependencies",
      "import Combine" in probe
      and "let id = UUID()" in probe_block and "var questionCard: Bool?" in probe_block
      and "@MainActor enum SimpleTranscript" in probe
      and row.replace("block: AssistantBlock", "block: FeedbackProbeBlock", 1) in probe
      and has_text in probe
      and glow in probe)
authorization = gate[gate.index("static func enableNotificationsFromSettings"):]
check("undecided authorization is requested only from foreground settings interaction",
      "if enabled { Task { await enableNotificationAuthorization() } }" in settings
      and 'Button("Enable Notification Permission")' in settings
      and "notificationAuthorization == .denied" in settings and "UIApplication.openSettingsURLString" in settings
      and "applicationState == .active, !isRequestingAuthorization" in authorization
      and "settings.authorizationStatus == .notDetermined, UIApplication.shared.applicationState == .active" in authorization
      and "center.requestAuthorization" in authorization and gate.count("center.requestAuthorization") == 1)
