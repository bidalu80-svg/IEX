#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text()


def section(text, start, end):
    offset = text.index(start)
    return text[offset:text.index(end, offset)]


def check(description, condition):
    assert condition, description
    print(f"PASS: {description}")


def without_swift_comments(text):
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)


chat = source("Views/Chat/AIChatView.swift")
settings = source("Views/ContentView.swift")
v3 = source("Agent/MessageList/CollectionViewMessageListV3.swift")
infra = source("Agent/MessageList/MessageListInfrastructure.swift")
layout = source("Agent/MessageList/MessageListLayout.swift")
search = source("Views/Chat/ChatSearch.swift")
share = source("Views/Chat/SessionExport/ChatExportRenderer.swift")
assistant = source("Views/Chat/AssistantBlockView.swift")
markdown = source("Views/Chat/SelectableMarkdownView.swift")
message_views = source("Views/Chat/ChatMessageViews.swift")
vm = source("Agent/Chat/AIChatViewModel.swift")
parser = source("Agent/Markdown/ZeMarkdownParser.swift")
media = source("Views/Chat/ZeMediaViews.swift")
video = source("Views/Chat/Media/VideoPlayer.swift")

preference = "@AppStorage(ChatTranscriptDisplayMode.preferenceKey)"
check("appearance alone offers the default-standard, local enum preference",
      '"chat.transcriptDisplayMode"' in infra and settings.count(preference) == chat.count(preference) == 1
      and 'Picker("正文显示", selection: $transcriptDisplayMode)' in settings
      and chat.count("transcriptDisplayMode: transcriptDisplayMode") == 2)
check("single V3 host receives mode before attach and updates it in place",
      chat.count("CollectionViewMessageListV3(") == 1 and ".id(transcriptDisplayMode)" not in chat
      and re.search(r"setInitialTranscriptMode\(transcriptDisplayMode\).*?\.attach\(to:", v3, re.S))

projection = section(v3, "// Build items", "// Remap height cache")
simple_projection = section(projection, "case .assistant:", "newItems.append(.assistantHeader(message.id))")
check("simple projects source segments before the standard fold branch and keeps questions whole",
      re.search(r"case \.assistant:\s*if transcriptMode == \.simple \{\s*"
                r"for block in message\.blocks \{\s*guard let role = SimpleTranscript\.row\(for: block\) else \{ continue \}\s*"
                r"let ids: \[SimpleSegmentID\?\] = role == \.question \? \[nil\] : block\.simpleBody\.segments\.map \{ \$0\.id \}\s*"
                r"for id in ids \{\s*let item = MessageListItem\.assistantBlock\(message\.id, block\.id, id\)\s*newItems\.append\(item\)", simple_projection)
      and simple_projection.count("newItems.append(") == 2 and "continue" in simple_projection)
simple_roles = section(infra, "enum Row: Equatable", "static func hasText")
check("unreferenced tool images cannot form an independent simple row",
      re.search(r"enum Row: Equatable \{\s*case text\s*case question\s*case standalone\s*\}", simple_roles)
      and re.search(r"-> Row\? \{\s*if block\.questionCard != nil \{ return \.question \}\s*"
                    r"if block\.kind == \.text, hasText\(block\.content\) \{ return \.text \}\s*return nil\s*\}", simple_roles))
simple_content = section(v3, "private func simpleContent", "private var simpleReadAloud")
segment_view = section(v3, "private struct SimpleAssistantSegmentView", "/// Footer: typing indicator")
simple_text_body = section(segment_view, "SelectableMarkdownView(markdown:", ".modifier(ZeOpenURLHandler())")
text_view = section(assistant, "private var textBlockView", "/// A delegation")
inline_media = section(markdown, "case .link(let destination, let children):", "case .html(let html):")
check("standard still renders whole Markdown with its original inline links and media",
      "SelectableMarkdownView(\n            markdown: block.content," in text_view
      and "linkAttrs[.link] = url" in inline_media and "return renderInlines(children, baseAttributes: linkAttrs)" in inline_media
      and "case .image(let source, let children):" in inline_media and "return renderImageAttachment(source: source)" in inline_media)
pieces = section(parser, "struct SimpleBodySegment:", "extension Array where Element == BlockNode")
check("AST extracts an embedding or table exclusively, keeping code, links and enclosing styles in the text path",
      re.search(r"if case \.image\(let source, let alt\) = inline \{\s*let media = Media\(source: source, alt: alt, linkDestination: link\).*?return \[\.standalone", pieces, re.S)
      and re.search(r"case \.table:\s*guard let table = BlockNode.*?return \[\.standalone", pieces, re.S)
      and all(marker in pieces for marker in ("node.children.flatMap(inlinePieces)", ".emphasis, .strong, .strikethrough, .link", ".blockquote(children:", ".numberedList(isTight:", "default: return [.content(inline)]"))
      and "blocks.contains(where: visible)" in pieces
      and "case .softBreak, .lineBreak: return false" in pieces)
check("one render path per segment uses parsed nodes for display and measurement, not tool output or full raw Markdown",
      re.search(r"if let media = segment\.media \{\s*SimpleStandaloneMedia.*?\} else if case \.table.*?SimpleStandaloneTable.*?\} else \{\s*SelectableMarkdownView", segment_view, re.S)
      and "cachedContent: MarkdownContent(blocks: segment.blocks)" in simple_text_body
      and "toolSnapshots" not in segment_view and "imageFilePath" not in segment_view
      and "searchSegmentID == nil ? MarkdownContent(preparedPrefix).blocks : (cachedContent?.blocks ?? [])" in markdown
      and "blockContent" not in simple_content)
