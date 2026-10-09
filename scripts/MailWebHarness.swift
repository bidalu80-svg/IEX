import SwiftUI
import WebKit
import UIKit

// Only a brand-view stub: the real web session, JavaScript, live view and
// permission state machine are compiled unchanged into this simulator app.
struct GmailBrandMark: View { var body: some View { Image(systemName: "envelope.fill").foregroundColor(.red) } }

@main
struct MailWebHarness: App {
    @StateObject private var session = MailWebSession(provider: .gmail, dataStore: .nonPersistent())
    var body: some Scene {
        WindowGroup {
            NavigationStack { MailWebView(session: session) }
                .task { await runChecks(session) }
        }
    }
    @MainActor private func runChecks(_ session: MailWebSession) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw MailError.message(name) }
            checks.append(name)
        }
        func pause(_ seconds: Double = 0.15) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func load(_ html: String, base: String = "https://mail.google.com/mail/u/0/") async throws {
            session.webView.stopLoading()
            session.webView.loadHTMLString(html, baseURL: URL(string: base))
            for _ in 0..<80 {
                try await pause()
                if !session.webView.isLoading,
                   let text = try? await session.webView.evaluateJavaScript("document.body.innerText") as? String,
                   text.contains("FIXTURE") { return }
            }
            throw MailError.message("Fixture navigation did not complete")
        }
        func snapshot(_ name: String) throws {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else {
                throw MailError.message("No rendered window")
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()!.write(to: docs.appendingPathComponent(name))
        }
        do {
            try await pause(0.5)
            try check(!session.enabled, "Initial page opening does not grant agent access")
            try check(MailWebProvider.gmail.contains(URL(string: "https://mail.google.com/mail/u/0/#inbox")), "Exact Gmail mailbox origin accepted")
            for url in ["https://mail.google.com.evil.example/", "http://mail.google.com/", "https://accounts.google.com/", "https://user:pass@mail.google.com/", "https://mail.google.com:444/"] {
                try check(!MailWebProvider.gmail.contains(URL(string: url)), "Reject origin " + url)
            }
            try check(!MailWebProvider.qq.contains(URL(string: "https://mail.qq.com.evil.example/")), "Reject spoofed QQ host")
            let html = """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>邮箱会话回归夹具</title></head>
            <body style="font-family:system-ui;padding:18px"><h2>FIXTURE Gmail 收件箱</h2>
            <nav role="navigation"><a href="#inbox">收件箱</a></nav>
            <form onsubmit="event.preventDefault(); document.querySelector('#result').innerText='搜索完成 FIXTURE';"><input name="q" type="search" placeholder="搜索邮件"><button>搜索</button></form>
            <button onclick="document.querySelector('#result').innerText='注册验证码 246810 FIXTURE'">打开验证邮件</button>
            <p id="result">点击邮件查看验证码</p>
            <script>document.cookie='fixture_session=local-only;path=/;SameSite=Lax';</script></body></html>
            """
            try await load(html)
            try await pause(0.3)
            await session.verifyAndEnable()
            try check(session.enabled, "Mailbox DOM verification grants access")
            try snapshot("mail-web-inbox-fixture.png")
            let originalView = ObjectIdentifier(session.webView)
            // Simulate leaving settings: no replacement view or cookie copy.
            session.endManual()
            let first = try await session.perform(action: "read", snapshot: nil, index: nil, text: nil)
            try check(first["mailbox"] as? Bool == true, "Agent reads the exact settings mailbox document")
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: first), as: UTF8.self)
            try check(!encoded.contains("local-only"), "Cookie values never appear in the agent result")
            let cookie = try await session.webView.evaluateJavaScript("document.cookie") as? String ?? ""
            try check(cookie.contains("fixture_session=local-only"), "Same browser retains fixture login cookie")
            let elements = first["elements"] as! [[String: Any]]
            let messageIndex = elements.first { ($0["label"] as? String) == "打开验证邮件" }!["index"] as! Int
            let click = try await session.perform(action: "click", snapshot: first["snapshot"] as? String, index: messageIndex, text: nil)
            try check(click["success"] as? Bool == true, "Confirmed interaction clicks the displayed mailbox element")
            let second = try await session.perform(action: "read", snapshot: nil, index: nil, text: nil)
            try check((second["text"] as? String)?.contains("246810") == true, "Next agent read sees the opened verification code")
            let stale = try await session.perform(action: "click", snapshot: first["snapshot"] as? String, index: messageIndex, text: nil)
            try check(stale["success"] as? Bool == false, "Stale element snapshots are rejected")
            let search = (second["elements"] as! [[String: Any]]).first { $0["kind"] as? String == "search" }!["index"] as! Int
            let typed = try await session.perform(action: "type", snapshot: second["snapshot"] as? String, index: search, text: "验证邮件")
            try check(typed["success"] as? Bool == true, "Mailbox search field accepts query")
            let submitted = try await session.perform(action: "submit_search", snapshot: second["snapshot"] as? String, index: search, text: nil)
            try check(submitted["success"] as? Bool == true, "Search submit reaches the page form handler")
            let third = try await session.perform(action: "read", snapshot: nil, index: nil, text: nil)
            try check((third["text"] as? String)?.contains("搜索完成") == true, "Search result is verified rather than assumed")
            let old = try session.accessVersion()
            session.revoke(); await session.verifyAndEnable()
            do { try session.validate(old); throw MailError.message("Off/on accepted an old permission ticket") }
            catch { try check(error.localizedDescription != "Off/on accepted an old permission ticket", "Off/on invalidates old operations") }
            session.beginManual()
            do { _ = try session.accessVersion(); throw MailError.message("Manual login leaked to agent") }
            catch { try check(error.localizedDescription != "Manual login leaked to agent", "Manual takeover blocks agent reads") }
            session.endManual()
            try check(ObjectIdentifier(session.webView) == originalView, "Reopening settings preserves the identical WKWebView")
            try await load("<html><body>FIXTURE LOGIN<input type=password value='DO_NOT_EXPOSE'><nav role=navigation>nav</nav></body></html>")
            await session.verifyAndEnable()
            try check(!session.enabled, "Password page never qualifies as a mailbox")
            try await load(html, base: "https://accounts.google.com/")
            await session.verifyAndEnable()
            try check(!session.enabled, "Authentication origin is excluded even with mailbox-looking DOM")
            try await load(html)
            await session.disconnect()
            try await pause(0.3)
            let remaining = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            try check(!remaining.contains { $0.name == "fixture_session" }, "Disconnect clears the isolated session cookie")
            try check(!session.enabled, "Disconnect revokes model access")
            try snapshot("mail-web-disconnected.png")
            var live: [String: Any] = ["real_account_login": "not_tested"]
            // Observe the real Gmail entry without entering credentials. Network
            // or provider restrictions are evidence, not a fake successful login.
            session.beginManual(); session.openHome()
            for _ in 0..<80 {
                try await pause(0.25)
                if !session.loading && !session.pageURL.isEmpty && session.pageURL != "about:blank" { break }
            }
            live["url"] = session.webView.url?.absoluteString ?? ""
            live["title"] = try? await session.webView.evaluateJavaScript("document.title")
            live["status"] = session.status
            live["text_excerpt"] = (try? await session.webView.evaluateJavaScript("document.body.innerText.slice(0,1500)")) ?? ""
            try snapshot("mail-web-gmail-entry-live.png")
            let output: [String: Any] = ["success": true, "checks": checks, "live_entry": live,
                "boundary": "Local mailbox fixtures prove same-view DOM operation, permission control and clearing; a real Google/QQ account login was not performed."]
            try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: docs.appendingPathComponent("mail-web-result.json"))
        } catch {
            try? snapshot("mail-web-failure.png")
            let output: [String: Any] = ["success": false, "checks": checks, "error": error.localizedDescription,
                                      "url": session.webView.url?.absoluteString ?? "", "status": session.status]
            try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted]).write(to: docs.appendingPathComponent("mail-web-result.json"))
        }
    }
}
