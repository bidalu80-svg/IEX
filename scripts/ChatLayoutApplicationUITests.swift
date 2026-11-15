import XCTest

final class ChatLayoutApplicationUITests: XCTestCase {
    @MainActor
    func testActualChatLayoutAndPreviewTap() {
        continueAfterFailure = false
        let bundle = ProcessInfo.processInfo.environment["ZE_LAYOUT_BUNDLE"]!
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "--verify-conversation-chat", "--verify-chat-layout-only"]
        let verifyAvatar = ProcessInfo.processInfo.environment["ZE_VERIFY_SOUL_HEADER"] == "1"
        if verifyAvatar { app.launchArguments.append("--verify-soul-avatar") }
        if let fallback = ProcessInfo.processInfo.environment["ZE_LAYOUT_DYLD"], !fallback.isEmpty {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = fallback
        }
        if verifyAvatar {
            // Already launched via simctl and completed the in-app checks.
            // Avoid XCTest's launch-idle handshake while state stress runs.
            app.activate()
        } else {
            app.launch()
        }
        let ready = app.staticTexts["chat.layout.ready"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ready.exists || app.staticTexts["chat.layout.failed"].exists
        }, object: nil)
        let completedWait = XCTWaiter.wait(for: [finished], timeout: 330) == .completed
        let complete = completedWait && ready.exists
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "complete-app-layout-result"
        screen.lifetime = .keepAlways
        add(screen)
        XCTAssertTrue(complete, "Full application checks must finish; inspect chat-verification/result.json and hierarchy on failure")
        if verifyAvatar {
            let avatar = app.buttons["chat.soulAvatar"].firstMatch
            XCTAssertTrue(avatar.waitForExistence(timeout: 5))
            let beforeTap = XCTAttachment(string: app.debugDescription)
            beforeTap.name = "header-before-avatar-tap"
            beforeTap.lifetime = .keepAlways
            add(beforeTap)
            // A custom overlay can have a valid on-screen frame while XCTest
            // reports isHittable=false. Send an actual screen touch and require
            // the actual settings sheet; never invoke the action directly.
            avatar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let done = app.buttons["完成"].firstMatch
            let openedSoul = done.waitForExistence(timeout: 5)
            if !openedSoul {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "header-after-avatar-tap"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            XCTAssertTrue(openedSoul, "Avatar tap opens actual Soul settings")
            done.tap()
            // The action establishes one deadline shared across view remounts.
            // Wait for its expiry, then background/foreground the actual app.
            let animation = app.descendants(matching: .any)["chat.soulAnimation"].firstMatch
            let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (animation.value as? String) == "idle"
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 8), .completed)
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(avatar.waitForExistence(timeout: 5))
            XCTAssertEqual(animation.value as? String, "idle", "Expired celebration is not replayed on return")
            let returned = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            returned.name = "actual-avatar-after-settings-and-foreground"
            returned.lifetime = .keepAlways
            add(returned)
        }
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
