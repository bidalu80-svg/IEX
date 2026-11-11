import SwiftUI
import UIKit

// Fixtures supply display state only. Every visible call control is the actual
// production VoiceCallPanel. XCTest taps its accessibility elements.
enum ProviderType { case openAI, openAIResponses, anthropic, gemini, antigravity, openRouter, xAI, kimiCode, githubCopilot, workBuddy, unsupported
    var displayName: String { String(describing: self) }
}

private struct VoiceCallFixture: View {
    @State private var expanded = false
    @State private var muted = false
    @State private var active = true
    @State private var responding = false
    @State private var paused = false
    private let began = Date()
    private var dark: Bool { ProcessInfo.processInfo.arguments.contains("--dark") }
    private var large: Bool { ProcessInfo.processInfo.arguments.contains("--large") }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if active {
                        VoiceCallPanel(providerType: .gemini, providerName: "Gemini",
                            status: paused ? "通话已暂停" : muted ? "麦克风已静音" : responding ? "正在说话" : "正在听",
                            startDate: began, audioLevel: muted ? 0 : 0.45,
                            isMuted: muted, canInterrupt: responding,
                            recoveryMessage: paused ? "音频被系统中断，请点继续通话。" : nil,
                            transcript: "你好，今天我们可以聊些什么？", isExpanded: $expanded,
                            onMute: { muted.toggle() }, onHangUp: { active = false },
                            onInterrupt: { responding = false; muted = false },
                            onResume: { paused = false })
                    } else {
                        Text("通话已结束").accessibilityIdentifier("fixture.ended")
                    }
                    Text("聊天消息保留在当前会话里。")
                }
            }
            // Test controls must not move with the panel's spring transition.
            // Otherwise XCTest can resolve the old frame and tap its neighbour
            // while the production panel is still collapsing above it.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("模拟回复") { responding = true }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("fixture.respond")
                    Button("模拟系统中断") { paused = true }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("fixture.pause")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .buttonStyle(.bordered)
            }
            .navigationTitle("语音交互验证")
        }
        .preferredColorScheme(dark ? .dark : .light)
        .environment(\.dynamicTypeSize, large ? .accessibility2 : .large)
    }
}

@main struct VoiceCallUIHarness: App {
    var body: some Scene { WindowGroup { VoiceCallFixture() } }
}
