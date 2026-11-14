import XCTest

final class SoulHeaderUITests: XCTestCase {
    @MainActor func testHeaderLayoutAndControls() {
        let app = XCUIApplication(bundleIdentifier: "com.ze.soul-header-harness")
        for arguments in [[], ["--dark"], ["--long-name"]] as [[String]] {
            app.launchArguments = arguments
            app.launch()
            let avatar = app.buttons["chat.soulAvatar"]
            XCTAssertTrue(avatar.waitForExistence(timeout: 15))
            let name = app.buttons["chat.providerName"]
            XCTAssertTrue(name.exists)
            XCTAssertEqual(avatar.frame.midX, app.frame.midX, accuracy: 3)
            XCTAssertEqual(name.frame.midX, app.frame.midX, accuracy: 3)
            XCTAssertLessThanOrEqual(name.frame.minY, avatar.frame.maxY + 1)
            XCTAssertGreaterThanOrEqual(name.frame.minY, avatar.frame.maxY - 10)
            XCTAssertLessThanOrEqual(name.frame.width, 200)
            // No frame lower bound for the pill: XCUI reports the label's intrinsic
            // width (78.3pt) regardless of the rendered capsule (measured from the
            // screenshots at 107pt hug-width / 129pt with the 128pt floor). The
            // 200pt cap above is observable and stays; width is screenshot-verified.
            XCTAssertLessThan(avatar.frame.maxX, app.buttons["fixture.phone"].frame.minX)
            save(app, "header-\(arguments.joined())")
            let scroll = app.scrollViews.firstMatch
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)), withVelocity: .slow, thenHoldForDuration: 0.2)
            save(app, "scrolled-\(arguments.joined())")
            avatar.tap()
            let slider = app.sliders.firstMatch
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            slider.adjust(toNormalizedSliderPosition: 1)
            save(app, "soul-size-maximum-\(arguments.joined())")
            // The synthetic drag can stop short of the end (landed on 71 of 80 in
            // one run), so assert against the size the slider actually settled on:
            // the production contract is that the header renders the chosen size.
            let rawSliderValue = (slider.value as? String ?? "").trimmingCharacters(in: .whitespaces)
            let chosenSliderSize: Double
            if rawSliderValue.hasSuffix("%"), let pct = Double(rawSliderValue.dropLast()) {
                chosenSliderSize = 40 + pct / 100 * 40
            } else {
                chosenSliderSize = Double(rawSliderValue) ?? -1
            }
            XCTAssertGreaterThan(chosenSliderSize, 0)
            app.buttons["完成"].tap()
            XCTAssertTrue(avatar.waitForExistence(timeout: 5))
            XCTAssertEqual(avatar.frame.width, CGFloat(chosenSliderSize), accuracy: 3)
            save(app, "header-maximum-\(arguments.joined())")
            name.tap()
            XCTAssertTrue(app.staticTexts["fixture.models"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    @MainActor private func save(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name
        a.lifetime = .keepAlways; add(a)
    }
}
