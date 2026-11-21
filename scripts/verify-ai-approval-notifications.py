#!/usr/bin/env python3
import json
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
card = source("Views/Chat/AIApprovalCard.swift")
presentation = source("Shared/RemoteServers/AIApprovalPresentation.swift")
settings = source("Views/Settings/EnhancedBackgroundSettingsView.swift")
request = section(gate, "func request(", "func resolve(")
resolve = section(gate, "func resolve(", "func openNotification(")

check("the common gate captures the dispatching session and still admits only one request",
      re.search(r"AIApprovalContext\.\$sessionID\.withValue\(self\.sessionId\) \{\s*await self\.executeSingleToolUse\(", vm)
      and "@TaskLocal static var sessionID: String?" in gateway
      and "let id = UUID()" in request and "let sessionID = AIApprovalContext.sessionID" in request
      and "id: id, sessionID: sessionID" in request and gate.count("private var continuation:") == 1
      and "guard pending == nil, !Task.isCancelled else { return false }" in request
      and re.search(r"self\.pending = request\s*notifyIfBackgrounded\(\)", request))
check("only the current request resolves once and cancellation also settles by UUID",
      "self.resolve(id: id, allowed: false)" in request
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
ready = section(dialog, "private func presentationReady", "private func resolve")
decision = dialog[dialog.index("private func resolve"):]
modal = section(card, "struct AIApprovalModalHost", "private struct ApprovalExpandableText")
check("a ready unlocked host presents only the intended pending UUID and settles by captured IDs",
      "hostReady: isChatViewVisible && !vm.isLoadingSession && !titleIsVisuallyLocked" in chat
      and ".modifier(AIApprovalDialogModifier(sessionID: nil," in home
      and "request.sessionID == nil || request.sessionID == sessionID" in dialog
      and "gate.notificationPresentationID == nil || gate.notificationPresentationID == request.id" in dialog
      and "guard canPresent, let request = gate.pending" in dialog and "!lockStore.appIsLocked" in dialog
      and "!lockStore.isVisuallyLocked" in dialog
      and "scenePhase == .active" in dialog and "!gate.showsExpiredNotice" in dialog
      and "onReady: presentationReady, onDecision: resolve" in dialog and ".id(request.id)" in modal
      and "configuration?.request?.id == id" in modal
      and "self?.configuration?.onDecision(request.id, allowed)" in modal
      and "guard presentableRequest?.id == id else { return }" in ready and "gate.presentationReady(id: id)" in ready
      and "guard presentableRequest?.id == id else { return }" in decision
      and "gate.resolve(id: id, allowed: allowed)" in decision and dialog.count("gate.resolve(") == 1
      and '.alert("此审核已失效"' in chat and ".modifier(AIApprovalExpiredNoticeModifier())" in home)
check("the single modal path blocks the background, deactivates without settling and honors the first explicit click",
      dialog.count("AIApprovalModalHost(") == 1 and ".confirmationDialog" not in dialog
      and modal.count("AIApprovalCard(") == 1 and "AIApprovalCard(" not in dialog + home
      and "view.accessibilityViewIsModal = true" in modal
      and ".background(Color.black.opacity(0.45).ignoresSafeArea().accessibilityHidden(true))" in card
      and ".onTapGesture" not in card
      and "UIApplication.willResignActiveNotification" in modal and "removeCard()" in modal
      and "onDisappear" not in card + dialog and "resolve(" not in card
      and ".accessibilityAction(.escape) { decide(false) }" in card
      and re.search(r"guard !submitted, canDecide\(\) else \{ return \}\s*submitted = true\s*onDecision\(allowed\)", card)
      and decision.index("visibleApprovalID = nil") < decision.index("gate.resolve(")
      and 'String(localized: "This review has ended")' in dialog)
def defers_approval_under_presentations(modal_source):
    update = section(modal_source, "func updateCard()", "private var activeWindow")
    container = section(modal_source, "private func availableContainer(", "private func hasPresentation(")
    presentations = section(modal_source, "private func hasPresentation(", "private func isShowing(")
    return bool(
        re.search(r"watchPresentation\(\)\s*guard let \(parent, container\) = availableContainer\(in: window\) else \{\s*"
                  r"removeCard\(\)\s*return\s*\}", update)
        and update.index("availableContainer(in: window)") < update.index("UIHostingController(rootView:")
        and "!hasPresentation(from: parent, in: window) else { return nil }" in container
        and "controller.presentedViewController != nil || controller.transitionCoordinator != nil" in presentations
        and "child.viewIfLoaded?.window === window && hasPresentation(from: child, in: window)" in presentations)


def checks_approval_card_visibility(modal_source):
    showing = section(modal_source, "private func isShowing(", "private func watchPresentation()")
    observer = section(modal_source, "private func checkPresentation()", "@objc func appWillResignActive()")
    return bool(
        "configuration?.request?.id == id, let window = activeWindow" in showing
        and "let (parent, container) = availableContainer(in: window)" in showing
        and "hosting.parent === parent && view.superview === container && container.subviews.last === view" in showing
        and "view.window === window && !view.isHidden && view.alpha > 0.01 && !view.bounds.isEmpty" in showing
        and re.search(r"guard let configuration, let id = configuration\.request\?\.id, isShowing\(id\) else \{\s*"
                      r"updateCard\(\)\s*return\s*\}.*?configuration\.onReady\(id\)", observer, re.S)
        and re.search(r"canDecide: \{ \[weak self\] in\s*self\?\.isShowing\(request\.id\) == true\s*\}", modal_source)
        and modal_source.count(".onReady(") == 1)


def uses_matched_approval_container(modal_source):
    update = section(modal_source, "func updateCard()", "private var activeWindow")
    container = section(modal_source, "private func availableContainer(", "private func hasPresentation(")
    return bool(
        "let parent = window.rootViewController" in container
        and "let container = parent.viewIfLoaded, container.window === window" in container
        and "return (parent, container)" in container
        and re.search(r"view\.frame = container\.bounds\s*"
                      r"view\.autoresizingMask = \[\.flexibleWidth, \.flexibleHeight\]\s*"
                      r"parent\.addChild\(controller\)\s*hosting = controller\s*"
                      r"container\.addSubview\(view\)\s*controller\.didMove\(toParent: parent\)", update)
        and update.count(".addSubview(") == 1)


check("the root container remains free of approvals until existing presentations and transitions finish",
      defers_approval_under_presentations(modal))
check("only the attached front-most approval can report ready or accept a decision",
      checks_approval_card_visibility(modal) and "window.isKeyWindow, !window.isHidden" in modal
      and ".task(id: notificationID)" not in card)
check("the pending approval is retried without a SwiftUI state change and watching stops on teardown or deactivation",
      "guard presentationTimer == nil else { return }" in modal
      and "repeats: true" in modal and "MainActor.assumeIsolated { self.checkPresentation() }" in modal
      and "RunLoop.main.add(timer, forMode: .common)" in modal
      and "let window = activeWindow, let request = configuration?.request else {\n                stopWatchingPresentation()" in modal
      and "anchor.configuration = nil\n        anchor.updateCard()" in modal
      and "UIApplication.didBecomeActiveNotification" in modal
      and "func appWillResignActive() {\n            stopWatchingPresentation()" in modal
      and re.search(r"presentationTimer\?\.invalidate\(\)\s*presentationTimer = nil\s*removeCard\(\)", modal))
check("the approval hosting controller and view mount in the same root container",
      uses_matched_approval_container(modal))
update_card = section(modal, "func updateCard()", "private var activeWindow")
check("an already mounted approval host updates its content without remounting",
      re.search(r"if let hosting, hosting\.parent !== parent \|\| hosting\.view\.superview !== container \{\s*"
                r"removeCard\(\)\s*\}", update_card)
      and re.search(r"if let hosting \{\s*if container\.subviews\.last !== hosting\.view \{ container\.bringSubviewToFront\(hosting\.view\) \}\s*"
                    r"hosting\.rootView = AnyView\(card\)\s*return\s*\}\s*"
                    r"window\.endEditing\(true\)\s*let controller = UIHostingController", update_card))

for description, before, after, guard_ in (
    ("legacy UUID and non-nil window only",
     section(modal, "private func isShowing(", "private func watchPresentation()"),
     "private func isShowing(_ id: UUID) -> Bool {\n"
     "            configuration?.request?.id == id && hosting?.view.window != nil\n        }\n\n        ",
     checks_approval_card_visibility),
    ("mount directly on the root despite an existing sheet",
     "guard let (parent, container) = availableContainer(in: window) else {",
     "guard let parent = window.rootViewController, let container = parent.view else {",
     defers_approval_under_presentations),
    ("split UIKit controller and view containment again", "container.addSubview(view)",
     "window.addSubview(view)", uses_matched_approval_container),
):
    mutated = modal.replace(before, after, 1)
    check(f"approval visibility mutation rejected: {description}", mutated != modal and not guard_(mutated))

actions = section(card, "private var actions: some View", "private func decide(")
check("Allow approves and Deny rejects through the explicit decision path",
      re.findall(r'Button\s*\{\s*decide\((true|false)\)\s*\}\s*label:\s*\{\s*Text\("(Allow|Deny)"\)', actions)
      == [("true", "Allow"), ("false", "Deny")])
expandable = section(card, "private struct ApprovalExpandableText", "private struct ApprovalCardContent")
check("detail expansion requires hidden characters or actual overflow of the collapsed text",
      "let hasMorePages = firstPage < value.endIndex" in expandable
      and "let preview = text(through: firstPage)" in expandable
      and re.search(r"preview\.lineLimit\(lines\)\s*\.onGeometryChange.*\{ collapsedHeight = \$0 \}", expandable)
      and re.search(r"preview\.lineLimit\(nil\)\s*\.hidden\(\)\s*\.accessibilityHidden\(true\)\s*"
                    r"\.onGeometryChange.*\{ fullHeight = \$0 \}", expandable)
      and "let wrapsPastLimit = collapsedHeight > 0 && fullHeight > collapsedHeight" in expandable
      and re.search(r'if expanded \|\| hasMorePages \|\| wrapsPastLimit \{\s*Button\(expanded \? String\(localized: "Collapse details"\)', expandable))
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
      and "pending = nil" in resolve and "self.resolve(id: id, allowed: false)" in request
      and re.search(r"guard let current = pendingNavigationTarget, current\.approvalID == target\.approvalID else \{ return \}\s*"
                    r"NotificationNavigationStore\.shared\.navigate\(to: current\)", entry)
      and "resolve(" not in entry)

