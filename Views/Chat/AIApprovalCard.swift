import SwiftUI
import UIKit

@MainActor
struct AIApprovalCard: View {
    let request: RemoteServerAIConfirmationRequest
    var canDecide: () -> Bool
    var onDecision: (Bool) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicType
    @AccessibilityFocusState(for: .voiceOver) private var questionFocused: Bool
    @State private var submitted = false
    @State private var showsAllFiles = false

    var body: some View {
        GeometryReader { geometry in
            let width = min(520, max(0, geometry.size.width - 32))
            let height = geometry.size.height * 0.85
            let summary = ApprovalCardContent(request.presentation, soul: request.soulName)
            Group {
                if dynamicType.isAccessibilitySize || geometry.size.width > geometry.size.height || height < 380 {
                    ScrollView { bodyAndActions(summary, width: width) }
                } else {
                    ViewThatFits(in: .vertical) {
                        bodyAndActions(summary, width: width).fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 0) {
                            ScrollView { details(summary, width: width).padding(20) }
                            Divider()
                            actions.padding(20)
                        }
                    }
                }
            }
            .frame(width: width)
            .frame(maxHeight: height)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.opacity(0.45).ignoresSafeArea().accessibilityHidden(true))
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { decide(false) }
        .onAppear { questionFocused = true }
    }

    private func bodyAndActions(_ summary: ApprovalCardContent, width: CGFloat) -> some View {
        VStack(spacing: 20) {
            details(summary, width: width)
            actions
        }
        .padding(20)
    }

    private func details(_ summary: ApprovalCardContent, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 5) {
                SoulAvatarView(size: 48).accessibilityHidden(true)
                Text(verbatim: request.soulName).font(.headline)
                Text("Review required").font(.subheadline.weight(.semibold)).foregroundStyle(Color(uiColor: .systemBlue))
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilitySortPriority(1)

            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let symbol = summary.symbol {
                        Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                    } else {
                        GitHubMark(size: 28)
                    }
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                Text(verbatim: summary.title).font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($questionFocused)
            }
            .accessibilitySortPriority(2)
            Text(verbatim: summary.message)
            if let impact = summary.impact {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: request.isDestructive ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                        .foregroundStyle(Color(uiColor: .systemOrange)).accessibilityHidden(true)
                    Text(verbatim: impact).fontWeight(.semibold)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summary.fields.indices, id: \.self) { index in
                    field(summary.fields[index], labelWidth: max(0, (width - 68) / 3))
                }
                if !summary.files.isEmpty { files(summary.files) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func field(_ field: ApprovalCardContent.Field, labelWidth: CGFloat) -> some View {
        if dynamicType.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) { fieldLabel(field.label); fieldValue(field) }
                .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                fieldLabel(field.label).frame(width: labelWidth, alignment: .leading)
                fieldValue(field)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(verbatim: label).foregroundStyle(.secondary)
    }

    @ViewBuilder private func fieldValue(_ field: ApprovalCardContent.Field) -> some View {
        if let lines = field.lines {
            ApprovalExpandableText(value: field.value, lines: lines)
        } else {
            Text(verbatim: field.value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func files(_ files: [AIApprovalPresentation.FileChange]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Files in this commit").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(0..<(showsAllFiles ? files.count : min(3, files.count)), id: \.self) { index in
                Divider()
                switch files[index] {
                case .write(let path, let content):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Write").fontWeight(.semibold)
                        ApprovalExpandableText(value: path, lines: 2)
                        if content.isEmpty { Text("Empty file (0 bytes)") }
                        else { ApprovalExpandableText(value: content, lines: 4) }
                    }
                case .delete(let path):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delete").fontWeight(.semibold)
                        ApprovalExpandableText(value: path, lines: 2)
                    }
                }
            }
            if files.count > 3 {
                Button {
                    showsAllFiles.toggle()
                } label: {
                    if showsAllFiles { Text("Show fewer files") }
                    else { Text("Show all \(files.count) items") }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button { decide(true) } label: {
                Text("Allow").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(uiColor: .systemBlue))
            Button { decide(false) } label: {
                Text("Deny").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .keyboardShortcut(.cancelAction)
        }
        .disabled(submitted)
    }

    private func decide(_ allowed: Bool) {
        guard !submitted, canDecide() else { return }
        submitted = true
        onDecision(allowed)
    }
}

@MainActor
struct AIApprovalModalHost: UIViewRepresentable {
    let request: RemoteServerAIConfirmationRequest?
    let notificationID: UUID?
    var onReady: (UUID) -> Void
    var onDecision: (UUID, Bool) -> Void

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(anchor, selector: #selector(Anchor.appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(anchor, selector: #selector(Anchor.updateCard),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.configuration = self
        anchor.updateCard()
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: ()) {
        NotificationCenter.default.removeObserver(anchor)
        anchor.configuration = nil
        anchor.updateCard()
    }

    final class Anchor: UIView {
        var configuration: AIApprovalModalHost?
        private var hosting: UIHostingController<AnyView>?
        private var presentationTimer: Timer?
        private var lastReportedReady: (requestID: UUID, notificationID: UUID?)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateCard()
        }

        @objc func updateCard() {
            guard let window = activeWindow, let request = configuration?.request else {
                stopWatchingPresentation()
                return
            }
            watchPresentation()
            guard let (parent, container) = availableContainer(in: window) else {
                removeCard()
                return
            }
            if let hosting, hosting.parent !== parent || hosting.view.superview !== container {
                removeCard()
            }
            let card = AIApprovalCard(request: request, canDecide: { [weak self] in
                self?.isShowing(request.id) == true
            }, onDecision: { [weak self] allowed in
                self?.configuration?.onDecision(request.id, allowed)
            }).id(request.id)
            if let hosting {
                if container.subviews.last !== hosting.view { container.bringSubviewToFront(hosting.view) }
                hosting.rootView = AnyView(card)
                return
            }
            window.endEditing(true)
            let controller = UIHostingController(rootView: AnyView(card))
            let view = controller.view!
            view.backgroundColor = .clear
            view.accessibilityViewIsModal = true
            view.frame = container.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            parent.addChild(controller)
            hosting = controller
            container.addSubview(view)
            controller.didMove(toParent: parent)
        }

        private var activeWindow: UIWindow? {
            guard let window, window.windowScene?.activationState == .foregroundActive,
                  UIApplication.shared.applicationState == .active else { return nil }
            return window
        }

        private func availableContainer(in window: UIWindow) -> (UIViewController, UIView)? {
            guard window.isKeyWindow, !window.isHidden, window.alpha > 0.01, let parent = window.rootViewController,
                  let container = parent.viewIfLoaded, container.window === window,
                  !container.isHidden, container.alpha > 0.01, !container.bounds.isEmpty,
                  !hasPresentation(from: parent, in: window) else { return nil }
            return (parent, container)
        }

        private func hasPresentation(from controller: UIViewController, in window: UIWindow) -> Bool {
            if controller.presentedViewController != nil || controller.transitionCoordinator != nil { return true }
            return controller.children.contains { child in
                child !== hosting && child.viewIfLoaded?.window === window && hasPresentation(from: child, in: window)
            }
        }

        private func isShowing(_ id: UUID) -> Bool {
            guard configuration?.request?.id == id, let window = activeWindow,
                  let (parent, container) = availableContainer(in: window), let hosting,
                  let view = hosting.viewIfLoaded else { return false }
            return hosting.parent === parent && view.superview === container && container.subviews.last === view
                && view.window === window && !view.isHidden && view.alpha > 0.01 && !view.bounds.isEmpty
        }

        private func watchPresentation() {
            guard presentationTimer == nil else { return }
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                MainActor.assumeIsolated { self.checkPresentation() }
            }
            presentationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func checkPresentation() {
            guard let configuration, let id = configuration.request?.id, isShowing(id) else {
                updateCard()
                return
            }
            guard lastReportedReady?.requestID != id || lastReportedReady?.notificationID != configuration.notificationID else { return }
            lastReportedReady = (id, configuration.notificationID)
            configuration.onReady(id)
        }

        @objc func appWillResignActive() {
            stopWatchingPresentation()
        }

        private func stopWatchingPresentation() {
            presentationTimer?.invalidate()
            presentationTimer = nil
            removeCard()
        }

        private func removeCard() {
            guard let hosting else { return }
            hosting.willMove(toParent: nil)
            hosting.view.removeFromSuperview()
            hosting.removeFromParent()
            self.hosting = nil
            lastReportedReady = nil
        }
    }
}

