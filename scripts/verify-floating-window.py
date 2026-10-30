#!/usr/bin/env python3
"""Structural checks for the background floating window (T-floating-window-pip).

The window is Picture in Picture: the conversation is rasterised into a video
stream so the system can float it over other apps (the same trick remote-desktop
apps use). The Live Activity conversation card is only the fallback on devices
where PiP cannot float.

These checks pin the wiring so a refactor cannot silently leave the switch
toggling nothing, the stream without a frame source, or the window alive with no
task running.

Run: python3 scripts/verify-floating-window.py
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
checks = 0
failures = 0


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def check(condition, what):
    global checks, failures
    checks += 1
    if condition:
        print(f"PASS: {what}")
    else:
        print(f"FAIL: {what}")
        failures += 1


def main():
    content_view = read("Views/ContentView.swift")
    manager = read("Agent/Background/AgentLiveActivityManager.swift")
    keep_alive = read("Agent/Background/BackgroundKeepAliveManager.swift")
    attributes = read("Shared/AgentActivityAttributes.swift")
    widget = read("AgentWidget/AgentLiveActivityWidget.swift")
    pip = read("Agent/Background/ChatPiPController.swift")
    plist = read("Info.plist")
    project = read("Ze.xcodeproj/project.pbxproj")

    key = '"backgroundFloatingWindow"'

    # --- Picture in Picture is the actual window ----------------------

    check("AVPictureInPictureController" in pip,
          "the window is a real AVPictureInPictureController")
    check("AVSampleBufferDisplayLayer" in pip,
          "frames go through a sample-buffer layer (custom content, not a video file)")
    check("sampleBufferDisplayLayer: layer" in pip,
          "the controller is built from that layer as its content source")
    check("CMSampleBufferCreateReadyWithImageBuffer" in pip,
          "rasterised frames are wrapped into CMSampleBuffers")
    check("ImageRenderer(content:" in pip,
          "the card is rendered from SwiftUI into pixels")
    check("layer.enqueue(sample)" in pip,
          "frames are pushed into the layer")
    check("import AVKit" in pip and "import AVFoundation" in pip,
          "the controller links AVKit/AVFoundation")

    # --- Background survivability -------------------------------------

    check("<string>audio</string>" in plist,
          "the app declares the audio background mode PiP needs to keep streaming")
    check("SilentAudioKeepAlive" in pip and "setCategory(.playback" in pip,
          "a silent audio session keeps the process alive while the window floats")
    check("willResignActiveNotification" in pip,
          "the window is raised when the app leaves the foreground")
    check("didBecomeActiveNotification" in pip,
          "and torn down when the user comes back")

    # --- It must not outlive the task ---------------------------------

    tick = pip.split("private func tick()", 1)[-1][:900]
    check("sessions.isEmpty" in tick and "teardown()" in tick and "sawActiveSession" in tick,
          "the frame timer closes the window only once a task has ended")
    check("if !forcedPreview {" in tick,
          "the preview keeps the card alive with no task running")
    check("guard Self.isEnabled" in pip,
          "the controller refuses to run with the switch off")
    check("AVPictureInPictureController.isPictureInPictureSupported()" in pip,
          "support is checked before claiming the window exists")

    # --- The switch ---------------------------------------------------

    check("@AppStorage(%s) private var backgroundFloatingWindow: Bool = false" % key in content_view,
          "Appearance owns the switch, defaulting to off")
    check('static let preferenceKey = "backgroundFloatingWindow"' in pip,
          "the controller reads the same key")
    check("ChatPiPController.shared.setPreference(true)" in content_view,
          "flipping the switch on prepares the window")
    check("ChatPiPController.shared.setPreference(false)" in content_view,
          "flipping it off tears it down")
    check("ChatPiPController.shared.preview()" in content_view and "预览悬浮窗" in content_view,
          "there is a preview button so the window can be proven without backgrounding")

    # --- Prepare first, float later (the bug that shipped once) -------

    check("func ensurePrepared()" in pip,
          "the layer is built separately from the PiP request")
    check("func prepareIfEnabled()" in pip and "prepareIfEnabled()" in read("AppDelegate.swift"),
          "the layer is prepared during launch, not when the app is leaving")
    check("sawActiveSession" in pip,
          "an idle launch is not treated as 'the task ended'")
    check("func present(force: Bool = false)" in pip and "startPictureInPicture()" in pip,
          "presenting only asks the system to float an already-rendering layer")
    check("SessionActivityTracker.shared.$activeSessions" in pip,
          "preparation starts as soon as a task starts, while still foreground")
    check("pip.isPictureInPicturePossible" in pip,
          "the request waits until the layer is actually able to float")
    check("retry" in pip and "startRetries" in pip,
          "a not-yet-possible layer is retried instead of failing silently")
    check("window.addSubview(host)" in pip,
          "the layer is attached to the window (PiP refuses an off-screen source)")
    check("host.alpha" not in pip,
          "the host view is not made transparent (that also fails the request)")
    check("func dismiss()" in pip and "func teardown()" in pip,
          "floating and teardown are separate, so re-backgrounding is instant")
    check("forcedPreview" in pip and "present(force: true)" in pip,
          "the preview button floats the card with no task running")
    check(".disabled(!ChatPiPController.isSupported)" in content_view,
          "the switch is disabled where PiP cannot float")
    check("这台设备不支持画中画" in content_view,
          "and explains why instead of doing nothing")

    # --- Shape: a small horizontal strip -------------------------------

    check("static let cardWidth: CGFloat = 480" in pip and "static let cardHeight: CGFloat = 180" in pip,
          "the card is 480x180 — wide and short, not a portrait card")
    check("width: FloatingConversationCard.cardWidth" in pip,
          "the renderer uses that size, so the PiP window inherits the strip shape")
    check("width: 360, height: 480" not in pip,
          "the old portrait size is gone")
    check("design: .monospaced" in pip,
          "the output is monospaced, like a terminal")
    check("model.steps.suffix(9)" in pip,
          "up to nine tool rows fill the strip instead of leaving a void")

    # --- Appearing on the FIRST backgrounding --------------------------

    check("canStartPictureInPictureAutomaticallyFromInline = true" in pip,
          "the system floats the window as the app leaves the foreground")
    check("automatic start did not happen" in pip,
          "a delayed manual request covers the case where it does not")
    check("isPictureInPictureActive != true" in pip,
          "and does not race a start that already happened")
    did_start = pip.split("pictureInPictureControllerDidStartPictureInPicture", 1)[-1][:700]
    check("silentAudio?.start()" in did_start,
          "the keep-alive starts with the window, including the automatic path")

    # --- The Live Activity is only a fallback now ---------------------

    check("static var usesLiveActivityCard: Bool" in manager,
          "the manager decides between PiP and the activity card")
    check("isFloatingWindowEnabled && !ChatPiPController.isSupported" in manager,
          "the activity card is used only when PiP is unavailable")
    check(manager.count("floatingWindow = Self.usesLiveActivityCard") >= 2,
          "both the first frame and every push use that decision")
    check("floatingWindow = Self.isFloatingWindowEnabled" not in manager,
          "the activity card no longer mirrors the raw preference")
    check("var floatingWindow: Bool = false" in attributes,
          "ContentState keeps the flag with a default (old payloads decode)")
    check("var conversationLine: String = \"\"" in attributes,
          "the fallback card still carries the conversation line")
    check("conversationLine" in keep_alive,
          "the snapshot builder fills it")
    check(widget.count("conversationLine") >= 2,
          "the fallback renders it on both surfaces")

    # --- Wiring -------------------------------------------------------

    check("ChatPiPController.swift in Sources" in project,
          "the new controller is compiled into the app target")
    check("Agent/MessageList" not in pip,
          "the controller does not depend on the message list")

    print()
    if failures:
        print(f"{failures} of {checks} checks failed")
        return 1
    print(f"{checks} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
