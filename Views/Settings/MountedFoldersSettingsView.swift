//
//  MountedFoldersSettingsView.swift
//  ZeApp
//
//  Settings screen for managing user-mounted external folders. Lets the user
//  pick a folder from iOS Files (e.g. an Obsidian vault in iCloud Drive),
//  give it a custom name, and mount it at /var/ze/mounts/<name>.
//

import SwiftUI
import UniformTypeIdentifiers

private let mountUILogger = AppLogger(category: "MountedFoldersUI")

/// Carries the selected folder through the picker-dismissal handoff into the
/// Add-Mount confirmation sheet.
private struct PendingMount: Identifiable {
    let id = UUID()
    let url: URL
    var name: String
    var allowWrite: Bool
}

struct MountedFoldersSettingsView: View {
    @StateObject private var model = MountedFoldersViewModel()
    @State private var pendingMount: PendingMount?
    @State private var errorText: String?
    /// One picker, one presentation.
    ///
    /// [T-mount-single-importer] This view used to carry two `.fileImporter`
    /// modifiers (add + re-authorize) on the same `List`. SwiftUI keeps a
    /// single presentation slot per modifier chain, so with both attached the
    /// "+" button could flip its own flag without anything appearing.
    ///
    /// `isPickerPresented` drives the sheet; `pickerMode` carries the intent
    /// and must stay set until the completion runs. Clearing the intent from
    /// the `isPresented` setter instead (as an earlier revision did) made the
    /// completion read nil and return early — the picker opened, "Open" was
    /// tapped, and nothing happened.
    @State private var pickerMode: MountPickerMode?
    @State private var isPickerPresented = false
    /// Why the last pick failed, shown in the list instead of disappearing
    /// into a dismissed sheet.
    @State private var pickerDiagnostic: String?

    private enum MountPickerMode {
        case add
        case reauthorize(UUID)
    }

