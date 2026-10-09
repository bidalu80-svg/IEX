import SwiftUI
import UIKit

/// Only a successful, durable store operation produces the success checkmark.
struct MediaFavoriteActionState {
    private(set) var succeeded = false
    private(set) var errorMessage: String?
    mutating func perform(_ action: () throws -> Void) {
        guard !succeeded else { return }
        do {
            try action()
            succeeded = true
            errorMessage = nil
        } catch {
            succeeded = false
            errorMessage = error.localizedDescription
        }
    }
}

struct MediaFavoriteActionButton<Label: View>: View {
    let action: () throws -> Void
    @ViewBuilder let label: (Bool) -> Label
    @State private var state = MediaFavoriteActionState()
    @State private var showError = false

    var body: some View {
        Button {
            state.perform(action)
            showError = state.errorMessage != nil
            UINotificationFeedbackGenerator().notificationOccurred(state.succeeded ? .success : .error)
        } label: {
            label(state.succeeded)
        }
        .disabled(state.succeeded)
        .accessibilityLabel(state.succeeded ? "已收藏" : "收藏到收藏夹")
        .alert("收藏失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: { Text(state.errorMessage ?? "请检查媒体文件和存储空间后重试。") }
    }
}

/// The clear square determines layout; the image lives in an overlay, so a tall
/// source image cannot change the grid row's height. Cropping affects previews only.
struct MediaFavoriteSquare<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    content()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

enum MediaFavoriteActionError: LocalizedError {
    case missingFile
    var errorDescription: String? { "媒体文件不存在或暂时不可读取，请重新打开后再收藏。" }
}
