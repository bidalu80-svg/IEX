import XCTest

final class UserMessageCollapsePolicyTests: XCTestCase {
    func testExactlyCharacterThresholdRemainsExpanded() {
        XCTAssertFalse(UserMessageCollapsePolicy.shouldCollapse(
            characterCount: UserMessageCollapsePolicy.characterThreshold
        ))
    }

    func testMoreThanCharacterThresholdStartsCollapsed() {
        XCTAssertTrue(UserMessageCollapsePolicy.shouldCollapse(
            characterCount: UserMessageCollapsePolicy.characterThreshold + 1
        ))
    }

    func testCollapsedPreviewHasAStablePositiveLineLimit() {
        XCTAssertGreaterThan(UserMessageCollapsePolicy.collapsedLineLimit, 0)
        XCTAssertEqual(UserMessageCollapsePolicy.characterThreshold, 1_200)
        XCTAssertEqual(UserMessageCollapsePolicy.lineThreshold, 16)
    }

    func testShortTextRemainsExpanded() {
        XCTAssertFalse(UserMessageCollapsePolicy.shouldCollapse(String(repeating: "a", count: 500)))
        XCTAssertFalse(UserMessageCollapsePolicy.shouldCollapse(String(repeating: "中", count: 500)))
    }

    func testSameLengthChineseAndEnglishCollapseIdentically() {
        let english = String(repeating: "a", count: 1_201)
        let chinese = String(repeating: "中", count: 1_201)
        XCTAssertTrue(UserMessageCollapsePolicy.shouldCollapse(english))
        XCTAssertTrue(UserMessageCollapsePolicy.shouldCollapse(chinese))

        let englishShort = String(repeating: "a", count: 1_200)
        let chineseShort = String(repeating: "中", count: 1_200)
        XCTAssertFalse(UserMessageCollapsePolicy.shouldCollapse(englishShort))
        XCTAssertFalse(UserMessageCollapsePolicy.shouldCollapse(chineseShort))
    }

    func testManyHardLineBreaksCollapseShortText() {
        let text = Array(repeating: "x", count: UserMessageCollapsePolicy.lineThreshold + 2)
            .joined(separator: "\n")
        XCTAssertFalse(UserMessageCollapsePolicy.shouldCollapse(
            characterCount: text.count,
            lineCount: UserMessageCollapsePolicy.lineThreshold
        ))
        XCTAssertTrue(UserMessageCollapsePolicy.shouldCollapse(text))
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