    var body: some View {
        List {
            Section {
                InfoBanner()
            }

            // [T-mount-inline-editor] The confirmation used to be a `.sheet`.
            // Chaining a sheet straight after `.fileImporter` dismisses is
            // unreliable — the picker returns, the sheet never appears, and the
            // whole flow looks dead. Editing inline has no presentation slot to
            // compete for.
            if let pending = pendingMount {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Source path")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(pending.url.path)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TextField("Name", text: Binding(
                        get: { pendingMount?.name ?? "" },
                        set: { pendingMount?.name = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Toggle(isOn: Binding(
                        get: { pendingMount?.allowWrite ?? true },
                        set: { pendingMount?.allowWrite = $0 }
                    )) {
                        Text("Allow writes")
                    }

                    Button {
                        confirmMount(pending)
                    } label: {
                        Label("Mount", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(pending.name.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button(role: .cancel) {
                        pendingMount = nil
                    } label: {
                        Text("Cancel")
                    }
                } header: {
                    Text("New Mount")
                } footer: {
                    Text("This will be the folder name under /var/ze/mounts/")
                }
            }

            if let pickerDiagnostic {
                Section {
                    Label {
                        Text(pickerDiagnostic)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if model.entries.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "externaldrive.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No mounted folders")
                            .font(.headline)
                        Text("Tap + to pick a folder from Files (e.g. an Obsidian vault in iCloud Drive).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(model.entries) { entry in
                        NavigationLink {
                            MountDetailView(
                                context: detailContext(for: entry),
                                onDismiss: { model.refresh() }
                            )
                        } label: {
                            MountedFolderRow(
                                entry: entry,
                                state: model.state(for: entry.id),
                                sourceURL: model.resolvedURL(for: entry.id)
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                model.remove(id: entry.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                pickerMode = .reauthorize(entry.id)
                                isPickerPresented = true
                            } label: {
                                Label(String(localized: "Re-authorize"), systemImage: "key.fill")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                pickerMode = .reauthorize(entry.id)
                                isPickerPresented = true
                            } label: {
                                Label(String(localized: "Re-authorize"), systemImage: "key.fill")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Mounted Folders")
                        Spacer()
                        Text("\(model.entries.count) / \(MountedFoldersManager.maxMountCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(model.isAtCapacity ? .orange : .secondary)
                    }
                } footer: {
                    if model.isAtCapacity {
                        Text("Mount limit reached. Remove an existing mount before adding a new one.")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Mount External Folders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    pendingMount = nil
                    pickerMode = .add
                    isPickerPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(model.isAtCapacity)
            }
        }
        // Use SwiftUI's system file importer directly. It owns the Files
        // presentation/dismissal lifecycle, so the provider's “Open” button
        // reliably returns the selected security-scoped folder URL instead of
        // leaving a nested UIDocumentPicker sheet stuck on screen.
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard let mode = pickerMode else { return }
            pickerMode = nil
            pickerDiagnostic = nil

            switch result {
            case .failure(let error):
                let ns = error as NSError
                // Cancelling is not a failure.
                if ns.code != NSUserCancelledError {
                    pickerDiagnostic = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
                    mountUILogger.warning("picker failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
                }
            case .success(let urls):
                guard let url = urls.first else { return }
                switch mode {
                case .add:
                    pendingMount = PendingMount(
                        url: url,
                        name: Self.defaultMountName(for: url),
                        allowWrite: true
                    )
                    mountUILogger.info("picked \(url.path)")
                case .reauthorize(let id):
                    do {
                        try model.reauthorize(id: id, pickedURL: url)
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            }
        }
        .alert(String(localized: "Error"),
               isPresented: Binding(get: { errorText != nil },
                                    set: { if !$0 { errorText = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func confirmMount(_ pending: PendingMount) {
        do {
            _ = try model.add(
                pickedURL: pending.url,
                customName: pending.name,
                userAllowWrite: pending.allowWrite
            )
            pendingMount = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Build the MountDetailView context for an external-mount entry.
    private func detailContext(for entry: MountedFolderEntry) -> MountDetailContext {
        // Host URL for Browse Files goes through the fakefs symlink so the
        // breadcrumb shows /var/ze/mounts/<name>.
        let mountPath = RootfsManager.shared.dataPath
            .appendingPathComponent("var/ze/mounts", isDirectory: true)
            .appendingPathComponent(entry.name)
        return MountDetailContext(
            kind: .external,
            linuxPath: "/var/ze/mounts/\(entry.name)",
            sourceDisplayName: entry.sourceDisplayName,
            hostURL: mountPath,
            iconName: "externaldrive.fill",
            iconColor: .orange,
            subtitle: nil,
            initialName: entry.name,
            canRename: true,
            externalMountId: entry.id,
            isOSWritable: entry.isWritable,
            initialUserAllowWrite: entry.userAllowWrite,
            sharedFolderName: nil,
            initialVisibleInFiles: true,
            isReadOnlyFromFiles: false
        )
    }

    /// Trivial / meaningless segments often appearing at the end of an iCloud
    /// container identifier's reverse-DNS bundle ID (e.g. `iCloud~com~nssurge~inc`
    /// where "inc" is just the company suffix). We skip these when picking a
    /// friendly default mount name.
    private static let trivialSuffixes: Set<String> = [
        "inc", "ltd", "llc", "app", "co", "corp", "gmbh"
    ]

    /// Default mount name suggestion.
    ///
    /// When the user picks an iCloud Drive app folder, `url.lastPathComponent`
    /// is often literally "Documents" because Apple's ubiquity container
    /// structure is:
    ///     .../Mobile Documents/iCloud~<team>~<bundle-parts>/Documents/
    ///
    /// Using "Documents" as the mount name gives no hint about which app the
    /// folder belongs to. We detect that case and instead derive the name
    /// from the parent container, picking the most meaningful segment of the
    /// reverse-DNS bundle ID (e.g. `iCloud~com~nssurge~inc` → `nssurge`, not
    /// `inc`).
    private static func defaultMountName(for url: URL) -> String {
        let lastName = url.lastPathComponent
        let candidate: String
        if lastName == "Documents" {
            // Walk up: parent is the ubiquity container directory.
            let parent = url.deletingLastPathComponent()
            let parentName = parent.lastPathComponent
            if parentName.hasPrefix("iCloud~") {
                // Format: "iCloud~<team>~<bundle-component-1>~<bundle-component-2>..."
                // Drop the "iCloud" prefix and the TLD-like team segment
                // (index 1, usually "com" / "net" / "org" / "io" / "md").
                let parts = parentName.split(separator: "~").map(String.init)
                let remaining = Array(parts.dropFirst(2)) // drop "iCloud" + team
                // Prefer the last segment that isn't a trivial corporate suffix.
                let best = remaining.reversed().first { segment in
                    !Self.trivialSuffixes.contains(segment.lowercased())
                } ?? remaining.last ?? parts.last ?? lastName
                candidate = best
            } else if !parentName.isEmpty {
                // Not an iCloud container but still called Documents —
                // fall back to the parent name for disambiguation.
                candidate = parentName
            } else {
                candidate = lastName
            }
        } else {
            candidate = lastName
        }

        let cleaned = candidate
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "mount" : cleaned
    }
}

// MARK: - Banner

private struct InfoBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Mount external folders", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            Text("Picked folders are bind-mounted at /var/ze/mounts/<name>. You can browse them in Browse Files and read/write them directly from the iSH shell, just like /var/ze/shared. Up to 10 folders can be mounted at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Row

private struct MountedFolderRow: View {
    let entry: MountedFolderEntry
    let state: MountActivationState
    let sourceURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text(entry.name)
                    .font(.body.weight(.medium))
                accessBadge
                Spacer()
            }
            Text("/var/ze/mounts/\(entry.name)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: "← \(sourceURL?.path ?? entry.sourceDisplayName)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    /// Small pill reflecting the effective write state of this mount:
    /// - "R/W": the OS allows writes AND the user allowed writes
    /// - "Locked": the OS allows writes but the user set Allow Writes = off
    /// - "Read-only": the OS itself does not allow writes (user choice n/a)
    @ViewBuilder
    private var accessBadge: some View {
        if !entry.isWritable {
            badgePill(text: String(localized: "Read-only"), color: .orange)
        } else if !entry.userAllowWrite {
            badgePill(text: String(localized: "Locked"), color: .purple)
        } else {
            badgePill(text: String(localized: "R/W"), color: .green)
        }
    }

    private func badgePill(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1)
            )
    }
}

// MARK: - Add mount sheet

// MARK: - ViewModel

@MainActor
final class MountedFoldersViewModel: ObservableObject {
    @Published private(set) var entries: [MountedFolderEntry] = []
    @Published private(set) var states: [UUID: MountActivationState] = [:]

    var isAtCapacity: Bool {
        entries.count >= MountedFoldersManager.maxMountCount
    }

    init() {
        refresh()
    }

    func refresh() {
        entries = MountedFoldersManager.shared.entries
        states = MountedFoldersManager.shared.activationStates
    }

    func state(for id: UUID) -> MountActivationState {
        states[id] ?? .failed("")
    }

    /// Resolved host URL for a mount, if currently active. Exposed to row views
    /// so they can display the underlying iOS filesystem path.
    func resolvedURL(for id: UUID) -> URL? {
        MountedFoldersManager.shared.resolvedURL(for: id)
    }

    @discardableResult
    func add(pickedURL: URL, customName: String, userAllowWrite: Bool) throws -> MountedFolderEntry {
        // Match the working Ze lifecycle: return promptly from Files'
        // delegate, then create the bookmark when the user confirms the mount.
        // The scope result is only used to balance stopAccessing; a false value
        // is not treated as a cancelled/invalid picker selection.
        let startedScope = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if startedScope {
                pickedURL.stopAccessingSecurityScopedResource()
            }
        }
        let bookmark = try pickedURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let entry = try MountedFoldersManager.shared.add(
            pickedURL: pickedURL,
            bookmark: bookmark,
            customName: customName,
            userAllowWrite: userAllowWrite
        )
        refresh()
        return entry
    }

    func remove(id: UUID) {
        MountedFoldersManager.shared.remove(id: id)
        refresh()
    }

    func rename(id: UUID, to newName: String) throws {
        try MountedFoldersManager.shared.rename(id: id, to: newName)
        refresh()
    }

    func setUserAllowWrite(id: UUID, to allow: Bool) {
        MountedFoldersManager.shared.setUserAllowWrite(id: id, to: allow)
        refresh()
    }

    func reauthorize(id: UUID, pickedURL: URL) throws {
        try MountedFoldersManager.shared.reauthorize(id: id, pickedURL: pickedURL)
        refresh()
    }
}