check("source position and the previous standalone boundary key rows; an in-flight table row does not make another card",
      "cmark_node_get_start_line(node), column: cmark_node_get_start_column(node)" in pieces
      and "textID = .init(kind: .text, line: segment.id.line, column: segment.id.column)" in pieces
      and "case assistantBlock(UUID, UUID, SimpleSegmentID? = nil)" in infra
      and "splitStreamingTableTail(markdown)" in pieces
      and 'split.prefix.hasSuffix("\\n\\n")' in pieces
      and 'output.last?.id.kind != .table || prepared.prefixEndsWithBlankLine' in pieces)
browser_capsule = section(assistant, "case .browserTool:", "case .readImageTool:")
check("standard browser tool still opens the existing capsule detail",
      "ToolCapsuleView(block: block" in browser_capsule and "detailBlock: $detailBlock" in browser_capsule
      and re.search(r"\.onTapGesture \{\s*detailBlock = block\s*\}", assistant))
column = section(v3, "if let simpleRow {", "} else {\n                standardContent")
check("every standalone row and fitted bubble share the column's leading edge and 6pt spacing",
      ".frame(width: segmentID == nil ? nil : max(1, maxWidth), alignment: .leading)" in column
      and "shortReplyWidth" not in v3
      and re.search(r"\.fixedSize\(horizontal: false, vertical: true\)\s*\.padding\(\.horizontal, 12\)\s*\.padding\(\.vertical, 6\)\s*\.background\(", simple_text_body)
      and "layout.simpleSegmentGaps = Set(newItems.indices.dropLast().filter" in v3
      and "simpleSegmentGaps.contains(i) ? 6 : itemSpacing" in layout)
glow = section(v3, "fileprivate final class CompletionGlow", "// MARK: - V3 Coordinator")
check("user bubble, menu preview, simple reply and completion glow share the 18pt radius",
      re.search(r"enum ChatBubbleStyle \{\s*static let cornerRadius: CGFloat = 18\s*\}", message_views)
      and re.search(r"RoundedRectangle\(cornerRadius: ChatBubbleStyle\.cornerRadius\)\s*\.fill\(ChatColors\.userMessageBubble\)", message_views)
      and ".contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: ChatBubbleStyle.cornerRadius))" in message_views
      and re.search(r"\.background\(Color\(uiColor: \.secondarySystemBackground\), in: RoundedRectangle\(cornerRadius: ChatBubbleStyle\.cornerRadius\)\)\s*\.overlay", simple_text_body)
      and "roundedRect: frame, cornerRadius: ChatBubbleStyle.cornerRadius" in glow
      and "RoundedRectangle(cornerRadius: 10, style: .continuous)" in section(message_views, "private func quoteBlock", "private var userRow"))
feedback = section(vm, "private func notifyCompletionFeedback", "private func runAgentLoop")
check("only successful completion emits the last projected text block before sound or background notification",
      vm.count("ReplyCompletionGlowEvents.shared.send(") == 1
      and re.search(r"guard AppFeedbackPreferences\.shouldComplete\(hasError: message\.error != nil, isCancelled: cancelled,\s*"
                    r"canResume: canResume, hasReply: hasReply\) else \{ return \}\s*feedbackCompletedReplyID = message\.id\s*"
                    r"if let sessionId, let block = message\.blocks\.last\(where: \{ SimpleTranscript\.row\(for: \$0\) == \.text \}\) \{\s*"
                    r"ReplyCompletionGlowEvents\.shared\.send\(\.init\(sessionID: sessionId, messageID: message\.id, blockID: block\.id\)\)\s*\}\s*"
                    r"if AppFeedback\.completedReply\(.*?await notifyBackgroundReplyCompletion", feedback, re.S)
      and "let cancelled = Task.isCancelled || userDidCancel" in feedback)
glow_events = section(infra, "@MainActor\nfinal class ReplyCompletionGlowEvents", "@MainActor enum SimpleTranscript")
check("process-wide completion dedup marks the session and message before non-replaying delivery",
      "static let shared = ReplyCompletionGlowEvents()" in glow_events
      and "PassthroughSubject<ReplyCompletionGlowEvent, Never>()" in glow_events
      and re.search(r"guard completed\[event\.sessionID, default: \[\]\]\.insert\(event\.messageID\)\.inserted else \{ return \}\s*subject\.send\(event\)", glow_events))
glow_delivery = section(v3, "private func showCompletionGlow", "private func clearCompletionGlows")
check("glow delivery is synchronous and limited to the visible target in the current foreground simple chat",
      re.search(r"ReplyCompletionGlowEvents\.shared\.events\s*\.sink \{ \[weak self\] event in self\?\.showCompletionGlow\(event\) \}", v3)
      and re.search(r"cell\.glowItem == item else \{ return \}\s*cell\.completionGlow\.play", glow_delivery)
      and all(marker in glow_delivery for marker in ("vm?.sessionId == event.sessionID", "transcriptMode == .simple",
          "requestedTranscriptMode == .simple", "applicationState == .active", "window.isKeyWindow",
          "vc.isListOnScreen", "activationState == .foregroundActive", "message.blocks.reversed().lazy.compactMap",
          r"SimpleBodySegment.parse(block.content, finalised: true).last(where: \.hasVisibleText)", "simpleRows[item] == .text",
          "cv.indexPathsForVisibleItems.contains(indexPath)", "cell.glowItem == item"))
      and v3.count("completionGlow.play(") == 1)