private struct ApprovalExpandableText: View {
    let value: String
    let lines: Int
    @State private var expanded = false
    @State private var end: String.Index?
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        let firstPage = value.index(value.startIndex, offsetBy: 2048, limitedBy: value.endIndex) ?? value.endIndex
        let visibleEnd = expanded ? end ?? firstPage : firstPage
        let hasMorePages = firstPage < value.endIndex
        let wrapsPastLimit = collapsedHeight > 0 && fullHeight > collapsedHeight
        VStack(alignment: .leading, spacing: 4) {
            if expanded {
                text(through: visibleEnd)
            } else {
                let preview = text(through: firstPage)
                preview.lineLimit(lines)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { collapsedHeight = $0 }
                    .background(alignment: .topLeading) {
                        if !hasMorePages {
                            preview.lineLimit(nil)
                                .hidden()
                                .accessibilityHidden(true)
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { fullHeight = $0 }
                        }
                    }
            }
            if expanded || hasMorePages || wrapsPastLimit {
                Button(expanded ? String(localized: "Collapse details") : String(localized: "Expand details")) {
                    expanded.toggle()
                }
                .font(.footnote)
            }
            if expanded, visibleEnd < value.endIndex {
                Button("Load more text") {
                    end = value.index(visibleEnd, offsetBy: 2048, limitedBy: value.endIndex) ?? value.endIndex
                }
                .font(.footnote)
            }
        }
    }

    private func text(through end: String.Index) -> some View {
        Text(verbatim: String(value[..<end]))
            .font(.body.monospaced())
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ApprovalCardContent {
    struct Field {
        let label: String
        let value: String
        let lines: Int?
    }

    let symbol: String?
    let title: String
    let message: String
    let impact: String?
    let fields: [Field]
    let files: [AIApprovalPresentation.FileChange]

    private init(_ symbol: String?, _ title: String, _ message: String, impact: String? = nil,
                 fields: [Field], files: [AIApprovalPresentation.FileChange] = []) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.impact = impact
        self.fields = fields
        self.files = files
    }

    init(_ presentation: AIApprovalPresentation, soul: String) {
        switch presentation {
        case .githubCommit(let repo, let branch, let head, let message, let files):
            let deleted = files.filter { if case .delete = $0 { return true }; return false }.count
            let written = files.count - deleted
            self.init(nil, Self.localized("Allow %@ to push this GitHub commit?", soul),
                      Self.localized("%@ wants to push one commit to %@ on %@ as %@: %@, %@.",
                                     soul, repo.fullName, branch, repo.account,
                                     String(localized: "\(written) items to write"), String(localized: "\(deleted) items to delete")),
                      impact: deleted > 0 ? Self.localized("Files marked Delete will be removed from the target branch.") : nil,
                      fields: Self.repository(repo) + [Self.field("Target branch", branch), Self.field("Expected HEAD", head, lines: 2),
                                                       Self.field("Commit message", message, lines: 4)], files: files)
        case .githubBranch(let repo, let branch, let from):
            self.init(nil, Self.localized("Allow %@ to create a GitHub branch?", soul),
                      Self.localized("%@ wants to create branch %@ in %@ as %@ from the specified commit.", soul, branch, repo.fullName, repo.account),
                      fields: Self.repository(repo) + [Self.field("New branch", branch), Self.field("Starting commit", from, lines: 2)])
        case .githubWrite(let repo, let branch, let path, let message, let sha, let content):
            let branch = branch ?? Self.localized("Repository default branch")
            var fields = Self.githubFile(repo, branch: branch, path: path, message: message)
            if let sha { fields.append(Self.field("Original file SHA", sha, lines: 2)) }
            fields += [Self.field("UTF-8 bytes", content.utf8.count.formatted()), Self.contentField("File content", content)]
            self.init(nil, Self.localized("Allow %@ to write and push this GitHub file?", soul),
                      Self.localized("%@ wants to write %@ in %@ on %@ and commit the change.", soul, path, repo.fullName, branch), fields: fields)
        case .githubDelete(let repo, let branch, let path, let message, let sha):
            let branch = branch ?? Self.localized("Repository default branch")
            self.init(nil, Self.localized("Allow %@ to delete and push this GitHub file?", soul),
                      Self.localized("%@ wants to delete %@ from %@ on %@ and commit the change.", soul, path, repo.fullName, branch),
                      impact: Self.localized("The file will be removed from the target branch."),
                      fields: Self.githubFile(repo, branch: branch, path: path, message: message) + [Self.field("File SHA to delete", sha, lines: 2)])
        case .serverCommand(let server, let command):
            self.init("terminal", Self.localized("Allow %@ to run a command on this server?", soul),
                      Self.localized("%@ wants to run the command below on %@ as %@.", soul, server.name, server.user),
                      fields: Self.serverFields(server) + [Self.field("SSH user", server.user), Self.field("Command", command, lines: 4)])
        case .sftp(let server, let change):
            let fields = Self.serverFields(server)
            switch change {
            case .write(let path, let content):
                let bytes = content.utf8.count.formatted()
                self.init("doc.badge.plus", Self.localized("Allow %@ to write a remote file?", soul),
                          Self.localized("%@ wants to write %@ bytes to %@ on %@.", soul, bytes, path, server.name),
                          impact: Self.localized("Existing contents may be overwritten."),
                          fields: fields + [Self.field("Target path", path, lines: 2), Self.field("UTF-8 bytes", bytes), Self.contentField("Text preview", content)])
            case .mkdir(let path):
                self.init("folder.badge.plus", Self.localized("Allow %@ to create a remote folder?", soul),
                          Self.localized("%@ wants to create the folder %@ on %@.", soul, path, server.name),
                          fields: fields + [Self.field("New folder path", path, lines: 2)])
            case .rename(let path, let target):
                self.init("arrow.right.doc.on.clipboard", Self.localized("Allow %@ to move or rename a remote item?", soul),
                          Self.localized("%@ wants to move %@ to %@ on %@.", soul, path, target, server.name),
                          fields: fields + [Self.field("Original path", path, lines: 2), Self.field("Target path", target, lines: 2)])
            case .delete(let path, let isDirectory):
                self.init("trash", Self.localized(isDirectory ? "Allow %@ to delete a remote folder?" : "Allow %@ to delete a remote file?", soul),
                          Self.localized("%@ wants to delete %@ from %@.", soul, path, server.name),
                          fields: fields + [Self.field("Target path", path, lines: 2), Self.field("Target type", Self.localized(isDirectory ? "Folder" : "File"))])
            }
        case .serverCredential(let server, let credential):
            let title: String
            switch credential {
            case .password: title = Self.localized("Allow %@ to save this server password?", soul)
            case .privateKey: title = Self.localized("Allow %@ to save this server private key?", soul)
            }
            self.init("key", title, Self.localized("%@ wants to save the %@ for %@ in this device’s Keychain.",
                                                    soul, Self.sshType(credential, shared: false), server.name),
                      impact: Self.localized("This replaces the server’s saved credentials."),
                      fields: Self.serverFields(server) + Self.sshFields(credential, shared: false))
        case .serverDelete(let server):
            let scope = Self.localized("Local configuration and Keychain password, private key and passphrase")
            self.init("server.rack", Self.localized("Allow %@ to delete this server’s local configuration?", soul),
                      Self.localized("%@ wants to remove the local configuration and credentials for %@, disconnecting it first if connected.", soul, server.name),
                      impact: Self.localized("This cannot be undone. The remote server is not deleted."),
                      fields: Self.serverFields(server) + [Self.field("Removal scope", scope)])
        case .diskCredential(let disk, let credential):
            let title = Self.localized("Allow %@ to save this network disk credential?", soul)
            let fields = Self.diskFields(disk)
            switch credential {
            case .sharedSSH(let server, let kind):
                self.init("externaldrive", title, Self.localized("%@ wants to update the shared credentials on %@ used by %@.", soul, server.name, disk.name),
                          impact: Self.localized("The old SSH connection and verification for all linked disks will be invalidated."),
                          fields: fields + [Self.field("Linked SSH server", server.name), Self.field("SSH address", server.address)] + Self.sshFields(kind, shared: true))
            case .password, .s3SecretKey:
                let kind = credential == .password ? Self.localized("Approval password") : Self.localized("S3 Secret Key")
                self.init("externaldrive", title, Self.localized("%@ wants to save the credentials for %@ in this device’s Keychain.", soul, disk.name),
                          fields: fields + [Self.field("Credential type", kind)])
            }
        case .diskDelete(let disk, let retainsSharedSSH):
            self.init("externaldrive", Self.localized("Allow %@ to delete this network disk’s local configuration?", soul),
                      Self.localized("%@ wants to remove the local configuration and independent credentials for %@.", soul, disk.name),
                      impact: Self.localized(retainsSharedSSH ? "Remote files, the linked SSH server and its shared credentials will be kept. The local removal cannot be undone."
                          : "Remote files will be kept. The local removal cannot be undone."),
                      fields: Self.diskFields(disk) + [Self.field("Removal scope", Self.localized("Local configuration and independent Keychain credentials"))])
        case .sessionDelete(let title, let id):
            let title = title ?? Self.localized("Untitled conversation")
            let scope = Self.localized("Messages, media, conversation directory and persistent browser data")
            self.init("bubble.left.and.text.bubble.right", Self.localized("Allow %@ to permanently delete this local conversation?", soul),
                      Self.localized("%@ wants to permanently delete the local conversation %@.", soul, title),
                      impact: Self.localized("This cannot be undone. Messages, media, the conversation directory and persistent browser data will be deleted."),
                      fields: [Self.field("Conversation", title), Self.field("Target conversation ID", id), Self.field("Removal scope", scope)])
        case .favoriteDelete(let name, let kind, let id):
            let type: String
            switch kind {
            case .image: type = Self.localized("Favorite image")
            case .video: type = Self.localized("Video")
            case .audio: type = Self.localized("Audio")
            }
            let original = Self.localized("The original conversation file will be kept.")
            self.init("star", Self.localized("Allow %@ to delete this media favorite?", soul),
                      Self.localized("%@ wants to delete the favorite copy of %@.", soul, name), impact: original,
                      fields: [Self.field("Favorite name", name), Self.field("Media type", type), Self.field("Favorite ID", id.uuidString), Self.field("Original file", original)])
        case .subagentConfigure(let model, let thinking):
            var fields: [Field] = []
            let modelTarget: String?
            switch model {
            case .none: modelTarget = nil
            case .some(.followConversation):
                let follow = Self.localized("Follow the current conversation")
                modelTarget = follow
                fields.append(Self.field("Model", follow))
            case .some(.model(let name, let provider)):
                modelTarget = Self.localized("%@ (%@)", name, provider)
                fields += [Self.field("Model", name), Self.field("Provider", provider)]
            }
            let thinkingTarget = thinking.map { Self.localized($0 ? "On (medium)" : "Off") }
            if let thinkingTarget { fields.append(Self.field("Thinking", thinkingTarget)) }
            let message: String
            switch (modelTarget, thinkingTarget) {
            case (let model?, let thinking?): message = Self.localized("%@ wants to set the subagent model to %@ and thinking to %@.", soul, model, thinking)
            case (let model?, nil): message = Self.localized("%@ wants to set the subagent model to %@.", soul, model)
            case (nil, let thinking?): message = Self.localized("%@ wants to set subagent thinking to %@.", soul, thinking)
            case (nil, nil): message = Self.localized("%@ wants to change subagent settings.", soul)
            }
            self.init("person.2", Self.localized("Allow %@ to change subagent settings?", soul), message, fields: fields)
        }
    }

    private static func localized(_ key: String, _ values: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "AI approval card")
        return values.isEmpty ? format : String(format: format, locale: Locale.current, arguments: values)
    }

    private static func field(_ label: String, _ value: String, lines: Int? = nil) -> Field {
        Field(label: localized(label), value: value, lines: lines)
    }

    static func fileText(_ content: String) -> String { content.isEmpty ? localized("Empty file (0 bytes)") : content }

    private static func contentField(_ label: String, _ content: String) -> Field {
        field(label, fileText(content), lines: content.isEmpty ? nil : 4)
    }

    private static func repository(_ repo: AIApprovalPresentation.Repository) -> [Field] {
        [field("Account", repo.account), field("Repository owner", repo.owner), field("Repository", repo.name)]
    }

    private static func githubFile(_ repo: AIApprovalPresentation.Repository, branch: String, path: String, message: String) -> [Field] {
        repository(repo) + [field("Target branch", branch), field("Path", path, lines: 2), field("Commit message", message, lines: 4)]
    }

    private static func serverFields(_ server: AIApprovalPresentation.Server) -> [Field] {
        [field("Approval server", server.name), field("SSH address", server.address)]
    }

    private static func diskFields(_ disk: AIApprovalPresentation.Disk) -> [Field] {
        [field("Network disk", disk.name), field("Protocol", disk.protocolName), field("Address", disk.address)]
    }

    private static func sshType(_ credential: AIApprovalPresentation.SSHCredential, shared: Bool) -> String {
        switch credential {
        case .password: return localized(shared ? "SSH password" : "Approval password")
        case .privateKey: return localized(shared ? "SSH private key" : "Private key")
        }
    }

    private static func sshFields(_ credential: AIApprovalPresentation.SSHCredential, shared: Bool) -> [Field] {
        var fields = [field("Credential type", sshType(credential, shared: shared))]
        if case .privateKey(let hasPassphrase) = credential {
            fields.append(field("Save passphrase", localized(hasPassphrase ? "Yes" : "No")))
        }
        return fields
    }
}
