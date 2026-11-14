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
    /// The header dissolve, exercised through the PRODUCTION
    /// ChatKeyboardViewport with fadeCompleteY = 200 (production uses
    /// 67; the taller band clears the simulator's status bar so the
    /// gradient is sampleable — the mechanism under test is identical)
    /// over a solid blue
    /// content surface: below the band the blue must be fully opaque;
    /// inside the band it must be dissolved toward the window
    /// background (white in light mode, black in dark mode). This is
    /// the check that was missing while the device stayed solid
    /// through five "green" runs.
    @MainActor
    func testHeaderFade() {
        let app = XCUIApplication(bundleIdentifier: "com.ze.keyboard-harness")
        app.launchArguments = ["--fade"]
        app.launch()
        let field = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        save(app, "fade-band")
        let image = app.screenshot().image
        let below = Self.pixel(image, xFraction: 0.5, yPoints: 320)
        XCTAssertGreaterThan(below.b, 200, "below the band the content must be opaque blue: \(below)")
        XCTAssertLessThan(below.r, 80, "below the band the content must be opaque blue: \(below)")
        let inside = Self.pixel(image, xFraction: 0.5, yPoints: 60)
        XCTAssertTrue(inside.r > 120 || inside.b < 120,
                      "inside the band the blue must be dissolved toward the background: \(inside)")
        app.terminate()
    }

    @MainActor
    func testPreviewAfterKeyboardDismissal() {
        let app = XCUIApplication(bundleIdentifier: "com.ze.keyboard-harness")
        for mode in [["--preview"], ["--preview", "--preview-only"]] {
            app.launchArguments = mode
            app.launch()
            let field = app.textFields["composer"].exists ? app.textFields["composer"] : app.textViews["composer"]
            XCTAssertTrue(field.waitForExistence(timeout: 15))
            for _ in 0..<2 {
                field.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                app.buttons["send"].tap()
                let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !app.keyboards.firstMatch.exists
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                let preview = app.buttons["preview-card"]
                XCTAssertTrue(preview.isHittable)
                // The upper half was outside the old 34pt/zero-height host.
                preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
                XCTAssertTrue(app.buttons["close-preview"].waitForExistence(timeout: 3))
                app.buttons["close-preview"].tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            save(app, "preview-after-dismiss-\(mode.count)")
            app.terminate()
        }
    }

    @MainActor
    func testFadeInsideNavigationStack() {
        let app = XCUIApplication(bundleIdentifier: "com.ze.keyboard-harness")
        app.launchArguments = ["--navigation-fade"]
        app.launch()
        XCTAssertTrue(app.buttons["next"].waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let image = app.screenshot().image
        // Away from the island, time glyph and navbar buttons.
        let top = Self.pixel(image, xFraction: 0.08, yPoints: 36)
        let below = Self.pixel(image, xFraction: 0.08, yPoints: 150)
        XCTAssertGreaterThan(top.r, below.r + 20, "production safe-area band must fade toward white")
        XCTAssertGreaterThan(below.b, 200)
        XCTAssertLessThan(below.r, 50)
        save(app, "navigation-production-fade")
        app.buttons["next"].tap()
        XCTAssertTrue(app.otherElements["next-page"].waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let next = Self.pixel(app.screenshot().image, xFraction: 0.08, yPoints: 36)
        XCTAssertLessThan(next.r, 80, "pushed page must not inherit conversation mask")
        app.terminate()
    }

    private static func pixel(_ image: UIImage, xFraction: CGFloat, yPoints: CGFloat) -> (r: Int, g: Int, b: Int) {
        let cg = image.cgImage!
        let px = min(cg.width - 1, max(0, Int(xFraction * CGFloat(cg.width))))
        let py = min(cg.height - 1, max(0, Int(yPoints * image.scale)))
        var raw: [UInt8] = [0, 0, 0, 0]
        let context = CGContext(data: &raw, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -px, y: -(cg.height - 1 - py), width: cg.width, height: cg.height))
        return (Int(raw[0]), Int(raw[1]), Int(raw[2]))
    }

    @MainActor private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
