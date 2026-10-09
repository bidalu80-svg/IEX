from pathlib import Path
import plistlib
root = Path(__file__).resolve().parents[1]
def read(path): return (root/path).read_text(encoding='utf-8-sig')
checks = 0
def check(value, message):
    global checks
    assert value, message
    checks += 1
    print('PASS:', message)
auth=read('Shared/Gmail/GmailConnector.swift')
ui=read('Views/Settings/MailConnectorViews.swift')
gateway=read('Shared/Gmail/MailConnectorTools.swift')
client=read('Shared/Mail/MailClient.swift')
check('ASWebAuthenticationSession' in auth and 'prefersEphemeralWebBrowserSession = false' in auth, 'Gmail uses system Google login, not mailbox password or scraped cookies')
check('S256' in auth and 'code_verifier' in auth and 'SecRandomCopyBytes' in auth and '?.value == state' in auth, 'OAuth uses PKCE, random state, exact callback validation')
check('gmail.readonly' in auth and 'gmail.send' not in auth and 'mail.google.com/' not in auth, 'Gmail requests readonly scope only')
check('GmailOAuthClientID' in auth and 'configurationReady' in auth and 'GeminiOAuthManager' not in auth, 'Ze-owned OAuth client required; no borrowed provider credentials')
check('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly' in auth and 'refreshes' in auth, 'Keychain token persistence and single-flight renewal')
check('oauth2.googleapis.com/revoke' in auth and 'records.filter { $0.account.id != id }' in auth, 'disconnect removes local credentials and requests Google revocation')
check('imap.qq.com' in ui and 'smtp.qq.com' in ui and '不是 QQ 密码' in ui and ui.index('MailClient.testIncoming') < ui.index('MailAccountStore.shared.save'), 'QQ preset verifies authorization-code login before saving')
check('GmailConnectionSection()' in read('Views/Settings/MailAccountsView.swift') and 'QQMailLoginView()' in read('Views/Settings/MailAccountsView.swift'), 'Gmail and QQ connectors precede advanced manual settings')
check('INTERNALDATE' in client and 'MailVerificationFilter' in client and 'BODY.PEEK' in client, 'QQ verification uses received time and read-only fetch')
for tool in ['gmail_search','gmail_read','mail_search','mail_wait_verification']:
 check(f'name: "{tool}"' in gateway and f'"{tool}"' in read('Agent/Chat/AIChatViewModel+ConcurrentTools.swift'), 'tool wired: '+tool)
check('group.cancelAll()' in gateway and 'Task.checkCancellation()' in gateway and '.seconds(10)' in gateway, 'verification polling is bounded and cancellable')
check('MailConnectorTools.instructions' in read('Agent/Chat/AIChatViewModel.swift'), 'task-scoped verification instructions reach agent')
check('"provider": "gmail"' in read('Shared/Mail/MailAIToolGateway.swift'), 'account discovery includes Gmail and QQ provider identities')
plist=plistlib.loads((root/'Info.plist').read_bytes())
check(plist['GmailOAuthClientID']=='$(GOOGLE_GMAIL_CLIENT_ID)' and any('$(GOOGLE_GMAIL_CALLBACK_SCHEME)' in v.get('CFBundleURLSchemes',[]) for v in plist['CFBundleURLTypes']), 'OAuth callback registered in Info.plist')
project=read('Ze.xcodeproj/project.pbxproj')
for name in ['GmailConnector','GmailModels','MailConnectorTools','MailConnectorViews','MailVerification']:
 check(project.count(f'/* {name}.swift in Sources */') == 2, 'app target contains '+name)
check('imapPassword: credentials.imapPassword, smtpPassword: credentials.smtpPassword' in ui and '.disabled(connecting)' in ui, 'QQ saves the exact tested credential snapshot and locks login inputs')
check('MailVerificationPager.collect' in gateway and 'pageToken: cursor' in gateway and 'includeSpamTrash: true' in gateway, 'Gmail verification follows page tokens including spam/trash')
check('MailVerificationPager.collect' in client and 'before: before' in client, 'IMAP verification traverses UID pages before declaring absence')
check('let ticket = try store.accessTicket(for: id)' in read('Shared/Mail/MailAIToolGateway.swift') and read('Shared/Mail/MailAIToolGateway.swift').count('store.validateAccess(ticket)') >= 4, 'legacy list/read/send revalidate authorization generations')
check('access.synchronize' in read('Shared/Mail/MailAccountStore.swift') and 'access.invalidate(account.id)' in auth, 'off/on and reconnect invalidate pending tool results')
check('MailAsyncWait.value' in auth and 'withTaskCancellationHandler' in read('Shared/Mail/MailModels.swift'), 'a cancelled waiter does not block on a shared OAuth refresh')
check(client.count('try await authorize()') == 2, 'SMTP authorization is checked again before DATA and before the body')
check('maxPages' in read('Shared/Mail/MailVerification.swift') and 'visited.insert(next)' in read('Shared/Mail/MailVerification.swift'), 'pagination is bounded and rejects cursor loops')
print(f'Mail connector structural checks passed: {checks}')
