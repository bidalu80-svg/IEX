#!/usr/bin/env python3
"""Build a standalone UI-test runner and drive the already-built Ze simulator app.

The host bridges small request/ack JSON files over loopback because the test
runner must not assume direct access to another application's sandbox. XCTest
performs real accessibility taps/drags; the production app remains the oracle
for activity-controller presentation, cancellation, current files and screenshots.
"""
from __future__ import annotations

import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import threading
import time
import urllib.parse


DRIVER = r'''
import XCTest
import Foundation
import UIKit

final class ShareDriver: XCTestCase {
    private struct Request: Decodable {
        let sequence: String?
        let action: String
        let identifier: String?
        let startX: Double?
        let startY: Double?
        let endX: Double?
        let endY: Double?
        let success: Bool?
        let error: String?
    }

    @MainActor
    private func dismissSystemShareSheet(_ app: XCUIApplication) throws -> String {
        let dismissNames = NSPredicate(format: "label IN %@ OR identifier IN %@",
            ["Close", "关闭", "Cancel", "取消"], ["Close", "关闭", "Cancel", "取消"])
        // A presented remote container can exist before its share controls load.
        // Wait for the same safe targets used below; never tap while polling.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let sheets = app.sheets.allElementsBoundByIndex
            let activity = app.otherElements["ActivityListView"].firstMatch
            let scopes = activity.exists ? [activity] + sheets : sheets
            for scope in scopes where scope.exists {
                let buttons = scope.buttons.matching(dismissNames).allElementsBoundByIndex.filter { $0.isHittable }
                if buttons.count == 1 { return true }
            }
            let close = NSPredicate(format: "label IN %@ OR identifier IN %@", ["Close", "关闭"], ["Close", "关闭"])
            let buttons = app.buttons.matching(close).allElementsBoundByIndex.filter { $0.isHittable }
            let export = app.buttons["chatShare.export"].firstMatch
            if buttons.count == 1 && (!export.exists || !export.isHittable) { return true }
            let screen = app.frame.size
            return sheets.contains { sheet in
                guard sheet.exists else { return false }
                let frame = sheet.frame
                return frame.width > screen.width * 0.5 && frame.height > 150
                    && frame.minY > 44 && frame.minY < screen.height - 180
                    && frame.maxY <= screen.height + 2
            }
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 25) == .completed else {
            throw NSError(domain: "ShareDriver", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "System-share controls did not become ready within 25 seconds; no blind gesture used"])
        }
        let sheets = app.sheets.allElementsBoundByIndex
        let activity = app.otherElements["ActivityListView"].firstMatch
        let scopes = activity.exists ? [activity] + sheets : sheets
        for scope in scopes where scope.exists {
            let candidates = scope.buttons.matching(dismissNames).allElementsBoundByIndex.filter { $0.isHittable }
            if candidates.count == 1 {
                candidates[0].tap()
                return "system-sheet-dismiss-button"
            }
        }
        // Some OS versions expose the activity view without a Sheet ancestor.
        // Only Close is safe globally: Cancel also belongs to the underlying preview.
        let close = NSPredicate(format: "label IN %@ OR identifier IN %@", ["Close", "关闭"], ["Close", "关闭"])
        let closeButtons = app.buttons.matching(close).allElementsBoundByIndex.filter { $0.isHittable }
        let export = app.buttons["chatShare.export"].firstMatch
        if closeButtons.count == 1 && (!export.exists || !export.isHittable) {
            closeButtons[0].tap()
            return "unique-system-close-button"
        }
        // Bounds must come from an actual XCUI sheet, never the application's
        // full-screen presentation wrapper. Refuse a status-bar-origin drag.
        let screen = app.frame.size
        for sheet in sheets where sheet.exists {
            let frame = sheet.frame
            guard frame.width > screen.width * 0.5, frame.height > 150,
                  frame.minY > 44, frame.minY < screen.height - 180,
                  frame.maxY <= screen.height + 2 else { continue }
            let start = sheet.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width / 2, dy: 12))
            let end = start.withOffset(CGVector(dx: 0, dy: screen.height - frame.minY - 30))
            start.press(forDuration: 0.1, thenDragTo: end)
            return "xcui-sheet-bounds-drag"
        }
        throw NSError(domain: "ShareDriver", code: 6, userInfo: [NSLocalizedDescriptionKey:
            "No unambiguous system-share Close/Cancel control or actual sheet bounds; AX tree and screen recorded, no blind gesture used"])
    }

    private func exchange(_ path: String, body: [String: Any]? = nil) throws -> Data {
        // The simulator's first loopback request can time out while XCTest is
        // establishing its automation session. Retry only read-only polling,
        // never taps, dismissals, acknowledgments or failed app assertions.
        let attempts = body == nil ? 3 : 1
        for attempt in 1...attempts {
            do { return try exchangeOnce(path, body: body) }
            catch {
                let failure = error as NSError
                let transient = (failure.domain == NSURLErrorDomain &&
                    [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(failure.code)) ||
                    (failure.domain == "ShareDriver" && failure.code == 3)
                guard transient, attempt < attempts else { throw error }
                print("Share driver loopback read retry \(attempt)/\(attempts), error \(failure.code)")
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        throw NSError(domain: "ShareDriver", code: 8)
    }

    private func exchangeOnce(_ path: String, body: [String: Any]? = nil) throws -> Data {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["ZE_SHARE_DRIVER_BRIDGE"],
              let secret = environment["ZE_SHARE_DRIVER_SECRET"],
              let url = URL(string: base + path) else {
            throw NSError(domain: "ShareDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing loopback bridge configuration"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue(secret, forHTTPHeaderField: "X-Ze-Fixture-Secret")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let completed = DispatchSemaphore(value: 0)
        var received: Data?
        var failure: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            else if (response as? HTTPURLResponse)?.statusCode != 200 {
                failure = NSError(domain: "ShareDriver", code: 2, userInfo: [NSLocalizedDescriptionKey: "Loopback bridge rejected request"])
            } else { received = data }
            completed.signal()
        }
        task.resume()
        guard completed.wait(timeout: .now() + 8) == .success else {
            task.cancel()
            throw NSError(domain: "ShareDriver", code: 3, userInfo: [NSLocalizedDescriptionKey: "Loopback bridge timed out"])
        }
        if let failure { throw failure }
        guard let received else { throw NSError(domain: "ShareDriver", code: 4) }
        return received
    }

    @MainActor
    func testProductionShareButtonAndInteractiveDismissal() throws {
        continueAfterFailure = false
        guard let bundleID = ProcessInfo.processInfo.environment["ZE_SHARE_DRIVER_BUNDLE"] else {
            XCTFail("Target bundle identifier is missing"); return
        }
        let app = XCUIApplication(bundleIdentifier: bundleID)
        // Let XCTest own launch ordering. testmanager may reinstall/terminate the
        // target, so attaching to an earlier simctl launch would lose its arguments.
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--verify-conversation-share"]
        if let fallback = ProcessInfo.processInfo.environment["ZE_SHARE_DRIVER_DYLD_FALLBACK"], !fallback.isEmpty {
            app.launchEnvironment["DYLD_FALLBACK_LIBRARY_PATH"] = fallback
        }
        app.launch()
        // Independent visualization, disclosure and export suites retain their
        // own action bounds and must all be allowed to publish a result.
        let deadline = Date().addingTimeInterval(600)
        var handled = Set<String>()
        var actions = 0
        var actionFailures: [String] = []
        while Date() < deadline {
            let request = try JSONDecoder().decode(Request.self, from: exchange("/request"))
            if request.action == "finish" {
                XCTAssertEqual(request.success, true, request.error ?? "Production share verification failed")
                XCTAssertTrue(actionFailures.isEmpty, actionFailures.joined(separator: "\n"))
                XCTAssertGreaterThanOrEqual(actions, 16, "Expected eight real share-button taps and eight interactive dismissals")
                return
            }
            guard let sequence = request.sequence, !handled.contains(sequence), request.action != "wait" else {
                Thread.sleep(forTimeInterval: 0.15)
                continue
            }
            var beforePNG: String?
            var hierarchy: String?
            var targetGeometry: [String: String]?
            var strategy = request.action
            do {
                switch request.action {
                case "selectVisualization":
                    let target = app.descendants(matching: .any)[request.identifier ?? "ze.visualization.custom.preview"].firstMatch
                    guard target.waitForExistence(timeout: 10) else {
                        throw NSError(domain: "ShareDriver", code: 9, userInfo: [NSLocalizedDescriptionKey: "Visualization selection target is missing"])
                    }
                    let point = target.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: request.startX ?? 20, dy: request.startY ?? 20))
                    targetGeometry = ["frame": NSCoder.string(for: target.frame),
                                      "point": NSCoder.string(for: point.screenPoint)]
                    if request.endX == 2 { point.doubleTap(); strategy = "xcui-visualization-double-tap" }
                    else { point.press(forDuration: 0.65); strategy = "xcui-visualization-long-press" }
                case "tapImageMain":
                    let target = app.images[request.identifier ?? "markdown.imageGroup.main"].firstMatch
                    guard target.waitForExistence(timeout: 10), target.isHittable else {
                        throw NSError(domain: "ShareDriver", code: 11, userInfo: [NSLocalizedDescriptionKey: "Main image did not become hittable"])
                    }
                    target.tap()
                    strategy = "xcui-main-image-tap"
                case "tapImageThumbnail":
                    let button = app.buttons[request.identifier ?? "markdown.imageGroup.thumbnail.0"].firstMatch
                    let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: button)
                    guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
                        throw NSError(domain: "ShareDriver", code: 10, userInfo: [NSLocalizedDescriptionKey: "Image thumbnail did not become hittable"])
                    }
                    button.tap()
                    strategy = "xcui-image-thumbnail-tap"
                case "open":
                    let button = app.buttons[request.identifier ?? "chatShare.export"].firstMatch
                    let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: button)
                    guard XCTWaiter.wait(for: [ready], timeout: 25) == .completed else {
                        throw NSError(domain: "ShareDriver", code: 5, userInfo: [NSLocalizedDescriptionKey: "Production share button did not become hittable"])
                    }
                    button.tap()
                case "dismiss":
                    beforePNG = XCUIScreen.main.screenshot().pngRepresentation.base64EncodedString()
                    hierarchy = app.debugDescription
                    strategy = try dismissSystemShareSheet(app)
                default:
                    throw NSError(domain: "ShareDriver", code: 7, userInfo: [NSLocalizedDescriptionKey: "Unknown UI action"])
                }
                let screen = XCUIScreen.main.screenshot()
                let capture = XCTAttachment(screenshot: screen)
                capture.name = "share-\(sequence)-\(request.action)"
                capture.lifetime = .keepAlways
                add(capture)
                var acknowledgment: [String: Any] = ["sequence": sequence, "success": true, "action": request.action,
                    "strategy": strategy, "screenPNG": screen.pngRepresentation.base64EncodedString()]
                acknowledgment["beforeScreenPNG"] = beforePNG
                acknowledgment["hierarchy"] = hierarchy
                acknowledgment["targetGeometry"] = targetGeometry
                _ = try exchange("/ack", body: acknowledgment)
                handled.insert(sequence)
                actions += 1
            } catch {
                var failure: [String: Any] = ["sequence": sequence, "success": false, "error": error.localizedDescription,
                    "screenPNG": XCUIScreen.main.screenshot().pngRepresentation.base64EncodedString(),
                    "hierarchy": hierarchy ?? app.debugDescription]
                failure["beforeScreenPNG"] = beforePNG
                _ = try? exchange("/ack", body: failure)
                // The app records this failed action in its current suite.
                // Keep driving later independent suites; the final verdict
                // still fails even if an app-side report lost this error.
                handled.insert(sequence)
                actionFailures.append("\(request.action) \(request.identifier ?? ""): \(error.localizedDescription)")
            }
        }
        XCTFail("Production share verification did not complete within 600 seconds")
    }
}
'''