check("sky-blue pulse is a noninteractive one-shot layer cleared on reuse, mode switch and departure",
      re.search(r"CompletionGlowAnchor\(glow: glow\)\s*\.allowsHitTesting\(false\)\s*\.accessibilityHidden\(true\)", simple_text_body)
      and all(marker in glow for marker in ("anchor.isDescendant(of: cell)", ".intersects(collectionView.bounds",
          "UIColor.systemBlue.cgColor", "if !reduceMotion", "opacity.duration = 0.55", "cell.layer.addSublayer(pulse)",
          "CATransaction.setCompletionBlock { pulse.removeFromSuperlayer() }"))
      and "repeatCount" not in glow and "repeatDuration" not in glow
      and "completionGlow.reset()" in section(v3, "private final class AssistantBlockCellV3", "private final class AssistantFooterCellV3")
      and "if mode != requestedTranscriptMode { clearCompletionGlows() }" in v3
      and "onListDisappearance = { [weak self] in self?.clearCompletionGlows() }" in v3
      and "coordinator.setAllowsCompletionGlow(false)" in v3
      and "(cell as? AssistantBlockCellV3)?.completionGlow.clear()" in v3)
text_fit = without_swift_comments(section(markdown, "private static func fittedTextWidth", "@available(iOS 16.0, *)\n    func sizeThatFits"))
sizing = without_swift_comments(section(markdown, "func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableMarkdownTextView",
                                        "private static let stfLogger"))
check("two short rendered lines hug the longest line; soft wraps keep the content column width",
      all(marker in text_fit for marker in ("NSTextStorage(attributedString: text)", "width: limit - insets",
                                            "manager.enumerateLineFragments(forGlyphRange: glyphs)",
                                            "longest = max(longest, used.maxX + container.lineFragmentPadding)",
                                            "return wraps || longest <= 0 ? limit : min(limit, ceil(longest + insets))"))
      and re.search(r"string\.rangeOfCharacter\(from: \.newlines, range: NSRange\(location: end - 1, length: 1\)\)"
                    r"\.location == NSNotFound \{\s*wraps = true", text_fit))
check("short attachment-free text reaches fitted width without an extra full-width return",
      re.search(r"guard text\.length > 0, text\.length <= 8000, limit\.isFinite, limit > insets else \{\s*return limit\s*\}", text_fit)
      and len(re.findall(r"\breturn\b", text_fit)) == 2
      and re.search(r"(?m)^\s*let fittedWidth = text\.map \{ Self\.fittedTextWidth\(for: \$0, limit: width, using: uiView\) \} \?\? width[ \t]*$",
                    sizing)
      and "let size = CGSize(width: fittedWidth, height: height)" in sizing
      and [branch["text"] for branch in re.finditer(
          r"(?ms)^(?P<indent>[ \t]*)if !hasAnyAttachment \{\n.*?"
          r"return result\(height: h, text: (?P<text>pending|liveStorage)\)\s*\n(?P=indent)\}", sizing
      )] == ["pending", "liveStorage"]
      and sizing.count("if !fitTextWidth, bindingLen == coord.cachedSizeMarkdownCount,") == 2
      and "let disableStreamEst = true\n        if !disableStreamEst," in sizing
      and [expression.strip() for expression in re.findall(r"\breturn\s+([^\n}]+)", sizing)] == [
          "size", "CGSize(width: width, height: height)", "size",
          "CGSize(width: width, height: cachedHeight)", "CGSize(width: width, height: nearestHeight)",
          "CGSize(width: width, height: estimated)", "false", "found",
          "result(height: h, text: pending)", "result(height: h, text: liveStorage)",
          "result(height: size.height)",
      ])
check("only simple assistant text opts into fitted width without swapping the selectable renderer",
      "fitTextWidth: true" in simple_text_body
      and "fitTextWidth: false" in section(v3, "private var blockContent", "private func simpleContent")
      and "var fitTextWidth = false" in assistant and "var fitTextWidth = false" in markdown
      and "fitTextWidth: fitTextWidth" in text_view and ".modifier(ZeOpenURLHandler())" in text_view
      and "guard fitTextWidth else { return CGSize(width: width, height: height) }" in sizing)
observer = section(v3, "private func observeSimpleProjection", "private func markSimpleProjectionDirty")
message_loop = observer.partition("for message in assistants where ")[2]
message_sink = re.search(
    r"(?ms)let sub = Publishers\.Merge\(blocks, errors\)\s*"
    r"^(?P<indent>[ \t]*)\.receive\(on: DispatchQueue\.main\)\.sink \{[^\n]*\n"
    r"(?P<body>.*?)^(?P=indent)\}[ \t]*$", message_loop)
