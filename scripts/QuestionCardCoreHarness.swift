// Compiled against an extracted, unmodified shipping core (Foundation only).
import Foundation

@main struct QuestionCardCoreHarness {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); count += 1; print("PASS \(label)")
        }
        check(QuestionCardNotificationIdentity.matches(sessionId: "child", questionIndex: 1, expectedSessionId: "child", expectedIndex: 1), "notification matches owning session and displayed question")
        check(!QuestionCardNotificationIdentity.matches(sessionId: "parent", questionIndex: 1, expectedSessionId: "child", expectedIndex: 1), "notification cannot answer another session")
        check(!QuestionCardNotificationIdentity.matches(sessionId: "child", questionIndex: 0, expectedSessionId: "child", expectedIndex: 1), "stale notification question rejected")
        check(!QuestionCardNotificationIdentity.matches(sessionId: "child", questionIndex: nil, expectedSessionId: "child", expectedIndex: 1), "legacy notification without question identity rejected")
        let rich = #"[{"id":"features","header":"Features","question":"Select features","options":[{"label":"Search","description":"Find notes"},"Export"],"multi_select":true}]"#
        let questions = QuestionCardParser.questions(from: ["questions": rich])
        check(questions.count == 1 && questions[0].multiSelect, "structured multi-select parses")
        check(questions[0].header == "Features", "structured question header retained")
        check(questions[0].options == ["Search", "Export"], "object and legacy string options both survive")
        check(questions[0].optionDescriptions.first! == "Find notes", "option descriptions retained")
        var draft = QuestionCardDraft(selectedIndices: [1, 0, 1])
        check(draft.answer(for: questions[0]) == "Search；Export", "multiple answers are unique and in display order")
        draft.otherText = "Custom"; draft.note = "Please keep data"
        check(draft.answer(for: questions[0]) == "Search；Export；其他：Custom；补充说明：Please keep data", "other and notes are returned with selected choices")
        draft.delegated = true
        check(draft.answer(for: questions[0]) == "由你决定。补充说明：Please keep data", "delegation is explicit and never a hidden selection")
        let single = QuestionCardQuestion(id: "q", prompt: "One", options: ["A", "B"])
        check(!QuestionCardDraft(selectedIndices: [0, 1]).isComplete(for: single), "single-choice rejects multiple selections")
        check(!QuestionCardDraft(selectedIndices: [-1]).isComplete(for: single), "invalid selected index rejected")
        check(!QuestionCardDraft().isComplete(for: single), "empty draft is not an answer")
        check(QuestionCardDraft(otherText: "Custom").isComplete(for: single), "freeform answer supported")
        let confirm = QuestionCardParser.questions(from: ["questions": [["type": "confirm", "question": "Proceed?", "impact": "Changes data", "risk": "high"]]])[0]
        check(confirm.isConfirmation && confirm.options == ["取消", "允许"], "confirmation has explicit deny/allow choices")
        check(confirm.impact == "Changes data" && confirm.risk == "high", "confirmation context retained")
        check(!QuestionCardDraft(delegated: true).isComplete(for: confirm), "confirmation cannot be delegated")
        check(!QuestionCardDraft(otherText: "maybe").isComplete(for: confirm), "confirmation requires an explicit choice")
        check(QuestionCardDraft(selectedIndices: [0]).answer(for: confirm) == "取消", "deny remains a real answer")
        var decisionState = QuestionCardState(requestId: "decisions", title: "Confirm", questions: [confirm], timeoutAt: .distantFuture)
        check(decisionState.submit(answer: "取消；补充说明：保留数据", at: 0), "canonical deny with note accepted")
        check(decisionState.confirmationDecision(at: 0) == "deny", "live confirmation uses explicit decision")
        decisionState.confirmationDecisions = nil
        decisionState.answers = ["取消了什么只是普通文本"]
        check(decisionState.confirmationDecision(at: 0) == nil, "arbitrary localized prefix never becomes denial")
        decisionState.answers = ["允许"]
        check(decisionState.confirmationDecision(at: 0) == "allow", "legacy canonical option remains compatible")
        let wire = "{\"confirmed\":true,\"source\":\"notification\",\"answers\":[{\"id\":\"\(confirm.id)\",\"answer\":\"Denied\",\"decision\":\"deny\"}]}"
        QuestionCardParser.apply(resultJSON: wire, to: &decisionState)
        check(decisionState.confirmationDecision(at: 0) == "deny", "structured decision survives translated display answer")
        check(decisionState.resolutionSource == "notification", "tool result source restored")
        let duplicates: [[String: Any]] = [["id":"same", "question":"A"], ["id":"same", "question":"B"]]
        check(QuestionCardParser.questions(from: ["questions": duplicates]).isEmpty, "duplicate IDs rejected instead of misbinding answers")
        check(QuestionCardParser.questions(from: ["questions": (0..<9).map { "Question \($0)" }.joined(separator:"\n")]).isEmpty, "legacy oversized batch rejected")
        check(QuestionCardParser.questions(from: ["questions": (0..<9).map { ["question":"Q\($0)"] }]).isEmpty, "structured oversized batch rejected")
        check(QuestionCardParser.questions(from: ["questions": #"[{"question":"valid"},{"options":["bad"]}]"#]).isEmpty, "invalid structured questions are not silently omitted")
        let legacy = QuestionCardParser.questions(from: ["questions":"Style || A（red, blue） | B"])
        check(legacy[0].options == ["A（red, blue）", "B"], "legacy nested option punctuation preserved")
        let oldQuestion = Data(#"{"id":"q1","prompt":"Old","options":["A","B"]}"#.utf8)
        let decodedOld = try JSONDecoder().decode(QuestionCardQuestion.self, from: oldQuestion)
        check(!decodedOld.multiSelect, "old saved question remains decodable")

        let id = "harness-\(UUID())"
        defer {
            UserDefaults.standard.removeObject(forKey: "question-card.state." + id)
            UserDefaults.standard.removeObject(forKey: "question-card.drafts." + id)
        }
        let args: [String: Any] = ["questions": "First || A | B\nSecond"]
        var state = QuestionCardParser.state(requestId: id, arguments: args, timeout: 900)!
        check(state.submit(answer: "A", at: 0), "first submitted answer advances")
        check(!state.submit(answer: "stale notification", at: 0), "old notification index cannot answer next question")
        check(state.navigate(to: 0), "previous question can be revisited")
        check(state.answers[0] == "A", "navigation retains previous submitted answer")
        check(state.submit(answer: "B", at: 0) && state.status == .pending, "editing earlier answer does not confirm whole card")
        check(!state.submit(answer: "late", at: 1, now: state.timeoutAt), "deadline rejects late answers")
        check(state.answers[1] == nil, "rejected answers do not mutate next question")
        state.answers[0] = "A"; state.currentIndex = 1
        QuestionCardPersistence.save(state)
        check(QuestionCardPersistence.load(id)?.status == .pending, "same-process live snapshot stays pending")
        QuestionCardPersistence.saveDraft(requestId: id, questionIndex: 1, draft: QuestionCardDraft(otherText: "unfinished"))
        check(QuestionCardPersistence.draft(requestId: id, questionIndex: 1).otherText == "unfinished", "draft survives re-render and navigation")
        // An old-format pending snapshot has no live continuation after relaunch.
        UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: "question-card.state." + id)
        let restored = QuestionCardParser.restoredState(requestId: id, arguments: args, timeout: 900)
        check(restored?.status == .unconfirmed && restored?.resolutionSource == "interrupted", "orphan request explicitly expires after relaunch")
        check(restored?.answers[0] == "A", "partial submitted answer is preserved on expiration")
        var resolved = restored!
        QuestionCardParser.apply(resultJSON: #"{"confirmed":true,"answers":[{"id":"q1","answer":"B"},{"id":"q2","answer":"Done"}]}"#, to: &resolved)
        check(resolved.status == .confirmed && resolved.answers == ["B", "Done"], "persisted real tool result overrides expired preview")
        print("PASS \(count) question-card core checks")
    }
}
