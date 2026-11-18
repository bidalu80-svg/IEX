# 网络磁盘实现与验证记录

日期：2026-11-19。基线：`42339dfa9a68dff11dd856ab6c6867657b851841`。

六项清单的代码接入已完成；**五协议均未完成真实服务验收**。本机是 Linux，没有 `xcodebuild`、`swiftc`、`swift`，没有编译应用、执行 Swift 夹具或运行 iOS UI。不能把下述静态通过当成协议可用证明。

## 接手状态与提交

接手时已有 10 个受跟踪文件修改、6 个新增 Swift 文件和 brief，全部未提交，六项功能均有草稿。本轮先保留并分步提交这些实现，再独立只读审核、运行 scripts 自查；发现问题另作修复提交，没有整文件翻转行尾。

原克隆 `.git` 在环境权限中只读，未尝试改动它。提交在 `/tmp/netdisk-commits.git` 的独立可写 Git 元数据中创建，工作文件仍在本克隆；最终导出 `./netdisk.bundle`。原克隆的 `git status` 仍显示相对原 HEAD 的改动，这是未写原 `.git` 的结果，不能据此认为 bundle 缺少提交。

| 提交 | 内容 |
|---|---|
| `922eaa1` | WebDAV、FTP、S3 协议修补；提交信息明确 live protocols unverified |
| `2af532b` | 持久磁盘配置、只读服务、设置和 SSH 主机信任 |
| `ee91c25` | AI 文件读取、文件浏览和聊天附件入口、工程引用 |
| `8b90f54` | 提交后审核修复：DAV 默认端口、S3 同名文件/目录、SFTP 根路径与验证版本 |
| `ffc831b` | 生产代码 Swift 夹具、静态集成检查与 scripts 双向扫描 |
| `7832f1d` | 仅改密码也更新配置版本，拒绝旧请求/旧验证结果；兼容旧 JSON |
| `b57bdc0` | FTP 被动端口畸形响应安全拒绝、非 UTF-8 目录失败、SFTP 分块取消检查 |

报告与双向扫查清单另作最后一个文档提交。bundle 只包含基线之后的全部提交，分支名 `netdisk-implementation`；需要接收仓库已有上述基线。可在工作树干净且包含基线的仓库中使用：

```sh
git bundle verify /path/to/netdisk.bundle
git fetch /path/to/netdisk.bundle netdisk-implementation
git log --oneline 42339df..FETCH_HEAD
```

## 六项清单的实现落点

| 项目 | 已实现 | 验证界限 |
|---|---|---|
| 1. 协议阻塞点 | FTP 隐式 TLS、一次恢复 gate、粘包/多行/EOF、EPSV/PASV、MLSD/Unix LIST；S3 端口/编码签名/分页/目录前缀；DAV 校验与 propstat 解析 | 代码核对；真实服务、第三方库编译未验 |
| 2. 配置与只读服务 | `RemoteDiskStore`、`RemoteDiskReading`、五协议适配；稳定 UUID 地址；Keychain；下载返回值上限 64 MiB；配置/SSH 版本检查 | 只读调用面与版本检查静态通过；Keychain/断网行为未跑 |
| 3. 设置 | 新增/编辑/删除配置、连接/列目录/读取分别记录、重新验证与选文件验证；复用备份表单；SFTP 显式信任 | 工程接入静态通过；UI/重启持久化/主机指纹交互未跑 |
| 4. AI 文件工具 | `remote_disk_list` 及工具分页；`file_read` 识别地址，复用 UTF-8、行范围、80,000 字符截断；媒体存到请求会话并返回本地地址；写/编辑直接拒绝 | 注册、调度、只读和本地缓存路径静态通过；真实工具运行/read_image 未验 |
| 5. 浏览文件 | 本地/网络来源、异步目录、上级、重试、失败提示、只读预览 | 源码无远端上传/删除/重命名/建目录入口；iOS 浏览/预览未跑 |
| 6. 聊天媒体 | 附件菜单网络磁盘入口，受限下载后调用现有 `addFileAttachment` 与发送链路 | 已核到图片分类、会话 uploads 和 `.imageData`，文本/音视频沿现有附件路径；模型实际接收、文本实际读取、音视频播放未验 |