sink_body = message_sink["body"] if message_sink else ""
after_sink = message_loop[message_sink.end():] if message_sink else ""
message_edges = section(v3, "private static func messageBlockEdges", "private func observeSimpleProjection")
array_edges = section(v3, "private static func edgesForBlocks", "private static func messageBlockEdges")
block_edges = section(v3, "private static func blockEdges", "private static func edgesForBlocks")
text_edges = section(v3, "private static func textEdges", "private static func normalizedStatus")
content_edges = section(v3, "private static func contentEdges", "private static func textEdges")
status = section(v3, "private static func normalizedStatus", "private static func blockEdges")
check("late questions and first nonblank text can enter without token-driven tool log diffs",
      "simpleMessageSubs[message.id]?.0 != ObjectIdentifier(message)" in observer
      and re.search(r"let blocks: Edge = Self\.messageBlockEdges\(message\)\s*"
                    r"let errors: Edge = message\.\$error\.removeDuplicates\(\)\.dropFirst\(\)"
                    r"\.map \{ _ in \(\) \}\.eraseToAnyPublisher\(\)\s*"
                    r"let sub = Publishers\.Merge\(blocks, errors\)\s*"
                    r"\.receive\(on: DispatchQueue\.main\)\.sink", message_loop)
      and all(marker in message_edges for marker in (
          "message.$blocks", ".removeDuplicates { $0.elementsEqual($1, by: { $0 === $1 }) }",
          ".map { blocks -> Edge in Self.edgesForBlocks(blocks) }",
          "return sources.switchToLatest().dropFirst().eraseToAnyPublisher()"))
      and "blocks.flatMap { Self.blockEdges($0) }" in array_edges
      and "return Publishers.MergeMany(edges).prepend(()).eraseToAnyPublisher()" in array_edges
      and "let text: Edge = Self.textEdges(block)" in block_edges
      and "return [text, kind, question, status]" in block_edges
      and all(f"block.${field}.removeDuplicates().dropFirst()" in block_edges
              for field in ("kind", "questionCard"))
      and all(marker in text_edges for marker in (
          "block.$kind.map { $0 == .text }.removeDuplicates()", "isText.map",
          "guard isText else { return Empty<Void, Never>().eraseToAnyPublisher() }",
          "return Self.contentEdges(block)", "return sources.switchToLatest().eraseToAnyPublisher()"))
      and r"body.$segments.map { $0.map(\.id) }.removeDuplicates().dropFirst()" in content_edges
      and "Publishers.Merge(states, updates).eraseToAnyPublisher()" in content_edges)
check("streamed body batches updates and invalidates changed segment sizes without a snapshot edge",
      ".throttle(for: .milliseconds(32), scheduler: DispatchQueue.main, latest: true)" in simple_roles
      and "previous[segment.id].map { $0 != segment } == true ? segment.id : nil" in simple_roles
      and "block.simpleBody.contentChanges" in v3 and "simpleBlockObjects[item] == ObjectIdentifier(block)" in v3
      and "if newItems == previousSnapshotIds && reconfigured.isEmpty && !modeChanged" in v3)
check("message sink marks the simple projection dirty",
      re.search(r"(?m)^[ \t]*self\.markSimpleProjectionDirty\(\)[ \t]*$", sink_body))
check("message sink rejects queued callbacks from replaced message instances",
      re.search(r"(?m)^[ \t]*guard\b[^{}]*,\s*"
                r"self\.simpleMessageSubs\[message\.id\]\?\.0 == ObjectIdentifier\(message\)"
                r"\s+else\s*\{\s*return\s*\}", sink_body))
check("message projection retains its subscription under the current message identity",
      re.match(r"\s*simpleMessageSubs\[message\.id\] = \(ObjectIdentifier\(message\), sub\)", after_sink))
check("tool byte growth is ignored while message footer reconciliation remains live",
      re.search(r"block\.\$toolStatus\.map \{ Self\.normalizedStatus\(\$0\) \}\s*"
                r"\.removeDuplicates\(\)\.dropFirst\(\)", block_edges)
      and re.search(r"if case \.streaming\(_\)\? = status \{ return \.streaming\(bytes: 0\) \}\s*return status", status)
      and "self.markFooterDirty(message.id)" in sink_body
      and "footerPresentation(for: message" in simple_projection)
check("visible assistant and user rows retain a reachable menu and accessibility actions",
      ".contextMenu { simpleMessageActions }" in v3 and ".accessibilityActions { simpleMessageActions }" in v3
      and ".accessibilityActions" in source("Views/Chat/ChatMessageViews.swift"))
read = section(v3, "private var simpleReadAloud", "private var standardContent")
check("simple Read from Start requires a finished reply with nonblank text",
      "guard !bridge.isStreaming" in read and "$0.kind == .text && SimpleTranscript.hasText($0.content)" in read
      and 'if let read = simpleReadAloud { Button("Read from Start", action: read) }' in read)
standard_block = section(v3, "private var standardContent", "// Context menu on zero-size overlay")
check("standard block attaches the overlay after the baseline frame, padding and presentation modifiers",
      standard_block.strip().splitlines()[1:] == [
          "        blockContent", "        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)",
          "        .frame(maxWidth: .infinity)", "        .padding(.horizontal, 16)",
          "        .opacity(message.isCompactedHistory ? 0.5 : 1.0)", "        .accessibilityIdentifier(blockAccessibilityId)",
      ] and re.search(r"private var standardContent:.*?// Context menu on zero-size overlay[^\n]*\n[^\n]*\n        \.overlay", v3, re.S))
estimate = section(v3, "static func estimateItemHeight", "private static func baseItemHeight")
check("snapshot, cell configuration and prefetch account for the simple bubble's vertical padding",
      "estimateTextBlockHeight(segment.searchText" in estimate and "lineHeight: scale * 1.4) + 12" in estimate
      and "simpleRow: role" in section(v3, "// Remap height cache", "// Re-entry seed:")
      and "simpleRow: simpleRows[item]" in section(v3, "// Height estimation for items not yet measured", "/// Subscriptions for bridge")
      and "simpleRow: simpleRows[item]" in section(v3, "prefetchItemsAt indexPaths:", "// MARK: - UIScrollViewDelegate"))
