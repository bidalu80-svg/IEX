#if ZE_CONNECTION_EXPERIMENT
import SwiftUI
import UserNotifications
import ConnectionExperimentCore

@MainActor private final class ConnectionExperimentModel: ObservableObject {
    @Published var pin: String?
    @Published var routeConfirmed = false
    @Published var mode = ProbeMode.firstPairing
    @Published var exportText = ""
    @Published var message: String?
    let coordinator: ConnectionProbeCoordinator
    private let notifications = UNUserNotificationCenter.current()
    private var notificationID = "Ze.ConnectionExperiment.PIN.initial"
    private var notificationGeneration = UUID()
    init() {
        let backend = NativePairingBackend()
        let recorder = ConnectionEvidenceRecorder()
        coordinator = ConnectionProbeCoordinator(enabled: true, backend: backend, tunnel: backend,
            host: BonjourPairingHost(), store: KeychainPairingIdentityStore(),
            lifetime: ConnectionExperimentLifetime(heartbeat: { recorder.recordLifecycle(.heartbeat) }), recorder: recorder)
        coordinator.changed = { [weak self] in self?.objectWillChange.send() }
        coordinator.showPIN = { [weak self] value in self?.updatePIN(value) }
    }
    var running: Bool { coordinator.state == .running }
    var status: String {
        switch coordinator.state {
        case .idle: return "尚未开始；进入此页不会启动网络或读取配对身份"
        case .running: return "连接验证进行中；发布或端口可达不代表管理连接通过"
        case .queryPassed: return "本机管理连接与只读查询通过"
        case .stopped(let reason):
            switch reason {
            case .audioConflict: return "实验已停止：音频占用不明确或存在冲突。请停止录音、播放、悬浮窗口；必要时重开 Ze。"
            case .identityCreationRequired: return "无记录，需要建立新身份。无法判断这是首次使用，还是重签导致原身份不可见；确认前不会生成、保存或广播新身份。"
            case .identityUnavailable: return "原配对身份不可读取，需要重新配对；不会自动替换身份"
            case .storageFailed: return "实验已停止：配对身份未能安全保存，不能确认可复用"
            case .connectionRefused: return "已完成端口探测，连接均被拒绝；请检查 LocalDevVPN 路由与设备服务状态。"
            case .connectionTimeout: return "端口发现或协议响应超时；不能确认尚未完成探测的端口是否存在服务。"
            case .wrongService: return "至少一个端口有响应，但未通过预期 RPPairing 协议识别。"
            case .identityRejected: return "设备未接受已保存身份；记录保留，不会自动重新配对。"
            case .routeBlocked: return "配对证据已保留；管理连接受 VPN 路由前置条件阻塞"
            default: return "实验已停止：\(reason.rawValue)"
            }
        }
    }
    func start() {
        message = nil
        _ = coordinator.start(mode: mode, routeConfirmed: routeConfirmed)
        requestNotificationsIfRunning()
    }
    func confirmNewIdentity(runID: UUID) {
        guard coordinator.confirmNewIdentity(runID: runID) else { return }
        requestNotificationsIfRunning()
    }
    private func requestNotificationsIfRunning() {
        guard running else { return }
        // Notification authorization is requested only after explicit Start.
        let unavailable = coordinator.lifecycleCallback(.notificationUnavailable)
        notifications.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard !granted else { return }
            Task { @MainActor in unavailable() }
        }
    }
    private func updatePIN(_ value: String?) {
        pin = value; notificationGeneration = UUID()
        coordinator.recorder.recordLifecycle(value == nil ? .pinCleared : .pinAvailable)
        notifications.removePendingNotificationRequests(withIdentifiers: [notificationID])
        notifications.removeDeliveredNotifications(withIdentifiers: [notificationID])
        guard let value else { return }
        notificationID = "Ze.ConnectionExperiment.PIN." + notificationGeneration.uuidString
        let requestID = notificationID
        let content = UNMutableNotificationContent(); content.title = "Ze 配对 PIN"
        content.body = value; content.sound = .default
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        let generation = notificationGeneration
        notifications.add(request) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.notificationGeneration != generation else { return }
                self.notifications.removePendingNotificationRequests(withIdentifiers: [requestID])
                self.notifications.removeDeliveredNotifications(withIdentifiers: [requestID])
            }
        }
    }
    func deleteIdentity() {
        guard !running else { return }
        do { try KeychainPairingIdentityStore().delete(); message = "已本地删除实验身份；这不等于系统端已撤销信任。" }
        catch { message = "身份删除失败，原记录保留。" }
    }
    func export() {
        if let data = try? coordinator.recorder.export() { exportText = String(decoding: data, as: UTF8.self) }
    }
}

