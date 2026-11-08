#!/usr/bin/env python3
"""Drive a focused diagnostic; selected ranges are measured by the target app.

An absent selection is an experimental result, never a successful feature test.
The existing standalone XCTest project generator keeps this independent of Ze's
native dependencies, account state and full application build.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import plistlib


DRIVER = r'''import XCTest

final class SelectionDiagnosticDriver: XCTestCase {
    @MainActor
    func testRealGesturesInEachContainer() throws {
        continueAfterFailure = false
        let cases = ["native-long", "native-double", "combined-long", "combined-double",
                     "attachment-long", "attachment-double", "production-long", "production-double"]
        let app = XCUIApplication(bundleIdentifier: "com.ze.selection-diagnostic")
        for name in cases {
            app.launchArguments = ["--case", name]
            app.launch()
            let identifier = name.hasPrefix("native-") ? "ze.selection.native" : "ze.visualization.custom.preview"
            let target = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 5), "Missing target for \(name)")
            let point = target.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: 28))
            if name.hasSuffix("-double") { point.doubleTap() }
            else { point.press(forDuration: 0.65) }
            XCTAssertTrue(app.staticTexts["ze.selection.recorded"].waitForExistence(timeout: 15),
                          "Target app did not record native selection state for \(name)")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--generate-only', action='store_true')
    args = parser.parse_args()
    args.work = args.work.resolve()
    args.evidence = args.evidence.resolve()
    args.evidence.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).with_name('share-xcui-driver.py')
    spec = importlib.util.spec_from_file_location('share_driver', source)
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    shared.DRIVER = DRIVER
    project = shared.write_project(args.work)
    if args.generate_only:
        print(project)
        return 0
    code = shared.logged([
        'xcodebuild', 'build-for-testing', '-project', str(project), '-scheme', 'ShareDriver',
        '-configuration', 'Debug', '-destination', f'platform=iOS Simulator,id={args.device}',
        '-derivedDataPath', str(args.work / 'DerivedData'), 'CODE_SIGNING_ALLOWED=NO',
        'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=', 'ONLY_ACTIVE_ARCH=YES',
    ], args.evidence / 'driver-build.log', 300)
    if code:
        return code
    descriptors = list((args.work / 'DerivedData/Build/Products').glob('*.xctestrun'))
    if len(descriptors) != 1:
        raise RuntimeError(f'Expected one test descriptor, found {len(descriptors)}')
    with descriptors[0].open('rb') as stream:
        descriptor = plistlib.load(stream)
    targets = list(shared.test_targets(descriptor))
    if len(targets) != 1:
        raise RuntimeError(f'Expected one UI test target, found {len(targets)}')
    targets[0]['UITargetAppPath'] = str(args.app.resolve())
    targets[0]['UITargetAppBundleIdentifier'] = 'com.ze.selection-diagnostic'
    # Xcode resolves __TESTROOT__ relative to this file. Keep the configured
    # descriptor beside the original products, as the full-app driver does.
    configured = descriptors[0].with_name('SelectionDiagnostic-Configured.xctestrun')
    with configured.open('wb') as stream:
        plistlib.dump(descriptor, stream)
    return shared.logged([
        'xcodebuild', 'test-without-building', '-xctestrun', str(configured),
        '-destination', f'platform=iOS Simulator,id={args.device}',
        '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
        '-disable-concurrent-destination-testing', '-resultBundlePath', str(args.evidence / 'SelectionDiagnostic.xcresult'),
        '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '210',
    ], args.evidence / 'driver-test.log', 240)


if __name__ == '__main__':
    raise SystemExit(main())
