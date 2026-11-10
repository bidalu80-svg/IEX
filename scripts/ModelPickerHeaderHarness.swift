import SwiftUI
import UIKit
import Foundation

// Network/configuration fixtures only. The production parser, cache and header
// are compiled unchanged; no real provider credentials or endpoints are used.
// Keep this enum in step with the production `ProviderType`: the quota client
// switches over every case, so a missing one fails the type-check here long
// before the app build runs.
enum ProviderType {
    case openAI, openAIResponses, openRouter, xAI, kimiCode
    case anthropic, gemini, antigravity, githubCopilot, workBuddy, unsupported
}
enum ProviderCredential { case apiKey, oauth }
struct ProviderInstance {
    var id: String
    var providerType: ProviderType = .openAI
    var credentialType: ProviderCredential = .apiKey
    var customBaseURL: String? = "https://quota-fixture.invalid"
    var appendV1Suffix = true
    var azureMode = false
    var customUserAgent: String?
    var label: String { "WorkBuddy" }
}
@MainActor enum ProviderKeychainHelper {
    static var keys: [String: String] = [:]
    static var tokens: [String: Data] = [:]
    static func loadAPIKey(instanceId: String) -> String? { keys[instanceId] }
    static func loadOAuthToken<T: Codable>(instanceId: String, as type: T.Type) -> T? {
        tokens[instanceId].flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    static func saveOAuthToken<T: Codable>(_ token: T, instanceId: String) {
        tokens[instanceId] = try? JSONEncoder().encode(token)
    }
    static func deleteOAuthToken(instanceId: String) { tokens[instanceId] = nil }
}
// Catalog storage is unrelated to quota; OAuth and billing are production sources.
@MainActor enum WorkBuddyModelsAPI { static func invalidate(instanceId: String) {} }
final class WorkBuddyQuotaFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var payload = "{}"
    private static var delay: Double = 0
    private static var requests = 0
    static func set(_ payload: String, delay: Double = 0) {
        lock.lock(); defer { lock.unlock() }
        self.payload = payload; self.delay = delay; requests = 0
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url, ["www.codebuddy.cn", "www.workbuddy.ai"].contains(url.host ?? ""),
              url.path.hasSuffix("/billing/meter/get-user-resource"), request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer fixture-") == true,
              request.value(forHTTPHeaderField: "X-Refresh-Token") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        Self.lock.lock()
        let payload = Self.payload; let delay = Self.delay; Self.requests += 1
        Self.lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
final class QuotaFixtureProtocol: URLProtocol {
    static var payload = "{}"
    static var count = 0
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "quota-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct ModelPickerHeaderHarness: App {
    var body: some Scene { WindowGroup { Text("模型选择页余额与编辑入口回归").task { await runChecks() } } }
    @MainActor private func runChecks() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var checks: [String] = []
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "HeaderHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks.append(label)
        }
        func parse(_ json: String) throws -> ProviderAPIQuota? {
            ProviderAPIQuotaClient.parse(object: try JSONSerialization.jsonObject(with: Data(json.utf8)), sourcePath: "/fixture")
        }
        do {
            let debt = try parse(#"{"balance":-0.05,"currency":"USD"}"#)!
            try check(debt.displayAmount == Decimal(string:"-0.05"), "Negative balance remains negative")
            try check(ModelPickerProviderHeader.amountText(debt.displayAmount!, currency:"USD") == "-US$0.05", "Debt badge matches reference formatting")
            let inferred = try parse(#"{"data":{"total_credits":1,"total_usage":1.05}}"#)
            try check(inferred?.displayAmount == Decimal(string:"-0.05"), "Total minus usage does not clamp debt to zero")
            let priority = try parse(#"{"total_available":2,"balance":8}"#)
            try check(priority?.displayAmount == 2, "Explicit remaining amount has deterministic priority")
            let zero = try parse(#"{"balance":0}"#)
            try check(zero?.displayAmount == 0, "Real zero balance is visible rather than treated as missing")
            for json in [#"{"balance":true}"#, #"{"balance":"NaN"}"#, #"{"balance":"1oops"}"#, #"{"error":{"balance":99}}"#, #"{"success":false,"balance":99}"#, #"{"a":{"total":9},"b":{"used":1}}"#, #"{"total":100}"#, #"{"usage":2}"#, "{}"] {
                try check(try parse(json) == nil, "Unrecognized/error/non-monetary payload hidden: " + json)
            }
            URLProtocol.registerClass(QuotaFixtureProtocol.self)
            let instance = ProviderInstance(id:"fixture-provider")
            ProviderKeychainHelper.keys[instance.id] = "fixture-not-a-real-secret"
            QuotaFixtureProtocol.payload = #"{"balance":-0.05,"currency":"USD"}"#
            await ProviderAPIQuotaStore.shared.refreshIfNeeded(instance)
            guard case .loaded(let loaded) = ProviderAPIQuotaStore.shared.state(for: instance.id) else { throw NSError(domain:"HeaderHarness",code:2) }
            try check(loaded.displayAmount == debt.displayAmount, "Provider response reaches shared observable cache")
            let requests = QuotaFixtureProtocol.count
            await ProviderAPIQuotaStore.shared.refreshIfNeeded(instance)
            try check(QuotaFixtureProtocol.count == requests, "Repeated header appearances reuse fresh cached balance")
            ProviderKeychainHelper.keys[instance.id] = "fixture-key-rotated"
            QuotaFixtureProtocol.payload = #"{"balance":3.75}"#
            await ProviderAPIQuotaStore.shared.refreshIfNeeded(instance)
            guard case .loaded(let rotated) = ProviderAPIQuotaStore.shared.state(for: instance.id) else { throw NSError(domain:"HeaderHarness",code:3) }
            try check(rotated.displayAmount == Decimal(string:"3.75") && QuotaFixtureProtocol.count > requests, "Credential edits invalidate cache")
            QuotaFixtureProtocol.payload = "{}"
            await ProviderAPIQuotaStore.shared.refresh(instance)
            if case .unavailable = ProviderAPIQuotaStore.shared.state(for: instance.id) { checks.append("Failed refresh removes the prior balance") }
            else { throw NSError(domain:"HeaderHarness",code:4) }
            let failedCount = QuotaFixtureProtocol.count
            await ProviderAPIQuotaStore.shared.refreshIfNeeded(instance)
            try check(QuotaFixtureProtocol.count == failedCount, "Unavailable quota is not re-probed on every redraw")
            URLProtocol.unregisterClass(QuotaFixtureProtocol.self)

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WorkBuddyQuotaFixtureProtocol.self]
            let session = WorkBuddyHTTP.makeSession(configuration: configuration)
            let workBuddyStore = ProviderAPIQuotaStore(workBuddyLoader: { id in
                try await WorkBuddyBalanceAPI.fetch(instanceId: id, session: session)
            })
            let paidPayload = #"{"code":0,"data":{"Response":{"Data":{"Accounts":[{"CapacitySize":100,"CapacityRemain":83,"CapacityUsed":17}]}}}}"#
            let zeroPayload = #"{"code":0,"data":{"Response":{"Data":{"Accounts":[]}}}}"#
            func login(_ id: String, uid: String = "fixture-user") {
                let token = WorkBuddyTokenStorage(accessToken: "fixture-" + uid, refreshToken: "fixture-refresh",
                    expiresAt: Date().addingTimeInterval(3600), realm: .cn, uid: uid,
                    enterpriseID: nil, domain: nil, nickname: nil, deviceToken: nil)
                ProviderKeychainHelper.saveOAuthToken(token, instanceId: id)
            }
            var workBuddyScreenshots: [String] = []
            for state in ["loaded", "error", "zero"] {
                let instance = ProviderInstance(id: "workbuddy-" + state, providerType: .workBuddy, credentialType: .oauth)
                login(instance.id)
                WorkBuddyQuotaFixtureProtocol.set(state == "loaded" ? paidPayload : (state == "zero" ? zeroPayload : #"{"code":401,"msg":"private-account-data","data":{}}"#))
                await workBuddyStore.refresh(instance)
                let quota: ProviderAPIQuota?
                if case .loaded(let value) = workBuddyStore.state(for: instance.id) {
                    quota = value
                    try check(value.remaining == (state == "zero" ? 0 : 83), "OAuth account balance reaches real observable store: " + state)
                } else {
                    quota = nil
                    guard state == "error", case .unavailable(let message) = workBuddyStore.state(for: instance.id) else { throw NSError(domain:"HeaderHarness",code:10) }
                    try check(!message.contains("private-account-data"), "OAuth error state hides stale amount and sensitive server content")
                }
                for scheme in [ColorScheme.light, .dark] {
                    let mode = scheme == .light ? "light" : "dark"
                    let picker = ProductionPickerQuota(instance: instance, quotaStore: workBuddyStore)
                        .environment(\.colorScheme,scheme).environment(\.locale,Locale(identifier:"zh-Hans"))
                    let detail = NavigationStack {
                        ProductionDetailQuota(instance: instance, quotaStore: workBuddyStore)
                            .navigationTitle("WorkBuddy")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement:.navigationBarLeading) { Button {} label: { Label("AI 服务商",systemImage:"chevron.left") } }
                                ToolbarItem(placement:.navigationBarTrailing) { Image(systemName:"square.and.arrow.up") }
                            }
                    }.environment(\.colorScheme,scheme).environment(\.locale,Locale(identifier:"zh-Hans"))
                    for surface in ["picker", "detail"] {
                        let name = "workbuddy-" + surface + "-" + state + "-" + mode + ".png"
                        if surface == "picker" {
                            try await renderHosted(picker, scheme: scheme, destination: docs.appendingPathComponent(name))
                        } else {
                            try await renderHosted(detail, scheme: scheme, destination: docs.appendingPathComponent(name))
                        }
                        workBuddyScreenshots.append(name)
                        checks.append("Separate production " + surface + " section renders nonempty: " + name)
                    }
                }
            }
            for mode in ["light", "dark"] {
                for surface in ["picker", "detail"] {
                    let prefix = "workbuddy-" + surface + "-"
                    let loadedPixels = try Data(contentsOf: docs.appendingPathComponent(prefix + "loaded-" + mode + ".png"))
                    let zeroPixels = try Data(contentsOf: docs.appendingPathComponent(prefix + "zero-" + mode + ".png"))
                    let errorPixels = try Data(contentsOf: docs.appendingPathComponent(prefix + "error-" + mode + ".png"))
                    try check(loadedPixels != zeroPixels && zeroPixels != errorPixels && loadedPixels != errorPixels,
                        "Loaded, zero and error produce distinct separate views: " + surface + " " + mode)
                }
            }
            let switched = ProviderInstance(id:"workbuddy-switch",providerType:.workBuddy,credentialType:.oauth)
            login(switched.id)
            WorkBuddyQuotaFixtureProtocol.set(paidPayload)
            await workBuddyStore.refreshIfNeeded(switched)
            let beforeRotation = workBuddyStore.refreshIdentity(switched)
            var rotatedToken = ProviderKeychainHelper.loadOAuthToken(instanceId: switched.id, as: WorkBuddyTokenStorage.self)!
            rotatedToken.accessToken = "fixture-rotated-access"
            rotatedToken.refreshToken = "fixture-rotated-refresh"
            rotatedToken.expiresAt = Date().addingTimeInterval(7200)
            ProviderKeychainHelper.saveOAuthToken(rotatedToken, instanceId: switched.id)
            try check(workBuddyStore.refreshIdentity(switched) == beforeRotation, "OAuth token rotation keeps SwiftUI quota task identity stable")
            let priorCount = WorkBuddyQuotaFixtureProtocol.count
            await workBuddyStore.refreshIfNeeded(switched)
            try check(WorkBuddyQuotaFixtureProtocol.count == priorCount, "OAuth same-account quota uses freshness cache")
            WorkBuddyQuotaFixtureProtocol.set(zeroPayload)
            WorkBuddyOAuthManager.shared.logout(instanceId:switched.id)
            login(switched.id,uid:"fixture-other-user")
            try check(workBuddyStore.refreshIdentity(switched) != beforeRotation, "Account switch changes SwiftUI quota task identity")
            await workBuddyStore.refreshIfNeeded(switched)
            guard case .loaded(let switchedQuota) = workBuddyStore.state(for:switched.id) else { throw NSError(domain:"HeaderHarness",code:11) }
            try check(switchedQuota.remaining == 0 && WorkBuddyQuotaFixtureProtocol.count == 1, "Account switch invalidates cache and shows new account zero")
            WorkBuddyQuotaFixtureProtocol.set(paidPayload,delay:0.3)
            let late = Task { @MainActor in await workBuddyStore.refresh(switched) }
            for _ in 0..<100 {
                if WorkBuddyQuotaFixtureProtocol.count > 0 { break }
                try await Task.sleep(nanoseconds:5_000_000)
            }
            try check(WorkBuddyQuotaFixtureProtocol.count == 1, "Cancellation fixture started actual billing request")
            late.cancel()
            await late.value
            try check(workBuddyStore.state(for:switched.id) == .idle, "Cancelled OAuth query returns store to idle")
            WorkBuddyQuotaFixtureProtocol.set(paidPayload,delay:0.3)
            let logoutFlight = Task { @MainActor in await workBuddyStore.refresh(switched) }
            for _ in 0..<100 {
                if WorkBuddyQuotaFixtureProtocol.count > 0 { break }
                try await Task.sleep(nanoseconds:5_000_000)
            }
            WorkBuddyOAuthManager.shared.logout(instanceId:switched.id)
            await workBuddyStore.refresh(switched)
            await logoutFlight.value
            guard case .unavailable = workBuddyStore.state(for:switched.id) else { throw NSError(domain:"HeaderHarness",code:12) }
            checks.append("Logout and early validation retire old flight without overwriting signed-out state")

            let credit = ProviderAPIQuota(remaining: 12.34, total: nil, used: nil, currency:"USD",sourcePath:"/fixture",updatedAt:Date())
            for width in [320.0,390.0] {
                for scheme in [ColorScheme.light,.dark] {
                    let cardColor = Color(uiColor: .secondarySystemBackground)
                    let view = VStack(spacing:16) {
                        Text("选择模型").font(.headline)
                        HStack { Image(systemName:"magnifyingglass"); Text("搜索模型").foregroundStyle(.secondary); Spacer() }
                            .padding(14).overlay(RoundedRectangle(cornerRadius:22).stroke(Color.secondary.opacity(0.3)))
                        card(title:"万", id:"unknown", quota:nil, model:"Z AI GLM 5.3", count:63, background:cardColor)
                        card(title:"grok", id:"debt", quota:debt, model:"Composer 2.5",count:141,background:cardColor)
                        card(title:"有余额的服务商", id:"credit", quota:credit, model:"DeepSeek",count:7,background:cardColor)
                        ModelPickerProviderHeader(title:"很长的服务商名称示例 Long Provider",providerID:"long",quota:credit,canEdit:true,collapsed:true,onEdit:{},onToggle:{})
                            .padding(12).background(cardColor,in:RoundedRectangle(cornerRadius:20))
                    }
                    .padding(16).frame(width:width).background(Color(uiColor:.systemBackground))
                    .environment(\.colorScheme,scheme).environment(\.locale,Locale(identifier:"zh-Hans"))
                    let renderer=ImageRenderer(content:view);renderer.scale=2
                    guard let image=renderer.uiImage, let data=image.pngData() else { throw NSError(domain:"HeaderHarness",code:5) }
                    try data.write(to:docs.appendingPathComponent("model-picker-\(Int(width))-\(scheme == .light ? "light" : "dark").png"))
                    try check(abs(image.size.width-width)<0.5,"Header/card fits \(Int(width))pt \(scheme)")
                }
            }
            try JSONSerialization.data(withJSONObject:["success":true,"checks":checks,"workBuddyScreenshots":workBuddyScreenshots,"scope":"Separate picker and detail page fixtures; exact production sections, fixture navigation/model catalog; no live-account balance verification"],options:[.prettyPrinted,.sortedKeys]).write(to:docs.appendingPathComponent("model-picker-result.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject:["success":false,"checks":checks,"error":error.localizedDescription],options:[.prettyPrinted]).write(to:docs.appendingPathComponent("model-picker-result.json"))
        }
    }
    @MainActor private func renderHosted<V: View>(_ view: V, scheme: ColorScheme, destination: URL) async throws {
        let controller = UIHostingController(rootView:view)
        controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw NSError(domain:"HeaderHarness",code:14,userInfo:[NSLocalizedDescriptionKey:"No active scene for quota capture"])
        }
        let previousKeyWindow = scene.windows.first(where: { $0.isKeyWindow })
        let window = UIWindow(windowScene:scene)
        window.frame = CGRect(x:0,y:0,width:390,height:844)
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds:250_000_000)
        controller.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds:controller.view.bounds)
        var drewHierarchy = false
        let image = renderer.image { _ in drewHierarchy = controller.view.drawHierarchy(in:controller.view.bounds,afterScreenUpdates:true) }
        guard let data = image.pngData() else { throw NSError(domain:"HeaderHarness",code:13) }
        try data.write(to:destination)
        guard drewHierarchy else { throw NSError(domain:"HeaderHarness",code:17,userInfo:[NSLocalizedDescriptionKey:"Quota drawHierarchy returned false: " + destination.lastPathComponent]) }
        guard let cg = image.cgImage, let pixels = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(pixels) else { throw NSError(domain:"HeaderHarness",code:15) }
        var colors = Set<UInt32>()
        let pixelBytes = cg.bitsPerPixel / 8
        for y in stride(from:0,to:cg.height,by:4) {
            for x in stride(from:0,to:cg.width,by:4) {
                let i = y * cg.bytesPerRow + x * pixelBytes
                colors.insert(UInt32(bytes[i]) << 16 | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]))
            }
        }
        guard colors.count > 64 else { throw NSError(domain:"HeaderHarness",code:16,userInfo:[NSLocalizedDescriptionKey:"Quota capture is blank: " + destination.lastPathComponent]) }
    }
    private func card(title:String,id:String,quota:ProviderAPIQuota?,model:String,count:Int,background:Color) -> some View {
        VStack(alignment:.leading,spacing:10) {
            ModelPickerProviderHeader(title:title,providerID:id,quota:quota,canEdit:true,collapsed:true,onEdit:{},onToggle:{})
            Divider()
            HStack(spacing:10) { Image(systemName:"circle").foregroundStyle(.secondary);Circle().fill(.green).frame(width:7,height:7);Text(model).font(.headline);Spacer();Image(systemName:"bolt.fill").foregroundColor(.blue) }.padding(.vertical,5)
            Divider()
            Label("显示 \(count) 个模型",systemImage:"chevron.down").font(.subheadline.weight(.medium)).foregroundColor(.blue)
        }.padding(14).background(background,in:RoundedRectangle(cornerRadius:22))
    }
}
