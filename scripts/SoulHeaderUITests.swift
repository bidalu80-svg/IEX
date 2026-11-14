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
            if arguments != ["--long-name"] { XCTAssertGreaterThan(name.frame.width, 100) }
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
            // adjust() can stop short of the end (one run landed on 71 of 80);
            // tap the track's right end until the value really is the maximum.
            var sliderAttempts = 0
            while (Double(slider.value as? String ?? "") ?? 0) < 80, sliderAttempts < 3 {
                slider.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5)).tap()
                sliderAttempts += 1
            }
            save(app, "soul-size-maximum-\(arguments.joined())")
            app.buttons["完成"].tap()
            XCTAssertTrue(avatar.waitForExistence(timeout: 5))
            XCTAssertEqual(avatar.frame.width, 80, accuracy: 3)
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
