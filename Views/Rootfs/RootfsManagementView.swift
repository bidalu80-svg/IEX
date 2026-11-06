//
//  RootfsManagementView.swift
//  ZeApp
//
//  UI for managing rootfs (reset, backup, restore)
//

import SwiftUI

struct RootfsManagementView: View {
    @StateObject private var viewModel = RootfsManagementViewModel()
    @ObservedObject private var aojit = AOJITAcceleration.shared
    @ObservedObject private var dns = ContainerDNSSettings.shared
    @State private var showFileBrowser = false

    var body: some View {
        List {
            Section("Status") {
                HStack {
                    Text("Installed")
                    Spacer()
                    Image(systemName: viewModel.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(viewModel.isInstalled ? .green : .red)
                }

                if viewModel.isInstalled {
                    HStack {
                        Text("Size")
                        Spacer()
                        if viewModel.rootfsSize > 0 {
                            Text(viewModel.formattedSize)
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    HStack {
                        Text("Path")
                        Spacer()
                        Text(viewModel.rootfsPath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if viewModel.isInstalled {
                Section("Browse") {
                    Button(action: { showFileBrowser = true }) {
                        Label {
                            Text("Browse Files")
                        } icon: {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.blue, in: Circle())
                        }
                    }
                }

                MirrorsSectionView()

                // [T-aojit] Pre-recorded JIT images for the libraries every
                // command links against. [T-container-dns] DNS mode sits right
                // below it, matching the Rootfs page's grouping.
                AOJITSection(aojit: aojit)
                ContainerNetworkSection(dns: dns)
            }

            Section("Actions") {
                if !viewModel.isInstalled {
                    Button(action: { viewModel.install() }) {
                        Label {
                            Text("Install Rootfs")
                        } icon: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.green, in: Circle())
                        }
                    }
                    .disabled(viewModel.isProcessing)
                } else {
                    Button(action: { viewModel.showResetConfirmation = true }) {
                        Label {
                            Text("全新重建 Rootfs")
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.orange, in: Circle())
                        }
                    }
                    .disabled(viewModel.isProcessing)

                    Button(action: { viewModel.showResetWithBackupConfirmation = true }) {
                        Label {
                            Text("重建并保留用户数据")
                        } icon: {
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.indigo, in: Circle())
                        }
                    }
                    .disabled(viewModel.isProcessing)
                }

                if viewModel.hasBackup {
                    Label("已安排恢复 /root；重启后会在内核启动前自动恢复。", systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.isProcessing {
                Section {
                    HStack {
                        ProgressView()
                        Text(viewModel.statusMessage)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let message = viewModel.resultMessage {
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundColor(viewModel.lastOperationSuccess ? .green : .red)
                }
            }

            Section("Info") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About Rootfs")
                        .font(.headline)

                    Text("重建会安装全新的 Alpine Linux 文件系统。原目录会完整保留在恢复目录中，不会释放其占用的存储空间。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("• 全新重建：保留原目录，但不自动恢复 /root\n• 保留用户数据：重启后自动恢复 /root\n• 恢复完成后仍保留原备份")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Rootfs Management")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.refresh()
            aojit.prepareIfNeeded()
            dns.apply()
        }
        .alert("重建 Rootfs？", isPresented: $viewModel.showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("全新重建", role: .destructive) {
                viewModel.resetRootfs(keepUserData: false)
            }
        } message: {
            Text("重启后安装全新的 rootfs，不自动恢复 /root。原目录会保留，不会释放存储空间。")
        }
        .alert("重建并保留用户数据？", isPresented: $viewModel.showResetWithBackupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("重建并保留用户数据", role: .destructive) {
                viewModel.resetRootfs(keepUserData: true)
            }
        } message: {
            Text("保留原目录并记录恢复任务。重启后会在内核启动前自动恢复 /root；其他位置的数据仍保留在原目录中。")
        }
        .sheet(isPresented: $showFileBrowser) {
            NavigationStack {
                FileBrowserView(rootPath: RootfsManager.shared.dataPath, rootLabel: "/")
            }
        }
    }
}

class RootfsManagementViewModel: ObservableObject {
    @Published var isInstalled = false
    @Published var isProcessing = false
    @Published var statusMessage = ""
    @Published var resultMessage: String?
    @Published var lastOperationSuccess = false
    @Published var rootfsSize: Int64 = 0
    @Published var hasBackup = false
    @Published var showResetConfirmation = false
    @Published var showResetWithBackupConfirmation = false


    var rootfsPath: String {
        RootfsManager.shared.rootfsPath.path
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: rootfsSize, countStyle: .file)
    }

    func refresh() {
        isInstalled = RootfsManager.shared.isInstalled
        hasBackup = RootfsManager.shared.hasPendingUserDataRestore

        if isInstalled {
            DispatchQueue.global(qos: .utility).async {
                do {
                    let size = try RootfsManager.shared.getRootfsSize()
                    DispatchQueue.main.async {
                        self.rootfsSize = size
                    }
                } catch {
                    print("Failed to get rootfs size: \(error)")
                }
            }
        }
    }

    func install() {
        isProcessing = true
        statusMessage = "Installing rootfs..."
        resultMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try RootfsManager.shared.installIfNeeded()

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastOperationSuccess = true
                    self.resultMessage = "✅ Rootfs installed successfully"
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastOperationSuccess = false
                    self.resultMessage = "❌ Installation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func resetRootfs(keepUserData: Bool) {
        isProcessing = true
        statusMessage = keepUserData ? "正在保留数据并安排恢复…" : "正在保留原目录并重建…"
        resultMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try RootfsManager.shared.reset(keepUserData: keepUserData)

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastOperationSuccess = true
                    self.hasBackup = RootfsManager.shared.hasPendingUserDataRestore

                    if self.hasBackup {
                        self.resultMessage = "✅ 已保留原目录。请重启应用，/root 将在内核启动前自动恢复。"
                    } else {
                        self.resultMessage = "✅ 已保留原目录。请重启应用以全新安装；未释放存储空间。"
                    }

                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastOperationSuccess = false
                    self.resultMessage = "❌ Reset failed: \(error.localizedDescription)"
                }
            }
        }
    }


}

#Preview {
    NavigationStack {
        RootfsManagementView()
    }
}
