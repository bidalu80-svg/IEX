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
check('GitHubConnectorView()' in content and 'GitHubMark(size: 13)' in content and '.background(Color(.systemGray5), in: Circle())' in content,'设置页包含 GitHub 连接器和圆形图标入口')
github_mark = ui[ui.find('struct GitHubMark'):]
check('Image("GitHubMark")' in github_mark and '.foregroundStyle(.primary)' in github_mark and 'RoundedRectangle(cornerRadius:' not in github_mark,'GitHub 图标使用官方矢量标识并适配明暗外观')
check('GitHubAccountLoginSheet' in ui and 'GitHubTokenLoginSheet' in ui,'GitHub 支持设备登录和访问令牌登录')
check('store.delete(account)' in ui and 'ForEach(store.accounts)' in ui,'账号列表支持多个账号和删除')
check('SecItemAdd' in store and 'com.ze.app.github-accounts' in store and 'accounts.json' in store,'Token 使用本地 Keychain、账号元数据单独保存')
check('github_account_list' in gateway and 'github_repository_list' in gateway and 'github_file_read' in gateway and 'github_file_write' in gateway and 'github_file_delete' in gateway,'GitHub 工具定义齐全')
check('GitHubAIToolGateway.definitions()' in defs and 'GitHubAIToolGateway.execute' in dispatch,'工具已注册并接入 dispatcher')
check('RemoteServerAIConfirmationGate.shared.request' in gateway,'写入和删除操作使用现有确认门')
check('Bearer \\(token)' in text(Path('Shared/GitHub/GitHubRepositoryClient.swift')) and '\"token\"' not in gateway[gateway.find('static func accountList'):gateway.find('private static func authorizedAccount')], '工具输出路径不包含令牌字段')
check('GitHubAIToolGateway.statusFragment' in chat and 'githubStatusFragment' in chat,'系统提示注入 GitHub 状态')
check('GitHubOAuthClientID' in text(Path('Info.plist')) and 'GITHUB_OAUTH_CLIENT_ID' in text(Path('Configs/ProviderCustomization.xcconfig.example')),'OAuth Client ID 配置存在')
for path in ['Shared/GitHub/GitHubModels.swift','Shared/GitHub/GitHubRepositoryClient.swift','Shared/GitHub/GitHubAccountStore.swift','Shared/GitHub/GitHubAIToolGateway.swift','Views/Connectors/GitHubConnectorView.swift']:
 check((f'path = {path};' in project or f'path = \"{path}\";' in project), f'Xcode source path: {path}')
client=text(Path('Shared/GitHub/GitHubRepositoryClient.swift'))
check('178c6fc778ccc68e1d6a' in store and 'GitHubCopilotOAuthManager' not in store and 'X-OAuth-Scopes' in store, 'Repository OAuth authorization is independent and records actual scopes')
check('repo read:org workflow read:user user:email' in store, 'Authorization requests repository, organization and workflow scopes')
check(all(name in gateway and name in dispatch for name in ['github_repository_info','github_commit_push','github_branch_create']), 'Repository info, atomic commit and branch tools are registered and dispatched')
check('owner,collaborator,organization_member' in client and 'next_page' in client, 'Repository pagination covers account affiliations')
check('"force": false' in client and 'expectedHead' in client, 'Atomic commits check expected branch head and use non-force push')
check('GitHub连接器' in ui and 'Text("GitHub连接器")' in content, 'Connector labels are consistent')
asset=root/'Assets.xcassets/GitHubMark.imageset'
check(json.loads((asset/'Contents.json').read_text())['images'][0]['filename']=='mark-github.svg' and '<path d=' in (asset/'mark-github.svg').read_text(), 'Official GitHub SVG asset exists and is referenced')
print(f'Structural checks passed: {checks}')