github_path = "Shared/GitHub/GitHubAIToolGateway.swift"
server_path = "Shared/RemoteServers/RemoteServerAIToolGateway.swift"
disk_path = "Shared/RemoteServers/RemoteDiskAIToolGateway.swift"
approval_calls = {
    github_path: (
        "presentation, isDestructive: true",
        ".githubWrite(repository: target, branch: branch, path: filePath, message: message, originalSHA: originalSHA, content: content), isDestructive: true",
        ".githubDelete(repository: target, branch: branch, path: filePath, message: message, fileSHA: sha), isDestructive: true",
    ),
    server_path: (
        ".serverCommand(server: server.approvalTarget, command: command), isDestructive: true",
        '.sftp(server: server.approvalTarget, change: change), isDestructive: action == "delete" || action == "write"',
        ".serverCredential(server: server.approvalTarget, credential: .password), isDestructive: false",
        ".serverCredential(server: server.approvalTarget, credential: .privateKey(hasPassphrase: passphrase != nil)), isDestructive: false",
        ".serverDelete(server: server.approvalTarget), isDestructive: true",
    ),
    disk_path: (
        ".diskCredential(disk: approvalTarget(disk), credential: credential), isDestructive: false",
        ".diskDelete(disk: approvalTarget(disk), retainsSharedSSH: disk.sshServerID != nil), isDestructive: true",
    ),
    "Agent/Chat/AIChatViewModel+ToolDefinitions.swift": (
        ".sessionDelete(title: session.title, targetID: id), isDestructive: true",
    ),
    "Agent/Chat/AIChatViewModel+MediaFavoriteTools.swift": (
        ".favoriteDelete(name: item.fileName, kind: kind, id: item.id), isDestructive: true",
    ),
    "Agent/Chat/SubAgentAIToolGateway.swift": (
        ".subagentConfigure(model: model, thinking: thinkingValue), isDestructive: false",
    ),
}
call = r"RemoteServerAIConfirmationGate\.shared\.request\s*\("
found = {}
for path in ROOT.rglob("*.swift"):
    if any(part.startswith(".") for part in path.relative_to(ROOT).parts):
        continue
    matches = re.findall(call, path.read_text())
    if matches:
        found[path.relative_to(ROOT).as_posix()] = len(matches)
