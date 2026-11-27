# selfsign 阶段 0 调研报告

本报告仅依据本地只读参考代码；没有进行真机、Apple 账号登录、签名或安装实验。方案 `plan-selfsign-astra.md` 已全文阅读。证据路径均相对于克隆根目录，参考目录不纳入 Ze 提交。

## 材料与版本

- siboot：`6be886b7b6609b929d2d08ac9aaff5fd44d4bb65`；`minis/Cargo.toml` 为 0.22.0。
- SideInstaller 子模块：`58c5ea59b1fb7bd33c573e51a523dd0aca142bad`。用户给定 v2.2.0；该快照 README 徽章已写 2.3.0，故以 SHA 为准，不能只凭 README 的版本标签归档。
- 顶层 siboot README 仅指向安装站并要求 iOS 27+；SideInstaller README 仍描述 rootshell 转交流程，而当前 siboot 0.22.0 已删除 rootshell 路线。以当前 minis 源码为本次链路依据。

## 已核实的核心结论：不需要用户自备证书，并非没有开发者签名

`minis/README.md` 开头明确写 signed with your own Apple Account，并说明免费账号 7 天、付费团队约一年及首次需要在系统设置中信任账号。`minis/src/main.rs::run` 依次执行 Apple Account 登录、`sign::sign`、`install::install`，不存在从“隧道通”直接跳到“任意无签名 IPA 可启动”的路径。

`minis/src/sign.rs::sign` 调用 isideload `Sideloader::sign_app`，传入设备名和 UDID、`MemoryLimit::Off`、启用 app group，再从已签 app 读取 bundle ID 和版本。配对密钥只用于设备管理会话，不能取代 Apple 开发者代码签名身份。VPN、Bonjour 和 Developer Mode 也不是任意代码的信任根。下文继续追踪证书/profile/签名的具体实现。

## 安装链（已核对入口与传输实现）

| 步骤 | 实际动作与调用 | 依赖/权限与证据 |
|---|---|---|
| 0 工具自举 | `minis/install.sh` 下载 ARM64 musl Linux siboot，依次尝试 GitHub 与 jsDelivr，按脚本固定 SHA256 校验后保存到 `~/.siboot/bin/siboot` 并运行 | shell、wget/curl、摘要工具、Linux ARM64 执行环境；不是 iOS 原生可执行文件。脚本入口本身仍需版本固定，不应照搬远程管道执行 |
| 1 预检查/IPA 获取 | 检查 Apple 登录服务可达、下载/缓存 SideInstaller，或使用 `--ipa`；探测 LocalDevVPN 下设备 RPPairing listener | 默认 `10.7.0.1:49152`；非固定端口时探测动态端口，避开 62078；见 `preflight.rs`、`download.rs` |
| 2 复用/创建配对 | `pairing::ensure` 先验证已保存文件；否则在 loopback 监听，通过 `minis-bonjour advertise` 发布 `_remotepairing-pairable-host._tcp`，由设置里的 Pair with siboot 反向连接，`idevice::PairableHost::accept` 回应，显示六位码 | Minis 1.16 的宿主 Bonjour 桥接和 Info.plist 服务声明、局域网授权、用户系统设置操作；不是 guest shell 自己拥有 multicast 权限。host identifier、密钥对、altIRK 跨次保留；失败/结束撤销广播 |
| 2a 保活 | `keepalive.rs` 生成静音 WAV，通过 `apple-player` 播放；通知引导用户并显示配对码 | 宿主后台音频及通知桥接；shell 自己不能保证切到设置后存活；配对阶段有等待上限和最多三次连接尝试 |
| 3 建隧道 | `tunnel::open`：读取 RpPairingFile → attemptPairVerify/validate_pairing → create_tcp_listener → 新 TCP → TLS-PSK → CDTunnel → Adapter 软件 TCP → RSD handshake | 配对密钥、LocalDevVPN 路由；`idevice` 与 jktcp；MSS 为 min(MTU,8192)-60；lockdownd 经 RSD 提供设备名、系统版本和 UDID；各步有超时 |
| 4 账号登录 | `account.rs` 复用存储的 developer token，失效后 GrandSlam + 2FA；复用 SideInstaller `apple_session.rs` 和 `error_text.rs`；多团队可选择 | Apple 在线认证与 developer portal、远端 anisette；不是“全离线安装”。shell 存储用 fs-storage，不能视为 iOS Keychain |
| 5 重签 | `sign.rs` 调用 `sign_app` 注册设备、处理 bundle/app group、profile 与代码签名 | 目标 app 自己的签名/profile，独立于 Ze 自身的分发签名 |
| 6 上传/安装 | `install.rs` 逐文件 AFC 上传 `.app` 到 `/PublicStaging/<name>.app`，核对每个文件的远端长度，然后经 RSD 的 installation_proxy 发 install，`PackageType: Developer` | AFC 与 installation_proxy 设备服务；代码注释说明缺该选项会因 profile 未读取而拒绝。安装错误单独传播；上传文件长度一致不等于签名内容正确 |
| 7 配对转交 | `seed.rs` 用 house_arrest VendContainer 后的 AFC 写入 SideInstaller `Library/Application Support/rp_pairing_file.plist`，读回逐字节校验；删除旧 combined pairing，合并偏好并原子改名写 importedPairingFileName | 依赖开发签名容器可被 vend；失败时提示手动导入。转交的是敏感设备身份，不应进 Ze 通用 rootfs/聊天/日志 |
| 8 使用者启动 | 最后提供 `sideinstaller://` 按钮，提示首次信任账号 | 当前 siboot 的 installed 提示依据安装 RPC 返回；没有对目标版本做独立安装查询、没有实际启动及重启验证，不能据此宣称“已启动/永久可用” |

