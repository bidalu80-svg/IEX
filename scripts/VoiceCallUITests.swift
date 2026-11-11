import XCTest

final class VoiceCallUITests: XCTestCase {
    @MainActor
    func testProductionCallControls() {
        let app = XCUIApplication(bundleIdentifier: "com.ze.voice-call-harness")
        for dark in [false, true] {
            app.launchArguments = dark ? ["--dark"] : []
            app.launch()
            let expand = app.buttons["voiceCall.expand"]
            XCTAssertTrue(expand.waitForExistence(timeout: 15))
            XCTAssertEqual(expand.label, "展开通话画面")
            save(app, dark ? "compact-dark" : "compact-light")
            expand.tap()
            XCTAssertEqual(expand.label, "收起通话画面")
            XCTAssertTrue(app.buttons["voiceCall.captions"].waitForExistence(timeout: 3))
            save(app, dark ? "expanded-dark" : "expanded-light")
            let mute = app.buttons["voiceCall.mute"]
            mute.tap()
            XCTAssertEqual(mute.label, "取消麦克风静音")
            XCTAssertEqual(app.staticTexts["voiceCall.status"].label, "麦克风已静音")
            mute.tap()
            XCTAssertEqual(mute.label, "麦克风静音")
            app.buttons["voiceCall.captions"].tap()
            XCTAssertFalse(app.staticTexts["voiceCall.transcript"].exists)
            app.buttons["voiceCall.captions"].tap()
            XCTAssertTrue(app.staticTexts["voiceCall.transcript"].exists)
            expand.tap()
            XCTAssertEqual(expand.label, "展开通话画面")
            XCTAssertFalse(app.buttons["voiceCall.captions"].exists)
            XCTAssertTrue(app.buttons["fixture.respond"].isHittable)
            app.buttons["fixture.respond"].tap()
            XCTAssertEqual(app.staticTexts["voiceCall.status"].label, "正在说话")
            XCTAssertTrue(app.buttons["voiceCall.interrupt"].waitForExistence(timeout: 3))
            app.buttons["voiceCall.interrupt"].tap()
            XCTAssertEqual(app.staticTexts["voiceCall.status"].label, "正在听")
            app.buttons["fixture.pause"].tap()
            XCTAssertEqual(app.staticTexts["voiceCall.status"].label, "通话已暂停")
            XCTAssertTrue(app.buttons["voiceCall.resume"].waitForExistence(timeout: 3))
            XCTAssertGreaterThanOrEqual(app.buttons["voiceCall.resume"].frame.height, 44)
            save(app, dark ? "paused-dark" : "paused-light")
            app.buttons["voiceCall.resume"].tap()
            XCTAssertFalse(app.buttons["voiceCall.resume"].exists)
            app.buttons["voiceCall.hangUp"].tap()
            XCTAssertTrue(app.staticTexts["fixture.ended"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["voiceCall.mute"].exists)
            app.terminate()
        }
        app.launchArguments = ["--large"]
        app.launch()
        XCTAssertTrue(app.buttons["voiceCall.expand"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["voiceCall.hangUp"].isHittable)
        XCTAssertTrue(app.buttons["voiceCall.mute"].isHittable)
        save(app, "compact-accessibility")
        app.buttons["voiceCall.expand"].tap()
        XCTAssertTrue(app.buttons["voiceCall.hangUp"].isHittable)
        save(app, "expanded-accessibility")
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        // AX switches to the destination tree before SwiftUI's 0.42 s spring
        // has visually settled. This wait is for screenshot sampling only;
        // control assertions still run against actual events with their limits.
        // Keep the shipping animation enabled so the image is its final frame.
        Thread.sleep(forTimeInterval: 0.8)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "voice-call-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