check("the production approval inventory contains exactly 13 request sites",
      sum(found.values()) == 13 and found == {path: len(calls) for path, calls in approval_calls.items()})
for path, calls in approval_calls.items():
    actual = re.findall(call + r"(.*?\bisDestructive:\s*[^)]*)\)", source(path), re.S)
    check(f"{path} binds each request to the matching operation and execution data",
          tuple(" ".join(args.split()) for args in actual) == calls)
github = source(github_path)
check("GitHub commit and branch requests carry the repository, captured target and per-file changes",
      all(marker in github for marker in (
          "Repository(account: account.login, owner: owner, name: repository)",
          "presentation = .githubCommit(repository: target, branch: branch, expectedHead: expectedHead, message: message, changes: files)",
          "presentation = .githubBranch(repository: target, branch: branch, fromSHA: fromSHA)",
          "files.append(.write(path: change.path, content: content))", "files.append(.delete(path: change.path))",
          "expectedHead: expectedHead, message: message, changes: changes, token: token",
          "branch: branch, fromSHA: fromSHA, token: token")))
sftp = section(gateway, "private static func mutateFileSystem", "private static func configureCredentials")
disk = source(disk_path)
check("SFTP validates write/rename parameters before approval and executes the very same change",
      all(sftp.index(marker) < sftp.index(".shared.request(") for marker in (
          'arguments["content"] as? String', 'string("new_path", from: arguments)',
          ".write(path: path, content: content)", ".mkdir(path: path)", ".rename(path: path, to: newPath)",
          '.delete(path: path, isDirectory: arguments["is_directory"] as? Bool ?? false)'))
      and sftp.index("switch change") > sftp.index("guard approved")
      and sftp.count("server.aiAccess == .fullAccess") == 1 and gateway.count("server.aiAccess == .fullAccess") == 2)