check("shared footer decision hides usage and action reservation and respects live question liveness",
      all(marker in v3 for marker in ("bridge.simpleFooter = footer", "newFooters[message.id] = footer",
                                      "mode == .standard && reservesCompletionActionSpace", ".questionCardToggled"))
      and "QuestionCardCoordinator.shared.isPending" in infra and "message.isAwaitingModelResponse" in infra)
soul = source("Agent/Session/SoulStore.swift")
waiting = section(assistant, "struct AssistantReplyWaitingIndicator", "// MARK: - Typing Indicator")
check("both live waiting rows use the header soul-name source without a second name cache",
      "SoulHeaderActivityText(vm: vm, assistantName: soulName" in chat
      and "@State private var soulName: String = SoulStore.cachedMetadata.displayName" in chat
      and chat.count("soulName = SoulStore.cachedMetadata.displayName") == 2
      and "get { metadataCache.metadata }" in soul
      and re.search(r"var displayName: String \{\s*let trimmed = name\.trimmingCharacters\(in: \.whitespacesAndNewlines\)\s*"
                    r'return trimmed\.isEmpty \? "Ze" : trimmed\s*\}', soul)
      and "@ObservedObject private var soul = SoulStore.metadataCache" in waiting
      and "TypingIndicator(assistantName: soul.metadata.displayName)" in waiting and "@State" not in waiting
      and re.search(r"if footer\.showsTyping \{\s*AssistantReplyWaitingIndicator\(\)", v3)
      and "showsTyping = isActive && (mode == .simple ? SimpleTranscript.showsWaiting(message)" in v3
      and re.search(r"if isActiveMessage && \(!hasVisibleContent \|\| message\.isAwaitingModelResponse\) \{\s*"
                    r"AssistantReplyWaitingIndicator\(\)", message_views))
check("physical tail and measured visible rows still gate send handoff",
      "item == previousSnapshotIds.last && (itemFrame(item, in: cv)?.height ?? 0) > 0.5" in v3
      and "if transcriptMode == .simple { return simpleRows[item] != nil }" in v3
      and "sendCanHandOff = !keyboardInFlight" in v3 and "abs(target - cv.contentOffset.y) <= 0.5" in v3)

switch = section(v3, "private func scheduleTranscriptUpdate", "private func observeSimpleProjection")
check("switch captures the old position without clearing live send ownership",
      switch.index("capturePosition(in: cv)") < switch.index("beginTranscriptGeneration")
      and "invalidatePositionRequests" not in switch and "sendPosition = nil" not in switch
      and "transcriptAnchor(modeAnchor, items: newItems" in v3 and "transcriptFallback(for: saved.item" in v3)
restore = section(v3, "if let key = scrollMemoryKey, let saved", "} else if reasons.contains(.transcriptMode)")
check("session re-entry uses saved offset for surviving rows, not simple-mode substitutes",
      "let savedFrame = itemFrame(saved.item, in: cv)" in restore
      and re.search(r"if savedFrame == nil && transcriptMode == \.simple \{\s*"
                    r"desired = frame\.minY - cv\.adjustedContentInset\.top\s*\} else \{\s*"
                    r"desired = frame\.minY - \(saved\.offset\.isFinite \? saved\.offset : 0\)", restore))
check("switch purges estimates, delayed heights and cell seeds and blocks old layout attributes",
      "deferredHeights.removeAll()\n        clearHeightCache()" in layout
      and layout.count("acceptsTranscriptMeasurement(preferredAttributes)") == 2
      and "cell.clearCachedHeight()" in switch and "pendingStreamingLayout?.cancel()" in switch
      and "!= transcriptGeneration" in infra and "snapshot.reconfigureItems(reconfigured)" in v3)
check("search uses mode and generation, never defaulting a hidden simple hit to another row",
      "if mode == .simple, SimpleTranscript.row(for: block) == nil { continue }" in search and "mode == self.transcriptMode" in search
      and "run(landOnNewest: false)" in section(search, "func updateTranscriptMode", "func activate")
      and "if transcriptMode == .simple { return items.first { $0 == preferred } }" in v3)
check("simple search indexes segments and lands on the matching table cell or exact filename row",
      "for segment in block.simpleBody.segmentsForSearch(block)" in search and "text = segment.searchText" in search
      and "segmentID: segment.id" in search and "hit.match.key.segmentID" in v3
      and "ChatSearchMarkdownText.tableCellText(cell)" in markdown and "NSIntersectionRange(matches[current], range)" in markdown
      and "scroll.scrollRectToVisible(tableCell.convert(tableCell.bounds, to: scroll)" in v3
      and "SearchHighlightText(media.name, key: key)" in media)
check("standalone image and video preserve one segment, use capped geometry and do not autoplay",
      all(marker in media for marker in ("min(400, width)", "UIScreen.main.bounds.height / 2", "9.0 / 16",
          "bodyModel.recordMediaSize(size, for: segmentID, media: media)", "onResize(segmentID)", "startsAutomatically: false", ".gallery(.init(items: items, startIndex: start))"))
      and "if externalPlayer == nil && startsAutomatically" in video
      and "startsAutomatically: Bool = true" in video)
check("audio and files use independent cards, with unavailable resources gated and no stop on row reuse",
      all(marker in media for marker in ("if let resource { SimpleAudioControls", "min(width, 360)", ".frame(height: kind == .audio ? Self.audioHeight : nil)", ".frame(minHeight: 56)",
          "GlobalAudioPlayer.shared", "player.debouncedSeek", ".disabled(!seekable)", "guard resource != nil, let sourceURL",
          "case .unavailable:", "case .unsupported:", "try checkResponse(response)"))
      and ".onDisappear" not in section(media, "struct SimpleStandaloneMedia", "private struct ZeMediaFavoriteModifier")
      and "guard transcriptDisplayMode == .simple, let message = note.object as? ChatMessage" in chat)
