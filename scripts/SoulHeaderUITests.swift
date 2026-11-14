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
            XCTAssertGreaterThan(name.frame.minY, avatar.frame.maxY)
            XCTAssertLessThanOrEqual(name.frame.width, 180)
            XCTAssertLessThan(avatar.frame.maxX, app.buttons["fixture.phone"].frame.minX)
            save(app, "header-\(arguments.joined())")
            app.scrollViews.firstMatch.swipeUp()
            save(app, "scrolled-\(arguments.joined())")
            avatar.tap()
            let slider = app.sliders.firstMatch
            XCTAssertTrue(slider.waitForExistence(timeout: 5))
            slider.adjust(toNormalizedSliderPosition: 1)
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
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name
        a.lifetime = .keepAlways; add(a)
    }
}
