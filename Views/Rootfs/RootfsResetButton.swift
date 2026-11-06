//
//  RootfsResetButton.swift
//  ZeApp
//
//  Quick reset button component for easy integration
//

import SwiftUI

/// Quick reset button that can be embedded anywhere in the UI
struct RootfsResetButton: View {
    enum Style {
        case compact  // Small icon button
        case normal   // Regular button
        case prominent // Large styled button
    }

    let style: Style
    let showBackupOption: Bool
    @State private var showResetAlert = false
    @State private var showBackupAlert = false
    @State private var isProcessing = false
    @State private var statusMessage: String?

    init(style: Style = .normal, showBackupOption: Bool = true) {
        self.style = style
        self.showBackupOption = showBackupOption
    }

    var body: some View {
        Group {
            switch style {
            case .compact:
                compactButton
            case .normal:
                normalButton
            case .prominent:
                prominentButton
            }
        }
        .disabled(isProcessing)
        .alert("重建 Rootfs？", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("全新重建", role: .destructive) {
                performReset(keepBackup: false)
            }
        } message: {
            Text("重启后安装全新的 rootfs，不自动恢复 /root。原目录会保留，不会释放存储空间。")
        }
        .alert("重建并保留用户数据？", isPresented: $showBackupAlert) {
            Button("Cancel", role: .cancel) {}
            Button("重建并保留用户数据", role: .destructive) {
                performReset(keepBackup: true)
            }
        } message: {
            Text("保留原目录并记录恢复任务。重启后会在内核启动前自动恢复 /root；其他位置的数据仍保留在原目录中。")
        }
    }

    private var compactButton: some View {
        Menu {
            Button(action: { showResetAlert = true }) {
                Label("全新重建", systemImage: "trash")
            }

            if showBackupOption {
                Button(action: { showBackupAlert = true }) {
                    Label("重建并保留用户数据", systemImage: "archivebox")
                }
            }
        } label: {
            Image(systemName: "arrow.clockwise.circle")
                .imageScale(.large)
                .foregroundColor(.red)
        }
    }

    private var normalButton: some View {
        Menu {
            Button(action: { showResetAlert = true }) {
                Label("全新重建", systemImage: "trash")
            }

            if showBackupOption {
                Button(action: { showBackupAlert = true }) {
                    Label("重建并保留用户数据", systemImage: "archivebox")
                }
            }
        } label: {
            Label("重建 Rootfs", systemImage: "arrow.clockwise")
                .foregroundColor(.red)
        }
    }

    private var prominentButton: some View {
        VStack(spacing: 12) {
            Button(action: { showResetAlert = true }) {
                Label("重建 Rootfs", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }

            if showBackupOption {
                Button(action: { showBackupAlert = true }) {
                    Label("重建并保留用户数据", systemImage: "archivebox")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }

            if isProcessing {
                HStack {
                    ProgressView()
                    Text(statusMessage ?? "Processing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func performReset(keepBackup: Bool) {
        isProcessing = true
        statusMessage = keepBackup ? "正在保留数据并安排恢复…" : "正在保留原目录并重建…"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let backup = try RootfsManager.shared.reset(keepUserData: keepBackup)

                DispatchQueue.main.async {
                    self.isProcessing = false

                    if keepBackup, backup != nil {
                        self.statusMessage = "✅ 已安排恢复 /root，请重启应用。原目录完整保留。"
                    } else {
                        self.statusMessage = "✅ 请重启应用以全新安装。原目录保留，未释放存储空间。"
                    }

                    // Clear message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self.statusMessage = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.statusMessage = "❌ Error: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Quick access reset toolbar item
struct RootfsResetToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            RootfsResetButton(style: .compact)
        }
    }
}

// MARK: - Usage Examples

/*

 // Example 1: Add to toolbar
 .toolbar {
     RootfsResetToolbarItem()
 }

 // Example 2: Compact icon button
 RootfsResetButton(style: .compact)

 // Example 3: Normal button
 RootfsResetButton(style: .normal)

 // Example 4: Prominent styled buttons
 RootfsResetButton(style: .prominent)

 // Example 5: Reset only (no backup option)
 RootfsResetButton(style: .normal, showBackupOption: false)

 // Example 6: In a Form/List
 Section("Danger Zone") {
     RootfsResetButton(style: .normal)
 }

 // Example 7: Custom layout
 VStack {
     Text("System Management")
         .font(.headline)
     RootfsResetButton(style: .prominent)
 }

 */

#Preview("Compact") {
    NavigationStack {
        VStack {
            RootfsResetButton(style: .compact)
        }
        .navigationTitle("Compact Style")
    }
}

#Preview("Normal") {
    NavigationStack {
        List {
            Section("Actions") {
                RootfsResetButton(style: .normal)
            }
        }
        .navigationTitle("Normal Style")
    }
}

#Preview("Prominent") {
    NavigationStack {
        VStack(spacing: 20) {
            Text("Rootfs Management")
                .font(.title)
                .fontWeight(.bold)

            RootfsResetButton(style: .prominent)
        }
        .padding()
        .navigationTitle("Prominent Style")
    }
}
