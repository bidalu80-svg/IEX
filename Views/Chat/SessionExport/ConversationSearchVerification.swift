#if DEBUG
import SwiftUI
import UIKit

/// Executes shipping search/model/TextKit/collection code inside the built app.
@MainActor enum ConversationSearchVerification {
    private static var checks = 0
    private static func require(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw NSError(domain: "ConversationSearchVerification", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private static func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    static func run() async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("search-verification")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var images: [String] = []
        var window: UIWindow?
        do {
            let vm = AIChatViewModel()
            var messages: [ChatMessage] = []
            for index in 0..<18 {
                messages.append(ChatMessage(role: .user, content: "第 \(index) 轮问题"))
                messages.append(ChatMessage(role: .assistant, content: "", blocks: [AssistantBlock(kind: .text, content: "第 \(index) 轮正文。" + String(repeating: "布局验证内容，保持真实消息高度。", count: 12))]))
            }
            let markdown = "**Café** needle needle\n\n`needle` [visible](https://hidden.invalid/needle)\n\n```swift\nlet needle = 1\n```\n\n| 名称 | 值 |\n| --- | --- |\n| needle | 42 |\n"
            let block = AssistantBlock(kind: .text, content: markdown)
            block.cachedMarkdown = MarkdownContent(prepareMarkdownForRender(markdown))
            let tool = AssistantBlock(kind: .shellTool(command: "hidden-command"), content: "hidden-output", toolStatus: .success)
            tool.toolSummary = "visible-tool needle"
            let assistant = ChatMessage(role: .assistant, content: "", blocks: [block, tool])
            messages.insert(assistant, at: 8)
            vm.messages = messages
            vm.chatSearch.bind(viewModel: vm)
            vm.chatSearch.activate()
            vm.chatSearch.query = "needle"
            await settle()
            try require(vm.chatSearch.hits.count == 6, "Visible prose/code/table/tool occurrences counted exactly; hidden link URL omitted")
            try require(vm.chatSearch.currentIndex == 5, "New query selects newest occurrence")
            try require(!vm.chatSearch.hits.contains(where: { $0.text.contains("hidden-output") }), "Hidden tool output excluded")
            let old = vm.chatSearch.current?.match
            vm.chatSearch.step(-1)
            try require(vm.chatSearch.current?.match != old, "Previous changes occurrence identity")
            let selected = vm.chatSearch.current?.match
            block.content += "\n\nnew streamed needle"
            block.cachedMarkdown = MarkdownContent(prepareMarkdownForRender(block.content))
            await settle()
            try require(vm.chatSearch.hits.count == 7, "Streaming recomputes result count")
            try require(vm.chatSearch.current?.match == selected, "Streaming preserves current occurrence")
            vm.chatSearch.query = "stale query"
            vm.chatSearch.query = "Café"
            await settle()
            try require(vm.chatSearch.hits.count == 1 && vm.chatSearch.current?.keyword == "Café", "Cancelled query never overwrites new result")
            vm.chatSearch.query = "needle"
            vm.chatSearch.deactivate()
            await settle()
            try require(vm.chatSearch.hits.isEmpty && !vm.chatSearch.isActive, "Closing cancels pending search")
            let other = ChatSearchHighlightCenter()
            let key = ChatSearchUnitKey(messageId: assistant.id, blockId: block.id, field: .body)
            let independent = other.token(for: key)
            vm.chatSearch.activate(prefill: "needle")
            await settle()
            try require(independent.state == nil, "Other conversation center stays clear")

            // Real collection view and real Markdown rendering, no replacement views.
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw NSError(domain: "Search", code: 0) }
            let activeWindow = UIWindow(windowScene: scene)
            activeWindow.frame = scene.coordinateSpace.bounds
            activeWindow.windowLevel = .alert + 1
            let host = UIHostingController(rootView: VStack(spacing: 0) {
                ChatSearchOverlay(model: vm.chatSearch, onJump: { _ in }, onClose: {})
                CollectionViewMessageListV3(vm: vm, inputFocused: false, maxContentWidth: 0, floatingBarHeight: 0, inputBarHeight: 0)
            }.environmentObject(vm).background(Color(uiColor: .systemBackground)))
            activeWindow.rootViewController = host
            activeWindow.makeKeyAndVisible(); window = activeWindow
            await settle(1.2)
            let target = vm.chatSearch.hits.first { $0.blockId == block.id && $0.match.ordinal == 1 }!
            vm.chatSearch.select(target)
            await settle()
            let all = descendants(host.view)
            guard let collection = all.compactMap({ $0 as? UICollectionView }).first else { throw NSError(domain: "Search", code: 1, userInfo: [NSLocalizedDescriptionKey: "Real collection view missing"]) }
            let textViews = descendants(collection).compactMap { $0 as? SelectableMarkdownTextView }
            guard let rendered = textViews.first(where: { $0.searchUnitKey == key }) else { throw NSError(domain: "Search", code: 2, userInfo: [NSLocalizedDescriptionKey: "Search navigation did not reveal target Markdown block"]) }
            rendered.refreshSearchHighlight()
            let immutable = NSAttributedString(attributedString: rendered.textStorage)
            let originalSize = collection.contentSize
            try require(rendered.searchHits.count == 6, "Actual rendered Markdown agrees with search projection after stream")
            try require(rendered.searchHighlightCurrentOrdinal == 1, "Actual TextKit current mark is second duplicate")
            try require(rendered.searchHits.filter { $0.attachmentIndex != nil }.count == 2, "Code and table each map to their real attachment")
            try require(rendered.searchHighlightLayer?.path != nil, "Matching code/table outlines are drawn")
            let highlightedHeight = rendered.sizeThatFits(CGSize(width: rendered.bounds.width, height: .greatestFiniteMagnitude)).height
            var siblingEvents = 0
            let siblingKey = ChatSearchUnitKey(messageId: assistant.id, blockId: tool.id, field: .body)
            let siblingSubscription = vm.chatSearch.highlights.token(for: siblingKey).$state.dropFirst().sink { _ in siblingEvents += 1 }
            vm.chatSearch.select(vm.chatSearch.hits.first { $0.blockId == block.id && $0.match.ordinal == 2 }!)
            await settle(0.1)
            try require(siblingEvents == 0, "Moving inside one block does not publish unrelated tool highlights")
            try require(rendered.textStorage.isEqual(to: immutable), "Moving highlight does not mutate attributed storage")
            try require(abs(rendered.sizeThatFits(CGSize(width: rendered.bounds.width, height: .greatestFiniteMagnitude)).height - highlightedHeight) < 0.5, "Moving highlight preserves text layout height")
            siblingSubscription.cancel()
            vm.chatSearch.select(target)
            await settle(0.1)
            if let rect = rendered.searchMatchRect(ordinal: 1) {
                let contentRect = rendered.convert(rect, to: collection)
                let visible = CGRect(origin: CGPoint(x: collection.contentOffset.x, y: collection.contentOffset.y + collection.adjustedContentInset.top), size: CGSize(width: collection.bounds.width, height: collection.bounds.height - collection.adjustedContentInset.top - collection.adjustedContentInset.bottom))
                try require(visible.intersects(contentRect), "Exact match rectangle is inside actual collection viewport")
            } else { try require(false, "Duplicate occurrence has no TextKit rectangle") }
            func capture(_ name: String) throws {
                let renderer = UIGraphicsImageRenderer(bounds: activeWindow.bounds)
                let image = renderer.image { _ in activeWindow.drawHierarchy(in: activeWindow.bounds, afterScreenUpdates: true) }
                guard let png = image.pngData() else { throw NSError(domain: "Search", code: 3) }
                try png.write(to: directory.appendingPathComponent(name)); images.append(name)
            }
            try capture("search-current-duplicate.png")
            let beforeOffset = collection.contentOffset
            vm.chatSearch.deactivate()
            await settle()
            try require(rendered.textStorage.isEqual(to: immutable), "Close preserves original text, font, link, code backgrounds and attachments")
            try require(rendered.searchHits.isEmpty && (rendered.layoutManager as? ZeLayoutManager)?.searchHighlightRanges.isEmpty == true, "Close removes all search paint")
            try require(abs(collection.contentOffset.y - beforeOffset.y) < 2, "Closing leaves scroll position unchanged")
            try require(abs(collection.contentSize.height - originalSize.height) < 2, "Highlight removal does not relayout transcript")
            try capture("search-closed-restored.png")
            let result: [String: Any] = ["success": true, "checks": checks, "screenshots": images, "scope": "Actual application model, production search projection and TextKit, live collection navigation. No provider/network requests or device FPS claim."]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        } catch {
            let result: [String: Any] = ["success": false, "checks": checks, "error": error.localizedDescription, "screenshots": images]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"))
        }
        window?.isHidden = true
    }
}
#endif
