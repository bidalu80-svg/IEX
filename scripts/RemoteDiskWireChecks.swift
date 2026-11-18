import Foundation

/// Runs production parsers/address code extracted by test-netdisk.py. No
/// replacement implementation or successful-network claim is made here.
@main struct RemoteDiskWireChecks {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) {
        precondition(value, label); checks += 1; print("PASS: \(label)")
    }
    static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected rejection: \(label)") }
        catch { checks += 1; print("PASS: rejects \(label)") }
    }
    static func main() async throws {
        let disk = RemoteDisk(profile: .init(name: "fixture", proto: .webdav, host: "example.com", port: 443))
        let encoded = try JSONEncoder().encode(disk)
        check(try JSONDecoder().decode(RemoteDisk.self, from: encoded) == disk, "disk revision persists across reload")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "configurationRevision")
        let legacyDisk = try JSONDecoder().decode(RemoteDisk.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(legacyDisk.profile == disk.profile, "legacy disk configuration decodes with a new revision")
        let id = UUID()
        let root = try RemoteDiskAddress(diskID: id)
        let file = try root.child("空 格%?#.txt ")
        check(try RemoteDiskAddress(file.string) == file, "address preserves Unicode, spaces and reserved characters")
        check(try file.serverPath(root: "folder/") == "/folder/空 格%?#.txt ", "root normalized once; filename preserved")
        check(file.parent == root, "parent stays inside disk")
        for suffix in ["/..", "/%2e%2e", "/%2Fetc", "/%5Cetc", "/%00x", "/%0Ax", "/x?q=1", "/x#part"] {
            rejects(suffix) { _ = try RemoteDiskAddress(root.string.dropLast() + suffix) }
        }
        rejects("credentials") { _ = try RemoteDiskAddress("remote-disk://user:secret@\(id)/x") }
        rejects("port") { _ = try RemoteDiskAddress("remote-disk://\(id):80/x") }
        let escaped = try root.child("%2e%2e")
        check(try RemoteDiskAddress(escaped.string).components == ["%2e%2e"], "only one percent decoding pass")
        var profile = RemoteStorageProfile(name: "fixture", proto: .s3, host: "example.com", port: 9443)
        check(try RemoteStorageEndpoint.components(profile).url?.port == 9443, "custom endpoint port")
        for host in ["", "https://example.com", "a/b", "user@example.com", "a?b", "a#b", "a\n", " a"] {
            profile.host = host
            rejects("invalid endpoint \(host.debugDescription)") { _ = try RemoteStorageEndpoint.components(profile) }
        }
        profile.host = "example.com"; profile.port = 0
        rejects("port zero") { _ = try RemoteStorageEndpoint.components(profile) }
        check(RemoteStorageEndpoint.encode("a/+ &=中") == "a%2F%2B%20%26%3D%E4%B8%AD", "SigV4 component escaping")

        var replies = Data("220-first\r\nintermediate\r\n220 done\r\n230 next\r\n".utf8)
        check(try RemoteFTPReply.consume(&replies)?.hasPrefix("220-first") == true, "multiline FTP reply")
        check(try RemoteFTPReply.consume(&replies) == "230 next\r\n", "coalesced next FTP reply is retained")
        check(replies.isEmpty, "FTP frame fully consumed")
        var fragment = Data("150 incoming\r".utf8)
        check(try RemoteFTPReply.consume(&fragment) == nil, "fragmented CRLF waits for more")
        fragment.append(10)
        check(try RemoteFTPReply.consume(&fragment) == "150 incoming\r\n", "fragmented frame completes")
        rejects("invalid FTP frame") { var bad = Data("oops\r\n".utf8); _ = try RemoteFTPReply.consume(&bad) }
        check(try RemoteFTPPassivePort.extended("229 Entering (|||65535|)\r\n") == 65535, "EPSV port")
        check(try RemoteFTPPassivePort.classic("227 Entering (127,0,0,1,4,1)\r\n") == 1025, "PASV port; advertised host is never used")
        rejects("EPSV reversed parentheses") { _ = try RemoteFTPPassivePort.extended("229 ) (") }
        rejects("EPSV invalid delimiter layout") { _ = try RemoteFTPPassivePort.extended("229 (|123|)") }
        rejects("PASV octet overflow") { _ = try RemoteFTPPassivePort.classic("227 (127,0,0,1,256,1)") }
        let machine = try RemoteFTPListing.parse("type=cdir; .\r\ntype=pdir; ..\r\ntype=file;size=3; a;b .txt \r\ntype=dir; sub\r\n", base: "/root", machine: true)
        check(machine.count == 2 && machine[0].name == "a;b .txt " && machine[0].size == 3, "MLSD preserves semicolons and trailing spaces; removes dot entries")
        check(machine[1].isDirectory && machine[1].path == "/root/sub", "MLSD directory")
        let unix = try RemoteFTPListing.parse("-rw-r--r-- 1 user group 3 Nov 19 12:00 a b.txt\nlrwxrwxrwx 1 user group 3 Nov 19 12:00 link -> /outside", base: "/", machine: false)
        check(unix.count == 1 && unix[0].name == "a b.txt", "Unix LIST handles spaces and excludes symlinks")
        rejects("unknown LIST") { _ = try RemoteFTPListing.parse("unrecognized layout", base: "/", machine: false) }
        let gate = RemoteFTPReadyGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.install(continuation)
            check(gate.finish(nil), "FTP ready first resume wins")
            check(!gate.finish(CancellationError()), "FTP cancel/timeout cannot resume twice")
        }

        func response(_ href: String, _ props: String, status: String = "200 OK") -> String {
            "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(props)</d:prop><d:status>HTTP/1.1 \(status)</d:status></d:propstat></d:response>"
        }
        let base = URL(string: "https://example.com:443/dav/")!
        let directory = "<d:resourcetype><d:collection/></d:resourcetype>"
        let regular = "<d:resourcetype/><d:getcontentlength>3</d:getcontentlength>"
        func dav(_ body: String) -> Data { Data("<d:multistatus xmlns:d=\"DAV:\">\(body)</d:multistatus>".utf8) }
        let rows = try RemoteDAVListing.parse(dav(response("https://EXAMPLE.com/dav/", directory) + response("/dav/a%20%26.txt", regular)), baseURL: base)
        check(rows.count == 1 && rows[0].name == "a &.txt" && rows[0].size == 3, "DAV same origin accepts implicit default port, decodes filename")
        let empty = try RemoteDAVListing.parse(dav(response("/dav/", directory)), baseURL: base)
        check(empty.isEmpty, "DAV genuine empty directory")
        rejects("DAV forbidden properties cannot fake empty") { _ = try RemoteDAVListing.parse(dav(response("/dav/", directory, status: "403 Forbidden")), baseURL: base) }
        rejects("DAV wrong origin") { _ = try RemoteDAVListing.parse(dav(response("https://other.test/dav/a", regular)), baseURL: base) }
        rejects("DAV wrong nondefault port") { _ = try RemoteDAVListing.parse(dav(response("https://example.com:8443/dav/a", regular)), baseURL: base) }
        rejects("DAV descendant beyond Depth 1") { _ = try RemoteDAVListing.parse(dav(response("/dav/sub/a", regular)), baseURL: base) }
        rejects("DAV malformed XML") { _ = try RemoteDAVListing.parse(Data("<x>".utf8), baseURL: base) }

        func s3(_ body: String, truncated: Bool = false, token: String = "") -> Data {
            Data("<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><IsTruncated>\(truncated)</IsTruncated>\(body)<NextContinuationToken>\(token)</NextContinuationToken></ListBucketResult>".utf8)
        }
        let page = try RemoteS3Listing.parse(s3("<Contents><Key>root/a</Key><Size>3</Size></Contents><CommonPrefixes><Prefix>root/a/</Prefix></CommonPrefixes>", truncated: true, token: "t&amp;=+"), prefix: "root/")
        check(page.entries.count == 2 && page.entries.filter(\.isDirectory).count == 1, "S3 preserves same-name object and folder")
        check(page.nextToken == "t&=+", "S3 XML continuation token")
        let thousand = (0..<1001).map { "<Contents><Key>root/f\($0)</Key><Size>1</Size></Contents>" }.joined()
        check(try RemoteS3Listing.parse(s3(thousand), prefix: "root/").entries.count == 1001, "S3 parses more than 1000 fixture entries (transport pagination separate)")
        rejects("S3 truncated without token") { _ = try RemoteS3Listing.parse(s3("", truncated: true), prefix: "") }
        rejects("S3 error document") { _ = try RemoteS3Listing.parse(Data("<Error><Code>AccessDenied</Code></Error>".utf8), prefix: "") }
        rejects("S3 wrong prefix") { _ = try RemoteS3Listing.parse(s3("<Contents><Key>elsewhere/a</Key></Contents>"), prefix: "root/") }
        rejects("S3 nested key beyond delimiter") { _ = try RemoteS3Listing.parse(s3("<Contents><Key>root/a/b</Key></Contents>"), prefix: "root/") }
        print("Production wire/address fixture checks passed: \(checks). These are not live protocol tests.")
    }
}