## Open Minis 提供的能力

据 `minis/src/bridge.rs`、`pairing.rs`、`keepalive.rs` 和 minis README：关键能力为宿主声明并广播 pairing Bonjour 类型、把宿主收到的连接转发到 guest loopback；`apple-player` 后台音频、`apple-notification` 通知、`minis-open` 同 App 内浏览页、`apple-clipboard` 剪贴板属于宿主桥接。Minis 1.16 gate 实际检查 `minis-bonjour` 和声明类型，并非直接读取版本号。

文件读写、下载、TLS/HTTP、TCP 监听、JSON/plist 处理、软件 TCP、Rust 加密运算、终端输入及 loopback HTTP 页面属于普通兼容 shell/运行时能力。ARM64 Linux 模拟执行是该发行物的运行条件，不是 shell 这一概念自带的能力。Minis 本体实现不在参考目录中：桥接内部权限、App Store 当前可获取性和能否完整替代，只能从调用契约判断，证据不足以认定已在 Ze 或当前用户设备验证。

## LocalDevVPN / Mobile Data Mode（后续补充源码定位）

`siboot-ref/SideInstaller/README.md:73` 将 LocalDevVPN 链到 App Store，`tunnel.rs` 以其将 `10.7.0.1` 路由回本机为前提。它承担可达性，不负责 Apple 证书、profile 或代码签名。其源代码/Network Extension 实现不在这份参考目录内，具体内部转发机制和重签后 entitlement 可用性证据不足。

Mobile Data Mode 是 0.22.0 beta 的人工切飞行模式流程，不是新 VPN 或绕签：listener 拒绝而 Apple 可达时提示进入；飞行模式且 LocalDevVPN 保持连接时尝试配对/建隧道；登录前关飞行模式等待网络；安装尽量复用已有隧道，失效则再请用户开飞行模式。README 明确 siboot 此版本该模式尚未在 iPhone 上跑过，特别是飞行模式下首次配对条目是否出现没有真机证据。

### 签名信任的直接实现证据

- `SideInstaller/rust-core/vendor/isideload/src/sideload/sideloader.rs:124` 的 `sign_app`：`ensure_device_registered` → `CertificateIdentity::retrieve` → 注册 App IDs/app group（主 ID 添加 team ID 后缀）→ `download_team_provisioning_profile` → `sign::sign`。
- `.../cert_identity.rs:114`：读取/生成本地 RSA 私钥，先向 Apple 查找匹配公钥的证书；没有则 `request_certificate`（319 行）创建 CSR，调用 `submit_development_csr`，再取回 Apple 返回的 DER 证书。`.../dev/certificates.rs:211` 的请求名正是 `submitDevelopmentCSR`，携带 teamId、csrContent、machineName、machineId。不是用普通自生成证书骗过系统。
- `.../sideload/sign.rs:29`：解析 portal 返回的 provisioning profile，用签名私钥、叶证书、profile/内置 WWDR 中间链创建 `RustCryptoCmsSigner`；`sign_bundle` 生成签名。主包及每个 `.appex` 在封装前写 `embedded.mobileprovision`，entitlements 基于 profile；旧 `_CodeSignature` 会先移除。
- 该依赖当前对扩展采用“主包 profile/entitlements 复用”的策略；代码存在不等于任意第三方扩展的所有权限都获系统接受。不能照此承诺通用 IPA 兼容性。

结论：这条路线省去的是**用户购买/导入 `.p12` 与 profile**；Apple 在线签发的开发签名证书、账号授权、设备注册及 profile 仍在链中。代码证据支持“标准开发签名安装路径”，不支持“绕过签名校验”“永久安装”“无限 App”“无 Apple 账号”。系统最终如何在特定 build 校验、当前账号实际签出期限、启动/重启/吊销后的可用性，本次均**证据不足**。README 的 7 天/一年是上游说明，本次未读取实际签发 profile 验证。

