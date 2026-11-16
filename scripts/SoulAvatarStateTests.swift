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
        // [T-avatar-idle-static] Idle is the transparent main image composited
        // at runtime over the theme's baked background colour; only the
        // explicit short idle-playback window may show video. The four working
        // states keep their existing animated assets.
        precondition(SoulAvatarIdlePolicy.posterAsset == "SoulAvatar-main")
        precondition(SoulAvatarIdlePolicy.posterBackground(theme: "light")
                     == SoulAvatarIdlePolicy.PosterBackground(red: 251, green: 251, blue: 251))
        precondition(SoulAvatarIdlePolicy.posterBackground(theme: "dark")
                     == SoulAvatarIdlePolicy.PosterBackground(red: 12, green: 10, blue: 20))
        precondition(SoulAvatarIdlePolicy.posterBackground(theme: "unspecified")
                     == SoulAvatarIdlePolicy.PosterBackground(red: 251, green: 251, blue: 251))
        precondition(SoulAvatarIdlePolicy.showsStaticPoster(motion: .idle, idlePlaybackActive: false))
        precondition(!SoulAvatarIdlePolicy.showsStaticPoster(motion: .idle, idlePlaybackActive: true))
        for motion in [SoulAvatarMotion.thinking, .speaking, .working, .celebrate] {
            precondition(!SoulAvatarIdlePolicy.showsStaticPoster(motion: motion, idlePlaybackActive: false),
                         "Only idle may show the static poster: \(motion)")
            precondition(motion.asset.hasPrefix("SoulAvatar-"),
                         "Non-idle states still resolve to animated assets: \(motion)")
        }
        precondition(SoulAvatarIdlePolicy.playbackInterval.lowerBound >= 8
                     && SoulAvatarIdlePolicy.playbackInterval.upperBound <= 15)
        precondition(SoulAvatarIdlePolicy.playbackDuration > 0
                     && SoulAvatarIdlePolicy.playbackDuration <= 3)
        precondition(SoulAvatarIdlePolicy.idlePlaybackDelay(randomUnit: 0) == 8)
        precondition(SoulAvatarIdlePolicy.idlePlaybackDelay(randomUnit: 1) == 15)
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
