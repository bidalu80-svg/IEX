import SwiftUI
import UIKit

@main
struct FavoritesUIHarness: App {
    var body: some Scene {
        WindowGroup {
            Text("收藏交互与正方形缩略图回归验证")
                .task { await MainActor.run { runChecks() } }
        }
    }

    @MainActor private func runChecks() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            var action = MediaFavoriteActionState()
            var calls = 0
            action.perform { throw MediaFavoriteActionError.missingFile }
            guard !action.succeeded, action.errorMessage != nil else { throw HarnessError.failed("failed save showed success") }
            action.perform { calls += 1 }
            guard action.succeeded, action.errorMessage == nil, calls == 1 else { throw HarnessError.failed("successful save did not show success") }
            action.perform { calls += 1 }
            guard calls == 1 else { throw HarnessError.failed("duplicate save not blocked") }

            let dimensions: [CGSize] = [CGSize(width: 80, height: 240), CGSize(width: 240, height: 80), CGSize(width: 120, height: 120)]
            var results: [[String: Double]] = []
            var images: [UIImage] = []
            for size in dimensions {
                let source = UIGraphicsImageRenderer(size: size).image { context in
                    UIColor.systemBlue.setFill(); context.fill(CGRect(origin: .zero, size: size))
                    UIColor.systemOrange.setFill()
                    context.fill(CGRect(x: size.width * 0.3, y: size.height * 0.3, width: size.width * 0.4, height: size.height * 0.4))
                }
                images.append(source)
                for width in [96.0, 144.0, 220.0] {
                    let square = MediaFavoriteSquare { Image(uiImage: source).resizable().scaledToFill() }
                    let host = UIHostingController(rootView: square)
                    let fitting = host.sizeThatFits(in: CGSize(width: width, height: 1000))
                    guard abs(fitting.width - width) < 0.5, abs(fitting.height - width) < 0.5 else {
                        throw HarnessError.failed("non-square layout: \(fitting), expected \(width)")
                    }
                    results.append(["sourceWidth": Double(size.width), "sourceHeight": Double(size.height), "width": Double(fitting.width), "height": Double(fitting.height)])
                }
            }
            for scheme in [ColorScheme.light, .dark] {
                let samples = HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        VStack(spacing: 6) {
                            MediaFavoriteSquare {
                                ZStack {
                                    Image(uiImage: image).resizable().scaledToFill()
                                    if index == 1 { Image(systemName: "play.fill").foregroundStyle(.white).padding(7).background(.black.opacity(0.6), in: Circle()) }
                                }
                            }
                            Text(index == 0 ? "竖图" : index == 1 ? "横向视频" : "正方形图").font(.caption)
                        }
                        .padding(7).frame(width: 144)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(12)
                .background(Color(uiColor: .systemBackground))
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: samples); renderer.scale = 2
                guard let data = renderer.uiImage?.pngData() else { throw HarnessError.failed("snapshot rendering failed") }
                try data.write(to: docs.appendingPathComponent(scheme == .light ? "favorites-light.png" : "favorites-dark.png"))
            }
            let output: [String: Any] = ["success": true, "actionChecks": 3, "squareLayouts": results]
            try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: docs.appendingPathComponent("favorites-ui-result.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject: ["success": false, "error": error.localizedDescription]).write(to: docs.appendingPathComponent("favorites-ui-result.json"))
        }
    }
}
private enum HarnessError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let value) = self { return value }; return nil }
}
