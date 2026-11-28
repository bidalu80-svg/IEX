# 阶段 1 实现报告（2026-11-28）

实现基线 `6c49748`；报告前代码提交 `369be026699335c3487997136fe8fdd23796c2af`。本轮只本地提交，未推送、未触发远端 CI。输入方案为 `plan-stage1-astra.md`；`siboot-ref/`、`vendor-ref/` 未修改、未登记进 Ze。

## 交付与信任边界

已交付独立连接核心、真实 Rust/C ABI、Ze 手动实验入口、受限保活仲裁、离线证据与 CI 构建路径。普通构建不定义 `ZE_CONNECTION_EXPERIMENT`，不会构造原生会话、读取实验身份、监听、广播或请求通知授权。进入实验页也不开始；首次配对与继续已有记录、App 重开、设备重启分别记录。

状态机明确区分 listener、发布、系统人工发现、认证配对、持久化、TCP、pair-verify、TLS-PSK/CDTunnel、RSD 与本次查询。最终文案只有“本机管理连接与只读查询通过”。发布成功不代替系统设置发现；通道未齐/响应旧/字段缺失/身份不匹配都不进入终点。真机的宿主、首次连接、App 重开、设备重启四项当前全部 **NOT TESTED**；本轮不能称阶段 1 真机验收通过。

身份集合仅在独立 Keychain service `app.ze.connection-experiment.identity.v1`，account `host-identity-set` 内原子更新并读回；WhenUnlockedThisDeviceOnly，不同步，不指定共享 access group，不复用 RemoteServerSecretStore。后端只收发内存 JSON/plist，不产生明文配对文件，应用自定义文件备份没有配对文件入口。认证拒绝不自动删除；界面说明本地删除不等于系统撤销信任。

保活不调用聊天 activity 状态，不停止别人的播放器。未知旧音频占用保守阻塞；其他 intent、四条旧直写音频路径、系统音频中断、后台任务到期、租约心跳异常都终止实验。旧播放结束后 AVAudioSession category 可能残留；归属不明时页面明确要求停止播放，必要时重开 Ze，首轮不强抢音频。实际切系统设置后的存活与通知可达性仍须真机验证。

## 来源与 API 差异

采用 `jkcoxson/idevice` **0.1.68**，SHA `c8fff6d7fb2690eaeb591ce510754effa7b1e19b`，MIT。先查看 upstream `ffi/` 与 `swift/`：Swift 包只是 IDevice/plist XCFramework 包装；已有 FFI 的 PairableHost 整合了 mdns-sd 发布，隧道 FFI 返回通用 adapter/service 面。Ze 自写窄 ABI，Swift NetService 发布真实 native listener，不引入其完整 FFI 或 SideInstaller 的安装/账号实现。

与本机 siboot 所携的**已补丁 0.1.63** 比较：0.1.68 的 PairableHostInfo 新增 `allows_pinless_pairing`，握手/设置 PIN 分支随该字段变化；Ze 显式固定 false。两份参考的 RsdHandshake 和 RpPairingFile 文件逐字节相同（不是声称与公开 0.1.63 一致）；稳定 UUID 接口沿用 `new_with_uuid`。参考中的两版均为 rand 0.10，未把它误记为本轮 API 差异。

只启用 `ring, remote_pairing, tcp, tunnel_tcp_stack, rsd`。ring/rustls 是 0.1.68 核心 PairingFile 类型的编译依赖；实际管理隧道使用 upstream **native TLS 1.2 PSK**，不以普通 HTTPS 代替。只复制所选源码闭包；未带入安装、签名、DDI、JIT 服务源码。

