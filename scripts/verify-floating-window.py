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
    check("forcedPreview" not in pip,
          "there is no preview mode: the window follows tasks and nothing else")
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
    check("预览悬浮窗" not in content_view and "ChatPiPController.shared.preview()" not in content_view,
          "the preview button is gone — it floated a placeholder that proved nothing")
    check('Text("后台终端悬浮窗口")' in content_view,
          "the section and the switch both use the new name")

    # --- Prepare first, float later (the bug that shipped once) -------

    check("func ensurePrepared()" in pip,
          "the layer is built separately from the PiP request")
    check("func prepareIfEnabled()" in pip and "prepareIfEnabled()" in read("AppDelegate.swift"),
          "the layer is prepared during launch, not when the app is leaving")
    check("sawActiveSession" in pip,
          "an idle launch is not treated as 'the task ended'")
    check("func present()" in pip and "startPictureInPicture()" in pip,
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
    check("present(force:" not in pip and "func present()" in pip,
          "presenting has one path — no forced start that bypasses the task check")
    check("forcedPreview" not in pip and "present(force" not in pip,
          "no code path can float a card with nothing running")
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

    check("canStartPictureInPictureAutomaticallyFromInline =" in pip
          and "!SessionActivityTracker.shared.activeSessions.isEmpty" in pip,
          "auto-float is armed only while a task runs")
    check("pip?.canStartPictureInPictureAutomaticallyFromInline = false" in pip,
          "and is disarmed on teardown, so an idle backgrounding shows nothing")
    check("if !SessionActivityTracker.shared.activeSessions.isEmpty {\n            renderFrame()" in pip,
          "an idle prepare leaves the layer empty (nothing to float)")
    resign = pip.split("willResignActiveNotification", 1)[-1][:900]
    check("self.present()" in resign,
          "leaving the foreground asks for the window directly, as insurance")
    check("self.ensurePrepared()" in resign,
          "and only after the layer is ready")
    did_start = pip.split("pictureInPictureControllerDidStartPictureInPicture", 1)[-1][:700]
    check("startAudioIfNeeded()" in did_start,
          "the keep-alive starts with the window, including the automatic path")
    sink = pip.split("private func observeSessions()", 1)[-1][:1600]
    check("self.startAudioIfNeeded()" in sink and "self.enableAutomaticStart(true)" in sink,
          "a task that starts brings up audio and auto-float while still in the foreground")
    # A playback range with no length is what a grey spinner looks like in
    # code: Picture in Picture reads it as "nothing to play" and never draws a
    # single queued frame, while the layer still reports `rendering` and the
    # timer keeps counting. This assertion used to demand the opposite, which
    # is why every check passed while the window stayed blank.
    check("CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)" in pip,
          "the playback range is indefinite, so the system presents the frames")
    check("CMTimeRange(start: .zero, duration: .zero)" not in pip,
          "the playback range never collapses to zero — that turns the window into a spinner")

    # --- The frames actually reach the screen -------------------------

    # A sample-buffer layer with no timebase queues frames that never become
    # "due": the window opens as a grey card with a spinner.
    check("CMTimebaseCreateWithSourceClock" in pip and "layer.controlTimebase = timebase" in pip,
          "the sample-buffer layer gets a timebase before any frame is queued")
    check("CMTimebaseGetTime" in pip and "presentationTimeStamp: presentationTime" in pip,
          "each frame is stamped with the layer clock reading, so it is always current")
    check("CMTime(value: index, timescale:" not in pip,
          "timestamps are no longer counted per frame, which falls behind on any throttled tick")
    check("CMTimeMaximum(now, CMTimeAdd(lastPresentationTime" in pip,
          "two frames never share a timestamp, which the layer would drop")
    check("frameIndex += 1" in pip, "frames are still counted, for the diagnostic line")
    check("kCVPixelBufferMetalCompatibilityKey" in pip,
          "the buffer is displayable by the render path")
    check("kCMSampleAttachmentKey_DisplayImmediately" in pip,
          "frames display on arrival instead of waiting for the timebase")
    check("duration: CMTime(value: 1, timescale: 2)" in pip,
          "a frame lasts half a second, which covers two ticks at 4 fps")
    check("24 * 60 * 60" not in pip,
          "the frame duration is not inflated to hours — that reads as 'no video' and pins the "
          "window on Picture in Picture's spinner")
    check("timeInterval: 0.25" in pip,
          "the card is rendered at 4 fps, so the half-second duration always overlaps")
    check("for delay in [0.2, 0.6, 1.2]" in pip,
          "frames keep arriving while the window animates in, not just once at the start")
    check("0.5s/帧" in pip,
          "the diagnostic line names the frame duration, so a report identifies the build")
    check("flushAndRemoveImage()" in pip and "requiresFlushToResumeDecoding" in pip,
          "a failed layer is rebuilt with a fresh clock, not merely flushed")
    check("lastPresentationTime = .invalid" in pip,
          "a rebuilt clock resets the stamp, since it starts again at zero")
    check("updateDiagnostic()" in pip and "pipController.diagnostic" in content_view,
          "the switch section shows live frame/layer state for device debugging")
    present_body = pip.split("func present()", 1)[-1][:2200]
    check(present_body.count("renderFrame()") >= 2,
          "presenting renders a frame first, so the window never opens on an empty layer")
    check("[PiP] first frame" in pip and "[PiP] render produced no image" in pip,
          "the first frame and a failed render are both logged, so a blank window is diagnosable")

    # --- A second window is not born without a clock -------------------

    teardown_body = pip.split("func teardown()", 1)[-1][:900]
    check("timebase = nil" in teardown_body,
          "teardown drops the timebase with the layer, so the next one reconfigures")
    check("frameIndex = 0" in teardown_body,
          "and the frame counter restarts with the new timebase")
    check("lastPresentationTime = .invalid" in teardown_body,
          "as does the remembered stamp, so the first frame of the next session is accepted")

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
