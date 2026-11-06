#!/usr/bin/env python3
"""Compile the actual web callback/token decoder; never contact an auth service."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Providers/OpenAI/ChatGPTWeb/ChatGPTWebOAuthManager.swift").read_text(encoding="utf-8")
storage = source[source.index("struct ChatGPTWebTokenStorage:"):source.index("@MainActor")]
protocol = source.split("// BEGIN ChatGPTWebAuthProtocol", 1)[1].split("// END ChatGPTWebAuthProtocol", 1)[0]
prelude = '''import Foundation
protocol RefreshableOAuthToken { var accessToken: String { get }; var refreshToken: String? { get }; var isExpired: Bool { get } }
enum LLMError: Error { case providerError(message: String) }
'''
checks = r'''
var count = 0
func check(_ value: Bool) { precondition(value); count += 1 }
func rejects(_ block: () throws -> Void) {
    do { try block(); fatalError("unexpected acceptance") } catch { count += 1 }
}
let root = "https://platform.openai.com/auth/callback"
check(try ChatGPTWebAuthProtocol.callbackCode(URL(string: root + "?code=ABC&state=S")!, expectedState: "S") == "ABC")
for url in [
    root + "?code=ABC&state=wrong", root + "?code=ABC", root + "?state=S",
    root + "?code=&state=S", root + "?code=A&code=B&state=S",
    root + "?code=A&state=S&state=S", root + "?code=A&state=S&error=denied",
    root + "?code=A&state=S#fragment", "http://platform.openai.com/auth/callback?code=A&state=S",
    "https://platform.openai.com.attacker.invalid/auth/callback?code=A&state=S",
    "https://platform.openai.com:8443/auth/callback?code=A&state=S",
    "https://user@platform.openai.com/auth/callback?code=A&state=S",
    "https://platform.openai.com/auth/callback/other?code=A&state=S"
] {
    rejects { _ = try ChatGPTWebAuthProtocol.callbackCode(URL(string: url)!, expectedState: "S") }
}
let now = Date(timeIntervalSince1970: 1000)
func token(_ body: [String: Any], _ previous: String? = nil) throws -> ChatGPTWebTokenStorage {
    try ChatGPTWebAuthProtocol.decodeToken(JSONSerialization.data(withJSONObject: body), previousRefreshToken: previous, now: now)
}
let original = try token(["access_token": "fixture", "refresh_token": "rotation", "expires_in": 3600])
check(original.expireDate == now.addingTimeInterval(3600))
check(original.refreshToken == "rotation")
check(original.credentialKind == "chatGPTWeb")
check(try token(["access_token": "fixture", "expires_in": 30], "old").refreshToken == "old")
check(try token(["access_token": "fixture", "refresh_token": "", "expires_in": 30], "old").refreshToken == "old")
check(try token(["access_token": "fixture", "refresh_token": "new", "expires_in": 30], "old").refreshToken == "new")
let invalidBodies: [[String: Any]] = [
    ["access_token": "", "expires_in": 30], ["access_token": "fixture"],
    ["access_token": "fixture", "expires_in": -1], ["access_token": "fixture", "expires_in": 0],
    ["access_token": "fixture", "expires_in": "wrong"], ["refresh_token": "without-access"]
]
for body in invalidBodies { rejects { _ = try token(body) } }
func jwt(_ expiry: Double) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: ["exp": expiry]).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header." + payload + ".signature"
}
check(try token(["access_token": jwt(2000)]).expireDate == Date(timeIntervalSince1970: 2000))
rejects { _ = try token(["access_token": jwt(900)]) }
let encoded = try JSONEncoder().encode(original)
check(try JSONDecoder().decode(ChatGPTWebTokenStorage.self, from: encoded).accessToken == "fixture")
// Legacy Codex credentials have no web discriminator; never decode them as web.
rejects { _ = try JSONDecoder().decode(ChatGPTWebTokenStorage.self, from: Data(#"{"accessToken":"codex","refreshToken":"r","expireDate":12345}"#.utf8)) }
print("PASS: \(count) production web OAuth callback/token fixtures")
'''

if not shutil.which("swiftc"):
    raise SystemExit("Swift compiler required: execute this test on the macOS CI runner")
with tempfile.TemporaryDirectory(prefix="ze-web-oauth-") as temp:
    main = Path(temp) / "main.swift"
    main.write_text(prelude + storage + protocol + checks, encoding="utf-8")
    binary = Path(temp) / "tests"
    subprocess.run(["swiftc", str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