受控副本额外补丁均登记 manifest：固定并校验 SRP 获得的 peer LTPK/identifier；校验 pair-verify M2 的签名/最终 State4/非零 DH；不调用会认证失败后自动 pair-setup 的 upstream connect；TLS server Finished 错误由“继续”改为拒绝，校验头/填充；CDTunnel 长度与参数严格验证；RPPairing magic 校验。不存在拿普通 TLS 或 stub 充当真后端的路径。独立线协议 fake peer 已覆盖错误 PIN proof 的真实 SRP 拒绝；完整成功 SRP/TLS/RSD 与设备互操作尚无真机正例，不推导为设备接受这些严格校验。

## 实测矩阵

| 项目 | Linux 实测 | macOS/iOS CI | 真机 |
|---|---|---|---|
| 生产 Swift 核心 + fixture | **69/69 PASS**（原 49 + 连接 20） | 新旧专项 workflow 推送后运行 | 不代表兼容 |
| 原脚本验证器 | **19/19 PASS** | 原专项 workflow 保留 | 不适用 |
| 原路径越界、上传当成功变异 | 两项编译 0 / 测试 1，均受控断言失败 | 待运行 | 不适用 |
| 发布当成功、TCP 当认证、查询失败回退、取消后迟到变异 | 四项编译 0 / 测试 1，均受控断言失败 | 待运行 | 不适用 |
| Rust 实际最小依赖 backend | **10/10 PASS**，含独立错误 SRP wire peer、RFC8032 验签/篡改、TLS alert/Finished、CDTunnel 边界 | macOS host tests 待运行 | 正例互操作未测 |
| 生产 Swift → C ABI → Rust 静态库 | **PASS**，身份/元数据往返、实际 listener、取消、损坏身份拒绝 | 同合同测试待运行 | 未测 |
| Apple Bonjour/Keychain/SwiftUI/音频 API | Linux 仅条件编译与语法检查，**不是 Apple 类型/链接验证** | 完整 simulator OFF/ON、device ON 编译和最终符号/Info.plist 检查待运行 | 权限/保存/后台未测 |
| Rust aarch64-apple-ios / aarch64-apple-ios-sim | **未构建**（无 Apple SDK） | 已提供真实构建步骤，**本轮未实跑** | 未测 |
| 宿主发现、配对、LocalDevVPN、只读查询、两种恢复 | **NOT TESTED** | CI 不能证明 | **NOT TESTED** |

本机：Linux x86_64，Swift 6.0.3，Python 3.12.3，Rust stable 1.100.1。原测试证据 `/home/hatch/workspace/selfsign-stage1-core-final/` 绑定提交 `22676b9`；连接证据 `/home/hatch/workspace/selfsign-stage1-connection-final/`；后续当前树另运行了全套 69 项 Swift。ABI 最终证据 `/home/hatch/workspace/selfsign-stage1-native-abi-verified/`；Rust 最终日志 `/home/hatch/workspace/selfsign-tools/stage1-rust-locked-final.log`。不是用户已核实的 `4728a848` 或旧 macOS run 证据。

实际命令（工具目录加入 PATH，Rust 的 CARGO_HOME/RUSTUP_HOME 指向 workspace 内持久目录）：

```bash
python3 Installer/run-review.py --evidence /home/hatch/workspace/selfsign-stage1-core-final
python3 Installer/run-connection-review.py --evidence /home/hatch/workspace/selfsign-stage1-connection-final
swift test --package-path Installer --parallel --num-workers 2 --disable-swift-testing
cargo test --locked --manifest-path Installer/Native/Cargo.toml
bash Installer/test-native-abi.sh /home/hatch/workspace/selfsign-stage1-native-abi-verified
swiftc -frontend -parse -D ZE_CONNECTION_EXPERIMENT InstallerHost/*.swift Views/ContentView.swift Providers/Voice/AudioSessionCoordinator.swift
bash -n Installer/*.sh scripts/build-share-search-simulator.sh
git -c core.whitespace=cr-at-eol diff --check 6c49748
```

ABI 首次实链发现 Rust LLVM23/Swift LLVM17 的元数据读取不兼容；已禁用 Rust LTO/嵌入 bitcode，隔离 ABI 构建目录，并经 `-Xlinker` 直接交给本机链接器，最终实际执行通过。仅语法 parse 未被记为 iOS 编译通过。

