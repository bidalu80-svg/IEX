//
//  LaunchAnimationView.swift
//  ZeApp
//
//  [T-launch-animation] Presentation only. Owns no business state and never
//  reads storage; the coordinator decides when it appears and disappears.
//
//  Visual language: the existing ghost mark, a single sheen, one orbit arc.
//  No particles, no slogans, no looping motion — the point is "the agent is
//  coming online", not a trailer.
//

import SwiftUI
import UIKit

struct LaunchAnimationView: View {
    @ObservedObject var coordinator: LaunchCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var sheenOffset: CGFloat = -1.25
    @State private var ringTrim: CGFloat = 0
    @State private var breathing = false

    private let markSize: CGFloat = 96

    /// Motion is allowed only while the layer is actually animating: reduce
    /// motion and the degraded (slow initialisation) path both drop the sweep
    /// and the orbit.
    private var allowsMotion: Bool {
        !reduceMotion && !coordinator.degraded
    }

    var body: some View {
        ZStack {
            // Same colour as the launch storyboard (`systemBackgroundColor`),
            // so the hand-off from the system launch image has no flash.
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            mark
                .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
                .opacity(appeared ? 1 : 0)
                .opacity(coordinator.degraded && breathing ? 0.88 : 1)
        }
        .opacity(coordinator.phase == .fading ? 0 : 1)
        .animation(.easeInOut(duration: 0.35), value: coordinator.phase)
        .onAppear {
            coordinator.armTimers()
            playIntro()
        }
        .onChange(of: coordinator.degraded) { degraded in
            if degraded { startBreathing() }
        }
        // Decorative: VoiceOver must not land here while the app is starting.
        .accessibilityHidden(true)
    }

    // MARK: - Mark

    private var mark: some View {
        ZStack {
            if allowsMotion {
                Circle()
                    .trim(from: 0, to: ringTrim)
                    .stroke(
                        Color.accentColor.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round)
                    )
                    .frame(width: markSize + 44, height: markSize + 44)
                    .rotationEffect(.degrees(-90))
            }

            Image("ZeAssistantAvatar")
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .overlay {
                    if allowsMotion {
                        sheen
                    }
                }
        }
        .frame(width: markSize + 60, height: markSize + 60)
    }

    /// One pass of light across the mark, clipped to its own shape.
    private var sheen: some View {
        LinearGradient(
            colors: [.clear, Color.white.opacity(0.9), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 42, height: markSize * 2)
        .rotationEffect(.degrees(16))
        .offset(x: sheenOffset * markSize)
        .blendMode(.plusLighter)
        .mask(
            Image("ZeAssistantAvatar")
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
        )
        .allowsHitTesting(false)
    }

    // MARK: - Timeline

    private func playIntro() {
        // Phase A — fade in and settle from 0.94.
        withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.45)) {
            appeared = true
        }
        guard !reduceMotion else { return }

        // Phase B — a single sheen and one orbit arc. Both are one-shot; the
        // layer never loops while waiting for the app to finish starting.
        withAnimation(.easeInOut(duration: 1.05).delay(0.42)) {
            sheenOffset = 1.25
        }
        withAnimation(.easeInOut(duration: 0.9).delay(0.35)) {
            ringTrim = 1
        }
    }

    private func startBreathing() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}