struct ConnectionExperimentView: View {
    @StateObject private var model = ConnectionExperimentModel()
    @State private var deleteConfirmation = false
    @State private var identityCreationRunID: UUID?
    @State private var identityCreationConfirmation = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            Section("实验条件") {
                Text("仅验证系统发现、配对、管理通道和只读查询。签名与安装尚未验证。首轮请使用 Wi-Fi 并开启开发者模式。")
                Link("获取 LocalDevVPN", destination: URL(string: "https://apps.apple.com/app/id6755608044")!)
                Toggle("我已确认 LocalDevVPN 显示已连接", isOn: $model.routeConfirmed).disabled(model.running)
                Picker("本次试验", selection: $model.mode) {
                    Text("首次配对／继续已有记录").tag(ProbeMode.firstPairing)
                    Text("重开 Ze 后复用配对并查询").tag(ProbeMode.appReopen)
                    Text("设备重启后复用配对并查询").tag(ProbeMode.deviceRestart)
                }.disabled(model.running)
            }
            Section("连接实验") {
                Text(model.status)
                if let reused = model.coordinator.isReusingIdentity { Text(reused ? "本次：复用已保存身份" : "本次：首次认证配对") }
                if let result = model.coordinator.readOnlyResult {
                    Text("设备服务返回：iOS \(result.productVersion) · \(result.buildVersion)")
                    Text("请与系统设置核对并保留截图；宿主首次配对与两种恢复仍需各自的真机证据。")
                }
                if let pin = model.pin { Text("PIN：\(pin)").font(.title.monospacedDigit()).privacySensitive() }
                Button("开始连接验证") { model.start() }.disabled(model.running)
                if model.coordinator.state == .stopped(.identityCreationRequired) {
                    Button("确认建立新身份…") {
                        identityCreationRunID = model.coordinator.recorder.runID
                        identityCreationConfirmation = true
                    }
                }
                Button("取消") { model.coordinator.cancel() }.disabled(!model.running)
                Text("开始后前往设置 → 隐私与安全性 → 开发者模式，查找本次 Pair with Ze… 对象。PIN 通知不可用时切回此页查看。窗口最长 120 秒。请先停止录音、播放及悬浮窗口；音频占用无法安全确认时实验会停止。")
                let discoveryRunID = model.coordinator.recorder.runID
                Button("我已在系统设置看到本次对象") {
                    model.coordinator.confirmSettingsDiscovery(runID: discoveryRunID)
                }.disabled(model.coordinator.recorder.results[.publication] != .pass)
                Text("可在返回 Ze 后为当前显示的这一轮补录；开始下一轮后，旧轮确认将被拒绝。")
                Text("系统列出对象必须人工确认，不能由 Bonjour 发布回调代替。")
            }
            Section("分层证据") {
                ForEach(ProbeStep.allCases, id: \.rawValue) { step in
                    HStack { Text(step.rawValue); Spacer(); Text(model.coordinator.recorder.results[step]?.rawValue ?? "NOT TESTED") }
                }
            }
            Section {
                Button("导出脱敏报告") { model.export() }
                if !model.exportText.isEmpty { ShareLink(item: model.exportText) { Text("分享脱敏报告") } }
                Button("删除本地实验身份", role: .destructive) { deleteConfirmation = true }.disabled(model.running)
                if let message = model.message { Text(message) }
                Text("本地删除不等于系统撤销信任；认证被拒时不会自动删除身份。重开 App 与设备重启是两次独立验证。")
            }
        }
        .navigationTitle("连接实验")
        .confirmationDialog("删除本地实验身份？系统端的信任需要另行管理。", isPresented: $deleteConfirmation) {
            Button("本地删除", role: .destructive) { model.deleteIdentity() }
        }
        .confirmationDialog("无记录，需要建立新身份。首次使用与重签后原身份不可见无法区分。是否建立新身份？", isPresented: $identityCreationConfirmation) {
            Button("建立新身份并开始") {
                guard let runID = identityCreationRunID else { return }
                model.confirmNewIdentity(runID: runID)
            }
        }
        .onChange(of: scenePhase) { phase in
            guard model.running else { return }
            model.coordinator.recorder.recordLifecycle(phase == .background ? .background : .foreground)
        }
        .onDisappear { model.coordinator.cancel() }
    }
}
#endif
