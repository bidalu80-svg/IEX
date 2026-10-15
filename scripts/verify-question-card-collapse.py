#!/usr/bin/env python3
from pathlib import Path

view = Path("Views/Chat/AssistantBlockView.swift").read_text(encoding="utf-8")
layout = Path("Agent/MessageList/CollectionViewMessageListV3.swift").read_text(encoding="utf-8")
models = Path("Agent/Chat/ChatModels.swift").read_text(encoding="utf-8")

start = view.index("private func collapsedCardContent")
end = view.index("private func answerHistory", start)
collapsed = view[start:end]
assert "answerHistory(card)" not in collapsed, "collapsed content still renders full answer history"
assert "collapsedStatusSummary" in collapsed, "collapsed progress summary missing"
assert "collapsedAnswerDetail" in collapsed, "collapsed answer detail missing"

estimate = layout[layout.index("static func estimateQuestionCardHeight"):layout.index("static func estimateTextBlockHeight")]
collapsedBranch = estimate[estimate.index("guard expanded else"):estimate.index("guard card.status == .pending")]
assert "compactContent" in collapsedBranch, "collapsed estimator is not compact"
assert "history +" not in collapsedBranch, "collapsed estimator still includes history height"
assert "isQuestionCardExpanded" in models, "expanded state is not model-owned"
assert "questionCardToggled" in layout, "collection view is not observing question card toggles"
print("question-card-collapse checks passed")