证书额度触发 7460 时 `request_certificate` 可按策略进入 revoke 分支；Ze 后续不能未经明确选择撤销用户其他工具的证书。账号 developer token 的有效期与目标 App profile 有效期是不同概念。

### 新核对：宿主、依赖与移植授权边界

`keepalive.rs` 明确静音为 16 分钟（8kHz/8bit/mono），用 RAII 在退出时停止；无法保证任意长后台运行。`SideInstaller/ios-app/MobileDataMode.swift` 注释中的 iPhone 16/iOS 27.2.1/2026-11-26 测量属于上游记录，不能算本项目真机 PASS。`DeviceConnection.swift` 区分 VPN 的 Device IP（默认 10.7.0.1）与主屏“Connected to”地址；后者不能直接替换前者。

依赖分工：idevice 0.1.63 提供 RPPairing、TLS-PSK、RSD、设备服务；jktcp 0.1.8 处理隧道内软件 TCP；tokio 为异步/超时/进程；isideload 0.2.22（vendored）处理账号、portal、证书/profile 与 bundle 修改；apple-codesign-quick 0.1.0 处理 Mach-O、CMS、资源封装/嵌套签名；RustCrypto/RSA、plist、zip/deflate、reqwest、aws-lc 等是其构建/运行依赖。它们并不要求 Linux root 权限来替代 iOS 授权。动态网络与 Apple 接口仍会变化，需固定 Cargo.lock 和补丁。

许可证不能一概视为 MIT：siboot Cargo 声明 MIT；idevice/isideload Cargo 声明 MIT；apple-codesign-quick 声明 LGPL-2.1-or-later；SideInstaller `LICENSE.md` 是限制商业使用与官方二进制再分发的自定义许可证。siboot 直接编译子模块 `apple_session.rs`/`error_text.rs`，所以不能仅凭顶层 MIT 就把整套代码或官方 IPA 打包进 Ze。后续采用前需逐文件来源/许可证归档并解决相应授权和链接义务。本轮离线基础代码独立实现，不复制参考代码。

## 移植 Ze：逐项对照方案第 2 节

| 模块 | 可复用的 Ze 条件 | 必须新增/重写 | 当前条件给不了什么 |
|---|---|---|---|
| IPA 获取 | `Shared/ExternalFileImporter.swift:18` 的 security-scoped 读取、私有 inbox、去重思路 | 安装器独立收件/任务目录、安全 ZIP 与包检查；用户明确选择安装 | 现有附件导入不是安装授权，不能自动消费聊天附件 |
| 工具运行 | `Agent/ISH/ISHExecutionCoordinator.swift` 的任务调度与 rootfs | 重编工具或原生 Rust/C/Swift 集成、依赖 pin、错误/取消接口 | Minis 的 ARM64 Linux musl 静态发行物不能直接当 Ze guest 或 iOS 可执行文件；未证明 Ze guest 具备对应 ABI/系统调用。不能因 iPhone CPU 为 ARM64 就宣称 Linux ELF 可直接执行 |
| 原生桥接 | `NativeOffloads/NativeOffloadUtils.h:83` 的 stub、JSON envelope、guest→host 路径转换 | 原生 Bonjour pairing 服务声明、发布/转发、配对 responder、前后台协作；亦可直接原生实现避开 guest | 没有 minis-bonjour 的等价契约；guest 无宿主特权，复制命令名无效 |
| 网络 | `Info.plist:264` 已有局域网用途描述、普通网络 API | 配对、服务发现、TLS-PSK/CDTunnel/RSD、有限重连与会话生命周期 | 未找到完整设备管理客户端；已有局域网提示不等于获配对/安装权 |
| VPN | 普通联网可用，首版依赖外部 LocalDevVPN | 外部 App 引导、路由可达性探测、断连归因；可参考 `localdevvpn://enable` 调用契约 | `Ze.entitlements` 没有 Network Extension；不能据此自建 VPN。本轮不需加 VPN target 或 App Group |
| 密钥保管 | `Shared/RemoteServers/RemoteServerSecretStore.swift` 使用 Keychain、非同步、WhenUnlockedThisDeviceOnly | 独立 service/account 命名、配对记录和签名密钥封装、脱敏诊断 | siboot fs-storage / `~/.siboot` 不满足 Ze 的密钥隔离；不能直接迁入普通 rootfs 或默认云备份 |
| 应用处理 | Foundation 文件 API；本轮独立实现离线检查 | 安全解包、Mach-O/扩展检查、后续 profile/entitlement 策略和签名后端 | 目前 Ze 分发签名不授权其他目标 App，也不能导出全能签的私钥；通用第三方 IPA/加密 executable 未验证 |
| 后台与进度 | 现有任务展示/保活基础 | 独立事务、证据查询、取消与迟到回调隔离、重进前台恢复 | 不能保证后台无限时长；首版关键段要求前台。上游“installed”文本不能直接继承为成功证据 |