check("tables retain their own horizontal state and one border while reusing native table layout and selection",
      all(marker in markdown for marker in ("table.makeView(width: width, cornerRadius: ChatBubbleStyle.cornerRadius)",
          "table.preservedScrollOffset = bodyModel.tableOffsets[segmentID]", "bodyModel?.tableOffsets[segmentID] = offset",
          "scrollView.layer.cornerRadius = cornerRadius", "scrollView.layer.borderWidth = 0.5", "label.selectableAttributedText = attrStr")))

file_route = section(chat, "case .file(let url):", ".modifier(DismissImmersiveCoversListener")
file_preview = section(chat, "private func handleZeURLTap", "private func handleDropProviders")
check("standalone file URLs enter the existing preview and share dispatch without changing other links",
      "if url.isFileURL { presentChatFile(url, resolved:" in file_route and "else { _ = handleZeURLTap(url) }" in file_route
      and 'guard url.scheme == "ze" else { return .systemAction }' in file_preview
      and "presentChatFile(url, resolved: resolveZeFileURL(url: url))" in file_preview
      and "previewDocumentFile = fileURL" in file_preview and "shareFile = fileURL" in file_preview)
gallery = section(media, "private func openImageGallery()", "@MainActor enum SimpleTranscriptMediaRouter")
check("standalone gallery items retain checked image favorites for resolved local files",
      "onFavorite: {" in gallery and "source.isFileURL ? source : resolveZeFileURLCached(url: source)" in gallery
      and "MediaFavoritesStore.shared.addChecked(fileURL: fileURL, kind: .image, fileName:" in gallery)
standard_gallery = section(chat, "private func handleMarkdownImageTap", "private static func loadMarkdownImage")
gallery_titles = section(pieces, "static func imageGalleryTitles", "func markdownForCopy")
segment_tests = source("ZeTests/SimpleBodySegmentTests.swift")
source_alignment = section(pieces, "private static func originalStandalones", "private static let galleryImagePattern")
copy_markdown = section(pieces, "func markdownForCopy", "private static func position")
streaming_alignment_test = section(segment_tests, "func testOriginalSourceAlignmentIgnoresAnExtraImageInTheStreamingTail",
                                   "func testOriginalSourceAlignmentDoesNotBorrowTheSpan")
source_preparation = section(pieces, "private static func prepareSource", "static func parse(_ markdown:")
display_parse = section(pieces, "static func parse(_ markdown:", "private static func originalStandalones")
source_map = section(pieces, "private struct OriginalSource", "private enum Piece")
math_collision_test = section(segment_tests, "func testOriginalSourceAlignmentKeepsSameURLImagesDistinctAfterBlockMath",
                              "func testOriginalSourceAlignmentPreservesOriginalBytesAcrossOtherPreprocessing")
render_prep = section(source("Views/Chat/MarkdownPrepRegex.swift"), "func prepareMarkdownForRender", "// MARK: - CJK Emphasis Pair Fix")
visual_prep = section(source("Agent/Visualization/VisualizationDocument.swift"), "enum ZeVisualizationStreaming", "enum ZeVisualizationPrompt")
math_prep = section(parser, "static func extract(from markdown:", "static func restore(blocks:")
check("display and source lookup parse the same prepared coordinates and map slices back to original bytes",
      "prepareSource(markdown, finalised: finalised)" in display_parse
      and "prepareSource(original, finalised: finalised)" in source_alignment
      and all("UnsafeNode.parseMarkdown(prepared.markdown)" in path for path in (display_parse, source_alignment))
      and all(step in source_preparation for step in ("splitStreamingTableTail(markdown)",
          "prepareMarkdownForRender(split.prefix, recordEdits: recordEdits)",
          "ZeVisualizationStreaming.prepare(formatted, recordEdits: recordEdits)",
          "MarkdownMathExtractor.extract(from: prepared, recordEdits: recordEdits)"))
      and all(step in render_prep for step in ("insertBlankLineAfterTable(markdown, recordEdits: recordEdits)",
          "normalizeMarkdownListSyntax(tables, recordEdits: recordEdits)", "fixEmphasisPairsForCJK(lists, recordEdits: recordEdits)",
          "strictifyStrikethrough(padInlineCode(emphasis), recordEdits: recordEdits)"))
      and "normalizeEnvelopes(input, recordEdits: recordEdits)" in visual_prep
      and visual_prep.count("recordEdits?(edits)") == 2
      and "edits.append((offsets[i]..<offsets[end], placeholder.utf8.count))" in math_prep
      and "prepared.offset(line, column)" in source_map and "for stage in edits.reversed()" in source_map
      and "OriginalSource(raw: SourceText(original), prepared: SourceText(prepared.markdown), edits: edits)" in source_alignment
      and "source.raw.slice(start, end)" in gallery_titles and "source.raw.slice(start, end)" in copy_markdown
      and "imageGalleryTitles(in: parsedContent, segments: segments, finalised: parsedFinalised)" in infra
      and "markdownForCopy(in: parsedContent, segments: segments, finalised: parsedFinalised)" in infra
      and r'"$$\nx\n$$\n\n![_甲_](chart.png)\n\n![_乙_](chart.png)"' in math_collision_test
      and '["_甲_", "_乙_"]' in math_collision_test
      and '["![_甲_](chart.png)", "![_乙_](chart.png)"]' in math_collision_test)
