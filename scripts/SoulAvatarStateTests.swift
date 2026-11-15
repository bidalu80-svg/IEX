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
        let labels: [(Bool, Bool, Bool, Int, String?, Bool, String?)] = [
            (false, false, false, 0, nil, false, nil),
            (false, true, false, 0, "file_read", false, nil),
            (true, false, false, 0, nil, false, "思考中"),
            (true, true, false, 0, nil, false, "正在回复"),
            (true, true, true, 0, nil, false, "思考中"),
            (true, false, false, 0, "scheduled_task_create", false, "更新定时任务"),
            (true, false, false, 0, "file_read", false, "读取文件"),
            (true, false, false, 0, "printf private-argument", false, "处理中"),
            (true, true, false, 2, "file_read", false, "子任务执行中（2 个）"),
            (false, false, false, 1, nil, false, "子任务执行中"),
            (true, false, true, 0, "ask_user", true, "等待你的回复")
        ]
        for (processing, streaming, awaiting, count, tool, waiting, expected) in labels {
            let actual = SoulHeaderActivity.resolve(processing: processing, streamingText: streaming,
                awaitingResponse: awaiting, childCount: count, toolName: tool, waitingForUser: waiting)
            precondition(actual == expected, "Activity label: expected \(String(describing: expected)), got \(String(describing: actual))")
        }
        print("PASS: \(cases.count) avatar cases and \(labels.count) real activity policy cases")
    }
}
