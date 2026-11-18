# 网络磁盘网关修复交付报告

## 基线、提交顺序与环境

- 当前工作树最初为 `fix707`，实际基线提交 `f3eb356424bd754d26512f8f53bcc9307d7253a5`。本地没有 `608fb7cf` 对象，因此无法独立验证与该远端提交的树一致性；没有擅自换基线或拉取远端。
- 严格按“先实现、先本地提交，再自查；发现问题另起修复提交”执行。实现提交之后才运行检查及独立只读审核，返修沿用同一审核会话。
- 本克隆 `.git` 被环境挂载为只读，普通提交报 `index.lock: Read-only file system`。本地提交使用 `/tmp/disk-gateway-local.git` 的可写 Git 元数据，工作树仍是当前克隆。复制裸仓库后曾因未初始化索引生成一个错误的临时提交；已重建基线索引并替换该未发布引用，交付历史只包含下列正确提交。
- 原克隆 `.git` 的分支引用未改动；完整修改已保存在当前工作树，提交保存在交付 bundle。不要把原克隆 `git log` 仍显示基线误认为 bundle 没有提交。

| 提交 | 内容 |
| --- | --- |
| `0a1fa94cc5fd18547bf6c070133947447768052f` | 两处缺陷的实现，13 个文件 |
| `148851fe` | 提交后修复：上游凭据诊断与正文捕获、标题、弹层判断、检查脚本 |
| `d26d8c9ff41e137cae594fa1a5bb771b2c744625` | 提交后修复：畸形 OpenAI 流原始诊断、手动重生成标题的最新历史复查 |

源码最终树为 `9d0e4408354588ca59e9fb4015777d7a71d42b39`；交付另有文档提交，包含本报告与双向扫查明细。

## 缺陷 1：设置图标

`Views/ContentView.swift` 中网络磁盘行改用与服务器行一致的 `Label { Text } icon: { Image }` 结构：`externaldrive.fill`、10pt semibold 白色字形、21×21 frame、青绿色 Circle 底。尺寸、排版与同组一致，颜色与蓝色服务器图标协调。没有改动其它行图标。

原文件包含混合 CRLF/LF，只对目标字节片段做替换，检查确认未改变未修改行的行尾。未在模拟器或真机查看实际效果。

## 缺陷 2：网络磁盘配置网关

主要新实现：`Shared/RemoteServers/RemoteDiskAIToolGateway.swift`；原生表单呈现放在新文件 `Views/Servers/RemoteDiskAIDraftPresentationModifier.swift`。两个文件均已加入 Xcode 文件引用、分组和 app Sources。

| 工具 | 行为与确认 |
| --- | --- |
| `remote_disk_draft` | 模型仅能传协议、名称、主机、端口、用户名/Access Key ID、根路径、TLS、SMB 共享、S3 桶/区域、关联 SSH UUID 等非机密元数据。拒绝额外字段。只暂存草稿，打开既有原生磁盘编辑器；不保存、不连接、不信任主机。用户本人复核、保存或取消。 |
| `remote_disk_configure_credentials` | 仅用于用户明确提供并要求保存的凭据；统一确认门显示磁盘身份、地址及凭据类型，不显示凭据。批准后才通过 `RemoteServerCredentialChange` 直写 Keychain，不读取旧凭据；拒绝或取消不写入。 |
| `remote_disk_delete` | 统一确认门明确说明删除范围；批准后调用既有 `RemoteDiskStore.remove`，删除配置、验证记录及磁盘自身 `.remoteSecret`；不删除远程文件，也不删除关联 SSH 服务器及共享凭据。 |

草稿与服务器草稿互斥，避免并发调用挤出原生复核表单。磁盘草稿加入聊天 `hasOverlayPresented` 判断，呈现时抑制自动聚焦。保存凭据和删除在等待确认后都重新核对磁盘快照，SFTP 凭据还重新核对关联服务器快照，配置变化则拒绝旧请求。取消后检查 Task 取消状态。

### SFTP 与 full_access 边界

