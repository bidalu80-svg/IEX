# 网页邮箱主入口（本轮更新）

设置 → 邮箱 → Gmail / QQ 邮箱现在直接显示真实邮箱网页，原 API / 授权码连接移到“高级连接方式”。网页登录路径不依赖 GOOGLE_GMAIL_CLIENT_ID。

1. 用户在网页中亲自登录并完成二次验证。
2. 点击“已进入邮箱，允许智能体使用”，检查邮箱页面结构后授权并返回。
3. `mail_account_list` 返回 `web_gmail` / `web_qq`；智能体通过 `mail_web` 使用同一个 WKWebView 读取可见文本和邮箱元素，不复制 Cookie、不调用 Gmail API。
4. 搜索填写仅允许搜索框，点击/搜索需原生确认；操作后必须重新读取验证结果。元素快照和内容变化校验防止旧索引误点。
5. 手动操作时暂停智能体；关闭权限、离开登录域、清除会话会撤销旧操作。网页版打开邮件可能改变已读状态，不再宣称 API 式只读。

### 存储与验收边界
- iOS17+ 使用每个邮箱服务独立的持久化 WKWebsiteDataStore；iOS16 使用隔离临时存储，App 结束后需重新登录。没有把全局浏览器 Cookie 导入此会话。
- 此版本每个服务维护一个网页会话；Gmail 网页中的账号切换由用户控制。不把页面标题/网址当成已验证的邮箱地址。
- Google 可能限制嵌入式浏览器登录。打开页面不等于登录成功；若提供商拒绝该浏览器，入口会保留真实网页错误、权限保持关闭。在 Safari 登录不会同步到此 WebKit 会话。没有伪造 Google 受支持浏览器身份或绕过登录检查。
- 模拟器 `MailWebHarness.swift` 测试实际 WebKit 上的本地邮箱夹具、同一视图读取/点击/搜索、权限撤销、快照更新、Cookie隔离清理，并记录无凭据的真实 Gmail 入口截图。真实账号登录未由夹具测试替代。

### 运行验证
```sh
python scripts/verify-mail-web.py
# macOS + iOS Simulator
bash scripts/test-mail-web.sh
```

---
以下为保留的高级 API/IMAP 连接说明。

# Ze 邮箱连接器交付与配置

## 用户入口
设置 → 邮箱 → Gmail（Google 授权登录）或 QQ 邮箱（邮箱授权码）。
高级 IMAP/SMTP 保留原有账号配置，不迁移、不删除已有凭据。

QQ：填 @qq.com 或 @foxmail.com 地址和 QQ 邮箱设置中生成的授权码。
收信服务器 imap.qq.com:993，发信服务器 smtp.qq.com:465，均使用直接 TLS。
保存前验证 IMAP 登录，不发送测试邮件。授权码不是 QQ 登录密码。

## Google 开发者配置（发布前必须完成）
1. 在自己的 Google Cloud 项目启用 Gmail API，配置 OAuth 同意页。
2. 创建 iOS 类型 OAuth 客户端，Bundle ID 对应实际签名包（当前 com.ze.app）。
3. 配置 gmail.readonly 权限。按 Google Cloud 控制台要求添加测试用户或完成正式发布所需审核；测试授权可能受平台有效期限制。
4. 设置仓库 Actions variable 或 secret `GOOGLE_GMAIL_CLIENT_ID`（它不是密码，不需要 client secret）。变量优先于 secret；不读取其他服务商的客户端。需要强制 Gmail 可配置的发布构建时，同时设置 variable `REQUIRE_GMAIL_OAUTH=1`，缺失客户端立即失败。
5. CI 自动将 ID 与倒序域名形式的回调 Scheme 写入 ProviderCustomization.xcconfig，Info.plist 读取对应值。
6. 本地 Xcode 构建也可直接在 Configs/ProviderCustomization.xcconfig 配置 GOOGLE_GMAIL_CLIENT_ID 与 GOOGLE_GMAIL_CALLBACK_SCHEME。
7. 真实账号验证：授权取消/拒绝、只读授予、重启恢复、续期、多账号切换、关闭权限、解除连接和服务器撤销。

