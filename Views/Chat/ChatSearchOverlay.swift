//
//  ChatSearchOverlay.swift
//  ZeApp
//
//  [T-chat-search] Search bar for the open conversation.
//
//  Layout follows the in-chat search people already know: one horizontal bar
//  under the navigation bar, a filled field with the magnifier on the left and
//  "n/m" plus the clear button on the right, then the previous/next chevrons
//  and a Done button. No result list — the hits are painted on the transcript
//  itself, so the bar only has to move between them.
//

import SwiftUI

struct ChatSearchOverlay: View {
    /// Height of the bar, including its vertical padding. Used by the list to
    /// keep a jumped-to match clear of it.
    static let barHeight: CGFloat = 54

    @ObservedObject var model: ChatSearchModel
    var onJump: (ChatSearchHit) -> Void
    var onClose: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var fieldFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color(white: 0.92)
    }

    private var barFill: Color {
        colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.98)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? Color(white: 0.62) : Color(white: 0.45)
    }

    private var hairline: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    private var maxWidth: CGFloat {
        sizeClass == .regular ? 720 : .infinity
    }

    private var counterText: String {
        guard !model.hits.isEmpty else { return "0/0" }
        return "\(model.currentIndex + 1)/\(model.hits.count)"
    }

    var body: some View {
        HStack(spacing: 10) {
            field

            stepButton("chevron.up", label: String(localized: "Previous Match")) {
                step(-1)
            }
            stepButton("chevron.down", label: String(localized: "Next Match")) {
                step(1)
            }

            Button(action: onClose) {
                Text(String(localized: "Done"))
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close Search"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: maxWidth)
        .background(
            barFill
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(hairline)
                        .frame(height: 0.5)
                }
        )
        .onAppear { isFocused = true }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(secondaryText)

            TextField(String(localized: "Search"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { step(1) }

            if !model.query.isEmpty {
                Text(counterText)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(secondaryText)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.15), value: model.currentIndex)

                Button {
                    model.clear()
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(secondaryText.opacity(0.55))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear Search"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fieldFill)
        )
        .animation(.easeOut(duration: 0.12), value: model.query.isEmpty)
    }

    private func stepButton(_ symbol: String,
                            label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 28, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.hits.isEmpty ? secondaryText.opacity(0.35) : Color.accentColor)
        .disabled(model.hits.isEmpty)
        .accessibilityLabel(label)
    }

    // MARK: Stepping

    private func step(_ delta: Int) {
        guard !model.hits.isEmpty else { return }
        model.step(delta)
        if let current = model.current {
            onJump(current)
        }
    }
}
