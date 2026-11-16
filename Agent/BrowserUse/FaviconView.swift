import SwiftUI
import UIKit

/// Small favicon shown in tab chips and history rows. Displays the cached
/// image when available and a deterministic letter tile otherwise, then
/// upgrades itself asynchronously once `FaviconService` resolves a real icon.
struct FaviconView: View {
    let domain: String
    var url: String? = nil
    var size: CGFloat = 16

    @ObservedObject private var service = FaviconService.shared
    @State private var image: UIImage?
    @State private var imageKey: String = ""

    private var normalizedDomain: String {
        FaviconService.normalizedDomain(domain) ?? domain.lowercased()
    }

    var body: some View {
        let displayedImage = imageKey == taskKey
            ? image
            : service.peekIcon(forDomain: normalizedDomain)
        ZStack {
            if let displayedImage {
                Image(uiImage: displayedImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                FaviconFallbackTile(domain: normalizedDomain, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.23), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: max(3, size * 0.23), style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
        .task(id: taskKey) {
            let key = taskKey
            imageKey = key
            image = service.peekIcon(forDomain: normalizedDomain)
            guard image == nil else { return }
            let pageURL = url.flatMap { URL(string: $0) }
            let loaded = await service.icon(forDomain: normalizedDomain, pageURL: pageURL)
            guard !Task.isCancelled, imageKey == key else { return }
            image = loaded
        }
        .onChange(of: service.revision) { _ in
            guard imageKey == taskKey else { return }
            if let cached = service.peekIcon(forDomain: normalizedDomain) {
                image = cached
            }
        }
    }

    private var taskKey: String {
        "\(normalizedDomain)|\(url ?? "")|\(Int(size))"
    }
}

/// Deterministic fallback: domain initial on a stable hash-picked colour.
private struct FaviconFallbackTile: View {
    let domain: String
    let size: CGFloat

    var body: some View {
        let style = FaviconService.fallbackStyle(forDomain: domain)
        ZStack {
            Color(style.color)
            Text(style.letter)
                .font(.system(size: max(7, size * 0.58), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }
}
