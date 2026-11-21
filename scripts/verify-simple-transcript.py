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


chat = source("Views/Chat/AIChatView.swift")
settings = source("Views/ContentView.swift")
v3 = source("Agent/MessageList/CollectionViewMessageListV3.swift")
infra = source("Agent/MessageList/MessageListInfrastructure.swift")
layout = source("Agent/MessageList/MessageListLayout.swift")
search = source("Views/Chat/ChatSearch.swift")
share = source("Views/Chat/SessionExport/ChatExportRenderer.swift")

preference = "@AppStorage(ChatTranscriptDisplayMode.preferenceKey)"
check("appearance alone offers the default-standard, local enum preference",
      '"chat.transcriptDisplayMode"' in infra and settings.count(preference) == chat.count(preference) == 1
      and 'Picker("正文显示", selection: $transcriptDisplayMode)' in settings
      and chat.count("transcriptDisplayMode: transcriptDisplayMode") == 2)
check("single V3 host receives mode before attach and updates it in place",
      chat.count("CollectionViewMessageListV3(") == 1 and ".id(transcriptDisplayMode)" not in chat
      and re.search(r"setInitialTranscriptMode\(transcriptDisplayMode\).*?\.attach\(to:", v3, re.S))

projection = section(v3, "// Build items", "// Remap height cache")
check("simple projects source blocks and reuses their IDs before the standard fold branch",
      projection.index(".update(in: message, snapshots: snapshotImages)") < projection.index("let stepsCollapsed")
      and "for block in message.blocks" in projection and ".assistantBlock(message.id, block.id)" in projection
      and projection.index(".update(in: message, snapshots: snapshotImages)") < projection.index(".assistantHeader(message.id)"))
check("tool media requires a real detail asset and deduplicates against Markdown references",
      all(marker in infra for marker in ("snapshot.snapshot.type == .image", "snapshot.mediaResolver(ref)",
                                         "CGImageSourceGetCount", "referenced.isDisjoint(with: media.aliases)", "claimed.insert(local)"))
      and "Button { bridge.detailBlock = block }" in v3)
aliases = section(infra, "var aliases: Set<String>", "private struct Member")
path_aliases = section(infra, "private static func pathAliases", "// MARK: - MessageListItem")
check("reply path wins over an image snapshot copied from the original tool path",
      all(marker in aliases for marker in ("original, readPath, snapshot?.ref.relativePath, snapshot?.ref.linuxPath",
                                           "pathAliases($0)", "url.standardizedFileURL.path"))
      and "original = block.imageFilePath" in infra and "case .readImageTool(let path)" in infra
      and "pathAliases($0, markdown: true)" in infra and "resolveZeFileURL(url: url)" in path_aliases
      and "lastPathComponent" not in aliases + path_aliases)
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
check("hidden blocks can enter without token-driven tool log diffs",
      "vm.$toolSnapshots.map { SimpleTranscript.snapshotImages($0) }" in observer
      and "simpleMessageSubs[message.id]?.0 != ObjectIdentifier(message)" in observer
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
      and "return [text, kind, question, image, status]" in block_edges
      and all(f"block.${field}.removeDuplicates().dropFirst()" in block_edges
              for field in ("kind", "questionCard", "imageFilePath"))
      and all(marker in text_edges for marker in (
          "block.$kind.map { $0 == .text }.removeDuplicates()", "isText.map",
          "guard isText else { return Empty<Void, Never>().eraseToAnyPublisher() }",
          "return Self.contentEdges(block)", "return sources.switchToLatest().eraseToAnyPublisher()"))
      and "block.$content.map" in content_edges and "block.content" not in content_edges
      and "(hasText: SimpleTranscript.hasText(content), refs: SimpleTranscript.explicitMediaReferences(content))" in content_edges
      and re.search(r"return states\.removeDuplicates \{ previous, current in\s*"
                    r"previous\.hasText == current\.hasText && previous\.refs == current\.refs\s*"
                    r"\}\.dropFirst\(\)\.map \{ _ in \(\) \}", content_edges))
check("message sink marks the simple projection dirty",
      re.search(r"(?m)^[ \t]*self\.markSimpleProjectionDirty\(\)[ \t]*$", sink_body))
check("message sink rejects queued callbacks from replaced message instances",
      re.search(r"(?m)^[ \t]*guard\b[^{}]*,\s*"
                r"self\.simpleMessageSubs\[message\.id\]\?\.0 == ObjectIdentifier\(message\)"
                r"\s+else\s*\{\s*return\s*\}", sink_body))
check("message projection retains its subscription under the current message identity",
      re.match(r"\s*simpleMessageSubs\[message\.id\] = \(ObjectIdentifier\(message\), sub\)", after_sink))
signature = section(infra, "mutating func update(in message:", "static func rows(in message:")
attachment = section(v3, "attachmentSizeChangedSub = NotificationCenter", "let visibleIPs =")
check("semantic membership reuses rows while byte-count, Markdown and media edges are handled separately",
      re.search(r"block\.\$toolStatus\.map \{ Self\.normalizedStatus\(\$0\) \}\s*"
                r"\.removeDuplicates\(\)\.dropFirst\(\)", block_edges)
      and re.search(r"if case \.streaming\(_\)\? = status \{ return \.streaming\(bytes: 0\) \}\s*return status", status)
      and "self.markFooterDirty(message.id)" in sink_body
      and "footerPresentation(for: message" in projection
      and re.search(r"if messageObject == identity && members == nextMembers \{\s*"
                    r"guard imageProbes\.retryPending\(\) else \{ return rows \}", signature)
      and signature.index("else { return rows }") < signature.index("project(nextMembers, imageProbes: &imageProbes)")
      and all(marker in signature for marker in ("ObjectIdentifier(block)", "block.questionCard != nil",
                                                 "ToolImage(block: block, snapshots: snapshots)",
                                                 "previous.source == source", "explicitMediaReferences(source)"))
      and attachment.index("simpleProjections.removeAll()") < attachment.index("markSimpleProjectionDirty()"))
probe = section(infra, "private struct ImageProbes", "@MainActor struct Projection")
retry = section(probe, "mutating func retryPending()", "mutating func containsImage")
project = section(infra, "private static func project(", "static func hasText(")
check("an unchanged snapshot retries only failed image URLs and promotes readable files into the cache",
      "let arrived = pending.filter(Self.isImage)" in retry
      and "available.formUnion(arrived)" in retry and "pending.subtract(arrived)" in retry
      and "return !arrived.isEmpty" in retry
      and probe.index("if available.contains(url) { return true }") < probe.index("if Self.isImage(url)")
      and probe.index("if pending.contains(url) { return false }") < probe.index("if Self.isImage(url)")
      and re.search(r"if Self\.isImage\(url\) \{\s*available\.insert\(url\)\s*return true\s*\}\s*"
                    r"pending\.insert\(url\)\s*return false", probe)
      and project.index("referenced.isDisjoint(with: media.aliases)") < project.index("imageProbes.containsImage(at: local)")
      and project.index("imageProbes.containsImage(at: local)") < project.index("rows[member.id] = .media([local])"))
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
check("snapshot, cell configuration and prefetch all retain the simple media estimate",
      "if case .media(_)? = simpleRow { return 160 }" in estimate
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
      "SimpleTranscript.rows(in: message" in search and "mode == self.transcriptMode" in search
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
