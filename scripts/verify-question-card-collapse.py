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

# 4. Choices are staged. Single/multiple selections require the explicit
#    primary action; the previous auto-submit timer could confirm a mis-tap.
assert "private func optionRow" in view
assert "submitCurrentAnswer()" in view
choice = view[view.index("private func optionRow"):view.index("private var otherRow")]
assert "submitCurrentAnswer()" not in choice
assert "onDraft(a.draft)" in choice
assert "q.multiSelect" in choice
assert "QuestionAnswerInputSheet" in view
assert "coordinator.navigate(requestId:" in view
assert "questionIndex: card.currentIndex" in view
assert "case .options: optionsBody" in view
assert "case .confirm: confirmBody" in view
assert "raw.optionDescriptions" in view
assert "max(160, UIScreen.main.bounds.height * 0.5 - 120)" in view
assert "QuestionPendingBodyLayout" in view
assert "QuestionPendingLayoutCache.bodyHeight(key, width: width, bodyFont: bodyFont)" in view
assert "QuestionAskLocalized(\"Recommended\")" in view
assert "questionFullHeight > questionClampedHeight + 1" in view
assert "ViewThatFits(in: .horizontal)" in view
assert "Capsule(style: .continuous)" in view

# 5. Wrapped text is measured for the height estimate; no fixed 42pt row.
estimate = layout[
    layout.index("static func estimateQuestionCardHeight"):
    layout.index("static func estimateTextBlockHeight")
]
assert "questionTextHeight" in estimate
assert "QuestionPendingLayoutCache.bodyHeight" in estimate
assert "chrome + min(" in estimate
assert "CGFloat(question.options.count) * 42" not in estimate

# 6. The host sheet renders the full card, not `block.content`.
assert "QuestionCardDetailView" in view
assert "QuestionCardDetailView(block: block)" in sheet
assert "if block.kind.isQuestionCardTool {" in sheet

# 7. Option text is split only at the top level. The model writes a single
#    option as "free 生图/gpt-image-2（默认，约 941×1672）"; splitting on every
#    comma rendered that one answer as two radio rows on device.
assert "private static func splitOptionList" in lifecycle
assert "let options = splitOptionList(" in lifecycle
assert '.split(whereSeparator: { $0 == "|" || $0 == "、" || $0 == "," || $0 == "，" })' not in lifecycle
assert '"（", "(", "【", "[", "「"' in lifecycle
assert '"）", ")", "】", "]", "」"' in lifecycle

# 8. The resolved card follows one summary row with an aligned answer sheet,
#    not a stack of nested panels. Only the resolved face has a collapse control.
assert "private func answerSheet" in view
assert "resolvedQuestionRow(card, index: index)" in view
assert ".frame(width: 3)" not in view
# Multi-question summaries count answers instead of joining every answer into
# one truncated subtitle line.
assert '\\(card.answeredCount)/\\(card.questions.count)' in view
assert ".padding(.leading, 46)" in view

print("question-card checks passed")
