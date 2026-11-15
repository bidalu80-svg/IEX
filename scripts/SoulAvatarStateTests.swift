import Foundation

@main enum SoulAvatarStateTests {
    static func main() {
        let cases: [(Bool, Bool, Bool, Bool, SoulAvatarMotion)] = [
            (false, false, false, false, .idle),
            (false, true, false, false, .idle),
            (true, false, false, false, .thinking),
            (true, true, false, false, .speaking),
            (true, true, false, true, .thinking),
            (true, false, false, true, .thinking),
            (false, false, true, false, .working),
            (true, true, true, false, .working),
            (true, false, true, true, .working)
        ]
        for (processing, text, child, awaiting, expected) in cases {
            let actual = SoulAvatarMotion.resolve(processing: processing, streamingText: text,
                                                   childrenActive: child, awaitingResponse: awaiting)
            precondition(actual == expected, "Expected \(expected), got \(actual)")
        }
        print("PASS: idle, streaming, tool-followup waiting and child priority (\(cases.count) cases)")
    }
}