- SFTP 草稿要求一个已存在的 `ssh_server_id`。若尚未创建 SSH 服务器，先走 `remote_server_draft` 或原生服务器表单；磁盘表单仍允许用户选择/新增 SSH 服务器。该步骤不替用户确认 SSH 指纹，后续信任仍通过设置页原有显式指纹流程。
- SMB、WebDAV、FTP 使用 `password`；S3 使用 `secret_key`。SFTP 按关联服务器既有认证方式使用密码，或 OpenSSH RSA/Ed25519 私钥及可选口令；不改变认证方式或 AI 权限。
- SFTP 保存凭据会更改关联 SSH 服务器的共享凭据，确认文案明确提示影响。新 `perform(for disk:)` 重用原 `perform(for serverID:)`：旧连接不可达、清会话认证、推进服务器版本、清所有关联磁盘验证，然后写 Keychain。
- 非 SFTP 没有持久连接池，统一入口在写入前推进磁盘配置 revision 并清验证，使旧的进行中读取/验证无法发布。没有通过 `RemoteDiskStore.save(secret:)` 的回滚读旧凭据路径写入。
- 网络磁盘本身没有 `full_access` 权限等级。所有磁盘配置凭据保存和删除都强制确认，即使关联服务器是 `full_access` 也不豁免，与服务器配置凭据/删除工具一致。
- 磁盘配置是网络磁盘自己的授权边界：已配磁盘可配置其关联 SSH 凭据，不要求提高该服务器的 AI 命令权限；即使服务器 AI access 为 none，也不会因此开启命令或内容写权限。

### 注册、提示与用户可见状态

- 三个新工具紧邻 `remote_disk_list` 接入 `AIChatViewModel+ToolDefinitions.swift` 和 `AIChatViewModel+ConcurrentTools.swift`；列表工具的原注册、分发及参数保持不变。
- 系统提示在服务器状态片段的同一入口追加磁盘配置指引与显式字段组成的磁盘元数据清单，两条提示构建路径都能收到。清单包括名称、UUID、协议、主机/端口、用户名、根路径、TLS、共享/桶/区域、关联 SSH UUID、`read_only: true` 和 `remote-disk://` 地址，不序列化整个 profile 或 Keychain 项。
- 无磁盘时仍注入配置指引；存储加载错误时不伪称空清单。
- 指引写明：先 `remote_disk_list` 刷新配置/列目录，再用返回地址调用 `file_read`；媒体下载后的会话内路径可交 `read_image` 等工具。明确禁止任何磁盘内容写入。
- SoulStore 增加起草、保存凭据、删除配置和查看磁盘的中文状态文案。

### 凭据不回显与诊断边界

- 凭据工具的流式参数不进入预览或原始 chunk 诊断环。完整调用在进入常规工具流水线前，把凭据放入一次性内存 inbox；普通参数只含固定标题、合法磁盘 UUID 和随机句柄。未消费句柄 10 分钟过期，消费后不可重放，payload 不序列化。
- 工具结果使用固定成功/失败说明；不回显 credential、原始参数、底层任意错误描述。凭据确认中只显示身份及类型。网关没有 Keychain 读取调用。
- Anthropic/OpenAI 的凭据 JSON 解析失败诊断不再打印原文/十六进制；新工具可用的 OpenAI 请求不收集畸形流原始 firstLines。
- 凭据工具可用的请求禁用 API 请求/响应正文诊断捕获；Anthropic 三种传输模式的原始响应预览和错误正文捕获相应屏蔽，Anthropic/Gemini 的完整请求日志同样屏蔽。检查发生在正文截断或 SSE 分片之前。HTTP 状态、usage、耗时等元数据仍可保留。
- 因为新凭据工具始终注册，使用这套工具的智能体请求通常都会省略诊断正文；这是本次凭据保护带来的排查能力边界。
- 出现该凭据工具调用的会话，自动标题和手动重生成标题使用固定“网络磁盘配置”，防止从凭据输入摘要派生标题；已在进行的自动命名任务按会话标记退出，手动命名返回后重读最新历史。
- **继承边界：用户主动发送的原始聊天消息仍按既有机制显示和持久化，本轮没有删除或改写用户消息。模型在收到工具前已看到这些用户文本；不回显指令也不能证明模型绝不会在其它自由文本中泄露它。因此交付不声称全应用凭据零落盘，也不声称已证明模型输出绝对无泄露。** 原生 SecureField 输入仍是避免把凭据主动发进聊天的现有路径。

## 提交后自查及 scripts/ 双向扫查

