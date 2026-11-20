import XCTest

final class ChatLayoutApplicationUITests: XCTestCase {
    @MainActor
    func testActualChatLayoutAndPreviewTap() {
        continueAfterFailure = false
        let bundle = ProcessInfo.processInfo.environment["ZE_LAYOUT_BUNDLE"]!
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "--verify-conversation-chat", "--verify-chat-layout-only", "--verify-send-layout"]
        let verifyAvatar = ProcessInfo.processInfo.environment["ZE_VERIFY_SOUL_HEADER"] == "1"
        if verifyAvatar { app.launchArguments.append("--verify-soul-avatar") }
        if !verifyAvatar { app.launchArguments.append("--verify-search-focus-interruption") }
        if ProcessInfo.processInfo.environment["ZE_VERIFY_KEYBOARD_HANG"] == "1" {
            app.launchArguments.append("--verify-keyboard-hang")
        }
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
            let tapFrame = avatar.frame
            let tapEvidence = XCTAttachment(string: "{\"event\":\"avatar.coordinateTap\",\"point\":[\(tapFrame.midX),\(tapFrame.midY)],\"frame\":[\(tapFrame.minX),\(tapFrame.minY),\(tapFrame.width),\(tapFrame.height)]}")
            tapEvidence.name = "avatar-coordinate-tap.json"
            tapEvidence.lifetime = .keepAlways
            add(tapEvidence)
            avatar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let done = app.buttons["完成"].firstMatch
            let openedSoul = done.waitForExistence(timeout: 5)
            let queryEvidence = XCTAttachment(string: "{\"event\":\"settings.doneQuery\",\"exists\":\(openedSoul),\"label\":\"完成\"}")
            queryEvidence.name = "avatar-settings-query.json"
            queryEvidence.lifetime = .keepAlways
            add(queryEvidence)
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
        verifySearchThroughChatMenu(app, interruptsOpening: !verifyAvatar)
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

