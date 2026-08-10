import SwiftUI

/// A native SSH command console. Commands are sent through the already
/// verified Citadel connection, never by shelling out to the local Rootfs.
struct RemoteCommandConsoleView: View {
    let serverID: UUID
    let serverName: String
    var initialCommand: String = ""

    @ObservedObject private var connection = RemoteSSHConnectionService.shared
    @State private var command: String
    @State private var transcript: [RemoteConsoleEntry] = []
    @State private var isRunning = false
    @State private var errorMessage: String?

    init(serverID: UUID, serverName: String, initialCommand: String = "") {
        self.serverID = serverID
        self.serverName = serverName
        self.initialCommand = initialCommand
        _command = State(initialValue: initialCommand)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if transcript.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                                Text("已连接到 \(serverName)")
                                    .font(.headline)
                                Text("命令经已验证的原生 SSH 连接执行。输出最多保留 1 MB。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 56)
                        }
                        ForEach(transcript) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("$ \(entry.command)")
                                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.primary)
                                if !entry.output.isEmpty {
                                    Text(entry.output)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(entry.failed ? .red : .secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: transcript.count) { _ in
                    if let last = transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入 SSH 命令", text: $command, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button(action: execute) {
                    if isRunning {
                        ProgressView()
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .disabled(isRunning || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("执行命令")
            }
            .padding()
        }
        .navigationTitle("SSH 终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") { transcript.removeAll() }
                    .disabled(transcript.isEmpty)
            }
        }
        .alert("命令未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func execute() {
        let submitted = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        command = ""
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                let output = try await connection.executeCommand(submitted, on: serverID)
                transcript.append(RemoteConsoleEntry(command: submitted, output: output, failed: false))
            } catch {
                let detail = error.localizedDescription
                transcript.append(RemoteConsoleEntry(command: submitted, output: detail, failed: true))
                errorMessage = detail
            }
        }
    }
}

private struct RemoteConsoleEntry: Identifiable {
    let id = UUID()
    let command: String
    let output: String
    let failed: Bool
}
