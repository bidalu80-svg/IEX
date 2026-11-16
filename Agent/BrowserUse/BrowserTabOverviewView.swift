import Foundation
import SwiftUI
import UIKit

// MARK: - Share payload

/// Everything the browser's share button needs, frozen at tap time so a page
/// change underneath cannot alter what the system share sheet receives.
struct BrowserSharePayload: Identifiable {
    let id = UUID()
    let title: String
    let url: URL

    /// Share body: page title (when present) plus its URL, one per line.
    var text: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url.absoluteString : "\(trimmed)\n\(url.absoluteString)"
    }
}

/// UIActivityViewController wrapper for the current tab's title + URL.
struct BrowserShareSheet: UIViewControllerRepresentable {
    let payload: BrowserSharePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [payload.text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Tab overview

/// Reference-style tab grid: two columns of snapshot cards, each with the
/// page's favicon + domain underneath and a close button in the top-right.
/// Tapping a card selects that tab and dismisses the overview. The current
/// tab gets an accent outline. Snapshots come from `BrowserTabPool`'s bounded
/// in-memory cache; cards without one fall back to favicon + title. [P2]
struct BrowserTabOverviewView: View {
    @ObservedObject var pool: BrowserTabPool
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if pool.tabs.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .center, spacing: 20) {
                            ForEach(pool.tabs) { tab in
                                tabCard(tab)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("标签页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        addTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .regular))
                    }
                    .disabled(isAgentControlled || pool.tabs.count >= BrowserTabPool.maxTabs)
                    .accessibilityLabel(Text("新建标签页"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        // Presented as a full-screen page by BrowserSheetView; no sheet
        // detents or drag handle here.
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("没有打开的标签页")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isAgentControlled: Bool { pool.controlState == .agent }

    private func tabCard(_ tab: BrowserTabPool.Tab) -> some View {
        let isSelected = tab.id == pool.selectedTabId
        let domain = tabDomain(for: tab)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Button {
                    select(tab)
                } label: {
                    thumbnail(for: tab, isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .disabled(isAgentControlled)
                .accessibilityLabel(Text(tabTitle(for: tab)))

                Button {
                    _ = pool.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .disabled(isAgentControlled)
                .padding(8)
                .accessibilityLabel(Text("关闭标签页"))
            }

            Button {
                select(tab)
            } label: {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    FaviconView(domain: domain, url: tab.manager.currentURL, size: 16)
                    Text(domain.isEmpty ? tabTitle(for: tab) : domain)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Color(UIColor.label))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAgentControlled)
        }
    }

    private func thumbnail(for tab: BrowserTabPool.Tab, isSelected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))

            if let snapshot = pool.tabSnapshot(forTabId: tab.id) {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
            } else {
                thumbnailPlaceholder(for: tab)
            }
        }
        .aspectRatio(0.74, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.black.opacity(0.08),
                        lineWidth: isSelected ? 3 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// No snapshot yet (fresh tab, or history restored after a relaunch):
    /// favicon + title is the placeholder promised by the plan.
    private func thumbnailPlaceholder(for tab: BrowserTabPool.Tab) -> some View {
        VStack(spacing: 10) {
            FaviconView(domain: tabDomain(for: tab), url: tab.manager.currentURL, size: 44)
            Text(tabTitle(for: tab))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private func select(_ tab: BrowserTabPool.Tab) {
        if tab.id != pool.selectedTabId {
            // `selectedTabId.didSet` captures the outgoing tab's snapshot
            // before the browser view swaps it out.
            pool.selectedTabId = tab.id
            pool.touchActivity()
        }
        dismiss()
    }

    private func addTab() {
        if pool.newTab().success {
            dismiss()
        }
    }

    private func tabTitle(for tab: BrowserTabPool.Tab) -> String {
        let title = tab.manager.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let url = tab.manager.currentURL
        if !url.isEmpty { return url }
        return "Tab \(tab.id + 1)"
    }

    private func tabDomain(for tab: BrowserTabPool.Tab) -> String {
        FaviconService.normalizedDomain(tab.manager.currentURL) ?? ""
    }
}
