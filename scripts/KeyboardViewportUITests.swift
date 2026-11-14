import XCTest

final class KeyboardViewportUITests: XCTestCase {
    @MainActor
    func testKeyboardViewport() {
        let app = XCUIApplication(bundleIdentifier: "com.ze.keyboard-harness")
        for arguments in [[], ["--long"], ["--long", "--browse"]] as [[String]] {
            app.launchArguments = arguments
            app.launch()
            let field = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
            XCTAssertTrue(field.waitForExistence(timeout: 15))
            // Wait only for the fixture's initial UIKit layout and scroll.
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            let restingY = field.frame.midY
            let anchor = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'message.'"))
                .allElementsBoundByIndex.first(where: { $0.frame.minY > 150 && $0.frame.maxY < restingY - 80 })
            let anchorID = anchor?.identifier
            let anchorY = anchor?.frame.minY
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let raised = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in field.frame.midY < restingY - 100 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [raised], timeout: 5), .completed)
            field.typeText("hello")
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            XCTAssertLessThan(field.frame.maxY, app.keyboards.firstMatch.frame.minY)
            // Reject double keyboard avoidance (composer floating far above it).
            XCTAssertLessThan(app.keyboards.firstMatch.frame.minY - field.frame.maxY, 90)
            if arguments == ["--long"] {
                XCTAssertTrue(app.cells["message.199"].isHittable, "last message must stay above composer")
                XCTAssertLessThan(app.cells["message.199"].frame.maxY, field.frame.minY)
            }
            if arguments.contains("--browse"), let anchorID, let anchorY {
                XCTAssertEqual(app.cells[anchorID].frame.minY, anchorY, accuracy: 3)
            }
            save(app, "raised-\(arguments.joined(separator: "-"))")
            app.buttons["send"].tap()
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !app.keyboards.firstMatch.exists && abs(field.frame.midY - restingY) < 3
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            let landed = field.frame.midY
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            XCTAssertEqual(field.frame.midY, landed, accuracy: 1)
            if arguments == ["--long"] {
                XCTAssertTrue(app.cells["message.199"].isHittable)
                XCTAssertLessThan(app.cells["message.199"].frame.maxY, field.frame.minY)
            }
            if arguments.contains("--browse"), let anchorID, let anchorY {
                XCTAssertEqual(app.cells[anchorID].frame.minY, anchorY, accuracy: 3)
            }
            app.buttons["voice"].tap()
            XCTAssertEqual(field.frame.midY, restingY, accuracy: 3)
            save(app, "resting-\(arguments.joined(separator: "-"))")
            app.terminate()
        }
    }
    @MainActor private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
