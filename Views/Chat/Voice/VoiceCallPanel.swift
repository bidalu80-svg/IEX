import SwiftUI
import UIKit

/// Presentation only. Recording, playback and the lifetime of a call belong to
/// VoiceCallCoordinator; expanding the panel never recreates those resources.
struct VoiceCallPanel: View {
    let providerType: ProviderType
    var providerBaseURL: String? = nil
    let providerName: String
    let status: String
    let startDate: Date?
    let audioLevel: Float
    let isMuted: Bool
    let canInterrupt: Bool
    var recoveryMessage: String? = nil
    var transcript: String = ""
    @Binding var isExpanded: Bool
    let onMute: () -> Void
    let onHangUp: () -> Void
    let onInterrupt: () -> Void
    let onResume: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsTranscript = true

    private var level: CGFloat {
        audioLevel.isFinite && !isMuted ? CGFloat(min(1, max(0, audioLevel))) : 0
    }

    private var avatarSize: CGFloat { isExpanded ? 106 : 54 }
    private var accent: Color { Color(red: 0.57, green: 0.38, blue: 0.91) }

    var body: some View {
        VStack(spacing: isExpanded ? 14 : 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("语音通话")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    elapsedTime
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onHangUp) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 44)
                        .background(Color.red, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("挂断语音通话")
                .accessibilityIdentifier("voiceCall.hangUp")
            }

            HStack(alignment: .center, spacing: 16) {
                if isExpanded { Spacer(minLength: 0) }
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88)) {
                        isExpanded.toggle()
                    }
                } label: {
                    avatar
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起通话画面" : "展开通话画面")
                .accessibilityValue(providerName)
                .accessibilityIdentifier("voiceCall.expand")

                if !isExpanded {
                    identity
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }

                if !isExpanded { microphoneButton }
            }
            .padding(.vertical, isExpanded ? 14 : 4)

            if isExpanded {
                identity
                    .multilineTextAlignment(.center)
                HStack(spacing: 20) {
                    microphoneButton
                    Button {
                        showsTranscript.toggle()
                    } label: {
                        Image(systemName: showsTranscript ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 48, height: 44)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsTranscript ? "隐藏通话字幕" : "显示通话字幕")
                    .accessibilityIdentifier("voiceCall.captions")
                }
            }

            if let recoveryMessage, !recoveryMessage.isEmpty {
                VStack(spacing: 8) {
                    Text(recoveryMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("继续通话", action: onResume)
                        .font(.callout.weight(.semibold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("voiceCall.resume")
                }
                .frame(maxWidth: .infinity)
            } else if canInterrupt {
                Button(action: onInterrupt) {
                    Label("打断并说话", systemImage: "waveform")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(accent.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voiceCall.interrupt")
            }

            if isExpanded, showsTranscript, !transcript.isEmpty {
                Text(transcript)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("voiceCall.transcript")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.10 + Double(level) * 0.12), lineWidth: 9)
                .scaleEffect(reduceMotion ? 1 : 1.08 + level * 0.15)
            Circle()
                .stroke(accent.opacity(0.18 + Double(level) * 0.18), lineWidth: 2)
                .scaleEffect(reduceMotion ? 1 : 1.03 + level * 0.09)
            Circle().fill(Color(UIColor.secondarySystemBackground))
            ProviderBrandIcon(type: providerType, baseURL: providerBaseURL, size: avatarSize * 0.62)
                .accessibilityHidden(true)
        }
        .frame(width: avatarSize, height: avatarSize)
        .padding(10)
        .contentShape(Circle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
    }

    private var identity: some View {
        VStack(alignment: isExpanded ? .center : .leading, spacing: 5) {
            Text(providerName)
                .font(.headline)
                .lineLimit(2)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(isMuted ? Color.secondary : accent)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("voiceCall.status")
        }
    }

    private var microphoneButton: some View {
        Button(action: onMute) {
            Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isMuted ? Color.red : Color.primary)
                .frame(width: 48, height: 44)
                .background(isMuted ? Color.red.opacity(0.1) : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "取消麦克风静音" : "麦克风静音")
        .accessibilityValue(isMuted ? "已静音" : "已开启")
        .accessibilityIdentifier("voiceCall.mute")
    }

    @ViewBuilder
    private var elapsedTime: some View {
        if let startDate {
            TimelineView(.periodic(from: startDate, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(startDate)))
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("通话时长")
                    .accessibilityValue("\(seconds / 60)分\(seconds % 60)秒")
            }
        } else {
            Text("准备中")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
