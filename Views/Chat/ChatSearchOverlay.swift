//
//  ChatSearchBar.swift
//  Minis - chat page (AIChatView)
//
//  [T-in-chat-search] The bar "Search in Chat" opens under the navigation
//  bar: query field, "3/12" counter, previous (older) / next (newer), Done.
//  Mounted in AIChatView's `topBanners`, so the list's top inset already
//  makes room for it. Observes only the search controller - typing here
//  never re-renders the chat page.
//
//  Keys: Return = next result, Shift-Return = previous.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import SwiftUI
import UIKit

struct ChatSearchOverlay: View {
    @ObservedObject var model: ChatSearchModel
    static let barHeight: CGFloat = 52
    var onJump: (ChatSearchHit) -> Void
    var onClose: () -> Void
    /// Called after Done: the page restores its composer.

    @FocusState private var fieldFocused: Bool

    private var hasQuery: Bool { !model.normalizedQuery.isEmpty }
    private var hasResults: Bool { model.hits.count > 0 }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChatColors.secondaryText)
                TextField(String(localized: "Search this chat"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($fieldFocused)
                    .onSubmit {
                        model.step(1)
                        // Return must not dismiss the keyboard: the user is
                        // stepping through results.
                        fieldFocused = true
                    }
                    .accessibilityIdentifier("chatSearchField")
                if hasQuery {
                    counter
                    Button {
                        model.query = ""
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(ChatColors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Clear"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color(UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            navButton(systemName: "chevron.up", label: String(localized: "Previous Result")) { model.step(-1) }
                .keyboardShortcut(.return, modifiers: .shift)
                .accessibilityIdentifier("chatSearchPrevious")
            navButton(systemName: "chevron.down", label: String(localized: "Next Result")) { model.step(1) }
                .accessibilityIdentifier("chatSearchNext")

            Button {
                fieldFocused = false
                model.deactivate()
                onClose()
            } label: {
                Text(String(localized: "Done"))
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.leading, 2)
            .accessibilityIdentifier("chatSearchDone")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .overlay(alignment: .bottom) { noticeView.offset(y: 34) }
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusRequest) { _ in fieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatSearchBar")
    }

    @ViewBuilder
    private var counter: some View {
        if model.isSearching && !hasResults {
            ProgressView().scaleEffect(0.7).frame(width: 20)
        } else if hasResults {
            Text(verbatim: ChatSearchNavigation.counterText(index: model.hits.isEmpty ? nil : model.currentIndex, count: model.hits.count,
                                                            truncated: model.isTruncated))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("结果 \(model.currentIndex + 1)，共 \(model.hits.count) 个")
                .accessibilityIdentifier("chatSearchCounter")
        } else {
            Text(String(localized: "No results"))
                .font(.system(size: 13))
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("chatSearchCounter")
        }
    }

    private func navButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hasResults ? Color.accentColor : ChatColors.tertiaryText)
        .disabled(!hasResults)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var noticeView: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.75), in: Capsule())
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
