import Combine
import XCTest
@testable import Ze

final class SimpleBodySegmentTests: XCTestCase {
    func testUsesSourceOrderAndKeepsDuplicateEmbeddingsSeparate() {
        let source = """
        before ![first](chart.png) ![second](chart.png) between ![clip](movie.mov) after

        ![sound](sample.m4a)

        | name | score |
        | --- | --- |
        | item | 1 |

        ![report](report.pdf)
        """
        let segments = SimpleBodySegment.parse(source, finalised: true)
        XCTAssertEqual(segments.map(\.id.kind), [.text, .image, .image, .text, .video, .text, .audio, .table, .file])
        let images = segments.filter { $0.id.kind == .image }
        XCTAssertEqual(images.map { $0.media?.source }, ["chart.png", "chart.png"])
        XCTAssertEqual(Set(segments.map(\.id)).count, segments.count)
        XCTAssertEqual(segments.last?.searchText, "report.pdf")
        XCTAssertEqual(segments.first(where: { $0.id.kind == .table })?.searchText, "name\tscore\nitem\t1")
    }

    func testIgnoresLiteralImageSyntaxAndDoesNotCreateEmptyBubbles() {
        let literal = #"`![example](code.png)` \![escaped](escape.png) [report](report.pdf)"#
        let text = SimpleBodySegment.parse(literal, finalised: true)
        XCTAssertEqual(text.map(\.id.kind), [.text])
        XCTAssertTrue(text.first?.searchText.contains("report") == true)
        let media = SimpleBodySegment.parse("![image](ze://workspace/export)\n![image](ze://workspace/export)", finalised: true)
        XCTAssertEqual(media.map(\.id.kind), [.image, .image])
        XCTAssertEqual(Set(media.map(\.id)).count, 2)
        XCTAssertTrue(SimpleBodySegment.parse(" \n\n", finalised: true).isEmpty)
    }

    func testStreamingKeepsEstablishedPrefixAndTableIdentity() {
        let prefix = "prefix ![clip](one.mp4) suffix"
        let pending = SimpleBodySegment.parse(prefix + " ![open](two.m4", finalised: false)
        let completed = SimpleBodySegment.parse(prefix + " ![open](two.m4a)", finalised: false)
        XCTAssertEqual(pending.map(\.id.kind), [.text, .video, .text])
        XCTAssertEqual(Array(completed.prefix(pending.count).map(\.id)), pending.map(\.id))
        XCTAssertEqual(completed.last?.id.kind, .audio)

        let header = "| a | b |\n| --- | --- |\n| first | 2 |\n"
        let partial = SimpleBodySegment.parse(header + "| second", finalised: false)
        let committed = SimpleBodySegment.parse(header + "| second | 3 |\n", finalised: false)
        XCTAssertEqual(partial.map(\.id.kind), [.table])
        XCTAssertEqual(partial.map(\.id), committed.map(\.id))
        XCTAssertFalse(partial.first?.searchText.contains("second") ?? true)
        XCTAssertTrue(committed.first?.searchText.contains("second\t3") == true)
    }

    func testKeepsContainerStyleAndDoesNotSplitTableContents() {
        let quote = SimpleBodySegment.parse("> **before ![plot](plot.png) after**", finalised: true)
        XCTAssertEqual(quote.map(\.id.kind), [.text, .image, .text])
        for segment in quote where segment.id.kind == .text {
            guard case .blockquote(let blocks)? = segment.blocks.first,
                  case .paragraph(let inlines)? = blocks.first,
                  case .strong? = inlines.first else { return XCTFail("Lost quote or emphasis") }
        }
        let table = SimpleBodySegment.parse("| image |\n| --- |\n| ![figure](figure.png) |", finalised: true)
        XCTAssertEqual(table.map(\.id.kind), [.table])
    }

    func testOrderedListContinuesAcrossMediaWithoutRepeatingItsMarker() {
        let source = "4. before ![plot](a.png) after\n5. next\n6. ![plot](b.png)\n7. last"
        let segments = SimpleBodySegment.parse(source, finalised: true)
        XCTAssertEqual(segments.map(\.id.kind), [.text, .image, .text, .image, .text])
        let text = segments.filter { $0.id.kind == .text }.map(\.searchText)
        guard text.count == 3 else { return XCTFail("Expected three text segments") }
        XCTAssertEqual(text[0].trimmingCharacters(in: .whitespaces), "4. before")
        XCTAssertEqual(text[1].trimmingCharacters(in: .whitespaces), "after\n5. next")
        XCTAssertEqual(text[2], "7. last")
    }