check("source alignment matches each standalone by position without a whole-block equality gate",
      "Dictionary(grouping: raw, by: { $0.segment.id })" in source_alignment
      and "for segment in standalone" in source_alignment
      and "byPosition[segment.id], candidates.count == 1" in source_alignment
      and "candidate.segment.media == segment.media else { continue }" in source_alignment
      and "spans[segment.id] = candidate.span" in source_alignment
      and not any(gate in source_alignment for gate in ("raw.count", "standalone.count", "zip(", ".allSatisfy("))
      and "for (id, span) in spans where id.kind == .image" in gallery_titles
      and "guard let span = spans[id] else { return fallback }" in copy_markdown
      and "preceding.flatMap { spans[$0.id] }" in copy_markdown
      and "following.flatMap { spans[$0.id] }" in copy_markdown
      and "preceding == nil || start != nil, following == nil || end != nil" in copy_markdown
      and r'"**前 ![_季度_](chart.png) 后**\n\nA | ![后图](b.png)"' in streaming_alignment_test
      and "SimpleBodySegment.parse(source, finalised: false)" in streaming_alignment_test
      and 'XCTAssertEqual(titles[image.id], "_季度_")' in streaming_alignment_test
      and 'XCTAssertEqual(Array(prefix.markdownForCopy(in: source, segments: segments, finalised: false).utf8), Array("**前 ".utf8))' in streaming_alignment_test)
check("standalone gallery favorites use the standard verbatim alt and source filename fallback",
      r'NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)' in standard_gallery
      and r'NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)' in pieces
      and "alt.isEmpty ? (source as NSString).lastPathComponent : alt" in pieces
      and "let title = alt.isEmpty ? ((src as NSString).lastPathComponent) : alt" in standard_gallery
      and "kind: .image, fileName: ref.title)" in standard_gallery
      and "originalStandalones(in: original, segments: segments, finalised: finalised)" in gallery_titles
      and "let alt = content.substring(with: match.range(at: 1))" in gallery_titles
      and "let src = content.substring(with: match.range(at: 2))" in gallery_titles
      and "titles[id] = Media.galleryTitle(alt: alt, source: src)" in gallery_titles
      and "block.simpleBody.imageGalleryTitles()" in gallery
      and "titles[segment.id] ?? media.galleryTitle" in gallery
      and "kind: .image, fileName: title)" in gallery
      and "testGalleryTitlesUseOriginalAltAndStandardSourceFallback" in segment_tests)
check("split list fragments retain source ordinals and only one marker per source item",
      "start: node.listStart + (children.first?.0 ?? 0)" in pieces
      and "let continuation = emittedMarker" in pieces and "RawListItem(children: $0.2, continuesPrevious: $0.3)" in pieces
      and r'let number = item.continuesPrevious ? "" : "\(start + i). "' in markdown
      and r'if !item.continuesPrevious { out += "\(start + i). " }' in search
      and "firstLineIndent: item.continuesPrevious ? itemContentIndent : itemStartIndent" in markdown)
check("linked images retain their destination for normal link activation and Copy Link",
      "destination = target" in pieces and "linkDestination: link" in pieces
      and "let destination = media.linkDestination, let url = normalizedMarkdownLinkURL(from: destination)" in media
      and "SimpleTranscriptMediaRouter.post(message: message, payload: .link(url))" in media
      and 'if ["ze", "http", "https"].contains(url.scheme ?? "") { _ = handleZeURLTap(url) }' in file_route
      and 'Button("Copy Link") { UIPasteboard.general.string = link }' in v3)
check("standalone and text segment Markdown copy use original source rather than a render identity",
      "Array(original.utf8)" in pieces
      and "Self.originalStandalones(in: original, segments: segments, finalised: finalised)" in copy_markdown
      and "block.simpleBody.markdownForCopy(segment)" in v3
      and "bodyModel.markdownForCopy(segment)" in segment_view
      and "copyMarkdownSource: copyMarkdown" in simple_text_body
      and "textView.copyMarkdownSource = copyMarkdownSource" in markdown
      and "UIPasteboard.general.string = copyMarkdownSource()" in markdown)
emphasis_test = section(segment_tests, "func testCopyTextOnEitherSideOfImageInEmphasis", "func testCopyReferenceImage")
reference_test = section(segment_tests, "func testCopyReferenceImage", "func testOriginalSourceAlignmentIgnoresAnExtraImage")
check("Markdown copy around an emphasis-splitting image keeps only each text segment's source bytes",
      "source.offset($0.endLine, $0.endColumn, isStart: false)" in copy_markdown
      and "source.offset($0.startLine, $0.startColumn - 1, isStart: true)" in copy_markdown
      and re.search(r"let slice = source\.raw\.slice\(start \?\? 0, end \?\? source\.raw\.bytes\.count\) else \{ return fallback \}\s*"
                    r"if prior\?\.cutsInlineWrapper == true \|\| next\?\.cutsInlineWrapper == true \{\s*return slice\s*\}", copy_markdown)
      and '"**前 ![图](a.png) 后**"' in emphasis_test and '["**前 ", "![图](a.png)", " 后**"]' in emphasis_test
      and "markdownForCopy(in: source, segments: segments).utf8" in emphasis_test)