删除磁盘配置、下载到本地缓存不属于远端写入。磁盘服务没有远端写 API，AI 的远程地址写入/编辑明确失败。磁盘地址和工具 schema 不携带密码、私钥或 S3 secret。

## 逐协议状态

| 协议 | 已实现什么 | 本机验到哪一步 | 未验证 / 明确限制 |
|---|---|---|---|
| WebDAV | 主机/端口分离；Basic 认证；PROPFIND Depth 1；仅成功 propstat 的属性；目录/文件识别；同源有效端口比较；保留文件名；受限 GET | 只读调用链、输入与解析代码核对；生产解析夹具已准备 | 真实认证、207 响应、文件读取、HTTP 流式限额/取消、重定向兼容均未实测；Swift 未编译/执行 |
| SMB | 现有 `SMBClient` 适配器；登录、share、list/download；路径/大小元数据；读前 size 检查及读后实际字节检查 | 确认工程声明 `https://github.com/kishikawakatsumi/SMBClient.git`、product `SMBClient`、版本范围从 0.1.0 起；没有用桩替代 | **依赖真实源码/API 未核实**：无本地缓存，GitHub 请求被不可连接的环境代理阻断；登录/列目录/读取均未验。依赖整块 Data 下载，stat 后文件增长时无法保证严格传输内存限额；64 MiB 是返回数据上限 |
| SFTP | 复用 Citadel/SSH 认证和主机指纹；统一绝对根路径；服务器 realpath 范围检查；分块限额下载/取消；按服务器 updatedAt 检查连接复用与磁盘读取结果版本 | 确认工程固定 Citadel 0.11.1；磁盘配置版本检查经静态核对；本轮补齐四个 SSH 凭据写入入口的版本更新、连接移除与验证清除，尚未运行验证 | 依赖解析/编译未验；真实握手、首次信任、指纹变化、符号链接、断线重连、读取限额均未实测；realpath 检查不等于服务端原子隔离 |
| S3 | path-style endpoint 及自定义端口；SigV4 编码路径、排序 query、Host 含端口；delimiter 目录；continuation-token 循环/重复 token 拒绝；同名对象和目录并存；受限 GET | 签名与分页控制流核对；生产 XML 夹具已准备，包括 token、同名项与 >1000 条解析输入 | 未执行签名测试向量；未连 AWS/MinIO 等；实际 >1000 对象跨页、空目录 marker、鉴权及限额下载均未验；不支持 session token 临时凭据 |
| FTP | 明文 FTP；隐式 FTPS 990，控制/数据通道 TLS；PBSZ/PROT；EPSV/PASV 固定控制主机；MLSD 与 Unix LIST fallback；粘包/分段/多行/EOF；一次 continuation 恢复；受限 RETR | Network 调用顺序、TLS 和只读命令链核对；真实生产分帧/端口/列表解析夹具已准备 | **显式 AUTH TLS 未实现并拒绝**；隐式 TLS 当前仅接受端口 990；真实 FTP/FTPS、证书/被动 TLS 互通、断网/超时均未实测；DOS LIST 与非 UTF-8 名称不支持并报错 |

共享边界：配置根路径是磁盘寻址根，不是所有协议都具备的远端文件系统隔离机制。FTP/SMB/WebDAV 的服务器符号链接、alias 或共享配置仍需服务端账号权限/jail/share 约束；客户端词法路径检查不能证明服务器实际文件系统隔离。当前共享端点校验接受纯 DNS/IPv4 主机，拒绝带冒号的 IPv6 主机输入。

## 已实际运行的检查

均在实现分步提交之后运行；最后协议修复后重跑网络磁盘检查和夹具准备。

