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

    var body: some View {
        Section {
            Toggle(isOn: $aojit.isEnabled) {
                Label {
                    Text("AOJIT Optimization")
                } icon: {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.blue, in: Circle())
                }
            }

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
                if !aojit.isEnabled {
                    Text("AOJIT is off. Turn it on to record images for the installed libraries.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(aojit.states) { state in
                    row(state)
                }
            }
        } header: {
            Text("AOJIT")
        } footer: {
            Text("AOJIT runs pre-recorded, pre-compiled JIT code for the libraries below instead of emulating every instruction. Shell pipelines are usually 2–4× faster. A switch takes effect for commands started afterwards.\n\nEach library has a single image recorded from the version listed: that version runs at full speed. For other versions of the same library, unchanged code still runs from the image and the rest is emulated, which still gives a partial speed-up.")
        }
    }

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

            if !state.isAvailable {
                repairButton(state)
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

    private func repairButton(_ state: AOJITLibraryState) -> some View {
        Button {
            aojit.repair(state)
        } label: {
            HStack(spacing: 6) {
                if aojit.busyLibraryId == state.id {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(String(localized: "Repair: install") + " " + state.library.repairSpec)
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
    }
}
