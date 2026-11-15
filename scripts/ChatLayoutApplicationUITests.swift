import XCTest

final class ChatLayoutApplicationUITests: XCTestCase {
    @MainActor
    func testActualChatLayoutAndPreviewTap() {
        continueAfterFailure = false
        let bundle = ProcessInfo.processInfo.environment["ZE_LAYOUT_BUNDLE"]!
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "--verify-conversation-chat", "--verify-chat-layout-only"]
        if let fallback = ProcessInfo.processInfo.environment["ZE_LAYOUT_DYLD"], !fallback.isEmpty {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = fallback
        }
        app.launch()
        let ready = app.staticTexts["chat.layout.ready"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ready.exists || app.staticTexts["chat.layout.failed"].exists
        }, object: nil)
        let completedWait = XCTWaiter.wait(for: [finished], timeout: 210) == .completed
        let complete = completedWait && ready.exists
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "complete-app-layout-result"
        screen.lifetime = .keepAlways
        add(screen)
        XCTAssertTrue(complete, "Full application checks must finish; inspect chat-verification/result.json and hierarchy on failure")
        let preview = app.descendants(matching: .any)["chat.tool.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.isHittable)
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let close = app.buttons["chat.tool.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Upper part of real tool preview opens its real sheet")
        let opened = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        opened.name = "actual-tool-preview-opened"
        opened.lifetime = .keepAlways
        add(opened)
        close.tap()
        let tray = app.otherElements["chat.verify.attachments"].firstMatch
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        let point = tray.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 48, dy: tray.frame.height - 32))
        point.tap()
        XCTAssertTrue(app.navigationBars["附件.png"].waitForExistence(timeout: 5), "Actual attachment still opens its preview")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "actual-attachment-opened"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
