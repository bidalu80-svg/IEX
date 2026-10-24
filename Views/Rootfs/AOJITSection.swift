//
//  AOJITSection.swift
//  ZeApp
//
//  [T-aojit] Settings → Rootfs Management → AOJIT.
//
//  The list is deliberately dense but quiet: one title per library, the guest
//  paths it covers, what it is for, and — in secondary type — which version
//  the image was recorded from. The only colour in the row is the status pill
//  (green = full speed, orange = partial, grey = not installed), so scanning
//  the column tells you where the speed is without reading a word.
//

import SwiftUI

struct AOJITSection: View {
    @ObservedObject var aojit: AOJITAcceleration

    /// [T-aojit-repair] A version mismatch is repaired by installing the
    /// *recorded* version over the installed one, so it asks first.
    @State private var pendingOverwrite: AOJITLibraryState?

    var body: some View {
        Section {
            Toggle(isOn: $aojit.isEnabled) {
                Label {
                    Text("AOJIT Optimization")
                } icon: {
                    // [T-aojit-mark] The app's own mark: a blue ring with the
                    // wave inside. Drawn rather than picked from SF Symbols —
                    // `waveform.circle` draws bars and the `.fill` variant
                    // inverts the disc, neither of which matches.
                    AOJITMark(size: 28)
                }
            }

            // [T-aojit] When the switch is off the rows are noise — the footer
            // says what the feature covers instead, matching the app's own
            // off-state copy.
            if aojit.isEnabled {
                diagnosticsRow
                if aojit.states.isEmpty {
                    HStack(spacing: 8) {
                        if aojit.isContainerReady {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(aojit.isContainerReady
                             ? String(localized: "Checking installed libraries…")
                             : String(localized: "The container is not running yet."))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(aojit.states) { state in
                        row(state)
                    }
                }
            }
        } header: {
            Text("AOJIT")
        } footer: {
            if aojit.isEnabled {
                Text(Self.explanation)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.explanation)
                    Text(String(localized: "Includes:") + " " + Self.includedNames)
                }
            }
        }
    }

    /// Two paragraphs shared by both states.
    private static let explanation = String(localized: "AOJIT runs pre-recorded, pre-compiled JIT code for the libraries below instead of emulating every instruction. Shell pipelines are usually 2–4× faster. A switch takes effect for commands started afterwards.\n\nEach library has a single image recorded from the version listed: that version runs at full speed. For other versions of the same library, unchanged code still runs from the image and the rest is emulated, which still gives a partial speed-up.")

    /// The catalog itself, so the off-state copy can never drift from the rows.
    private static let includedNames = AOJITAcceleration.catalog
        .map(\.name)
        .joined(separator: ", ")

    // MARK: Row

    private func row(_ state: AOJITLibraryState) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.library.name)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                statusPill(state)
            }

            Text(state.library.paths)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            Text(state.library.summary)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "Recorded from") + " " + state.recordedLine)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let note = state.speedNote {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // [T-aojit-repair] Partial rows need the button too: that is the
            // case where the installed version differs from the recorded one.
            if state.status == .partial || state.status == .notInstalled {
                repairButton(state)
            }

            if let error = aojit.repairError[state.id] {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusPill(_ state: AOJITLibraryState) -> some View {
        let tint: Color
        switch state.status {
        case .available:    tint = .green
        case .partial:      tint = .orange
        case .recording:    tint = .blue
        case .notInstalled: tint = .secondary
        }

        return Text(state.statusTitle)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(state.status == .notInstalled ? 0.12 : 0.14))
            )
    }

    private var diagnosticsRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(aojit.jitRuntimeEnabled ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(String(localized: "JIT runtime") + ": "
                     + (aojit.jitRuntimeEnabled ? String(localized: "On") : String(localized: "Off")))
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text(aojit.footprintMode
                     ? String(localized: "Memory: footprint")
                     : String(localized: "Memory: ledger"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(String(localized: "Images linked") + ": \(aojit.linkedImageCount)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("settings.aojit.diagnostics")
    }

    private func repairButton(_ state: AOJITLibraryState) -> some View {
        Button {
            if state.status == .partial {
                pendingOverwrite = state
            } else {
                aojit.repair(state)
            }
        } label: {
            HStack(spacing: 6) {
                if aojit.busyLibraryId == state.id {
                    ProgressView()
                        .controlSize(.small)
                }
                Text((state.status == .partial
                      ? String(localized: "Repair: install")
                      : String(localized: "Install")) + " " + state.library.repairSpec)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(aojit.busyLibraryId != nil)
        .padding(.top, 2)
        .alert(String(localized: "Replace the installed version?"),
               isPresented: Binding(get: { pendingOverwrite != nil },
                                    set: { if !$0 { pendingOverwrite = nil } })) {
            Button(String(localized: "Cancel"), role: .cancel) { pendingOverwrite = nil }
            Button(String(localized: "Replace"), role: .destructive) {
                if let state = pendingOverwrite { aojit.repair(state) }
                pendingOverwrite = nil
            }
        } message: {
            if let state = pendingOverwrite {
                Text(String(format: String(localized: "This installs the recorded version %@ over the current %@."),
                            state.library.repairSpec,
                            state.installedVersion ?? "?"))
            }
        }
    }
}

// MARK: - Mark

/// Blue ring with a sine wave inside.
///
/// Both parts are native: `Circle().strokeBorder` for the ring and
/// `waveform.path` for the wave. The `waveform.circle` family draws vertical
/// bars, and a hand-built path read as a checkmark.
struct AOJITMark: View {
    var size: CGFloat = 26
    var tint: Color = .blue

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint, lineWidth: size * 0.072)

            Image(systemName: "waveform.path")
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
