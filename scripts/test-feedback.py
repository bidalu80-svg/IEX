#!/usr/bin/env python3
"""Compile feedback policy and typecheck shipping settings/runtime for iOS 16."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
policy = root / "Shared/AppFeedbackPreferences.swift"
with tempfile.TemporaryDirectory(prefix="ze-feedback-") as directory:
    work = Path(directory)
    binary = work / "feedback-policy-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(policy),
                    str(root / "scripts/FeedbackPolicyTests.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    boundary = work / "FeedbackAudioBoundary.swift"
    boundary.write_text("""import Foundation
@MainActor final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    enum Intent { case interfaceFeedback }
    var canPlayInterfaceFeedback = true
    func begin(_ intent: Intent) {}
    func end(_ intent: Intent) {}
}
""", encoding="utf-8")
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    target = ("arm64" if platform.machine() == "arm64" else "x86_64") + "-apple-ios16.0-simulator"
    subprocess.run(["xcrun", "swiftc", "-typecheck", "-D", "DEBUG", "-sdk", sdk, "-target", target,
                    str(policy), str(root / "Shared/AppFeedback.swift"),
                    str(root / "Views/Settings/SoundHapticsSettingsView.swift"), str(boundary)], check=True)

# A direct generator in a new surface would silently defeat the global OFF switch.
needles = ["UIImpactFeedbackGenerator(", "UINotificationFeedbackGenerator(",
           "UISelectionFeedbackGenerator(", "kSystemSoundID_Vibrate", ".sensoryFeedback("]
for folder in ["Views", "Agent", "Shared", "Providers", "NativeOffloads"]:
    for path in (root / folder).rglob("*.swift"):
        if path == root / "Shared/AppFeedback.swift":
            continue
        text = path.read_text(encoding="utf-8")
        assert not any(needle in text for needle in needles), f"Feedback bypasses global settings: {path}"
print("Feedback: all app-authored haptics use the global gate; shipping settings/runtime typechecked for iOS 16")
