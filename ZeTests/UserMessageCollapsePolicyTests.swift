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
}