未配置时仅构建通过不代表登录可用；界面明确显示配置缺失，不提交占位 client ID。
绝不借用 Gemini / 其他应用的 Google OAuth ID 或密钥。

## 智能体接口
- mail_account_list：列出 provider 为 gmail / qq / imap 的已允许访问账号。
- gmail_search / gmail_read：Gmail 搜索与正文读取，保留候选 HTTPS 链接。
- mail_list / mail_read：QQ/IMAP 收件箱读取，保留原有行为。
- mail_search：QQ/IMAP 精确发件人、主题、最近24小时接收时间过滤。
- mail_wait_verification：Gmail 与 QQ/IMAP 通用，按本次注册开始时间、完整发件邮箱和主题过滤，限时查询。
  不自动打开链接。候选数字不保证就是验证码，模型必须核对当前用户任务；未知发件地址不得猜测。

## 验收边界
iOS 16 SDK 类型检查、纯 Swift 解析测试、整 App 编译与打包可以由 CI 验证。
真实 Gmail / QQ 授权与收取新验证邮件需要账号实测；不要将编译成功当成该项已通过。

参考（以各服务官方文档与后台实时要求为准）：
https://developers.google.com/identity/protocols/oauth2/native-app
https://developers.google.com/workspace/gmail/api/auth/scopes
https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list
https://mail.qq.com/

## 本轮完善与回归检查
- QQ 连接期间锁定登录字段，保存已验证的不可变凭据快照，避免测试/保存之间的编辑竞态。
- Gmail 验证邮件查询遍历 pageToken，包含垃圾邮件和回收站；QQ/IMAP 遍历 UID 页，不再只筛首20封。最多100页，触顶/游标循环返回明确错误，不宣称邮件不存在。
- QQ/IMAP 当前仍仅查询 INBOX。`mail_search` 最多返回20个匹配结果；等待验证码找到第一个匹配即停止。
- 关闭再开启访问、编辑凭据、删除、重连、重新加载均使旧请求的授权票据失效；旧请求结果不会交给模型。发信在确认后、SMTP DATA 前和正文提交前再次校验。已提交给服务器的邮件不属于可撤回范围。
- Gmail 使用独立的浏览器会话标识，过期取消回调不会结束下一次登录。取消某个令牌续期等待者会及时返回，不会取消其他请求共享的续期任务。
- 等待验证码统一为1至120秒，默认60秒；仅前台工具限时运行，不是后台收信服务。
- 构建配置脚本幂等写入、拒绝占位/格式错误的 ID；CI 显示未配置警告，打包后核对实际 Info.plist 中客户端及回调 Scheme。

本地静态/配置检查：
```powershell
python scripts/verify-mail.py
python scripts/verify-mail-connectors.py
python scripts/test-gmail-oauth-config.py
git diff --check
```
macOS CI 另外执行 `scripts/GmailConnectorTests.swift`（真实 Swift 异步回归：跨页/空页/循环/扫描上限/取消/权限代次/共享续期取消）、旧 MailModelsTests、iOS16 SDK 类型检查和整 App 构建打包。

### 真实账号验收清单（另行记录，不与构建通过混同）
- Gmail：配置自有 iOS OAuth 客户端后，授权取消/成功、重启恢复、续期、多账号、撤销、关闭再开启访问、验证邮件位于下一页或垃圾箱。
- QQ：授权码错误/正确、慢网连接时编辑限制、收件箱验证码、用户确认发信、取消发送、读取中撤销访问。
- 两者：超时、取消、断网、邮件已删除、正文及验证码呈现。不读取本机 Keychain 实际账号来替代用户验收。

### 回滚
本轮在原有未提交代码的基础上完善，并纳入同一个功能提交。对推送提交执行 `git revert <本轮功能提交>` 会撤销整批新增连接器；恢复修改前的未提交版本，应使用本地 `ios-mail-backup-*` 目录中的 `files/` 与 `manifest.json`。恢复前先另存当前改动，切勿用强制重置覆盖其他工作。
