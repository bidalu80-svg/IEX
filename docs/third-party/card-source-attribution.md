# Native card source attribution

The question-card view structure, typography, button style and detail-card presentation adapted in `Views/Chat/AssistantBlockView.swift` and `Views/Chat/ZeSubAgentViews.swift` derive from the OpenMinis iOS sources at commit `1a71df0f381cefde80bf912b723de6f9831bc177`:

- `src/ios/Views/Chat/UserAskCardView.swift`
- `src/ios/Views/Chat/HelperBlockView.swift`
- `src/ios/Views/Chat/AIChatView/Sheets/SubAgentRunDetail.swift`
- `src/ios/Views/Chat/ChatShareModel.swift`
- `src/ios/Views/Chat/ChatShareSelectionView.swift`
- `src/ios/Views/Chat/ChatExportRenderer.swift`
- `src/ios/Views/Chat/AIChatView/Overlays/ChatSearchBar.swift`
- `src/ios/Agent/MessageList/CollectionViewMessageListV3/Search/`
- `src/ios/Agent/MessageList/CollectionViewMessageListV3/Coordinator/MessageListV3Coordinator+Search.swift`
- `src/ios/Views/Chat/Markdown/TextKit/SelectableMarkdownTextView+SearchHighlight.swift`

The conversation sharing model, selection/preview controls, export pipeline, in-chat search matching/navigation and highlight drawing are also adapted from this pinned source. The matching Simplified Chinese translations are drawn from its `Localizable.xcstrings`. Ze adapters retain its existing message types, provider view model and tool renderer. See `docs/share-search-acceptance.md` for the behavioral and verification scope.
- `src/ios/Views/Chat/ChatShareModel.swift`
- `src/ios/Views/Chat/ChatShareSelectionView.swift`
- `src/ios/Views/Chat/ChatExportRenderer.swift`

Source: https://github.com/OpenMinis/OpenMinis/tree/1a71df0f381cefde80bf912b723de6f9831bc177/src/ios

The upstream GPL-3.0 license text is preserved in `OpenMinis-LICENSE`. The reference-rendering scripts fetch unmodified declarations from this pinned source and record source hashes. Ze-specific changes adapt state, persistence, queue controls, localization and rendering performance to the existing application.
