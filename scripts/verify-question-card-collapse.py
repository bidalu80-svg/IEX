#!/usr/bin/env python3
"""Structural regression checks for the interactive question card.

These are source-level invariants that are cheap to verify without an iOS
build host. They cover the behaviours that regressed before:

* a resolved card must collapse even when the coordinator's weak block
  reference is stale;
* the manual collapse choice must survive a relaunch;
* the collapsed header must still show the question, not only the status;
* long options must be measured with wrapping, not counted as one row;
* the host preview must render the card instead of the tool's status word.
"""
from pathlib import Path

view = Path("Views/Chat/AssistantBlockView.swift").read_text(encoding="utf-8")
layout = Path("Agent/MessageList/CollectionViewMessageListV3.swift").read_text(encoding="utf-8")
models = Path("Agent/Chat/ChatModels.swift").read_text(encoding="utf-8")
lifecycle = Path("Agent/Chat/ChatLifecycleSupport.swift").read_text(encoding="utf-8")
sheet = Path("Views/Chat/ToolLiveSheet.swift").read_text(encoding="utf-8")

# 1. The view itself collapses on the status transition, not only the
#    coordinator (whose block reference is weak).
assert "if newValue.status != .pending" in view
assert "setExpanded(false, haptic: false)" in view
assert "QuestionCardExpansionStore.setExpanded" in view

# 2. Expansion is persisted per request and restored from the model.
assert "QuestionCardExpansionStore.isExpanded" in lifecycle
assert "isQuestionCardExpanded" in models
assert "isQuestionCardExpanded" in layout

# 3. The collapsed header always renders the question.
assert "card.displayQuestion" in view
assert "var displayQuestion" in lifecycle
assert "var chromeTitle" in lifecycle
assert "var summaryText" in lifecycle

# 4. Selecting an option submits (and therefore collapses) without a second
#    tap, while free text still uses the primary button.
assert "private func chooseOption" in view
assert "submitCurrentAnswer()" in view
assert "sleep(nanoseconds: 170_000_000)" in view

# 5. Wrapped text is measured for the height estimate; no fixed 42pt row.
estimate = layout[
    layout.index("static func estimateQuestionCardHeight"):
    layout.index("static func estimateTextBlockHeight")
]
assert "questionTextHeight" in estimate
assert "min(total * 1.10" in estimate
assert "CGFloat(question.options.count) * 42" not in estimate

# 6. The host sheet renders the full card, not `block.content`.
assert "QuestionCardDetailView" in view
assert "QuestionCardDetailView(block: block)" in sheet
assert "if block.kind.isQuestionCardTool {" in sheet

print("question-card checks passed")
