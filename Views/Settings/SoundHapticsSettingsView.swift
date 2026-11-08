import SwiftUI

struct SoundHapticsSettingsView: View {
    @ObservedObject private var settings = AppFeedbackSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
            Section {
                Toggle(isOn: $settings.preferences.completionSoundEnabled) {
                    Label("聊天回复音效", systemImage: "speaker.wave.2.fill")
                }
                .accessibilityIdentifier("feedback.completionSound")
            } header: {
                Text("回复提示")
            } footer: {
                Text("每次回复完整结束后播放一次。停止、失败和流式输出过程保持安静；录音时暂停音效，避免录入提示音。音量跟随系统。")
            }

            Section {
                ForEach(ReplyCompletionTone.allCases) { tone in
                    Button {
                        settings.preferences.completionTone = tone
                        AppFeedback.preview(tone)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.body)
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tone.title).foregroundStyle(.primary)
                                Text(tone.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if settings.preferences.completionTone == tone {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold)).foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("feedback.tone.\(tone.rawValue)")
                    .accessibilityLabel("\(tone.title)，\(tone.detail)")
                    .accessibilityHint("选择并试听此音效")
                    .accessibilityAddTraits(settings.preferences.completionTone == tone ? .isSelected : [])
                }
            } header: {
                Text("提示音")
            } footer: {
                Text("点按即可选择并试听。试听不会开启聊天回复音效。")
            }

            Section {
                Toggle(isOn: $settings.preferences.hapticsEnabled) {
                    Label("震动反馈", systemImage: "iphone.radiowaves.left.and.right")
                }
                .accessibilityIdentifier("feedback.haptics")

                Picker("反馈强度", selection: $settings.preferences.hapticStrength) {
                    ForEach(FeedbackHapticStrength.allCases) { strength in
                        Text(strength.title).tag(strength)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.preferences.hapticsEnabled)
                .accessibilityIdentifier("feedback.strength")
                .onChange(of: settings.preferences.hapticStrength) { _ in AppFeedback.haptic() }

                Button {
                    AppFeedback.haptic()
                } label: {
                    Label("体验震动", systemImage: "hand.tap")
                        .frame(minHeight: 32, alignment: .leading)
                }
                .disabled(!settings.preferences.hapticsEnabled)
                .accessibilityIdentifier("feedback.testHaptic")
            } header: {
                Text("触感")
            } footer: {
                Text("统一控制应用内的按钮、选择、复制和任务完成震动。关闭后不再触发应用震动；系统键盘等触感由 iOS 设置管理。实际触感随设备而异。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("声音与震动")
        .navigationBarTitleDisplayMode(.inline)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: settings.preferences.hapticsEnabled)
        .onDisappear { AppFeedback.stopSound() }
    }
}
