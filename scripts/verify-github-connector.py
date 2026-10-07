from pathlib import Path
import json, plistlib, re
root=Path(__file__).resolve().parents[1]
checks=0
def check(cond,msg):
 global checks
 if not cond: raise AssertionError(msg)
 checks+=1; print('PASS:',msg)
def text(path): return (root/path).read_text(encoding='utf-8-sig')
project=text(Path('Ze.xcodeproj/project.pbxproj'))
content=text(Path('Views/ContentView.swift'))
gateway=text(Path('Shared/GitHub/GitHubAIToolGateway.swift'))
store=text(Path('Shared/GitHub/GitHubAccountStore.swift'))
ui=text(Path('Views/Connectors/GitHubConnectorView.swift'))
defs=text(Path('Agent/Chat/AIChatViewModel+ToolDefinitions.swift'))
dispatch=text(Path('Agent/Chat/AIChatViewModel+ConcurrentTools.swift'))
chat=text(Path('Agent/Chat/AIChatViewModel.swift'))
check('GitHubConnectorView()' in content and 'GitHubMark(size: 21)' in content,'设置页包含 GitHub 连接器和图标入口')
check('GitHubAccountLoginSheet' in ui and 'GitHubTokenLoginSheet' in ui,'GitHub 支持设备登录和访问令牌登录')
check('store.delete(account)' in ui and 'ForEach(store.accounts)' in ui,'账号列表支持多个账号和删除')
check('SecItemAdd' in store and 'com.ze.app.github-accounts' in store and 'accounts.json' in store,'Token 使用本地 Keychain、账号元数据单独保存')
check('github_account_list' in gateway and 'github_repository_list' in gateway and 'github_file_read' in gateway and 'github_file_write' in gateway and 'github_file_delete' in gateway,'GitHub 工具定义齐全')
check('GitHubAIToolGateway.definitions()' in defs and 'GitHubAIToolGateway.execute' in dispatch,'工具已注册并接入 dispatcher')
check('RemoteServerAIConfirmationGate.shared.request' in gateway,'写入和删除操作使用现有确认门')
check('Bearer \\(token)' in store and '\"token\"' not in gateway[gateway.find('static func accountList'):gateway.find('private static func authorizedAccount')], '工具输出路径不包含令牌字段')
check('GitHubAIToolGateway.statusFragment' in chat and 'githubStatusFragment' in chat,'系统提示注入 GitHub 状态')
check('GitHubOAuthClientID' in text(Path('Info.plist')) and 'GITHUB_OAUTH_CLIENT_ID' in text(Path('Configs/ProviderCustomization.xcconfig.example')),'OAuth Client ID 配置存在')
for path in ['Shared/GitHub/GitHubModels.swift','Shared/GitHub/GitHubAccountStore.swift','Shared/GitHub/GitHubAIToolGateway.swift','Views/Connectors/GitHubConnectorView.swift']:
 check((f'path = {path};' in project or f'path = \"{path}\";' in project), f'Xcode source path: {path}')
print(f'Structural checks passed: {checks}')
