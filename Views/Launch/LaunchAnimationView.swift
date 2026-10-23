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
//  The system launch screen now draws this same mark at this same size on this
//  same colour, so the layer opens on the frame the user was already looking
//  at. That is why the intro is a 0.98→1.0 settle rather than a fade from
//  nothing: fading in a mark that is already on screen reads as a flash.
//

import SwiftUI
import UIKit

struct LaunchAnimationView: View {
    @ObservedObject var coordinator: LaunchCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var settled = false
    @State private var sheenOffset: CGFloat = -1.3
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
                // Starts at the size the launch image shows.
                .scaleEffect(settled ? 1 : 0.98)
                .opacity(coordinator.degraded && breathing ? 0.86 : 1)
        }
        .opacity(coordinator.phase == .fading ? 0 : 1)
        .animation(.easeInOut(duration: 0.45), value: coordinator.phase)
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
            // One orbit arc. Opacity-animated rather than conditionally
            // inserted so a degrade mid-flight does not pop a layer out.
            Circle()
                .trim(from: 0, to: ringTrim)
                .stroke(
                    Color.accentColor.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round)
                )
                .frame(width: markSize + 44, height: markSize + 44)
                .rotationEffect(.degrees(-90))
                .opacity(allowsMotion ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: allowsMotion)

            Image("ZeLaunchMark")
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .overlay {
                    sheen
                        .opacity(allowsMotion ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: allowsMotion)
                }
        }
        .frame(width: markSize + 60, height: markSize + 60)
    }

    /// One pass of light across the mark, clipped to its own shape.
    ///
    /// No `.blendMode` here: a blend mode forces the whole subtree into an
    /// offscreen buffer that has to be re-composited every frame, which is the
    /// one thing in this view that could miss a frame on an older device. A
    /// plain white gradient at reduced opacity over the masked shape reads the
    /// same and stays on the fast path.
    private var sheen: some View {
        LinearGradient(
            colors: [.clear, Color.white.opacity(0.75), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 46, height: markSize * 1.6)
        .rotationEffect(.degrees(16))
        .offset(x: sheenOffset * markSize)
        .mask(
            Image("ZeLaunchMark")
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
        )
        .allowsHitTesting(false)
    }

    // MARK: - Timeline

    private func playIntro() {
        guard !reduceMotion else {
            settled = true
            return
        }

        // Phase A — settle from 0.98. Opacity is left alone: the launch image
        // already shows this mark, so fading it in would read as a blink.
        withAnimation(.easeOut(duration: 0.5)) {
            settled = true
        }

        // Phase B — a single sheen and one orbit arc. Both are one-shot; the
        // layer never loops while waiting for the app to finish starting.
        withAnimation(.easeInOut(duration: 1.15).delay(0.35)) {
            sheenOffset = 1.3
        }
        withAnimation(.easeInOut(duration: 1.0).delay(0.3)) {
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