def write_project(directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    project = directory / "ShareDriver.xcodeproj"
    project.mkdir(exist_ok=True)
    (directory / "ShareDriver.swift").write_text(DRIVER, encoding="utf-8")
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "BNDL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True, "NSAllowsArbitraryLoads": True},
    }
    with (directory / "Runner-Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    # A standalone UI Testing Bundle has its own XCTest runner app. There is no
    # target dependency on Ze, TEST_HOST or source reference into the app project.
    pbx = r'''// !$*UTF8*$!
{
 archiveVersion = 1; classes = {}; objectVersion = 56;
 objects = {
  A00000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 1600;}; buildConfigurationList = A00000000000000000000010; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = A00000000000000000000002; productRefGroup = A00000000000000000000003; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000004);};
  A00000000000000000000002 = {isa = PBXGroup; children = (A00000000000000000000005, A00000000000000000000003); sourceTree = "<group>";};
  A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000006); name = Products; sourceTree = "<group>";};
  A00000000000000000000004 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000011; buildPhases = (A00000000000000000000008, A00000000000000000000009); buildRules = (); dependencies = (); name = ShareDriver; productName = ShareDriver; productReference = A00000000000000000000006; productType = "com.apple.product-type.bundle.ui-testing";};
  A00000000000000000000005 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ShareDriver.swift; sourceTree = "<group>";};
  A00000000000000000000006 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ShareDriver.xctest; sourceTree = BUILT_PRODUCTS_DIR;};
  A00000000000000000000007 = {isa = PBXBuildFile; fileRef = A00000000000000000000005;};
  A00000000000000000000008 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000007); runOnlyForDeploymentPostprocessing = 0;};
  A00000000000000000000009 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;};
  A00000000000000000000010 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000012); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;};
  A00000000000000000000011 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000013); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;};
  A00000000000000000000012 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {SDKROOT = iphonesimulator; IPHONEOS_DEPLOYMENT_TARGET = 16.0; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0;};};
  A00000000000000000000013 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = "com.ze.share-driver"; PRODUCT_NAME = "$(TARGET_NAME)"; INFOPLIST_FILE = "Runner-Info.plist"; GENERATE_INFOPLIST_FILE = NO; CODE_SIGNING_ALLOWED = NO; CODE_SIGNING_REQUIRED = NO; TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTED_PLATFORMS = iphonesimulator; ENABLE_TESTING_SEARCH_PATHS = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @loader_path/Frameworks";};};
 }; rootObject = A00000000000000000000001;
}
'''
    (project / "project.pbxproj").write_text(pbx, encoding="utf-8")
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    scheme = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="NO"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000004" BuildableName="ShareDriver.xctest" BlueprintName="ShareDriver" ReferencedContainer="container:ShareDriver.xcodeproj"/>
  </BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO">
  <Testables><TestableReference skipped="NO" parallelizable="NO">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000004" BuildableName="ShareDriver.xctest" BlueprintName="ShareDriver" ReferencedContainer="container:ShareDriver.xcodeproj"/>
  </TestableReference></Testables>
 </TestAction>
</Scheme>
'''
    (schemes / "ShareDriver.xcscheme").write_text(scheme, encoding="utf-8")
    return project


def logged(command: list[str], path: Path, timeout: int) -> int:
    print("Running " + " ".join(command), flush=True)
    with path.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            output.write(f"\nDriver command exceeded its bounded timeout ({timeout} seconds).\n")
            code = 124
    print(path.read_text(encoding="utf-8", errors="replace")[-18000:], flush=True)
    return code


def prepare(args: argparse.Namespace) -> int:
    project = write_project(args.work)
    if args.generate_only:
        print(project)
        return 0
    return logged([
        "xcodebuild", "build-for-testing", "-project", str(project), "-scheme", "ShareDriver",
        "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={args.device}",
        "-derivedDataPath", str(args.work / "DerivedData"), "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM=", "ONLY_ACTIVE_ARCH=YES",
    # A cold simulator SDK module cache can exceed two minutes on the shared
    # macOS runner. This bounds compilation only; runtime/UI deadlines and all
    # verification assertions remain unchanged.
    ], args.work / "build.log", 300)


def test_targets(run: dict):
    if "TestConfigurations" in run:
        for configuration in run["TestConfigurations"]:
            yield from configuration.get("TestTargets", [])
    else:
        for key, target in run.items():
            if not key.startswith("__") and isinstance(target, dict):
                yield target


def run_driver(args: argparse.Namespace) -> int:
    args.evidence.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(24)
    verification = args.container / "Documents/share-verification"
    verification.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, value: dict, status: int = 200):
            data = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def authorized(self):
            return secrets.compare_digest(self.headers.get("X-Ze-Fixture-Secret", ""), token)

        def do_GET(self):
            if not self.authorized() or urllib.parse.urlsplit(self.path).path != "/request":
                self.reply({"error": "unauthorized"}, 403)
                return
            with lock:
                result = verification / "result.json"
                request = verification / "ui-request.json"
                try:
                    if result.exists():
                        payload = json.loads(result.read_text())
                        self.reply({"action": "finish", "success": payload.get("success") is True, "error": payload.get("error", "")})
                    elif request.exists():
                        self.reply(json.loads(request.read_text()))
                    else:
                        self.reply({"action": "wait"})
                except (OSError, ValueError):
                    self.reply({"action": "wait"})

        def do_POST(self):
            if not self.authorized() or urllib.parse.urlsplit(self.path).path != "/ack":
                self.reply({"error": "unauthorized"}, 403)
                return
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 24 * 1024 * 1024:
                self.reply({"error": "invalid body"}, 400)
                return
            try:
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload.get("sequence"), str) or not re.fullmatch(r"[A-Za-z0-9-]{1,80}", payload["sequence"]) or not isinstance(payload.get("success"), bool):
                    raise ValueError("invalid acknowledgment")
                with lock:
                    pending = verification / "ui-request.json"
                    current = json.loads(pending.read_text()) if pending.exists() else {}
                    if payload["sequence"] != current.get("sequence") or (verification / "result.json").exists():
                        self.reply({"error": "stale acknowledgment"}, 409)
                        return
                    # Persist real screen output outside xcresult so CI reviewers
                    # can inspect remote system-share UI on any host platform.
                    for field, suffix in [("screenPNG", "after"), ("beforeScreenPNG", "before")]:
                        encoded = payload.pop(field, None)
                        if encoded is not None:
                            png = base64.b64decode(encoded, validate=True)
                            if not png.startswith(b"\x89PNG\r\n\x1a\n"):
                                raise ValueError("invalid screenshot PNG")
                            name = f"screen-{payload['sequence']}-{suffix}.png"
                            (args.evidence / name).write_bytes(png)
                            payload[field + "File"] = name
                    hierarchy = payload.pop("hierarchy", None)
                    if isinstance(hierarchy, str):
                        name = f"hierarchy-{payload['sequence']}.txt"
                        (args.evidence / name).write_text(hierarchy, encoding="utf-8")
                        payload["hierarchyFile"] = name
                    temporary = verification / "ui-ack.pending"
                    temporary.write_text(json.dumps(payload), encoding="utf-8")
                    temporary.replace(verification / "ui-ack.json")
                    with (args.evidence / "actions.jsonl").open("a", encoding="utf-8") as history:
                        history.write(json.dumps(payload) + "\n")
                self.reply({"ok": True})
            except (OSError, ValueError, TypeError):
                self.reply({"error": "invalid acknowledgment"}, 400)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        products = args.work / "DerivedData/Build/Products"
        candidates = sorted(products.glob("*.xctestrun"))
        if len(candidates) != 1:
            raise RuntimeError(f"Expected one built UI test descriptor, found {len(candidates)}")
        with candidates[0].open("rb") as stream:
            descriptor = plistlib.load(stream)
        count = 0
        for target in test_targets(descriptor):
            target.setdefault("EnvironmentVariables", {}).update({
                "ZE_SHARE_DRIVER_BRIDGE": f"http://127.0.0.1:{server.server_port}",
                "ZE_SHARE_DRIVER_SECRET": token,
                "ZE_SHARE_DRIVER_BUNDLE": args.bundle,
                "ZE_SHARE_DRIVER_DYLD_FALLBACK": os.environ.get("SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH", ""),
            })
            # The external app was already built/installed; no build dependency.
            target["UITargetAppPath"] = str(args.app)
            target["UITargetAppBundleIdentifier"] = args.bundle
            count += 1
        if count != 1:
            raise RuntimeError(f"Expected one standalone UI test target, found {count}")
        prepared = products / "ShareDriver-Configured.xctestrun"
        with prepared.open("wb") as stream:
            plistlib.dump(descriptor, stream)
        result = logged([
            "xcodebuild", "test-without-building", "-xctestrun", str(prepared),
            "-destination", f"platform=iOS Simulator,id={args.device}",
            "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
            "-disable-concurrent-destination-testing", "-resultBundlePath", str(args.evidence / "ShareDriver.xcresult"),
            "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "630",
        ], args.evidence / "test.log", 660)
        return result
    finally:
        server.shutdown()
        server.server_close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "run"])
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--generate-only", action="store_true")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--container", type=Path)
    parser.add_argument("--bundle")
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    args.work = args.work.resolve()
    if args.mode == "prepare":
        return prepare(args)
    for required in ["app", "container", "bundle", "evidence"]:
        if getattr(args, required) is None:
            parser.error(f"run requires --{required}")
    args.app = args.app.resolve()
    args.container = args.container.resolve()
    args.evidence = args.evidence.resolve()
    return run_driver(args)


if __name__ == "__main__":
    raise SystemExit(main())
