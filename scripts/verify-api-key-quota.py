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

check("apiKeyQuotaSection(instance)" in view, "额度分组接在图像端点设置之后")
check('Text("额度")' in view, "额度分组使用中文标题")
check('Image(systemName: "arrow.clockwise")' in view, "额度分组提供手动刷新按钮")
check("ProviderAPIQuotaStore.shared" in view, "详情页连接额度状态仓库")
check('Text("API Key 可用额度")' in view, "显示 API Key 可用额度")
check('Text("来源：服务商自报' in view and '更新时间：' in view, "显示来源与更新时间")
check('ProviderKeychainHelper.loadAPIKey(instanceId: instance.id)' in quota, "额度查询从 Keychain 读取 API Key")
check("/v1/usage" not in quota and 'Candidate(path: "usage", includesV1: true)' in quota, "包含 /v1/usage 探测")
for field in ("balance", "remaining", "total_available", "total_used"):
    check(field in quota, f"识别额度字段 {field}")
check("Bearer \\(apiKey)" in quota and "print(" not in quota, "密钥仅用于请求且未写入日志")
check("E5DQ0001 /* ProviderAPIQuota.swift in Sources */" in project, "额度文件加入 Xcode Sources")
check("E5DQ0011 /* ProviderAPIQuota.swift */" in project, "额度文件加入 Providers 分组")
check("xcrun swiftc -frontend -parse Providers/ProviderAPIQuota.swift" in workflow, "CI 对额度文件执行 Swift 语法解析")
print("API key quota structure checks passed")