standalone_copy = section(copy_markdown, "if id.kind != .text", "let preceding = ")
check("Markdown copy preserves a reference image's original fragment without reparsing it or adding its definition",
      "source.offset(span.startLine, span.startColumn - 1, isStart: true)" in standalone_copy
      and "source.offset(span.endLine, span.endColumn, isStart: false)" in standalone_copy
      and "return source.raw.slice(start, end) ?? fallback" in standalone_copy
      and "parseMarkdown" not in standalone_copy
      and 'let image = "![report][doc]"' in reference_test
      and "[doc]: ze://workspace/report.pdf" in reference_test
      and "XCTAssertEqual(Array(attachment.markdownForCopy(in: source, segments: segments).utf8), Array(image.utf8))" in reference_test)
check("loaded and pending audio rows use the same scaled height as the list estimate",
      ".frame(height: kind == .audio ? Self.audioHeight : nil)" in media and "case .audio: return SimpleStandaloneMedia.audioHeight" in v3
      and "UIFontMetrics(forTextStyle: .body).scaledValue" in media and "max(70, title + controls + 14)" in media
      and ".frame(minHeight: 70)" not in media)
failure = section(media, "private enum Failure: Error", "private struct Resource")
check("retry is allowlisted for temporary failures rather than unknown media errors",
      "Failure.classify(error)" in media and ".timedOut" in failure and "NSFileReadNoSuchFileError" in failure
      and "default: return .unsupported" in failure and failure.rstrip().endswith("return .unsupported\n        }\n    }")
      and "[408, 425, 429].contains(http.statusCode) || http.statusCode >= 500" in media
      and "guard let image else { throw Failure.unsupported }" in media)
visible_text = section(search, "var hasVisibleText:", "var searchText:")
check("completion selects visible text, ignoring decorative rules even within a list or quote",
      r"last(where: \.hasVisibleText)" in glow_delivery and "blocks.contains(where: containsText)" in visible_text
      and "block.children.contains(where: containsText)" in visible_text
      and "ChatSearchMarkdownText.text(blocks: [block]).trimmingCharacters" in visible_text
      and "case .thematicBreak, .mathBlock:\n            break" in search)
attachment_resize = section(v3, "private func itemsReferencingAttachment", "private func observeSimpleContent")
check("legacy size notifications only invalidate matching items, with offscreen lookup and reading anchor",
      "self?.attachmentSizeChanged(source)" in v3 and "itemsReferencingAttachment(source, in: snapshot.itemIdentifiers)" in attachment_resize
      and "return matches(media.source)" in attachment_resize and "markdown.blocks.contains(where: containsImageBlock)" in attachment_resize
      and "snapshot.reconfigureItems(affected)" in attachment_resize and "snapshot.reconfigureItems(snapshot.itemIdentifiers)" not in attachment_resize
      and attachment_resize.index("enqueuePosition(.attachment, scheduleLayout: false)") < attachment_resize.index("layout.invalidateContentHeight(at: path.item)"))
same_message = section(v3, "private func sameMessageTranscriptRow", "private func transcriptFallback")
anchor = section(v3, "private func transcriptAnchor(", "// MARK: - Live Assistant Footers")
check("mode-switch fallback chooses the exact segment, original block, then nearest same-message row before other visible rows",
      same_message.index("sameTurn.contains(removed)") < same_message.index("let sameBlock") < same_message.index("ranked.min")
      and anchor.index("sameMessageTranscriptRow(for: original") < anchor.index("cv.indexPathsForVisibleItems")
      and "readingY: before.readingY" in anchor)
body_state = section(infra, "@MainActor final class Body", "static func row(for block:")
check("same-position replacement clears old media geometry and rejects a late size from the old media",
      "mediaSizes.filter { currentMedia[$0.key] == $0.value.media }" in body_state
      and "entry.media == media" in body_state
      and "segments.contains(where: { $0.id == id && $0.media == media })" in body_state
      and "bodyModel.mediaSize(for: segmentID, media: media)" in media and "block.simpleBody.mediaSize(for: id, media: $0)" in v3)
check("only active simple-list subscriptions drive streaming parse work and re-entry refreshes from the block",
      "private var updates: AnyCancellable" not in body_state and "func observe(_ block: AssistantBlock) -> AnyPublisher<Void, Never> {\n            refresh(block)" in body_state
      and "let updates = body.observe(block)" in content_edges and "guard transcriptMode == .simple else { return }" in observer
      and "if self.transcriptMode == .standard { self.stopSimpleProjection() }" in v3
      and "func stopSimpleProjection() {\n            simpleMessageSubs.removeAll()\n            simpleContentSubs.removeAll()" in v3
      and "coordinator.stopSimpleProjection()" in v3)

fallback = section(v3, "if let onShareMessage = self.onShareMessage", "let retryMsg = onRetryMessage")
check("legacy screenshot freezes the selected round before async rendering and never reads a live snapshot",
      fallback.index("ChatShareSnapshot.request") < fallback.index("Task { @MainActor")
      and "renderTurnImage(request" in fallback and "captureScrollingTurnScreenshot" not in fallback
      and "ChatShareCells.renderGroups" in share and "renderer.render(groups: groups, messages: request.messages" in share)
for path in ("ChatExportRenderer", "ChatShareSelectionView", "SessionExportNativeRenderer"):
    check(f"{path} pins shared views to standard appearance",
          r".environment(\.chatTranscriptDisplayMode, .standard)" in source(f"Views/Chat/SessionExport/{path}.swift"))

check("no new unguarded Observation API or deployment-target changes",
      not re.search(r"^\+[^+].*(?:@Observable\b|import Observation\b|IPHONEOS_DEPLOYMENT_TARGET)",
                    subprocess.check_output(["git", "diff", "795063a1", "--", "*.swift", "*.pbxproj"], cwd=ROOT, text=True), re.M))