    @MainActor
    private func verifySearchThroughChatMenu(_ app: XCUIApplication, interruptsOpening: Bool) {
        let gear = app.buttons["chat.moreOptions"].firstMatch
        let search = app.buttons.matching(NSPredicate(format: "label IN %@", ["聊天内搜索", "Search in Chat"])).firstMatch
        let fields = app.textFields.matching(identifier: "chatSearchField")
        let field = fields.firstMatch
        let done = app.buttons["chatSearchDone"]
        let counter = app.staticTexts["chatSearchCounter"]
        let keyboard = app.keyboards.firstMatch
        let chinese = ProcessInfo.processInfo.environment["ZE_VERIFY_SEARCH_NINE_KEY"] == "1"
        let compactAccessibility = ProcessInfo.processInfo.environment["ZE_VERIFY_SEARCH_COMPACT_ACCESSIBILITY"] == "1"
        if compactAccessibility {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        defer {
            if compactAccessibility { XCUIDevice.shared.orientation = .portrait }
        }
        let trace = app.staticTexts["chat.search.trace"]
        XCTAssertTrue(trace.exists)
        let offset = searchEvents(trace).count

        XCTAssertFalse(field.exists)
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        recordSearchScreen("chat-search-before")
        gear.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(fields.count, 1)
        waitForSearchState("The field and Done are both hittable") { field.isHittable && done.isHittable }
        XCTAssertGreaterThanOrEqual(field.frame.minY, gear.frame.maxY)
        if interruptsOpening {
            waitForSearchState("A fully visible row has an unconsumed request") {
                self.searchEvents(trace).dropFirst(offset).contains {
                    $0["event"] as? String == "rowReady" && $0["held"] as? Bool == true
                }
            }
            XCTAssertFalse(keyboard.exists)
            XCTAssertFalse(searchEvents(trace).dropFirst(offset).contains { $0["event"] as? String == "focusBegan" })
            XCUIDevice.shared.press(.home)
            waitForSearchState("The app enters the background before retrying the pending focus request") {
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }
            app.activate()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let opening = Array(searchEvents(trace).dropFirst(offset))
        let openingNames = opening.compactMap { $0["event"] as? String }
        guard let ready = openingNames.firstIndex(of: "rowReady"),
              let focused = openingNames.firstIndex(of: "focusBegan"),
              let shown = openingNames.firstIndex(of: "keyboardWillShow"),
              let fieldID = opening[ready]["field"] as? String else {
            XCTFail("Missing opening events: \(opening)"); return
        }
        XCTAssertLessThan(ready, focused)
        XCTAssertLessThan(focused, shown)
        XCTAssertEqual(opening[focused]["field"] as? String, fieldID)
        XCTAssertEqual(opening[shown]["field"] as? String, fieldID)
        XCTAssertFalse(openingNames.contains("focusEnded"))
        XCTAssertEqual(openingNames.filter { $0 == "rowReady" }.count, 1)
        XCTAssertEqual(openingNames.filter { $0 == "fieldMounted" }.count, 1)
        if interruptsOpening {
            guard let background = openingNames.firstIndex(of: "backgroundBeforeFocus") else {
                XCTFail("No actual scene interruption was observed"); return
            }
            XCTAssertLessThan(ready, background)
            XCTAssertLessThan(background, focused)
        }
        if compactAccessibility {
            XCTAssertLessThan(opening[ready]["windowHeight"] as? Double ?? .infinity,
                              opening[ready]["windowWidth"] as? Double ?? 0)
            XCTAssertGreaterThan(opening[ready]["height"] as? Double ?? 0, 85)
            XCTAssertGreaterThanOrEqual(done.frame.minY, field.frame.maxY)
            XCTAssertEqual(opening[ready]["accessibilitySize"] as? Bool, true)
            XCTAssertEqual(opening[ready]["reduceMotion"] as? Bool, true)
        } else if (opening[ready]["width"] as? Double ?? 0) >= 360,
                  opening[ready]["accessibilitySize"] as? Bool == false {
            XCTAssertLessThan(done.frame.minY, field.frame.maxY)
            XCTAssertGreaterThan(done.frame.maxY, field.frame.minY)
        }
        let searchKey = keyboard.buttons.matching(NSPredicate(format: "label IN %@", ["搜索", "Search"])).firstMatch
        XCTAssertTrue(searchKey.exists)
        var submissionStart: Int?
        for single in [false, true] {
            if single { app.buttons["chatSearchClear"].tap() }
            let query = chinese ? (single ? "下次见" : "下次") : (single ? "singlequery" : "layoutsearch")
            if chinese {
                enterNineKeyQuery(query, digits: single ? "942245426" : "94224", app: app, keyboard: keyboard)
            } else {
                field.typeText(query)
            }
            XCTAssertEqual(field.value as? String, query)
            let count = single ? 1 : (chinese ? 4 : 3)
            waitForSearchState("Initial hit \(count)/\(count)") { counter.label == "结果 \(count)，共 \(count) 个" }
            let offset = searchEvents(trace).count
            if submissionStart == nil { submissionStart = offset }
            for (submit, index) in (single ? [1, 1] : [1, 2]).enumerated() {
                searchKey.tap()
                waitForSearchState("One native submit per tap, now at \(index)/\(count)") {
                    counter.label == "结果 \(index)，共 \(count) 个" && self.searchEvents(trace).dropFirst(offset)
                        .filter { $0["event"] as? String == "submit" }.count >= submit + 1
                }
                XCTAssertTrue(keyboard.exists)
            }
            let submitted = Array(searchEvents(trace).dropFirst(offset))
            let evidence = opening + submitted
            let data = try! JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted)
            let attachment = XCTAttachment(string: String(decoding: data, as: UTF8.self))
            attachment.name = single ? "chat-search-single-hit-events" : "chat-search-multiple-hit-events"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(submitted.compactMap { $0["event"] as? String }, ["submit", "submit"],
                           "No field replacement, responder loss, or keyboard hide/show during this submit sequence")
            XCTAssertTrue(submitted.allSatisfy {
                $0["field"] as? String == fieldID && $0["firstResponder"] as? Bool == true && $0["text"] as? String == query
            })
            XCTAssertEqual(fields.count, 1)
        }
        let frames = XCTAttachment(string: "field=\(field.frame), gear=\(gear.frame), done=\(done.frame), keyboard=\(keyboard.frame)")
        frames.name = "chat-search-frames"
        frames.lifetime = .keepAlways
        add(frames)
        recordSearchScreen("chat-search-typing")
        if let submissionStart {
            let allSubmissions = searchEvents(trace).dropFirst(submissionStart)
            XCTAssertEqual(allSubmissions.compactMap { $0["event"] as? String }, Array(repeating: "submit", count: 4))
        }
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !field.exists && !keyboard.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        recordSearchScreen("chat-search-closed")
    }

    @MainActor
    private func enterNineKeyQuery(_ query: String, digits: String, app: XCUIApplication, keyboard: XCUIElement) {
        let letters = ["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ"]
        for digit in digits {
            let group = letters[String(digit)] ?? ""
            guard let key = keyboard.keys.allElementsBoundByIndex.first(where: {
                $0.label == String(digit) || $0.label.uppercased().filter(\.isLetter) == group
            }) else {
                XCTFail("Configure and select the Simplified Chinese Pinyin 9-key keyboard (missing \(group))"); return
            }
            key.tap()
        }
        let candidates = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", query))
        waitForSearchState("Missing Chinese IME candidate \(query)") { candidates.allElementsBoundByIndex.contains(where: \.isHittable) }
        guard let candidate = candidates.allElementsBoundByIndex.first(where: \.isHittable) else { return }
        candidate.tap()
    }

    @MainActor
    private func searchEvents(_ trace: XCUIElement) -> [[String: Any]] {
        guard let value = trace.value as? String,
              let events = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[String: Any]] else { return [] }
        return events
    }

    @MainActor
    private func waitForSearchState(_ description: String, condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, description)
    }

    @MainActor
    private func recordSearchScreen(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
