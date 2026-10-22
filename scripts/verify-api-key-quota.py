from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8")

def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    print(f"PASS: {message}")

view = read("Views/Providers/ProviderInstanceDetailView.swift")
quota = read("Providers/ProviderAPIQuota.swift")
project = read("Ze.xcodeproj/project.pbxproj")
workflow = read(".github/workflows/build.yml")

check("if instance.credentialType == .apiKey {\n                apiKeyQuotaSection(instance)" in view, "额度分组对所有 API Key 服务商显示")
check("supportsImageEndpointSetting {\n                imageEndpointSection(instance)\n            }" in view, "额度分组不再嵌在图像端点设置里")
check('Text("额度")' in view, "额度分组使用中文标题")
check('Image(systemName: "arrow.clockwise")' in view, "额度分组提供手动刷新按钮")
check("ProviderAPIQuotaStore.shared" in view, "详情页连接额度状态仓库")
check('Text("API Key 可用额度")' in view, "显示 API Key 可用额度")
check('Text("来源：服务商自报' in view and '更新时间：' in view, "显示来源与更新时间")
check('ProviderKeychainHelper.loadAPIKey(instanceId: instance.id)' in quota, "额度查询从 Keychain 读取 API Key")
check('Candidate(path: "usage", includesV1: true)' in quota and "func endpointURL" in quota, "包含 /v1/usage 与 /usage 两种探测")
# Relays in the wild answer exactly one of these; probing only the OpenAI
# shape left every other gateway showing no balance at all.
for path in ("/status", "/user/balance", "/api/user/self", "/api/v1/user/self"):
    check(f'Candidate(path: "{path}"' in quota, f"包含 {path} 探测")
check('Candidate(path: "credits", includesV1: true)' in quota, "包含 /v1/credits 与 /credits 两种探测")
# Ordering is the regression that mattered: gateway probes used to run first,
# so every working provider paid up to five extra timeouts before reaching the
# route that answered.
compatible_at = quota.find("let compatible: [Candidate]")
gateway_at = quota.find("let gateways: [Candidate]")
check(0 <= compatible_at < gateway_at, "OpenAI 兼容探测排在网关探测之前")
check("parseWorkbuddyPool" in quota and '"accounts"' in quota, "识别账号池 credits")
check("parseDeepSeek" in quota and '"balance_infos"' in quota, "识别 DeepSeek 余额")
check("parseNewAPI" in quota and "500_000" in quota, "识别 New API 额度单位")
check("probeBilling" in quota and "/dashboard/billing/usage" in quota, "账单接口同时读取用量")
check('case .anthropic, .gemini, .antigravity, .githubCopilot, .unsupported: return nil' in quota, "没有额度接口的内置服务商直接返回不支持")
for field in ("balance", "remaining", "total_available", "total_used"):
    check(field in quota, f"识别额度字段 {field}")
check("Bearer \\(apiKey)" in quota and "print(" not in quota, "密钥仅用于请求且未写入日志")
check("E5DQ0001 /* ProviderAPIQuota.swift in Sources */" in project, "额度文件加入 Xcode Sources")
check("E5DQ0011 /* ProviderAPIQuota.swift */" in project, "额度文件加入 Providers 分组")
providers_group = project[project.find("E52000030 /* Providers */ = {"):project.find("A1C0A0000000000000000005 /* GitHubCopilot */ = {")]
check("E5DQ0011 /* ProviderAPIQuota.swift */" in providers_group, "额度文件挂到 Providers 源码目录而非 Views/Providers")
check("xcrun swiftc -frontend -parse Providers/ProviderAPIQuota.swift" in workflow, "CI 对额度文件执行 Swift 语法解析")
print("API key quota structure checks passed")
