from pathlib import Path
root = Path(__file__).resolve().parents[1]
def read(p): return (root/p).read_text(encoding="utf-8-sig")
session=read("Shared/Mail/MailWebSession.swift")
ui=read("Views/Settings/MailWebViews.swift")
settings=read("Views/Settings/MailAccountsView.swift")
tools=read("Shared/Mail/MailWebTools.swift")
scripts=read("Shared/Mail/MailWebScripts.swift")
checks=0
def check(value,label):
 global checks
 assert value,label
 checks+=1
 print("PASS:",label)
check(settings.index("MailWebEntry(provider: .gmail)") < settings.index("GmailConnectionSection()"),"Web login is the primary Gmail route; API lives in advanced settings")
check("MailWebEntry(provider: .qq)" in settings,"QQ also has a direct web login entry")
check("configurationReady" not in ui and "clientID" not in ui,"Web login is not disabled by missing OAuth client")
check("MailWebSurface(webView: session.webView)" in ui and "session.perform" in tools,"Settings and tools use the same retained web session")
check("WKWebsiteDataStore(forIdentifier: provider.storeID)" in session and ".nonPersistent()" in session,"Provider-isolated storage with explicit iOS16 ephemeral fallback")
check("CookieBackupStore" not in session and "httpCookieStore" not in scripts,"Web sessions never import or expose browser login cookies")
check("verifyAndEnable" in ui and "value[\"mailbox\"] as? Bool == true" in session,"Connection requires detected mailbox DOM and explicit user permission")
check("!manual" in session and "generation == version" in session,"Manual login and revocation block pending model access")
check("removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()" in session,"Disconnect erases only the dedicated provider store")
check("input[type=password]" in scripts and "if (!allowed)" in scripts,"Authentication pages are excluded from extraction")
check(".defaultClient" in session and "state.snapshot !==" in scripts,"DOM references live in an isolated script world and require a current snapshot")
check('name: "mail_web"' in tools and 'case "mail_web"' in read("Agent/Chat/AIChatViewModel+ConcurrentTools.swift"),"Webmail tool is registered and dispatched")
check("MailWebTools.accounts + gmailRows" in read("Shared/Mail/MailAIToolGateway.swift"),"Account discovery prioritizes actual allowed web sessions")
check("MailWebTools.instructions" in read("Agent/Chat/AIChatViewModel.swift"),"Agent knows web sessions are not API accounts")
check("RemoteServerAIConfirmationGate.shared.request" in tools,"Page mutations require explicit native confirmation")
check("MailAsyncWait.value(task)" in session and "15_000_000_000" in session,"WebKit waits are cancellable with a deadline")
check("Google 提示此浏览器受限" in ui and "iOS 16" in ui,"Provider login restrictions and storage limitations are visible")
project=read("Ze.xcodeproj/project.pbxproj")
for name in ["MailWebSession","MailWebScripts","MailWebTools","MailWebViews"]:
 check(project.count(f"/* {name}.swift in Sources */")==2,"App membership: "+name)
print(f"Webmail structure tests passed: {checks}")
