#!/usr/bin/env python3
"""Offline dx VM fixtures against pinned reference; no live challenges or network.

--fixtures-only validates fixed Python-reference vectors on Windows. Full mode
requires macOS Swift and compiles the actual production interpreter.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# Exact source pinned at basketikun/chatgpt2api commit
# 92dd80e91543157d36a4ddad60e765c5293760e9, utils/turnstile.py (MIT).
REFERENCE_PATH = ROOT / "scripts/fixtures/chatgpt-web/reference_turnstile.py"
REFERENCE = REFERENCE_PATH.read_text(encoding="utf-8")
assert hashlib.sha256(REFERENCE.encode()).hexdigest() == "c8fae2aeb7c4bd09e4502cebdf3034be9e34e5d6ede61535b3633b7de5ca4aac"



def encode(program, source="fixture-key"):
    plain = json.dumps(program, ensure_ascii=True, separators=(",", ":"))
    encoded = "".join(chr(ord(char) ^ ord(source[i % len(source)])) for i, char in enumerate(plain)) if source else plain
    return base64.b64encode(encoded.encode()).decode()


def vectors():
    output = lambda text: base64.b64encode(text.encode()).decode()
    # Hand-authored answers ensure the reference is not its own sole oracle.
    cases = [
        ("literal-result", [[3, "hello 世界"]], output("hello 世界")),
        ("alias-operation", [[8, 40, 3], [40, "alias"]], output("alias")),
        ("indirect-call", [[2, 40, "called"], [7, 3, 40]], output("called")),
        ("xor", [[2, 40, "ABC"], [2, 41, "x"], [1, 40, 41], [7, 3, 40]], output("9:;")),
        ("concat-string", [[2, 40, "a"], [2, 41, "b"], [5, 40, 41], [7, 3, 40]], output("ab")),
        ("integer-add-is-NaN", [[2, 40, 1], [2, 41, 2], [5, 40, 41], [7, 3, 40]], output("NaN")),
        ("float-concat", [[2, 40, 1.5], [2, 41, 2.5], [5, 40, 41], [7, 3, 40]], output("1.52.5")),
        ("list-append-json", [[2, 40, ["first"]], [2, 41, "second"], [5, 40, 41], [15, 42, 40], [7, 3, 42]], output('["first", "second"]')),
        ("property-location", [[2, 40, "document"], [6, 41, 10, 40], [2, 42, "location"], [6, 43, 41, 42], [7, 3, 43]], output("https://chatgpt.com/")),
        ("raw-property", [[2, 40, "document"], [24, 41, 10, 40], [2, 42, "location"], [24, 43, 41, 42], [7, 3, 43]], output("window.document.location")),
        ("json-order-unicode", [[2, 40, '{"z":1,"a":"中😀","b":true,"n":null}'], [14, 41, 40], [15, 42, 41], [7, 3, 42]], output('{"z": 1, "a": "\\u4e2d\\ud83d\\ude00", "b": true, "n": null}')),
        ("base64-roundtrip", [[2, 40, "héllo"], [19, 40], [18, 40], [7, 3, 40]], output("héllo")),
        ("conditional-equal", [[2, 40, 1], [2, 41, True], [2, 42, "equal"], [20, 40, 41, 3, 42]], output("equal")),
        ("conditional-not-equal", [[3, "kept"], [2, 40, 1], [2, 41, 2], [2, 42, "wrong"], [20, 40, 41, 3, 42]], output("kept")),
        ("raw-call-args-23", [[2, 40, True], [23, 40, 2, 41, "raw"], [7, 3, 41]], output("raw")),
        ("null-conditional", [[3, "kept"], [2, 40, None], [23, 40, 3, "wrong"]], output("kept")),
        ("call-return-None", [[2, 40, "call"], [17, 41, 3, 40], [2, 42, ""], [5, 42, 41], [7, 3, 42]], output("undefined")),
        ("no-op", [[21, 1, 2, 3], [3, "ok"]], output("ok")),
        ("source-register", [[7, 3, 16]], output("fixture-key")),
        ("special-object-string", [[2, 40, "window.Math"], [2, 41, ""], [5, 40, 41], [7, 3, 40]], output("[object Math]")),
        ("list-coercion-raw", [[2, 40, ["window.Math", "b"]], [19, 40], [7, 3, 40]], output(output("window.Math,b"))),
        ("list-mixed-coercion", [[2, 40, [1, None, "a"]], [19, 40], [7, 3, 40]], output(output("[1, None, 'a']"))),
        ("ordered-map-alias", [[2, 40, "window.Object.create"], [17, 41, 40], [8, 42, 41], [2, 43, "window.Reflect.set"], [2, 44, "key"], [2, 45, "value"], [7, 43, 41, 44, 45], [2, 46, "same"], [20, 41, 42, 3, 46]], output("same")),
        ("missing-register-then-result", [[7, 3, 999], [3, "recovered"]], output("recovered")),
        ("unknown-op-then-result", [[999, "ignored"], [3, "recovered"]], output("recovered")),
        ("non-callable-then-result", [[2, 40, "not callable"], [40, "ignored"], [3, "recovered"]], output("recovered")),
        ("unsupported-property-then-result", [[2, 40, "window.unavailable"], [17, 41, 40], [3, "recovered"]], output("recovered")),
        ("bad-base64-then-result", [[2, 40, "!"], [18, 40], [3, "recovered"]], output("recovered")),
        ("bad-json-then-result", [[2, 40, "{"], [14, 41, 40], [3, "recovered"]], output("recovered")),
        ("wrong-arity-then-result", [[3, "bad", "extra"], [3, "recovered"]], output("recovered")),
        ("result-before-optional-failure", [[3, "preserved"], [7, 3, 999]], output("preserved")),
        ("result-after-malformed-instruction", [None, [], [3, "recovered"]], output("recovered")),
    ]
    local_keys = ["STATSIG_LOCAL_STORAGE_INTERNAL_STORE_V4", "STATSIG_LOCAL_STORAGE_STABLE_ID", "client-correlated-secret", "oai/apps/capExpiresAt", "oai-did", "STATSIG_LOCAL_STORAGE_LOGGING_REQUEST", "UiState.isNavigationCollapsed.1"]
    cases.append(("localStorage-keys", [[2, 40, "window.Object.keys"], [2, 41, "window.localStorage"], [17, 42, 40, 41], [15, 43, 42], [7, 3, 43]], output(json.dumps(local_keys))))
    namespace = {}
    exec(compile(REFERENCE, "pinned-reference-turnstile.py", "exec"), namespace)
    fixtures = []
    for name, program, expected in cases:
        dx = encode(program)
        actual = namespace["solve_turnstile_token"](dx, "fixture-key")
        assert actual == expected, (name, actual, expected)
        fixtures.append({"name": name, "dx": dx, "source": "fixture-key", "expected": expected})
    # Property call op17's random/time branches have shape/range assertions, not
    # fake equality against values sampled in a different process.
    return fixtures


HARNESS = r'''
import Foundation
struct Vector: Decodable { let name: String; let dx: String; let source: String; let expected: String }
func encode(_ program: [[Any]], source: String = "fixture-key") throws -> String {
    let raw = String(data: try JSONSerialization.data(withJSONObject: program), encoding: .utf8)!
    let key = Array(source.unicodeScalars)
    let xor = String(String.UnicodeScalarView(raw.unicodeScalars.enumerated().map {
        UnicodeScalar($0.element.value ^ key[$0.offset % key.count].value)!
    }))
    return Data(xor.utf8).base64EncodedString()
}
func rejects(_ label: String, _ run: () throws -> Void) {
    do { try run(); fatalError("Accepted invalid challenge: \(label)") } catch {}
}
@main struct Main {
    static func main() async throws {
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for vector in vectors {
            let actual = try await ChatGPTWebChallenge.token(dx: vector.dx, source: vector.source)
            precondition(actual == vector.expected, "Reference mismatch: \(vector.name)")
        }
        rejects("invalid base64") { _ = try ChatGPTWebChallenge.evaluate(dx: "!", source: "key") }
        rejects("unknown opcode") { _ = try ChatGPTWebChallenge.evaluate(dx: encode([[999, "x"]]), source: "fixture-key") }
        rejects("unknown function") { _ = try ChatGPTWebChallenge.evaluate(dx: encode([[2,40,"window.eval"],[17,41,40]]), source:"fixture-key") }
        rejects("missing register") { _ = try ChatGPTWebChallenge.evaluate(dx: encode([[7,3,999]]), source:"fixture-key") }
        rejects("wrong arity") { _ = try ChatGPTWebChallenge.evaluate(dx: encode([[3,"x","extra"]]), source:"fixture-key") }
        rejects("missing result") { _ = try ChatGPTWebChallenge.evaluate(dx: encode([[21]]), source:"fixture-key") }
        rejects("source size") { _ = try ChatGPTWebChallenge.evaluate(dx: "e30=", source: String(repeating:"a",count:32_769)) }
        rejects("step budget") { _ = try ChatGPTWebChallenge.evaluate(dx: encode([[3,"x"]]), source:"fixture-key",maxSteps:0) }
        rejects("time budget") { _ = try ChatGPTWebChallenge.evaluate(dx: encode([[3,"x"]]), source:"fixture-key",timeBudget:0) }
        var expansion: [[Any]] = [[2,40,"x"]]
        for _ in 0..<24 { expansion.append([5,40,40]) }
        expansion.append([7,3,40])
        rejects("allocation budget") { _ = try ChatGPTWebChallenge.evaluate(dx: encode(expansion),source:"fixture-key") }
        let nested = String(repeating:"[",count:40) + "0" + String(repeating:"]",count:40)
        rejects("JSON depth") { _ = try ChatGPTWebChallenge.evaluate(dx: encode([[2,40,nested],[14,41,40]]),source:"fixture-key") }
        // A later valid result must never recover cancellation or local limits.
        rejects("depth limit before result") { _ = try ChatGPTWebChallenge.evaluate(dx: encode([[2,40,nested],[14,41,40],[3,"forbidden"]]),source:"fixture-key") }
        rejects("allocation limit before result") { _ = try ChatGPTWebChallenge.evaluate(dx: encode(expansion + [[3,"forbidden"]]),source:"fixture-key") }
        do {
            _ = try ChatGPTWebChallenge.evaluate(dx: encode([[7,3,999]]),source:"fixture-key")
            fatalError("Missing result accepted")
        } catch let failure as ChatGPTWebChallenge.Failure {
            precondition(failure.code == "WEB-DX-RESULT-I0-S1")
        }
        do {
            _ = try ChatGPTWebChallenge.evaluate(dx:"!",source:"private-fixture-source")
            fatalError("Encoding accepted")
        } catch let failure as ChatGPTWebChallenge.Failure {
            precondition(failure.code == "WEB-DX-ENCODING-S0" && !failure.code.contains("private"))
        }
        // op23 passes raw trailing addresses, including the function's own address.
        let recursion: [[Any]] = [[2,40,true],[8,41,23],[23,40,41,40,41,40,41,40,41]]
        rejects("malformed recursive call") { _ = try ChatGPTWebChallenge.evaluate(dx: encode(recursion),source:"fixture-key") }
        for function in ["window.Math.random", "window.performance.now"] {
            let dx = try encode([[2,40,function],[17,41,40],[15,42,41],[7,3,42]])
            let token = try await ChatGPTWebChallenge.token(dx:dx,source:"fixture-key")
            let text = String(data:Data(base64Encoded:token)!,encoding:.utf8)!
            let number = Double(text)!
            precondition(number.isFinite && number >= 0)
            if function == "window.Math.random" { precondition(number < 1) }
        }
        let cancelled = Task { try await ChatGPTWebChallenge.token(dx: encode([[3,"x"]]), source:"fixture-key") }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation ignored") } catch is CancellationError {}
        print("PASS: \(vectors.count) production Swift dx/reference vectors, malformed/unknown/arity/size/depth/step/time/allocation/cancellation limits and random/time ranges")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures-only", action="store_true")
    args = parser.parse_args()
    fixtures = vectors()
    print(f"PASS: {len(fixtures)} fixed expected results match pinned Python reference")
    if args.fixtures_only:
        print("Swift production execution not performed (--fixtures-only)")
        return
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("Swift compiler required for production challenge tests; use macOS CI")
    with tempfile.TemporaryDirectory(prefix="ze-web-challenge-") as temp:
        directory = Path(temp)
        fixture = directory / "fixtures.json"
        fixture.write_text(json.dumps(fixtures), encoding="utf-8")
        harness = directory / "Harness.swift"
        harness.write_text(HARNESS, encoding="utf-8")
        binary = directory / "challenge-tests"
        subprocess.run([compiler, "-swift-version", "5", "-target", f"{platform.machine()}-apple-macosx13.0", "-parse-as-library",
                        str(ROOT / "Providers/OpenAI/ChatGPTWeb/ChatGPTWebChallenge.swift"), str(harness), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(fixture)], check=True, timeout=20)


if __name__ == "__main__":
    main()