“能直接搬”应理解为可以参考协议/算法与已有 Ze 基础接口，而不是无条件复制整套 SideInstaller。路线特有部分（配对、隧道、签名、授权义务）留到阶段 1 真机证据后决定；本轮包检查和事务骨架完全路线无关。

## LocalDevVPN 的来源与位置

参考 README 给出的获取渠道为 Apple App Store `https://apps.apple.com/app/id6755608044`，与 Open Minis（id6759188481）是两个独立 App。`SettingsView.swift:247` 和 `DeviceShortcuts.swift` 显示 SideInstaller 可通过 `localdevvpn://enable` 请求启动并返回；这不是内置 VPN 实现。流程必须在向设备服务拨号前连接它；下载 GitHub 内容可在切换到它之前完成，因为 iOS 的常规使用条件下一次只有一个 VPN。当前 App Store 是否可下载、用户所在区可用性、实际 VPN 配置和重签后的签名权限，**证据不足**，没有替用户安装或联网查询商店状态。

## 协议实现补充与未证实项

`idevice/src/remote_pairing/responder.rs` 使用 SRP-3072/SHA512 完成 M1–M6 的 PIN 配对，交换长期身份；`remote_pairing/mod.rs:125` 的 pair-verify 使用 X25519 共享密钥、HKDF-SHA512、ChaCha20Poly1305 与 Ed25519 身份签名；`create_tcp_listener` 请求设备开 listener，后续 TLS-PSK 使用会话密钥。它们是管理会话身份，不是 Apple 代码签名证书。RSD/RemoteXPC 提供服务发现，AFC 和 installation_proxy 在隧道内工作；本次最小安装路径没有挂载 DDI 的调用。SideInstaller 的 JIT/位置/DDI/cryptex 工具是旁支，不能把这些可选服务都说成 siboot 安装必需权限。

`minis/download.rs` 取 GitHub latest release 并缓存，记录下载 SHA256；该记录用于诊断，不应等同于可信独立发布摘要验证。生产固定发行版本、官方来源及预置摘要是后续要求，不能把 `latest` 和远程脚本直接接到 Ze。

上游 fake iPhone、mock Bonjour/player、loopback 服务和账号错误测试只能证明实现路径；不能替代 iOS 系统校验或本机首次配对。本次没有重跑上游 Rust 测试，也未验证预编译 siboot ELF 与源码可复现对应。参考目录未提供 Open Minis/LocalDevVPN 本体、Apple 服务端或系统签名校验器，以上缺口均不能从客户端代码反推为已证实。

## 阶段 0 判定与下一步

- 信任来源已查明到客户端证据：**Apple Account 开发签名路线**，不是免除签名或无限期信任的特殊通道。免费账号仍需续签，证书/profile/额度/吊销仍成立。
- Open Minis 的关键桥接有可替代的原生实现方向；尚不能认定必须依赖已下架的 1.16，但能否在用户当前 Ze 分发条件、iOS build 和网络环境下替代，仍须阶段 1 验证。此结论不是“Ze 已支持首次自配对”。
- 后续真机先测：具体系统 build、Ze 签法、LocalDevVPN 版本；无旧配对的 Bonjour/授权/反向连接；保存与重启恢复；隧道和 lockdownd 查询。再用自有最小未加密 IPA 测 Apple profile、安装查询、实际启动、重开与重启、到期观察。
- 本轮 CI 仅做包处理、离线事务及关键保障变异；不虚构协议录制向量，不实现真实配对/签名/网络，不登记主工程或 UI。签名/profile、协议、UI、真机栏目明确为 NOT TESTED，不能显示整体设备能力 PASS。

### 提交后补核

`account.rs:179` 将用户选定团队通过 `sideloader.set_team` 固定，撤证策略为交互式 Prompt；未发现无需账号的签名旁路。`apple_session.rs` 缓存的是 adsid 与 `com.apple.gs.xcode.auth` token，按 Apple expiry 提前十分钟过期，与 App 的七天 profile 无关。私钥为本地生成/复用的 RSA-2048（`cert_identity.rs:257`）。

`installation_proxy.rs:414` 的安装 RPC 等待 `Status: Complete`，读取 ErrorDescription 与 PercentComplete；RSD 服务名为 `com.apple.mobile.installation_proxy.shim.remote`。因此上文“RPC 返回”具体指安装服务完成消息，不仅是请求被接收；仍缺少独立 bundle/version/build 查询与真实启动确认。SideInstaller `PairingController.swift:423` 使用原生 `NetService` 发布 pairing 类型，`Info.plist:74` 声明了该类型，进一步支持 Ze 未来可考虑原生替代 Minis 桥接的方向，但不是本项目真机可行性证明。
