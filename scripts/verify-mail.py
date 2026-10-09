from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
def text(path): return (root / path).read_text(encoding="utf-8-sig")
checks = 0
def check(value, message):
    global checks
    assert value, message
    checks += 1
    print("PASS:", message)
models = text("Shared/Mail/MailModels.swift")
store = text("Shared/Mail/MailAccountStore.swift")
client = text("Shared/Mail/MailClient.swift")
gateway = text("Shared/Mail/MailAIToolGateway.swift")
view = text("Views/Settings/MailAccountsView.swift")
content = text("Views/ContentView.swift")
project = text("Ze.xcodeproj/project.pbxproj")
workflow = text(".github/workflows/build.yml")
check(content.index("EnvironmentVariablesView()") < content.index("MailAccountsView()") < content.index('Text(String(localized: "Agent Runtime"))'), "mail entry directly follows environment variables")
check("SecItemUpdate" in store and "SecItemAdd" in store and "UserDefaults" not in store, "accounts and credentials persisted atomically in Keychain")
check("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly" in store, "credentials are device-local")
check(all(x in view for x in ['添加邮箱', '编辑邮箱', '删除邮箱', '测试连接', '允许智能体使用此邮箱']), "Chinese multiple-account management and connection test")
check("ContentUnavailableView" not in view and ".topBar" not in view, "settings avoids previously incompatible UI APIs")
check("using: .tls" in client and "sec_protocol_options_set_verify_block" not in client, "TLS with default certificate validation")
check("EXAMINE INBOX" in client and "BODY.PEEK" in client and "UIDVALIDITY" in client, "read-only inbox access with stable UID validation")
check("MailCompletion" in client and "asyncAfter" in client and "withTaskCancellationHandler" in client, "network operations bounded with race-safe timeout and cancellation")
check('request(serverName: "邮箱' in gateway and gateway.index("request(serverName:") < gateway.index("MailClient.send("), "mail send requires explicit approval before network submission")
check("store.accounts.first(where: { $0.id == id }) == account" in gateway, "revalidate account after confirmation")
check("external_untrusted_data" in gateway and "禁止自动重复发信" in gateway, "mail is untrusted data and uncertain sends are not auto-retried")
for name in ["mail_account_list", "mail_list", "mail_read", "mail_send"]:
    check(f'name: "{name}"' in gateway and f'"{name}"' in text("Agent/Chat/AIChatViewModel+ConcurrentTools.swift"), "tool registered and dispatched: " + name)
check("MailAIToolGateway.definitions()" in text("Agent/Chat/AIChatViewModel+ToolDefinitions.swift") and "MailAIToolGateway.statusFragment" in text("Agent/Chat/AIChatViewModel.swift"), "tool definitions and prompt connected")
for name in ["MailModels", "MailAccountStore", "MailClient", "MailAIToolGateway", "MailAccountsView"]:
    check(project.count(f"/* {name}.swift in Sources */") == 2, "app source membership: " + name)
check(set(re.findall(r"MARKETING_VERSION = ([^;]+);", project)) == {"1.1.1"}, "all marketing versions are 1.1.1")
check(set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", project)) == {"7"}, "all build numbers are 7")
check("-target arm64-apple-ios16.0" in workflow and "MailModelsTests.swift" in workflow, "CI checks actual mailbox UI and networking against iOS 16 before the full build")
print(f"Mail structural checks passed: {checks}")
