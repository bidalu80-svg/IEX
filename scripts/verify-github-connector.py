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
models=text(Path('Shared/GitHub/GitHubModels.swift'))
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
check('"scope": GitHubScopePolicy.requestValue' in store and
      'static let requestValue = requestedScopes.joined(separator: " ")' in models and
      'static let requestedScopes = requiredScopes + pendingScopes' in models,
      'Device request uses the shared scope policy')
requirements=models[models.index('static let requirements:'):models.index('static let requestedScopes')]
scopes=re.findall(r'\("([a-z_:]+)",', requirements)
expected={'repo','workflow','delete_repo','admin:org','admin:org_hook','user','gist','notifications',
          'admin:public_key','admin:gpg_key','admin:ssh_signing_key','write:packages','delete:packages',
          'project','codespace','codespace:secrets','admin:enterprise','read:audit_log',
          'manage_billing:copilot','write:network_configurations'}
check(set(scopes)==expected and len(scopes)==len(expected), 'Shared policy declares the agreed finite scope target without duplicate children')
pending_requirements=models[models.index('static let pendingRequirements:'):models.index('static let requiredScopes')]
pending_scopes=re.findall(r'\("([a-z_:]+)",', pending_requirements)
expected_pending={'admin:enterprise','read:audit_log','manage_billing:copilot','write:network_configurations'}
base_requirements=models[models.index('static let requirements:'):models.index('static let pendingRequirements:')]
base_scopes=re.findall(r'\("([a-z_:]+)",', base_requirements)
check(set(pending_scopes)==expected_pending and len(pending_scopes)==4 and
      set(base_scopes)==expected-expected_pending and len(base_scopes)==16 and
      'static let requiredScopes = requirements.map(\\.scope)' in models and
      'static let pendingScopes = pendingRequirements.map(\\.scope)' in models,
      'Sixteen base scopes are mandatory; four pending scopes remain requested separately')
validation=models[models.index('static func validateLogin('):models.index('enum GitHubScopeState:')]
check('let requiredMissing = scopes.filter { requiredScopes.contains($0) }' in validation and
      'if !requiredMissing.isEmpty {' in validation and 'missingDescription(requiredMissing)' in validation,
      'Device login rejects missing mandatory scopes without blocking on pending scopes')
check('let missing = requestedScopes.filter { !effective.contains($0) }' in models and
      'pendingScopes.contains(scope) ? "，待核验专项"' in models,
      'Account state still reports every missing requested scope and labels pending capabilities')
check('GitHubScopePolicy.state(for: grantedScopes)' in models and
      'case satisfied' in models and 'case missing([String])' in models and 'case unknown' in models,
      'Account permission display derives from the shared three-state policy')
add=store[store.index('private func addAccount('):store.index('private func load()')]
check(add.index('GitHubScopePolicy.validateLogin(') < add.index('GitHubAccountPersistence.commit(') and
      'expectedLogin: expectedLogin' in add and 'grantedScopes: scopes, method: method' in add,
      'Identity and device grant validation run before persistence')
check('response.value(forHTTPHeaderField: "X-OAuth-Scopes").map(GitHubAPI.scopes) ?? grantedScopes' in add and
      'grantedScopes: scopes, loginMethod: method' in add,
      'Authoritative header, including empty, wins over token response; raw grants are persisted')
check('method: .deviceAuthorization, expectedLogin: expectedLogin' in store and
      'method: .manualToken, expectedLogin: expectedLogin' in store and
      'if method == .deviceAuthorization' in models and 'case .unknown:' in models,
      'Device login requires verified grants while manual tokens may be restricted')
check('Text(account.permissionSummary)' in ui and 'Button("补全账号权限")' in ui and
      'GitHubLoginRequest(expectedLogin: account.login)' in ui and
      '.sheet(item: $deviceLoginRequest)' in ui and
      'GitHubAccountLoginSheet(store: store, expectedLogin: request.expectedLogin)' in ui and
      'store.finishDeviceLogin(next, expectedLogin: expectedLogin)' in ui,
      'Account rows expose missing permissions and bind reauthorization to the target login')
login=ui[ui.index('private struct GitHubAccountLoginSheet:'):ui.index('private struct GitHubTokenLoginSheet:')]
check(login.index('try await store.finishDeviceLogin(') < login.index('finish()', login.index('try await store.finishDeviceLogin(')) and
      'errorMessage = error.localizedDescription' in login and
      '实际授权兼容性仍待验证' in login,
      'Device login errors remain visible and OAuth limitations are disclosed')
tests=text(Path('scripts/GitHubRepositoryClientTests.swift'))
check('GitHubScopePolicy.effectiveScopes(' in tests and 'GitHubScopePolicy.validateLogin(' in tests and
      'legacyAccount' in tests and 'for missingScope in target' in tests,
      'Swift fixtures cover scope inheritance, missing grants, old metadata and login validation')
check(all(name in gateway and name in dispatch for name in ['github_repository_info','github_commit_push','github_branch_create']), 'Repository info, atomic commit and branch tools are registered and dispatched')
check('owner,collaborator,organization_member' in client and 'next_page' in client, 'Repository pagination covers account affiliations')
check('"force": false' in client and 'expectedHead' in client, 'Atomic commits check expected branch head and use non-force push')
check('GitHub连接器' in ui and 'Text("GitHub连接器")' in content, 'Connector labels are consistent')
asset=root/'Assets.xcassets/GitHubMark.imageset'
check(json.loads((asset/'Contents.json').read_text())['images'][0]['filename']=='mark-github.svg' and '<path d=' in (asset/'mark-github.svg').read_text(), 'Official GitHub SVG asset exists and is referenced')
print(f'Structural checks passed: {checks}')
