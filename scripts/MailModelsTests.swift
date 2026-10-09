import Foundation

@main
struct MailModelsTests {
    static func rejects(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected validation error") } catch {}
    }
    static func main() throws {
        var account = MailAccount()
        account.address = "sender@example.com"; account.imapHost = "imap.example.com"; account.smtpHost = "smtp.example.com"
        try account.validate()
        precondition(account.imapPort == 993 && account.smtpPort == 465)
        precondition(account.imapLogin == account.address && account.smtpLogin == account.address)
        account.smtpPort = 587; rejects { try account.validate() }; account.smtpPort = 465
        account.address = "a@example.com\r\nBcc: victim@example.com"; rejects { try account.validate() }
        account.address = "sender@example.com"
        for bad in ["", "a@@b.com", "<a@b.com>", "a b@b.com", ".a@b.com", "a..b@b.com", "a@b.com\n"] {
            precondition(!MailCodec.validAddress(bad), bad)
        }
        rejects { _ = try MailCodec.quoted("x\r\nLOGOUT") }
        let quotedValue = try MailCodec.quoted("a\\\"b")
        precondition(quotedValue == "\"a\\\\\\\"b\"")
        rejects { _ = try MailCodec.message(from: account.address, recipients: ["bad"], subject: "x", body: "x") }
        rejects { _ = try MailCodec.message(from: account.address, recipients: ["to@example.com"], subject: "x\nBcc: z@example.com", body: "x") }
        rejects { _ = try MailCodec.message(from: account.address, recipients: [], subject: "x", body: "x") }
        let subject = String(repeating: "中文测试", count: 20)
        let body = "你好\n.\n正文末尾"
        let encoded = try MailCodec.message(from: account.address, recipients: ["to@example.com"], subject: subject, body: body)
        let raw = String(decoding: encoded, as: UTF8.self)
        let headers = MailCodec.headers(raw)
        precondition(MailCodec.decodedHeader(headers["subject"]!) == subject)
        precondition(MailCodec.readableBody(raw).trimmingCharacters(in: .newlines) == body)
        precondition(!raw.components(separatedBy: "\r\n").contains("."))
        let qp = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n=E4=BD=A0=E5=A5=BD"
        precondition(MailCodec.readableBody(qp) == "你好")
        precondition(MailCodec.decodedHeader("=?UTF-8?Q?hello_world?=") == "hello world")
        let multipart = "Content-Type: multipart/mixed; boundary=\"demo\"\r\n\r\n--demo\r\nContent-Type: text/plain\r\n\r\nhello\r\n--demo\r\nContent-Disposition: attachment\r\nContent-Type: text/plain\r\n\r\nSECRET_ATTACHMENT\r\n--demo--"
        let readable = MailCodec.readableBody(multipart)
        precondition(readable.contains("hello") && !readable.contains("SECRET_ATTACHMENT"))
        let uids = MailCodec.searchUIDs(["* SEARCH 1 3 2 4 3 0 bogus", "* OK irrelevant", "* SEARCH 4294967296"], before: 4, limit: 2)
        precondition(uids == [3, 2])
        precondition(MailCodec.searchUIDs(["* SEARCH"], before: nil, limit: 10).isEmpty)
        let roundTrip = try JSONDecoder().decode(MailAccount.self, from: JSONEncoder().encode(account))
        precondition(roundTrip == account)
        print("Mail model tests passed: validation, header injection, TLS ports, MIME UTF-8/base64/quoted-printable/multipart, credential-free account roundtrip")
    }
}