    func testGalleryTitlesUseOriginalAltAndStandardSourceFallback() {
        let source = #"![季度趋势](chart.png) ![**季度** \*趋势](chart.png) ![ ](chart.png) ![](charts/chart%20one.png)"#
        let segments = SimpleBodySegment.parse(source, finalised: true)
        let titles = SimpleBodySegment.imageGalleryTitles(in: source, segments: segments)
        XCTAssertEqual(segments.map(\.id.kind), [.image, .image, .image, .image])
        XCTAssertEqual(segments.map { titles[$0.id] }, ["季度趋势", #"**季度** \*趋势"#, " ", "chart%20one.png"])
    }

    func testCopyUsesSourceMarkdownIncludingBothImageAndLinkDestinations() {
        let linkedImage = "[![plot](a.png)](https://example.com/detail)"
        let file = "![report](file:///tmp/report.pdf)"
        let firstText = "前文 [source](https://example.com/source)"
        let source = "\(firstText)\r\n\r\n\(linkedImage)\r\n\r\n\(file)"
        let segments = SimpleBodySegment.parse(source, finalised: true)
        XCTAssertEqual(segments.map(\.id.kind), [.text, .image, .file])
        XCTAssertEqual(segments.map { $0.markdownForCopy(in: source, segments: segments) }, [firstText, linkedImage, file])
        XCTAssertEqual(segments.first(where: { $0.id.kind == .image })?.media?.linkDestination, "https://example.com/detail")
    }

    func testCopyTextOnEitherSideOfImageInEmphasisUsesOnlyThatSourceSlice() {
        let source = "**前 ![图](a.png) 后**"
        let segments = SimpleBodySegment.parse(source, finalised: true)
        XCTAssertEqual(segments.map(\.id.kind), [.text, .image, .text])
        XCTAssertEqual(segments.map { Array($0.markdownForCopy(in: source, segments: segments).utf8) },
                       ["**前 ", "![图](a.png)", " 后**"].map { Array($0.utf8) })
    }

    func testCopyReferenceImagePreservesSourceWithoutItsDefinition() throws {
        let image = "![report][doc]"
        let source = "\(image)\r\n\r\n[doc]: ze://workspace/report.pdf"
        let segments = SimpleBodySegment.parse(source, finalised: true)
        XCTAssertEqual(segments.map(\.id.kind), [.file])
        let attachment = try XCTUnwrap(segments.first)
        XCTAssertEqual(attachment.media?.source, "ze://workspace/report.pdf")
        XCTAssertEqual(Array(attachment.markdownForCopy(in: source, segments: segments).utf8), Array(image.utf8))
    }

    func testOriginalSourceAlignmentIgnoresAnExtraImageInTheStreamingTail() throws {
        let source = "**前 ![_季度_](chart.png) 后**\n\nA | ![后图](b.png)"
        let segments = SimpleBodySegment.parse(source, finalised: false)
        XCTAssertEqual(segments.map(\.id.kind), [.text, .image, .text])
        XCTAssertEqual(SimpleBodySegment.parse(source, finalised: true).filter { $0.id.kind == .image }.count, 2)
        let image = try XCTUnwrap(segments.first(where: { $0.id.kind == .image }))
        let prefix = try XCTUnwrap(segments.first)
        let titles = SimpleBodySegment.imageGalleryTitles(in: source, segments: segments, finalised: false)
        XCTAssertEqual(titles[image.id], "_季度_")
        XCTAssertEqual(Array(prefix.markdownForCopy(in: source, segments: segments, finalised: false).utf8), Array("**前 ".utf8))
        XCTAssertEqual(image.markdownForCopy(in: source, segments: segments, finalised: false), "![_季度_](chart.png)")
    }

    func testOriginalSourceAlignmentDoesNotBorrowTheSpanOfAnImageAtAnotherPosition() throws {
        let source = "![other](chart.png)\n\n![_keep_](chart.png)"
        let segments = SimpleBodySegment.parse("lead ![moved](chart.png)\n\n![_keep_](chart.png)", finalised: true)
        let images = segments.filter { $0.id.kind == .image }
        let moved = try XCTUnwrap(images.first)
        let kept = try XCTUnwrap(images.last)
        let titles = SimpleBodySegment.imageGalleryTitles(in: source, segments: segments)
        XCTAssertNil(titles[moved.id])
        XCTAssertEqual(moved.markdownForCopy(in: source, segments: segments), "![moved](<chart.png>)")
        XCTAssertEqual(titles[kept.id], "_keep_")
        XCTAssertEqual(kept.markdownForCopy(in: source, segments: segments), "![_keep_](chart.png)")
    }

    func testOriginalSourceAlignmentKeepsSameURLImagesDistinctAfterBlockMath() throws {
        let source = "$$\nx\n$$\n\n![_甲_](chart.png)\n\n![_乙_](chart.png)"
        let segments = SimpleBodySegment.parse(source, finalised: true)
        let images = segments.filter { $0.id.kind == .image }
        XCTAssertEqual(images.map(\.id.line), [3, 5])
        let titles = SimpleBodySegment.imageGalleryTitles(in: source, segments: segments)
        XCTAssertEqual(images.map { titles[$0.id] }, ["_甲_", "_乙_"])
        XCTAssertEqual(images.map { $0.markdownForCopy(in: source, segments: segments) },
                       ["![_甲_](chart.png)", "![_乙_](chart.png)"])
        let formula = try XCTUnwrap(segments.first)
        XCTAssertEqual(formula.markdownForCopy(in: source, segments: segments), "$$\nx\n$$")
    }

    func testOriginalSourceAlignmentPreservesOriginalBytesAcrossOtherPreprocessing() throws {
        let table = "| name |\n| --- |\n| item |"
        let envelope = #"{"schemaVersion":1,"id":"summary","title":"Summary","components":[{"id":"totals","type":"metric_grid","items":[{"id":"total","label":"Total","value":1}]}]}"#
        let imageMarkdown = "![raw $x+y$](chart.png)"
        let source = "\(table)\n![_table_](chart.png)\n\n\(envelope)\n\n• text $x+y$ \(imageMarkdown)"
        let segments = SimpleBodySegment.parse(source, finalised: true)
        XCTAssertEqual(segments.map(\.id.kind), [.table, .image, .text, .image])
        let images = segments.filter { $0.id.kind == .image }
        let titles = SimpleBodySegment.imageGalleryTitles(in: source, segments: segments)
        XCTAssertEqual(images.map { titles[$0.id] }, ["_table_", "raw $x+y$"])
        XCTAssertEqual(images.map { $0.markdownForCopy(in: source, segments: segments) }, ["![_table_](chart.png)", imageMarkdown])
        let standaloneTable = try XCTUnwrap(segments.first)
        XCTAssertEqual(standaloneTable.markdownForCopy(in: source, segments: segments), table)
    }

    func testCompletionRequiresVisibleTextNotJustATextSegment() {
        let segments = SimpleBodySegment.parse("Readable\n\n![plot](a.png)\n\n---", finalised: true)
        XCTAssertEqual(segments.map(\.id.kind), [.text, .image, .text])
        XCTAssertEqual(segments.map(\.hasVisibleText), [true, false, false])
        XCTAssertFalse(SimpleBodySegment.parse("> ---", finalised: true).contains(where: \.hasVisibleText))
    }

    @MainActor
    func testMediaReplacementInvalidatesSizeAndAnUnobservedBodyDoesNotUpdate() async throws {
        let block = AssistantBlock(kind: .text, content: "![plot](wide.png)")
        let body = block.simpleBody
        let original = try XCTUnwrap(body.segments.first)
        let originalMedia = try XCTUnwrap(original.media)
        let size = CGSize(width: 300, height: 100)
        XCTAssertTrue(body.recordMediaSize(size, for: original.id, media: originalMedia))
        let subscription = body.observe(block).sink { _ in }
        subscription.cancel()

        block.content = "![plot](tall.png)"
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(body.segments.first?.media, originalMedia)
        XCTAssertEqual(body.segmentsForSearch(block).first?.media?.source, "tall.png")
        XCTAssertEqual(body.segments.first?.media, originalMedia)

        let resumed = body.observe(block).sink { _ in }
        defer { resumed.cancel() }
        let replacement = try XCTUnwrap(body.segments.first)
        let replacementMedia = try XCTUnwrap(replacement.media)
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertNil(body.mediaSize(for: replacement.id, media: replacementMedia))
        XCTAssertFalse(body.recordMediaSize(size, for: original.id, media: originalMedia))
        XCTAssertTrue(body.recordMediaSize(CGSize(width: 100, height: 300), for: replacement.id, media: replacementMedia))
    }
}
