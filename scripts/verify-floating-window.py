#!/usr/bin/env python3
"""Structural checks for the background floating window (T-floating-window).

The feature is a Live Activity presentation: with the switch on and a task
running, the card shows the conversation; with no task, nothing is shown. These
checks pin the wiring so a refactor cannot silently drop one half of it (the
switch, the payload, or the two render surfaces).

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

    key = '"backgroundFloatingWindow"'

    # --- The switch lives in Appearance and persists -------------------

    check("@AppStorage(%s) private var backgroundFloatingWindow: Bool = false" % key in content_view,
          "Appearance owns the switch, defaulting to off")
    check("Toggle(isOn: $backgroundFloatingWindow)" in content_view,
          "the Appearance row is a real toggle bound to that key")
    check('"settings.appearance.backgroundFloatingWindow"' in content_view,
          "the toggle has a stable accessibility identifier")
    check("if AgentLiveActivityManager.isLiveActivitySupported {" in content_view,
          "the row is hidden where Live Activities do not exist")
    check('updateLiveActivityIfNeeded(source: "floatingWindowToggle")' in content_view,
          "flipping the switch refreshes a card that is already on screen")
    check("@AppStorage" in content_view and "UserDefaults" not in content_view.split("backgroundFloatingWindow")[0][-400:],
          "persistence is @AppStorage (survives relaunch), not a manual write")

    # --- The manager reads the same key -------------------------------

    check("static var isFloatingWindowEnabled: Bool" in manager,
          "the manager exposes the floating preference")
    check(re.search(
        r'static var isFloatingWindowEnabled: Bool \{\s*\(UserDefaults\.standard\.object\(forKey: "backgroundFloatingWindow"\) as\? Bool\) \?\? false\s*\}',
        manager) is not None,
          "the manager reads the same key with a false default")
    check("return isFloatingWindowEnabled" in manager,
          "asking for the floating card is enough to create the activity")
    check("state.floatingWindow = Self.isFloatingWindowEnabled" in manager,
          "every pushed state carries the current preference")
    check(manager.count("floatingWindow = Self.isFloatingWindowEnabled") >= 2,
          "the first frame of a new activity carries it too (no flash of the old layout)")

    # --- Payload ------------------------------------------------------

    check("var floatingWindow: Bool = false" in attributes,
          "ContentState carries the flag with a default (old payloads decode)")
    check("var conversationLine: String = \"\"" in attributes,
          "the snapshot carries the conversation line with a default")
    check("conversationLine" in keep_alive and "AgentLiveActivityManager.conversationLine(for: sid)" in keep_alive,
          "the snapshot builder fills the conversation line")
    check("static func conversationLine(for sessionId: String) -> String?" in manager,
          "the conversation line is resolved from the session's view model")
    check("ViewModelCache.shared.get(for: sessionId)" in manager,
          "it reads the cached view model rather than inventing text")

    # --- Both surfaces render it --------------------------------------

    check(widget.count("floatingWindow") >= 4,
          "the island compact, expanded and the lock screen all branch on the flag")
    check(widget.count("conversationLine") >= 2,
          "the conversation line is rendered on both surfaces")
    check("bubble.left.and.text.bubble.right.fill" in widget,
          "the compact leading slot becomes a conversation glyph")
    check(widget.count("!context.state.floatingWindow") >= 1,
          "the session counter is hidden in floating mode")

    # --- Nothing claims a draggable overlay ---------------------------

    # iOS cannot draw over other apps; the footer must say so instead of
    # promising it. (A silent mismatch here would read as a broken feature.)
    footer_idx = content_view.find('Text("任务运行时')
    footer = content_view[footer_idx:footer_idx + 900] if footer_idx >= 0 else ""
    check("灵动岛" in footer and "锁屏" in footer,
          "the footer names the surfaces the card actually appears on")
    check("不允许" in footer,
          "the footer states that iOS has no true overlay window")

    print()
    if failures:
        print(f"{failures} of {checks} checks failed")
        return 1
    print(f"{checks} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