## CI 与远端核对的限制

只新增 `.github/workflows/connection-experiment-review.yml`，没有修改 build.yml、ipa-install-review.yml 或任何现有 workflow。新增文件前读取配置 origin：它是本机 `/home/hatch/workspace/codex-work/island-opt`，HEAD `0cc0863826b553083c4948959a596da5c2692e6d`，目标新文件不存在；该镜像无上游，gh 未认证。会话中已请求实际 GitHub 仓库地址，但未取得，**不能声称已与真实 GitHub 现行 workflow 核对**。本轮通过新增独立文件避免覆盖现有分叉，推送前仍须对实际 GitHub 新路径作核对。

没有可执行此次未推送代码的 macOS runner，本轮遵守“不推送”，未触发远端运行。新 job 会实际执行 cargo/rustup 的两个 iOS target 构建、完整 Ze 的 OFF/ON simulator 链接和 ON device 链接；失败会原样保留日志并使 job 失败，没有 stub 回退。iOS 原生后端集成仍是明确待关闭的独立验收项；在该 job 通过前不能把本轮代码当作已验证可装真机的包。CI 将产出未签实验 IPA 与摘要，保留 7 天，签名/安装由后续真机流程验证。

## 逐文件变更

| 文件 | 改动 |
|---|---|
| `.github/workflows/connection-experiment-review.yml` | 独立 macOS fixture/native ABI job 与 iOS 集成 job；always 上传、保留 7 天；未改现有 workflow。 |
| `Agent/Background/ChatPiPController.swift` | 仅专用标志下，在旧 PiP 音频激活前通知实验停止。 |
| `Agent/Speech/SpeechRecognitionManager.swift` | 仅专用标志下，在旧录音路径激活前通知实验停止。 |
| `Info.plist` | 登记 _remotepairing-pairable-host._tcp。 |
| `Installer/.gitignore` | 忽略 Python 导入缓存。 |
| `Installer/Native/.gitignore` | 忽略 Rust target 构建产物。 |
| `Installer/Native/Cargo.lock` | 锁定 Rust 传递依赖。 |
| `Installer/Native/Cargo.toml` | 最小启用 feature 与静态库；不启用 full/安装/签名/DDI/JIT；禁用跨 LLVM LTO。 |
| `Installer/Native/SwiftABIContract.swift` | 实际生产 Swift 适配器 + Rust archive 身份往返、listener/取消与损坏身份合同测试。 |
| `Installer/Native/include/ze_connection.h` | 不透明会话、串行调用、独立取消、事件/PIN 回调、输出所有权契约。 |
| `Installer/Native/src/lib.rs` | 内存身份、真实 Tokio listener、PairableHost、只复用 pair-verify、动态端口、TLS-PSK/CDTunnel、软件 TCP、RSD、限定 GetValue；10 项原生测试。 |
| `Installer/Native/upstream/LICENSE.txt` | 复制依赖的 MIT 许可证。 |
| `Installer/Native/upstream/manifest.json` | 来源 SHA、版本、原始逐文件 SHA256、裁剪清单、Ze 补丁清单。 |
| `Installer/Package.swift` | 新增 ConnectionExperimentCore、CConnectionABI 产品及直接编译生产模块的连接测试 target。 |
| `Installer/Sources/CConnectionABI/include/bridge.h` | 引用受控窄 ABI 声明。 |
| `Installer/Sources/CConnectionABI/module.modulemap` | Swift 导入窄 C ABI；不自行链接假库。 |
| `Installer/Sources/ConnectionExperimentCore/BonjourPairingHost.swift` | NetService 发布真实已监听端口；后端实例名/TXT；禁止自动改名；取消/完成撤销。 |
| `Installer/Sources/ConnectionExperimentCore/ConnectionContracts.swift` | PairingBackend、DeviceTunnelClient、PairingIdentityStore、PairingHost、ProbeLifetime 契约及分层证据类型。 |
| `Installer/Sources/ConnectionExperimentCore/ConnectionEvidenceRecorder.swift` | 无自由文本/原始错误载荷的脱敏事件、单调计时、生命周期、运行 ID、源码/宿主白名单元数据。 |
| `Installer/Sources/ConnectionExperimentCore/ConnectionProbeCoordinator.swift` | 显式单实验、总超时、取消、逐层证据、有序回调、身份读回校验、首次/两种恢复；只接受本次查询与同设备身份。 |
| `Installer/Sources/ConnectionExperimentCore/PairingIdentityStore.swift` | 独立 service/account；WhenUnlockedThisDeviceOnly；不共享、不云同步；缺失与访问失败分开；原子更新及读回。 |
| `Installer/Tests/ConnectionExperimentTests/ConnectionProbeTests.swift` | 20 项生产核心 fixture；失败分层、保存、复用、取消/迟到、脱敏与成功证据边界。 |
| `Installer/build-device-experiment.sh` | 真实 device 依赖/Ze + Rust 链接，生成未签实验 IPA 及摘要；不声称已签名或已安装。 |
| `Installer/build-host-experiment.sh` | 完整 Ze simulator 默认 OFF、专用标志 ON 两次编译；检查最终符号/Bonjour/源码绑定。 |
| `Installer/build-native-ios.sh` | macOS 上真实构建 device/simulator Rust archives；记录工具链、来源、锁文件/库摘要与导出符号。 |
| `Installer/run-connection-review.py` | 连接测试/四项业务变异独立证据；保留原始日志/XML，明确不代表原生或真机通过。 |
| `Installer/run-review.py` | 原验证流程仅增加忽略 Rust target，避免变异复制构建产物；19 项脚本测试保持。 |
| `Installer/test-native-abi.sh` | 实际编译生产适配器并链接 Rust；隔离 target；-Xlinker 避免 Swift 提取器解析 Rust std LLVM 元数据。 |
| `InstallerHost/ConnectionExperimentLifetime.swift` | 独立有期限后台执行/静音租约；监听音频冲突、心跳、资源释放，不写聊天状态。 |
| `InstallerHost/ConnectionExperimentView.swift` | 隐藏页的手动开始、外部 VPN 链接/确认、PIN/通知、实际复用模式、人工发现确认、分层结果、脱敏分享与显式本地删除。 |
| `InstallerHost/NativePairingBackend.swift` | 真实 ABI 适配器；串行 worker、会话/回调生命周期、按序回放证据、世代隔离；PIN 单独交给 UI。 |
| `Providers/Voice/AudioSessionCoordinator.swift` | 仅专用标志下的实验租约仲裁；占用不明/其他 intent/中断先停止实验。 |
| `Views/Chat/Media/VideoPlayer.swift` | 仅专用标志下，在旧视频音频路径激活前通知实验停止；原 CRLF 保留。 |
| `Views/ContentView.swift` | 仅专用标志下，关于 Ze 的版本点按 7 次解锁入口；进入不启动实验。 |
| `Views/Providers/ModelQuickTestSheet.swift` | 仅专用标志下，在模型音频预览激活前通知实验停止。 |
| `Ze.xcodeproj/project.pbxproj` | 只给 Ze 注册本地包/三个宿主文件；Ze 专属 Swift/链接参数默认空，避免污染扩展 target。 |
| `scripts/build-share-search-simulator.sh` | 仅 rsync 排除 Rust 产物和只读参考目录；原普通编译命令保持。 |