- `python3 scripts/verify-netdisk.py --scan-json /tmp/netdisk-final-literals.json`：26 项静态检查通过，含只读接口/接入点/工程对象唯一性和未改动行的原始行尾保持。
- `python3 scripts/verify-agent-scheduled-tools.py`：14 项通过。
- `python3 scripts/verify-github-connector.py`：23 项通过。
- `python3 scripts/verify-media-favorites.py`：30 项通过。
- `python3 scripts/test-shell-file-maintenance.py --prepare-only`：生产 worker 与 fakefs fixture 准备及静态断言通过，**没有 Swift 执行**。
- `python3 scripts/test-netdisk.py --prepare-only`：生产模型、地址与协议解析代码原文提取、哈希清单生成通过，**没有 Swift 编译/执行**。
- `git --git-dir=/tmp/netdisk-commits.git -c core.whitespace=cr-at-eol diff 42339df --check`：通过。普通 `diff --check` 把既有 CRLF 的 CR 视作尾空白；保留 CRLF 后使用 `cr-at-eol` 检查，没有为消警翻转行尾。

`RemoteDiskWireChecks.swift` 针对真实提取的生产实现，覆盖配置版本 JSON 兼容、一次地址解码/越界拒绝、FTP 分帧/被动端口/列表/gate、DAV 默认端口/失败属性/异源/深层项、S3 token/同名项/错误响应/前缀和 1001 条输入。它**尚未执行**；1001 条解析输入也不等于传输分页验证。

## scripts 双向扫查及独立审核

最终可复现清单见 `netdisk-script-scan.json`：4556 个长度至少 12 且不含换行的脚本字面，对 16 个变更生产文件逐文件比较基线/当前次数，共 71 个次数变化。Python 用 AST 字符串常量，Swift/shell 用双引号字面；这是词法清单，不是完整语义证明。

- 两个减少的字面：存储客户端的通用 `    static func `（`test-image-wire.py` 实际检查其它图片代码），以及 `encoding: .utf8`（新 `verify-netdisk.py` 在 FileTools 上检查，FileTools 保留）。没有移除它们实际目标上的锚点。
- 新增的通用 `withTaskCancellationHandler` / `try Task.checkCancellation()` 不在 BrowserTakeover 等脚本的否定断言目标块。已核相关 `block(...)` 锚点和检查边界。
- 本轮新 `verify-netdisk.py` 明确固定只读接口、工具注册、缓存和 UI 接入点、工程引用；`test-netdisk.py` 用声明边界提取生产代码，未来改名/移动这些声明须同步夹具提取。没有把 UI 展示文案当作协议实测。
- 按上级 AGENTS.md 的规则，另一个只读审核代理检查依赖闭包与 scripts 盲点；其发现的 DAV 默认端口、S3 身份、SFTP root、凭据与版本竞态均已修复并复核。它同样没有编译/协议实测条件。

## 仍需在 macOS/iOS 做的验收

1. 解析 SMB/Citadel 实际依赖并核对新增 API；Xcode 完整构建，运行 `python3 scripts/test-netdisk.py` 的生产 Swift 夹具。此夹具只验证模型和解析，不覆盖 Network/CryptoKit/第三方协议传输。
2. 每协议提供真实只读账号：在设置分别验连接、根目录、选中文本读取；检查失联/认证错误显示失败而非空目录；测试空文件、空目录、子目录、空格/Unicode/保留字符文件名。
3. WebDAV 默认端口 href、部分失败属性；S3 至少 1001 对象跨页、特殊 key、文件/目录同名；FTP 明文及隐式 FTPS 的 MLSD/LIST/RETR、TLS 证书、粘包/EOF/取消；SFTP 未信任/变更主机密钥、越界 symlink、掉线重连；SMB size 后增长文件的内存行为。
4. 验证 >64 MiB 拒绝与文本截断相互独立；验证下载期间编辑配置/仅改密码/编辑 SSH 配置不发布旧结果。
5. 三入口各实际读取；用 AI `file_read` 验行范围与截断、媒体的本地路径经 `read_image`；聊天图片核对最终模型请求与响应，文本附件实际 `file_read`，音视频在选择/草稿/发送后实际播放。现阶段这些全部标为未验证。