独立只读审核发现的上游 raw/hex 日志、原始响应捕获、脚本固定写入数量、草稿弹层判断、畸形空流诊断和并发标题问题，分别进入后续修复提交；最终小 diff 复核未发现明显新增问题。这是源码复核，不是编译或真机验证。

以下检查实际在本地运行通过：

| 检查 | 结果 |
| --- | --- |
| `python3 scripts/verify-netdisk-gateway.py` | 27 项源码边界检查通过 |
| `python3 scripts/verify-ssh-credential-invalidation.py` | 24 项通过，新增 3 条 SSH 凭据 save 均位于统一事务内 |
| `python3 scripts/verify-netdisk.py --base f3eb356424bd754d26512f8f53bcc9307d7253a5 --scan-json disk-gateway-literal-scan.json` | 26 项通过，包含既有只读硬线、Xcode 引用及未修改行 CRLF/LF 保留 |
| `python3 scripts/verify-sse-idle-timeout.py` | 52 项通过 |
| `python3 scripts/verify-github-connector.py` | 34 项通过 |
| `python3 scripts/verify-agent-scheduled-tools.py` | 14 项通过 |
| `python3 scripts/verify-media-favorites.py` | 30 项通过 |
| `git -c core.whitespace=cr-at-eol diff --check <基线> HEAD`（使用可写 Git 副本） | 通过；默认 diff --check 会把保留的 CRLF 识别为尾空白，没有为消除该提示翻转行尾 |

双向扫查明细见 `disk-gateway-literal-scan.json`：20 个生产 Swift/project 文件、4,786 个脚本字面、77 个出现次数变化，均为新增匹配，旧脚本字面没有减少。另逐条查了本轮删除/替换的生产代码行，包括旧裸图标 Label、旧 private 编辑器声明、旧 SSE 参数模式、旧标题 guard、原始诊断条件、正文捕获初始化及草稿 gate；这些整行字面没有现有 scripts/ 命中。

人工复核包含 block/body 锚点、否定断言和枚举计数，发现并修复：

1. `verify-ssh-credential-invalidation.py` 原有入口字典与 8 条 save 数量钉死，更新为包含磁盘网关的 6 个事务、11 条 SSH save，仍逐条验证 writer 位于统一入口中。
2. 同脚本原对整个 helper 文件做顺序搜索，会误命中新 overload 的 `try write()`；改为仅提取 `perform(for serverID:)` 函数体检查顺序，未放松既有失效次序。
3. 三个新工具名在既有脚本中没有枚举；最终只有本次新增的网关检查脚本明确引用它们。原 `remote_disk_list` 的注册/分发和无凭据参数断言均保留并通过。
4. 新增字面的其它命中均已按实际脚本读取的文件范围核对，无需重命名现有锚点或删除否定断言。新增网关检查及凭据失效检查已接入主 build workflow。

## 未验证项

本地没有 `swiftc` 或 Xcode，**没有编译 Swift、没有执行 Swift fixture、没有触发 CI，也没有运行模拟器/真机**；CI 将是本轮第一次编译。静态门通过不等于编译通过。

仍待 CI/设备验证：SwiftUI 类型检查与真实 sheet 呈现、21pt 图标视觉、确认拒绝/批准/取消、Keychain 实际成功和失败、不同认证方式、SFTP 指纹复核、旧连接/旧验证失效的真实时序、并发会话标题、SMB/WebDAV/FTP/S3/SFTP 实际互通。没有新增磁盘内容写 API；`file_write` / `file_edit` 对 `remote-disk://` 的拒绝和原 RemoteDiskReading 只读接口均未改动。

## 交付与导入

- `./disk-gateway.bundle`：`fix707` 的增量 bundle，前置提交为上述 `f3eb3564...`；包含实现、提交后修复及交付文档。
- `./disk-gateway-report.md`：本报告。
- `./disk-gateway-literal-scan.json`：可复核的双向字面清单。
- `ref-settings.jpg` 是原始输入，未加入提交。

在具有该基线且 Git 元数据可写的目标克隆中可导入：

```sh
git bundle verify ./disk-gateway.bundle
git fetch ./disk-gateway.bundle fix707
git merge --ff-only FETCH_HEAD
```

本轮未推送、未发布。