受控 idevice 子集逐文件清单（许可证、原始 SHA256 与补丁见 manifest；参考目录无变更）：

```text
Installer/Native/upstream/idevice/Cargo.toml
Installer/Native/upstream/idevice/src/cursor.rs
Installer/Native/upstream/idevice/src/darwin_errno.rs
Installer/Native/upstream/idevice/src/lib.rs
Installer/Native/upstream/idevice/src/obfuscation.rs
Installer/Native/upstream/idevice/src/pairing_file.rs
Installer/Native/upstream/idevice/src/provider.rs
Installer/Native/upstream/idevice/src/remote_pairing/errors.rs
Installer/Native/upstream/idevice/src/remote_pairing/lockdown.rs
Installer/Native/upstream/idevice/src/remote_pairing/mod.rs
Installer/Native/upstream/idevice/src/remote_pairing/opack.rs
Installer/Native/upstream/idevice/src/remote_pairing/peer_device.rs
Installer/Native/upstream/idevice/src/remote_pairing/responder.rs
Installer/Native/upstream/idevice/src/remote_pairing/rp_pairing_file.rs
Installer/Native/upstream/idevice/src/remote_pairing/socket.rs
Installer/Native/upstream/idevice/src/remote_pairing/tls_psk.rs
Installer/Native/upstream/idevice/src/remote_pairing/tlv.rs
Installer/Native/upstream/idevice/src/remote_pairing/tunnel.rs
Installer/Native/upstream/idevice/src/services/lockdown.rs
Installer/Native/upstream/idevice/src/services/mod.rs
Installer/Native/upstream/idevice/src/services/rsd.rs
Installer/Native/upstream/idevice/src/sni.rs
Installer/Native/upstream/idevice/src/tcp/mod.rs
Installer/Native/upstream/idevice/src/tunnel.rs
Installer/Native/upstream/idevice/src/utils/mod.rs
Installer/Native/upstream/idevice/src/utils/plist.rs
Installer/Native/upstream/idevice/src/xpc/errors.rs
Installer/Native/upstream/idevice/src/xpc/format.rs
Installer/Native/upstream/idevice/src/xpc/http2/frame.rs
Installer/Native/upstream/idevice/src/xpc/http2/mod.rs
Installer/Native/upstream/idevice/src/xpc/mod.rs
Installer/Native/upstream/idevice/src/xpc/xpc_macro.rs
```

