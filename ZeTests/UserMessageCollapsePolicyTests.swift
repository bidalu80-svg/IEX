import XCTest

final class UserMessageCollapsePolicyTests: XCTestCase {
    func testExactly500TokensRemainsExpanded() {
        XCTAssertFalse(UserMessageCollapsePolicy.shouldCollapse(tokenCount: 500))
    }

    func testMoreThan500TokensStartsCollapsed() {
        XCTAssertTrue(UserMessageCollapsePolicy.shouldCollapse(tokenCount: 501))
    }

    func testCollapsedPreviewHasAStablePositiveLineLimit() {
        XCTAssertGreaterThan(UserMessageCollapsePolicy.collapsedLineLimit, 0)
        XCTAssertEqual(UserMessageCollapsePolicy.tokenThreshold, 500)
    }

    func testShortUtf8TextSkipsTokenizer() {
        var tokenizerCalled = false
        let result = UserMessageCollapsePolicy.shouldCollapse(
            String(repeating: "a", count: 500)
        ) {
            tokenizerCalled = true
            return 501
        }

        XCTAssertFalse(result)
        XCTAssertFalse(tokenizerCalled)
    }

    func testLongTextUsesExactTokenCounter() {
        var tokenizerCalled = false
        let result = UserMessageCollapsePolicy.shouldCollapse(
            String(repeating: "a", count: 501)
        ) {
            tokenizerCalled = true
            return 501
        }

        XCTAssertTrue(result)
        XCTAssertTrue(tokenizerCalled)
    }

    func testViewportOffsetPreservesMessageScreenPosition() {
        let offset = UserMessageCollapsePolicy.viewportOffset(
            itemMinY: 960,
            preservedScreenMinY: 140,
            minimumOffset: -59,
            maximumOffset: 1_800
        )

        XCTAssertEqual(offset, 820)
        XCTAssertEqual(960 - offset, 140)
    }

    func testViewportOffsetClampsAtTopBoundary() {
        XCTAssertEqual(
            UserMessageCollapsePolicy.viewportOffset(
                itemMinY: 10,
                preservedScreenMinY: 100,
                minimumOffset: -59,
                maximumOffset: 1_800
            ),
            -59
        )
    }

    func testViewportOffsetClampsAtBottomBoundaryAfterCollapse() {
        XCTAssertEqual(
            UserMessageCollapsePolicy.viewportOffset(
                itemMinY: 1_900,
                preservedScreenMinY: 100,
                minimumOffset: -59,
                maximumOffset: 1_600
            ),
            1_600
        )
    }
}