check("credential presentation admits only credential type and passphrase presence, not credential values",
      re.findall(r"case (.+)", section(presentation, "enum SSHCredential", "enum DiskCredential"))
      == ["password", "privateKey(hasPassphrase: Bool)"]
      and re.findall(r"case (.+)", section(presentation, "enum DiskCredential", "enum FavoriteKind"))
      == ["password", "s3SecretKey", "sharedSSH(server: Server, credential: SSHCredential)"]
      and all(marker in disk for marker in (
          "credential = .sharedSSH(server: server.approvalTarget, credential: .password)",
          "credential = .sharedSSH(server: server.approvalTarget, credential: .privateKey(hasPassphrase: payload.passphrase?.isEmpty == false))",
          "credential = disk.profile.proto == .s3 ? .s3SecretKey : .password"))
      and not any(marker in card for marker in ('tool_title', 'payload.', 'SecretStore', 'Keychain.read')))
check("request data has no old serverName/operation/detail fallback and snapshots the Soul display name at admission",
      "_ presentation: AIApprovalPresentation" in request
      and "SoulStore.cachedMetadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines)" in request
      and 'soulName: name.isEmpty ? "Ze" : name' in request
      and all(marker not in request + dialog + card for marker in ("request.detail", "request.operation", "request.serverName"))
      and "request.soulName" in card)
identity = section(card, "private var identity:", "private func details(")
soul = source("Agent/Session/SoulStore.swift")
soul_avatar = section(soul, "struct SoulAvatarView:", "enum SoulAvatarMotion")
soul_header_avatar = section(soul, "struct SoulHeaderAvatarSurface:", "private struct SoulAvatarAnimation:")
check("the review identity uses the header's fitted personal avatar or its static idle poster",
      'private static let avatarSize: CGFloat = 48' in card
      and 'IdentityAvatar(size: Self.avatarSize).accessibilityHidden(true)' in identity
      and 'Text(verbatim: request.soulName).font(.subheadline.weight(.semibold))' in identity
      and 'Text("Review required").font(.footnote)' in identity
      and re.search(r"if usesPersonalAvatar \{\s*SoulAvatarView\(size: size, fitsImage: true\)\s*\} else \{\s*Image\(SoulAvatarIdlePolicy\.posterAsset\)", identity)
      and 'SoulAvatarStore.load() != nil || !SoulStore.cachedMetadata.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty' in identity
      and 'SoulAvatarIdlePolicy.darkPosterBackground : SoulAvatarIdlePolicy.lightPosterBackground' in identity
      and "SoulAvatarView(size: size * 0.76, fitsImage: true)" in soul_header_avatar
      and "SoulAvatarAnimation(motion:" in soul_header_avatar
      and "fallback.image = UIImage(named: SoulAvatarIdlePolicy.posterAsset)" in soul
      and "SoulAvatarStore.load()" in soul_avatar and "SoulStore.cachedMetadata.emoji" in soul_avatar
      and soul_avatar.index("if let image") < soul_avatar.index("if trimmed.isEmpty"))
