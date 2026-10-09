import SwiftUI
import UIKit
import Foundation

// Network/configuration fixtures only. The production parser, cache and header
// are compiled unchanged; no real provider credentials or endpoints are used.
enum ProviderType { case openAI, openAIResponses, openRouter, xAI, kimiCode, unknown }
enum ProviderCredential { case apiKey, oauth }
struct ProviderInstance {
    var id: String
    var providerType: ProviderType = .openAI
    var credentialType: ProviderCredential = .apiKey
    var customBaseURL: String? = "https://quota-fixture.invalid"
    var appendV1Suffix = true
    var azureMode = false
    var customUserAgent: String?
}
enum ProviderKeychainHelper {
    static var keys: [String: String] = [:]
    static func loadAPIKey(instanceId: String) -> String? { keys[instanceId] }
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
            try JSONSerialization.data(withJSONObject:["success":true,"checks":checks],options:[.prettyPrinted,.sortedKeys]).write(to:docs.appendingPathComponent("model-picker-result.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject:["success":false,"checks":checks,"error":error.localizedDescription],options:[.prettyPrinted]).write(to:docs.appendingPathComponent("model-picker-result.json"))
        }
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
