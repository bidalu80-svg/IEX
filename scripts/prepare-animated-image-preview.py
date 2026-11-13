#!/usr/bin/env python3
"""Compile exact production preview and exact in-app animation checks in a small UIKit host."""
import hashlib, json, pathlib, sys
root=pathlib.Path(__file__).resolve().parents[1]
output=pathlib.Path(sys.argv[1]);output.mkdir(parents=True,exist_ok=True)
manifest={}
def read(path):
    b=(root/path).read_bytes();manifest[path]=hashlib.sha256(b).hexdigest();return b.decode().replace('\r\n','\n')
def section(s,start,end):
    a=s.index(start);return s[a:s.index(end,a)]
preview=read('Views/Chat/Media/ImagePreview.swift')
# Exact zoom canvas and decoder/player/surface; unrelated save/print chrome is not exercised.
canvas=section(preview,'struct ImagePreviewContent:','// MARK: - Fullscreen Image Preview (single image + chrome)')
animation=preview[preview.index('// MARK: - On-demand animated image preview'):]
verification=read('Views/Chat/SessionExport/ConversationShareVerification.swift')
check=section(verification,'    private static func verifyAnimatedImagePreview(', '    private static func verifyMultiImageStrip(')
bridge=section(verification,'    static func requestUIAction(', '    private static func activityController(')
wait=section(verification,'    private static func waitUntil(', '    private static func verifyTaskDisclosure(')
capture=section(verification,'    private static func capture(_ window:', '    private static func capturePDF(')
markdown=read('Views/Chat/SelectableMarkdownView.swift')
poster=section(markdown,'func downsampleImageData(', '// MARK: - SelectableMarkdownTheme')
header='import UIKit\nimport SwiftUI\nimport ImageIO\nimport PDFKit\nfunc resolveZeFileURLCached(url: URL) -> URL? { url.isFileURL ? url : nil }\nenum ChatExportError: Error { case writeFailed, noWindow }\n'
harness='@MainActor enum ConversationShareVerification {\n    private static var checks: [String] = []\n    private static var files: [String] = []\n    private static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("share-verification")\n    private static func checkpoint(_ label: String) { print(label) }\n    private static func require(_ value: Bool, _ label: String) throws {\n        guard value else { throw verificationError(label) }\n        checks.append(label); print("PASS: " + label)\n    }\n    static func run(window: UIWindow) async {\n        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)\n        var failure: String?\n        do { try await verifyAnimatedImagePreview(window: window) }\n        catch { failure = error.localizedDescription; try? capture(window, name: "animation-failure.png") }\n        let report: [String: Any] = ["success": failure == nil, "error": failure ?? "", "checks": checks, "files": files,\n            "scope": "Exact production zoom canvas, decoder, player, preview surface and in-app GIF/WebP assertions; real XCTest play/pause and seek. Excludes chat integration and IPA validation."]\n        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {\n            try? data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)\n        }\n    }\n'
app='}\n@main final class AnimationPreviewHarness: UIResponder, UIApplicationDelegate {\n    var window: UIWindow?\n    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {\n        let window = UIWindow(frame: UIScreen.main.bounds)\n        window.rootViewController = UIViewController(); window.makeKeyAndVisible(); self.window = window\n        Task { @MainActor in\n            for _ in 0..<100 {\n                if UIApplication.shared.applicationState == .active { break }\n                try? await Task.sleep(nanoseconds: 100_000_000)\n            }\n            await ConversationShareVerification.run(window: window)\n        }\n        return true\n    }\n}\n'
(output/'AnimationPreview.swift').write_text('\n'.join([header,canvas,animation,poster,harness,check,bridge,wait,capture,app]),encoding='utf-8')
(output/'sources.json').write_text(json.dumps(manifest,indent=2))
print(output/'AnimationPreview.swift')
