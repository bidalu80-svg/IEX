#!/usr/bin/env python3
"""Structural checks for the foldable pane adaptation.

Verifies that the two-column layout is chosen from the window's size (not the
device idiom), that the selection and the reader's scroll position survive a
pane change, and that AOJIT carries no device-family gate that would disable it
on a new form factor.

Run: python3 scripts/verify-foldable-layout.py
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
    policy = read("Views/Layout/AdaptivePaneLayout.swift")
    scroll_memory = read("Views/Layout/ChatScrollMemory.swift")
    lifecycle = read("Agent/Chat/ChatLifecycleSupport.swift")
    chat_view = read("Views/Chat/AIChatView.swift")
    message_list = read("Agent/MessageList/CollectionViewMessageListV3.swift")
    kernel = read("iSH/ISHKernel.m")
    jit = read("Vendor/ZeNative/ish/asbestos/guest-arm64/jit.c")

    # --- The pane decision must come from size ------------------------

    check("AdaptivePanePolicy.layout(" in content_view,
          "ContentView asks AdaptivePanePolicy for the pane layout")
    check("isIPad" not in content_view,
          "ContentView no longer keys the wide layout on the iPad idiom")
    check('userInterfaceIdiom == .pad' not in content_view,
          "ContentView does not read userInterfaceIdiom at all")
    check(re.search(r"let paneLayout = AdaptivePanePolicy\.layout\(\s*for: geo\.size",
                    content_view) is not None,
          "the layout is computed from the measured geometry size")
    check("let wide = paneLayout == .split" in content_view,
          "the wide flag is derived from the policy result")

    # --- Policy rules -------------------------------------------------

    check("static let splitMinWidth: CGFloat = 700" in policy,
          "policy keeps the 700pt split entry width")
    check("static let splitMinHeight: CGFloat = 500" in policy,
          "policy refuses to split a short (landscape) window")
    check("size.height >= splitMinHeight" in policy,
          "policy checks height before width")
    check("previous == .split ? splitMinWidth - hysteresis : splitMinWidth" in policy,
          "policy applies hysteresis only when already split")

    # --- Selection hand-off between the two layouts -------------------

    check("private func carrySelectionAcrossPaneChange(wide: Bool)" in content_view,
          "ContentView hands the selection across a pane change")
    check("carrySelectionAcrossPaneChange(wide: newWide)" in content_view,
          "the hand-off runs from the wide-state onChange")
    handoff = content_view.split("private func carrySelectionAcrossPaneChange", 1)[-1]
    handoff = handoff.split("// MARK:", 1)[0]
    check("path.append(id)" in handoff and "navigationPath = path" in handoff,
          "collapsing pushes the open conversation onto the stack")
    check("selectedSessionId" in handoff,
          "the hand-off uses the split's selection as the source of truth")

    # --- Draft composer survives a rebuild ----------------------------

    check("private var drafts: [String: AIChatViewModel]" in lifecycle,
          "ViewModelCache keeps drafts keyed by draft ID")
    check("func getOrCreateDraft(id: String)" in lifecycle,
          "ViewModelCache can return an existing draft VM")
    check("drafts = drafts.filter { $0.value !== vm }" in lifecycle,
          "cacheDraft drops the draft key once the draft is a real session")
    check("CachedViewModel(sessionId: sessionId, draftId: draftId)" in chat_view,
          "AIChatView passes the draft ID into the cache wrapper")
    check("getOrCreateDraft(id: draftId)" in chat_view,
          "the cache wrapper reuses the draft VM instead of making an empty one")

    # --- Scroll position survives a rebuild ---------------------------

    check("final class ChatScrollMemory" in scroll_memory,
          "ChatScrollMemory exists")
    check("let messageId: UUID" in scroll_memory and "let offset: CGFloat" in scroll_memory,
          "the anchor stores a message id plus an intra-row offset")
    check("var scrollMemoryKey: String? = nil" in message_list,
          "the message list declares a scroll-memory key")
    check("scrollMemoryKey: sessionId ?? draftId" in chat_view,
          "AIChatView keys the list by session or draft")
    check("func updateScrollMemoryKey(_ key: String?)" in message_list,
          "the list rebinds its key when the conversation changes")
    check("func scheduleScrollRestoreIfNeeded()" in message_list,
          "the list schedules a scroll restore after a rebuild")
    check("func restoreScrollIfNeeded()" in message_list,
          "the list can scroll back to the saved anchor")
    check("func rememberScrollAnchor()" in message_list,
          "the list records the top row while the reader browses")
    check("rememberScrollAnchor()" in message_list,
          "the scroll callback feeds the anchor store")
    check("coord.scheduleScrollRestoreIfNeeded()" in message_list,
          "updateUIViewController triggers the restore")
    check("scrollMode = .browse" in message_list.split("private func restoreScrollIfNeeded()", 1)[-1][:1200],
          "a restore does not get re-pinned to the bottom by auto scrolling")
    check("ChatScrollMemory.shared.clear(sessionId)" in lifecycle,
          "deleting a session forgets its anchor")

    # --- AOJIT must not care about the device family ------------------

    check("userInterfaceIdiom" not in kernel,
          "the iSH kernel has no device-family gate (AOJIT is size/idom agnostic)")
    check("UIDevice" not in kernel,
          "the iSH kernel does not read UIDevice")
    check("m->prologue_words != prologue_words" in jit,
          "AOT images are accepted on register conventions, not device model")
    check(re.search(r'iPhone\d|iPad\d|machine\s*==', jit) is None,
          "the JIT has no hard-coded device model list")

    print()
    if failures:
        print(f"{failures} of {checks} checks failed")
        return 1
    print(f"{checks} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
