import Foundation

@main
struct GmailConnectorTests {
    @MainActor
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let filter = try MailVerificationFilter(sender: "verify@example.com", subject: "Verify", after: now.addingTimeInterval(-60), now: now)
        precondition(filter.matches(from: "Service <verify@example.com>", subject: "Please VERIFY email", received: now))
        precondition(!filter.matches(from: "verify@example.com <attacker@example.org>", subject: "Verify", received: now))
        precondition(!filter.matches(from: "verify@example.com.evil.org", subject: "Verify", received: now))
        precondition(!filter.matches(from: "verify@example.com", subject: "Verify", received: now.addingTimeInterval(-120)))
        precondition(!filter.matches(from: "verify@example.com", subject: "Invoice", received: now))
        func rejects(_ action: () throws -> Void) { do { try action(); fatalError("expected rejection") } catch {} }
        rejects { _ = try MailVerificationFilter(sender: "a@example.com\r\nSEARCH ALL", subject: "", after: now, now: now) }
        rejects { _ = try MailVerificationFilter(sender: "a@example.com", subject: "", after: now.addingTimeInterval(-90_000), now: now) }
        rejects { _ = try MailVerificationFilter(sender: "a@example.com", subject: "", after: now.addingTimeInterval(120), now: now) }
        let bytes = Data("你好 +/ test".utf8)
        precondition(GmailEncoding.decode(GmailEncoding.encode(bytes)) == bytes)
        let form = String(decoding: GmailEncoding.form(["q": "a+b c&"]), as: UTF8.self)
        precondition(form == "q=a%2Bb%20c%26")
        let html = "<p>验证码 123456</p><a href=\"https://example.com/verify?a=1&amp;b=2\">验证</a>"
        let sample: [String: Any] = ["id": "abc123", "internalDate": "1800000000000", "payload": [
            "mimeType": "multipart/mixed", "headers": [["name": "From", "value": "verify@example.com"], ["name": "Subject", "value": "Verify"]],
            "parts": [["mimeType": "text/html", "body": ["data": GmailEncoding.encode(Data(html.utf8))]],
                      ["mimeType": "text/plain", "filename": "private.txt", "body": ["data": GmailEncoding.encode(Data("SECRET_ATTACHMENT".utf8))]]]]]
        let message = try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: sample))
        precondition(message.content.text.contains("123456") && !message.content.text.contains("SECRET_ATTACHMENT"))
        let result = message.output["verification_candidates"] as! [String: Any]
        precondition((result["candidate_codes"] as? [String])?.contains("123456") == true)
        precondition((result["candidate_links"] as? [String])?.contains("https://example.com/verify?a=1&b=2") == true)
        precondition(message.received == now)
        let imapDate = MailVerification.imapReceivedDate(["* 5 FETCH (INTERNALDATE \"09-Oct-2026 13:00:00 +0800\" UID 3)"])
        precondition(imapDate != nil)
        let raw = "Content-Type: text/html\r\n\r\n" + html
        precondition(MailCodec.readableBody(raw, preserveHTML: true).contains("https://example.com/verify"))
        // The desired email is on page three, not among the newest twenty.
        let allUIDs = (1...65).map(String.init).joined(separator: " ")
        var imapPages = 0
        let found: [UInt32] = try await MailVerificationPager.collect(limit: 1, load: { cursor in
            imapPages += 1
            let ids = MailCodec.searchUIDs(["* SEARCH " + allUIDs], before: cursor.flatMap { UInt32($0) }, limit: 20)
            return MailVerificationPage(items: ids, nextCursor: ids.count == 20 ? ids.last.map { String($0) } : nil)
        }, transform: { uid in uid == 21 ? uid : nil })
        precondition(found == [21] && imapPages == 3, "IMAP must reach matches beyond the first twenty")
        var seenCursors: [String?] = []
        let gmailFound: [Int] = try await MailVerificationPager.collect(limit: 1, load: { cursor in
            seenCursors.append(cursor)
            switch cursor {
            case nil: return MailVerificationPage(items: Array(1...20), nextCursor: "page2")
            case "page2": return MailVerificationPage(items: [], nextCursor: "page3")
            default: return MailVerificationPage(items: Array(21...40), nextCursor: nil)
            }
        }, transform: { item in item == 31 ? item : nil })
        precondition(gmailFound == [31] && seenCursors == [nil, "page2", "page3"])
        let absent: [Int] = try await MailVerificationPager.collect(limit: 1, load: { _ in
            MailVerificationPage(items: [1, 2], nextCursor: nil)
        }, transform: { _ in nil as Int? })
        precondition(absent.isEmpty)
        let limited: [Int] = try await MailVerificationPager.collect(limit: 2, load: { _ in
            MailVerificationPage(items: [1, 2, 3], nextCursor: "unused")
        }, transform: { $0 })
        precondition(limited == [1, 2])
        do {
            let _: [Int] = try await MailVerificationPager.collect(limit: 1, load: { _ in
                MailVerificationPage(items: [1], nextCursor: "cycle")
            }, transform: { _ in nil as Int? })
            fatalError("Repeated cursors must fail rather than report not_found")
        } catch { precondition(error.localizedDescription.contains("同一页")) }
        var pageNumber = 0
        do {
            let _: [Int] = try await MailVerificationPager.collect(limit: 1, maxPages: 2, load: { _ in
                pageNumber += 1
                return MailVerificationPage(items: [1], nextCursor: String(pageNumber))
            }, transform: { _ in nil as Int? })
            fatalError("Incomplete bounded searches must not report absence")
        } catch { precondition(error.localizedDescription.contains("上限")) }
        let cancelledScan = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MailVerificationPager.collect(limit: 1, load: { _ in
                fatalError("Cancelled scan must not contact a server")
                return MailVerificationPage(items: [1], nextCursor: nil)
            }, transform: { $0 })
        }
        do { _ = try await cancelledScan.value; fatalError("Expected cancellation") }
        catch is CancellationError {}

        // Revocation, an off/on sequence, credential edits, deletion and reload
        // all invalidate in-flight requests; editing another account does not.
        let id = UUID(), other = UUID()
        var access = MailAccessTracker()
        access.reset(ids: [id, other])
        let initial = try access.ticket(for: id)
        try access.validate(initial)
        access.synchronize(ids: [id, other], changed: [other])
        try access.validate(initial)
        access.synchronize(ids: [id, other], changed: [id]) // off
        access.synchronize(ids: [id, other], changed: [id]) // on
        rejects { try access.validate(initial) }
        let edited = try access.ticket(for: id)
        access.invalidate(id) // credentials replaced / OAuth reconnected
        rejects { try access.validate(edited) }
        let beforeDelete = try access.ticket(for: id)
        access.synchronize(ids: [other], changed: [])
        rejects { try access.validate(beforeDelete) }
        rejects { _ = try access.ticket(for: id) }
        access.reset(ids: [id])
        let beforeReload = try access.ticket(for: id)
        access.reset(ids: [id])
        rejects { try access.validate(beforeReload) }

        // Cancelling a waiting tool returns promptly while a second caller can
        // still use the same single-flight token refresh.
        let clock = ContinuousClock(), start = clock.now
        let shared = Task<String, Error> {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return "refreshed"
        }
        let firstWaiter = Task { try await MailAsyncWait.value(shared) }
        try await Task.sleep(nanoseconds: 20_000_000)
        firstWaiter.cancel()
        do { _ = try await firstWaiter.value; fatalError("Expected cancellation") }
        catch is CancellationError {}
        precondition(clock.now - start < .seconds(1), "Cancelled waiter must not block on shared refresh")
        let secondValue = try await MailAsyncWait.value(shared)
        precondition(secondValue == "refreshed" && !shared.isCancelled)
        let failed = Task<String, Error> { throw MailError.message("test failure") }
        do { _ = try await MailAsyncWait.value(failed); fatalError("Expected refresh error") }
        catch { precondition(error.localizedDescription == "test failure") }
        print("Gmail/QQ regression tests passed: IMAP third-page match, Gmail cursors and empty pages, result limits, cursor cycles, scan caps, cancellation, access revocation/off-on/delete/reload, shared OAuth refresh cancellation")
        print("Gmail/QQ verification tests passed: exact sender, timestamp window, injection rejection, base64url, MIME links, attachment exclusion, IMAP INTERNALDATE")
    }
}
