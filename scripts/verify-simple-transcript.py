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
check("simple projects source blocks and reuses their IDs before the standard fold branch",
      re.search(r"for block in message\.blocks \{\s*guard let role = SimpleTranscript\.row\(for: block\) else \{ continue \}\s*"
                r"let item = MessageListItem\.assistantBlock\(message\.id, block\.id\)\s*newItems\.append\(item\)", simple_projection)
      and simple_projection.count("newItems.append(") == 2 and "continue" in simple_projection)
simple_roles = section(infra, "enum Row: Equatable", "static func hasText")
check("unreferenced tool images cannot form an independent simple row",
      re.search(r"enum Row: Equatable \{\s*case text\s*case question\s*\}", simple_roles)
      and re.search(r"-> Row\? \{\s*if block\.questionCard != nil \{ return \.question \}\s*"
                    r"if block\.kind == \.text, hasText\(block\.content\) \{ return \.text \}\s*return nil\s*\}", simple_roles))
simple_content = section(v3, "private func simpleContent", "private var simpleReadAloud")
simple_text_case = re.search(r"switch row \{\s*case \.text:(?P<body>.*?)^\s*case \.question:\s*"
                             r"QuestionCardView\(block: block\)\.padding\(\.vertical, 4\)\s*\}",
                             without_swift_comments(simple_content), re.M | re.S)
simple_text_body = simple_text_case["body"] if simple_text_case else ""
text_view = section(assistant, "private var textBlockView", "/// A delegation")
inline_media = section(markdown, "case .link(let destination, let children):", "case .html(let html):")
check("referenced images and links render only at their original Markdown position in simple replies",
      len(re.findall(r"\bblockContent\b", simple_text_body)) == 1
      and "SelectableMarkdownView(\n            markdown: block.content," in text_view
      and "linkAttrs[.link] = url" in inline_media and "return renderInlines(children, baseAttributes: linkAttrs)" in inline_media
      and "case .image(let source, let children):" in inline_media and "return renderImageAttachment(source: source)" in inline_media)
browser_capsule = section(assistant, "case .browserTool:", "case .readImageTool:")
check("standard browser tool still opens the existing capsule detail",
      "ToolCapsuleView(block: block" in browser_capsule and "detailBlock: $detailBlock" in browser_capsule
      and re.search(r"\.onTapGesture \{\s*detailBlock = block\s*\}", assistant))
column = section(v3, "if let simpleRow {", "} else {\n                standardContent")
check("first token and first line break keep the bubble at the full content column's leading edge",
      re.search(r"\.frame\(minWidth: simpleRow == \.text \? 0 : nil,\s*"
                r"maxWidth: maxWidth > 0 \? maxWidth : \(simpleRow == \.text \? \.infinity : nil\),\s*"
                r"alignment: \.leading\)", column)
      and "shortReplyWidth" not in v3
      and re.search(r"blockContent\s*\.padding\(\.horizontal, 12\)\s*\.padding\(\.vertical, 6\)\s*\.background\(", simple_text_body))
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
      "fitTextWidth: simpleRow == .text" in section(v3, "private var blockContent", "private func simpleContent")
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
      and "block.$content.map { SimpleTranscript.hasText($0) }" in content_edges
      and "return states.removeDuplicates().dropFirst().map { _ in () }" in content_edges)
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
      "return estimate + (simpleRow == .text ? 12 : 0)" in estimate
      and "simpleRow: role" in section(v3, "// Remap height cache", "// Re-entry seed:")
      and "simpleRow: simpleRows[item]" in section(v3, "// Height estimation for items not yet measured", "/// Subscriptions for bridge")
      and "simpleRow: simpleRows[item]" in section(v3, "prefetchItemsAt indexPaths:", "// MARK: - UIScrollViewDelegate"))
check("shared footer decision hides usage and action reservation and respects live question liveness",
      all(marker in v3 for marker in ("bridge.simpleFooter = footer", "newFooters[message.id] = footer",
                                      "mode == .standard && reservesCompletionActionSpace", ".questionCardToggled"))
      and "QuestionCardCoordinator.shared.isPending" in infra and "message.isAwaitingModelResponse" in infra)
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
