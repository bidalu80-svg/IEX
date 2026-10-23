//
//  LaunchCoordinator.swift
//  ZeApp
//
//  [T-launch-animation] Single owner of the cold-launch animation state.
//
//  Only a cold launch may play the animation, and only once: the state lives
//  here (app-level singleton) rather than in a view, so SwiftUI re-creating the
//  root, a `scenePhase` bounce, a deep link or a background restore can never
//  replay it.
//

import SwiftUI
import UIKit

/// Preference key, deliberately outside the `@MainActor` class so the App
/// initializer and `@AppStorage` can read it from any context.
///
/// Read with `object(forKey:)` so "never set" (→ on) is distinguishable from
/// "explicitly off".
enum LaunchAnimationPreference {
    static let key = "appearance.launchAnimationEnabled"
}

@MainActor
final class LaunchCoordinator: ObservableObject {

    static let shared = LaunchCoordinator()

    /// Pure `UserDefaults` read, safe from any context: the App initializer
    /// consults it before the first frame.
    nonisolated static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: LaunchAnimationPreference.key) != nil else { return true }
        return defaults.bool(forKey: LaunchAnimationPreference.key)
    }

    enum Phase: Equatable {
        /// Covering the root; motion is armed by the view's `onAppear`.
        case playing
        /// Cross-fading out.
        case fading
        /// Removed from the view tree; never returns.
        case finished
    }

    @Published private(set) var phase: Phase
    /// Flips after the minimum display time so a fast start does not flash.
    @Published private(set) var minimumElapsed = false
    /// Set when the real initialisation outruns the animation budget: the
    /// layer stops moving and holds a static mark with a light breath.
    @Published private(set) var degraded = false

    private var coreReady = false
    private var startedAt: Date?
    private var minTimer: Timer?
    private var degradeTimer: Timer?
    private var timersArmed = false

    /// 1.4 s: the launch image hands over a static mark, so anything shorter
    /// reads as a flicker rather than an animation. Still well inside the
    /// 1.2–1.8 s budget once the fade is added.
    private static let minimumDisplay: TimeInterval = 1.4
    /// Past this, stop animating and hold a static mark.
    private static let degradeAfter: TimeInterval = 2.5
    private static let fadeDuration: TimeInterval = 0.45

    /// Decides the very first frame: with the switch off the phase is already
    /// `.finished`, so the launch layer is never created and no timer exists.
    private init() {
        if Self.isEnabled {
            phase = .playing
            startedAt = Date()
            LaunchLog.info("armed (reduceMotion=\(UIAccessibility.isReduceMotionEnabled))")
        } else {
            phase = .finished
            LaunchLog.info("disabled — skipping")
        }
    }

    // MARK: - Timers

    /// Called from the launch view's `onAppear`, i.e. on the first frame the
    /// layer is actually on screen.
    func armTimers() {
        guard phase == .playing, !timersArmed else { return }
        timersArmed = true

        minTimer = Timer.scheduledTimer(withTimeInterval: Self.minimumDisplay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.minimumElapsed = true
                self.advanceIfReady()
            }
        }

        degradeTimer = Timer.scheduledTimer(withTimeInterval: Self.degradeAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .playing else { return }
                self.degraded = true
                LaunchLog.info("degraded — initialisation exceeded \(Self.degradeAfter)s")
            }
        }
    }

    // MARK: - Signals

    /// The root view has produced its first frame. This is the `coreReady`
    /// signal: the session list and the chat surface exist. Background work
    /// (`runtimeReady`: tool registry, shell warm-up, skill scan) deliberately
    /// does **not** gate the transition.
    func markCoreReady() {
        guard !coreReady else { return }
        coreReady = true
        LaunchLog.info("coreReady at +\(Self.elapsed(since: startedAt))s")
        advanceIfReady()
    }

    // MARK: - Transition

    private func advanceIfReady() {
        guard phase == .playing, coreReady, minimumElapsed else { return }
        minTimer?.invalidate(); minTimer = nil
        degradeTimer?.invalidate(); degradeTimer = nil

        phase = .fading
        LaunchLog.info("fading at +\(Self.elapsed(since: startedAt))s")

        Timer.scheduledTimer(withTimeInterval: Self.fadeDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .fading else { return }
                self.phase = .finished
                LaunchLog.info("finished at +\(Self.elapsed(since: self.startedAt))s")
            }
        }
    }

    /// Timers are cancelled when the app goes to the background; the animation
    /// resumes where it left off rather than restarting.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            minTimer?.invalidate(); minTimer = nil
            degradeTimer?.invalidate(); degradeTimer = nil
        case .active:
            guard self.phase == .playing else { return }
            if !minimumElapsed {
                minTimer?.invalidate()
                minTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.minimumElapsed = true
                        self.advanceIfReady()
                    }
                }
            }
        default:
            break
        }
    }

    private static func elapsed(since start: Date?) -> String {
        String(format: "%.2f", Date().timeIntervalSince(start ?? Date()))
    }
}

private enum LaunchLog {
    private static let logger = AppLogger(category: "Launch")
    static func info(_ message: String) { logger.info("[Launch] \(message)") }
}
