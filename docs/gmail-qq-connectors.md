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