card_layout = section(card, "var body: some View", "private func cardWithIdentity")
card_surface = section(card, "private func cardWithIdentity", "private func bodyAndActions(")
check("the identity occupies layout space while the card surface starts partway down its badge",
      re.search(r"VStack\(spacing: 0\) \{\s*identity\s*content\(\)\s*\}\s*\.background \{", card_surface)
      and "RoundedRectangle(cornerRadius: 20)" in card_surface
      and ".padding(.top, Self.avatarSize + Self.identitySpacing + Self.badgeAboveCard)" in card_surface
      and "private static let badgeAboveCard: CGFloat = 16" in card
      and ".offset(" not in card_surface and ".clipShape(" not in card_surface + card_layout
      and "identity" not in section(card, "private func details(", "@ViewBuilder private func field("))
check("the centered card tries intrinsic height before its constrained scroll layouts",
      re.search(r"ViewThatFits\(in: \.vertical\) \{\s*cardWithIdentity \{ bodyAndActions\(summary, width: width\) \}\s*\.fixedSize\(horizontal: false, vertical: true\)", card_layout)
      and "let height = geometry.size.height * 0.85" in card_layout
      and "ScrollView { cardWithIdentity { bodyAndActions(summary, width: width) } }" in card_layout
      and re.search(r"cardWithIdentity \{\s*VStack\(spacing: 0\) \{\s*ScrollView \{ paddedDetails\(summary, width: width\) \}\s*Divider\(\)\s*paddedActions", card_layout)
      and re.search(r"\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)\s*\.padding\(\.vertical, \(geometry\.size\.height - height\) / 2\)", card_layout)
      and card_layout.rindex("cardWithIdentity") < card_layout.index(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
action_style = section(card, "private struct ActionStyle:", "private func decide(")
check("both decisions use full-width capsule styling with at least 48 points of height",
      ".buttonStyle(ActionStyle(prominent: true))" in actions and ".buttonStyle(ActionStyle(prominent: false))" in actions
      and ".frame(maxWidth: .infinity, minHeight: 48)" in action_style
      and "Capsule().fill(LinearGradient(" in action_style
      and "Capsule().fill(Color(uiColor: .secondarySystemBackground))" in action_style)
check("the card selects an operation-specific rendering for every presentation case",
      re.findall(r"^    case (\w+)\(", presentation, re.M)
      == re.findall(r"^        case \.(\w+)\(", section(card, "init(_ presentation:", "private static func localized"), re.M))

catalog = json.loads(source("Localizable.xcstrings"))["strings"]
display_keys = set(re.findall(r'"([^"\n]+)"', card)) - set(re.findall(r'(?:systemName: |self.init\()"([^"\n]+)"', card))
display_keys -= {"AI approval card", "exclamationmark.circle", "exclamationmark.triangle.fill"}
display_keys = {re.sub(r"\\\([^)]*\)", "%lld", key) for key in display_keys} | {"This review has ended"}
locales = ("en", "zh-Hans", "zh-Hant")
check("all approval card strings have English, Simplified and Traditional Chinese entries",
      all(set(locales) <= catalog.get(key, {}).get("localizations", {}).keys() for key in display_keys)
      and {"zh-Hans", "zh-Hant"} <= catalog["Review pending operation"]["localizations"].keys())
for key in sorted(display_keys):
    for locale in locales:
        loc = catalog[key]["localizations"][locale]
        if "%lld" in key:
            plural = loc["variations"]["plural"]
            assert sorted(plural) == (["one", "other"] if locale == "en" else ["other"]), (key, locale)
            assert all(unit["stringUnit"]["value"].count("%lld") == 1 for unit in plural.values()), (key, locale)
        elif "%@" in key:
            value = loc["stringUnit"]["value"]
            count = key.count("%@")
            if locale == "en":
                assert value.count("%@") == count, (key, locale)
            else:
                assert sorted(map(int, re.findall(r"%(\d+)\$@", value))) == list(range(1, count + 1)), (key, locale)
check("plural variants and all format-argument positions are present", True)

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