## 提交顺序

实现提交先于各轮检查，检查发现的问题另起修复提交；未 squash、未改写历史。

```text
b0e60f3 feat(selfsign): add isolated connection probe contracts and evidence state machine
1c24e55 feat(selfsign): integrate pinned idevice backend through narrow memory-only C ABI
63dd729 feat(selfsign): wire explicitly gated Ze connection experiment and bounded audio lease
9c4415d feat(selfsign): register host files, hidden entry and audio ownership arbitration
1c5aac1 test(selfsign): add connection evidence runner and controlled semantic mutations
acde6a6 build(selfsign): add real iOS Rust archives and flag-off/on full Ze build checks
b7ee398 fix(selfsign): request SwiftPM parallel result export in connection review runner
d83b191 fix(selfsign): pin authenticated peer identity and require signed pair-verify evidence
6c33817 ci(selfsign): add separate connection fixture and real iOS integration jobs
d1a7483 fix(selfsign): stop experiment before legacy audio activation and fix entry conditional syntax
733e32f fix(selfsign): classify identity storage failures and bind lifecycle evidence to source
22676b9 test(selfsign): cover protocol proof tampering, negotiated parameters and storage failures
4bb0cb4 test(selfsign): exercise real Swift-to-Rust ABI identity and cancellation roundtrip
04bc9f5 fix(selfsign): scope PIN notification cleanup to its originating generation
38cf3bb fix(selfsign): keep Rust bitcode out of cross-toolchain Swift static linkage
2f44f5d test(selfsign): reject independent wire peer with invalid SRP PIN proof
2013916 fix(selfsign): show actual identity reuse and exclude local references from simulator staging
d58d37b ci(selfsign): verify final device Ze linkage and bind experimental IPA hash
ba69725 fix(selfsign): pass native Rust archive directly to linker and isolate ABI artifacts
369be02 docs(selfsign): distinguish fixture scope and record native source provenance in CI evidence
```
