//
//  ChatSearchOverlay.swift
//  ZeApp
//
//  [T-chat-search] Floating search panel pinned under the navigation bar.
//
//  Design notes:
//  - It floats over the transcript instead of pushing a sheet, so a jump is
//    visible immediately behind the panel (the whole point of "search in
//    this chat" rather than "search and then navigate back").
//  - One accent colour carries the whole surface: the field's focus ring, the
//    current row, and the keyword highlight all use the same tint, so the
//    panel reads as one control rather than a stack of boxes.
//  - Motion is limited to two places: the panel sliding in, and the row
//    selection tint cross-fading. Everything else stays still so the text is
//    the only thing moving under the reader's eye.
//

import SwiftUI

struct ChatSearchOverlay: View {
    @ObservedObject var model: ChatSearchModel
    var onJump: (ChatSearchHit) -> Void
    var onClose: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var surface: Color {
        colorScheme == .dark ? Color(white: 0.14) : Color.white
    }

    private var secondaryText: Color {
        colorScheme == .dark ? Color(white: 0.66) : Color(white: 0.42)
    }

    private var hairline: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    private var maxWidth: CGFloat {
        sizeClass == .regular ? 560 : .infinity
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !model.hits.isEmpty {
                Rectangle()
                    .fill(hairline)
                    .frame(height: 0.6)
                results
            } else if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                emptyState
            }
        }
        .frame(maxWidth: maxWidth)
        .background(surface.opacity(colorScheme == .dark ? 0.96 : 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(hairline, lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.13),
                radius: 18, x: 0, y: 8)
        .padding(.horizontal, 12)
        .onAppear { isFocused = true }
    }

    // MARK: Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isFocused ? Color.accentColor : secondaryText)

            TextField(String(localized: "Search this chat…"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { jumpToCurrent() }

            if !model.query.isEmpty {
                Button {
                    model.clear()
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryText.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear Search"))
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            if !model.hits.isEmpty {
                Text("\(model.currentIndex + 1)/\(model.hits.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06))
                    )
                    .contentTransition(.numericText())
                    .accessibilityLabel(String(localized: "Match position"))

                stepButton("chevron.up", label: String(localized: "Previous Match")) {
                    model.step(-1)
                    jumpToCurrent()
                }
                stepButton("chevron.down", label: String(localized: "Next Match")) {
                    model.step(1)
                    jumpToCurrent()
                }
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close Search"))
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .animation(.easeOut(duration: 0.16), value: model.hits.count)
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Results

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(model.hits) { hit in
                        row(hit)
                            .id(hit.id)
                    }
                }
            }
            .frame(maxHeight: 268)
            .animation(.easeOut(duration: 0.18), value: model.hits)
            .onChange(of: model.currentIndex) { _ in
                scrollToCurrent(proxy)
            }
            .onChange(of: model.hits.count) { _ in
                scrollToCurrent(proxy)
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current = model.current else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(current.id, anchor: .center)
        }
    }

    private func row(_ hit: ChatSearchHit) -> some View {
        let isCurrent = model.current?.id == hit.id
        return Button {
            model.select(hit)
            onJump(hit)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(hit.isUser ? Color.accentColor : Color.purple)
                        .frame(width: 5, height: 5)
                    Text(hit.isUser ? String(localized: "You") : String(localized: "Assistant"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(secondaryText)
                    Text(Self.timeFormatter.string(from: hit.timestamp))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(secondaryText.opacity(0.7))
                    if hit.isToolOutput {
                        Label(String(localized: "Tool"), systemImage: "wrench.and.screwdriver.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(secondaryText.opacity(0.8))
                            .labelStyle(.titleAndIcon)
                    }
                    Spacer(minLength: 0)
                }

                Text(ChatSearchHighlight.attributed(hit.snippet,
                                                    keywords: hit.keywords,
                                                    base: colorScheme == .dark ? .white : .black))
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SearchRowButtonStyle())
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(secondaryText.opacity(0.65))
            Text(String(localized: "No matches"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryText)
            Text(String(localized: "Separate keywords with spaces to narrow the results."))
                .font(.system(size: 11))
                .foregroundStyle(secondaryText.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
    }

    private func jumpToCurrent() {
        guard let current = model.current else { return }
        onJump(current)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

/// A press state that dims instead of highlighting: the row already carries a
/// tint when it is the current hit, so a second background would fight it.
private struct SearchRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
