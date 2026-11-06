# Native card source attribution

The question-card view structure, typography, button style and detail-card presentation adapted in `Views/Chat/AssistantBlockView.swift` and `Views/Chat/ZeSubAgentViews.swift` derive from the OpenMinis iOS sources at commit `1a71df0f381cefde80bf912b723de6f9831bc177`:

- `src/ios/Views/Chat/UserAskCardView.swift`
- `src/ios/Views/Chat/HelperBlockView.swift`
- `src/ios/Views/Chat/AIChatView/Sheets/SubAgentRunDetail.swift`

Source: https://github.com/OpenMinis/OpenMinis/tree/1a71df0f381cefde80bf912b723de6f9831bc177/src/ios

The upstream GPL-3.0 license text is preserved in `OpenMinis-LICENSE`. The reference-rendering scripts fetch unmodified declarations from this pinned source and record source hashes. Ze-specific changes adapt state, persistence, queue controls, localization and rendering performance to the existing application.
