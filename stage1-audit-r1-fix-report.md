# 阶段 1 astra r1 修复与验证记录

本轮基线：`086fe18`。先实现、本地提交，再检查；检查修复另起提交。未推送，不改任何既有 workflow；`siboot-ref/`、`vendor-ref/` 只读且不入库。本文件在最终全套运行前提交，之后冻结 HEAD 和全部受控文件；最终运行的提交号与 tree 摘要以证据 `summary.json` 为准，必须等于交付 HEAD。本文件不写入一个会因提交本文件而失效的“最终 SHA”。

## 逐项关闭对照

下表中的 PASS 指本地实现/回归检查，不代表 Apple 平台或真机通过。最终同树复跑由下述单一命令完成；若任何一项失败，则最终报告必须记 FAIL，并修复后换新目录全量重跑。

| 审核项 | 改动位置 | 回归测试 / 检查 | 本地判据与结果 |
|---|---|---|---|
| R1 首次执行前取消与旧资源清理 | `Installer/Sources/ConnectionExperimentCore/ConnectionProbeCoordinator.swift:55`、`:117`；`InstallerHost/NativePairingBackend.swift:81`、`:125`；`ConnectionContracts.swift:39` | `testImmediateCancelBeforeTaskRunsDoesNotReadOrPrepare`；`testStalePrepareReclaimsOnlyItsOwnSession`；真实 `SwiftABIContract.main` | 进入任务先查 token/取消；不读 Keychain、不建会话。prepare 接收 runID；过期任务仅清理自己的资源；原生调用返回前检查原 session 归属；失败 prepare 自行回收。初步 77 Swift 全过、真实 ABI 全过；最终同树复跑按证据核值。 |
| R5 宿主迟到回调 | `ConnectionProbeCoordinator.swift:130`；`Installer/Sources/ConnectionExperimentCore/ProbeCallbackScope.swift:6`；`InstallerHost/ConnectionExperimentLifetime.swift:19`、`:41`；`InstallerHost/ConnectionExperimentView.swift:58` | `testLateNotificationAuthorizationCannotWriteNextRun`；`testLateLifetimeCallbackCannotExpireNextLease` | 通知授权动作在注册时捕获当前轮 token；租约注册时生成独立 token 并绑定旧 expired 闭包，再跨 MainActor 跳转；释放先失效 token。心跳/旧音频通知同样门控；旧 PIN 通知完成只移除自己唯一 requestID。初步通过；最终同树复跑核值。 |
| R2 身份缺失显式化 | `ConnectionProbeCoordinator.swift:34`、`:59`；`InstallerHost/NativePairingBackend.swift:83`；`Installer/Native/src/lib.rs:164`；`InstallerHost/ConnectionExperimentView.swift:34`、`:153` | `testMissingIdentityRequiresConfirmationBeforeAnyPrepareOrSave`；`testOldIdentityCreationConsentCannotAuthorizeNextRun`；Rust `missing_identity_requires_explicit_creation_authorization`；真实 ABI 无授权 prepare 拒绝 | 首次模式发现 nil 先停止为 identityCreationRequired；明确告知“无记录，需要建立新身份”，说明无法区分首次使用与重签后原身份不可见。用户二次确认后，只有该缺失提示的 runID 可授权；新 run 开始/授权使用后失效。默认 Swift/ABI/Rust 均拒绝静默生成；保存的身份继续复用；访问错误不降级。初步通过；最终同树复跑核值。 |
| R3 发现范围及归因 | `Installer/Native/src/lib.rs:58`、`:63`、`:77`、`:108`、`:135`；`Installer/Native/README.md:18` | `discovery_set_covers_observed_port_and_full_dynamic_range`；`discovery_classifies_refusal_timeout_wrong_service_separately`；原 Swift `testRejectedReuseKeepsIdentity` | 16383 个候选：49152…65535 排除无关 lockdown 62078；优先49152/55021/65535；最多32并发、TCP200ms、协议1s、总30s。拒绝、超时、错误服务、身份拒绝分别返回。身份拒绝立即结束且不自动配对；总时限未扫完报超时，不能声称无服务。初步 Rust13全过；最终同树复跑核值。 |
| R4 系统发现补录 | `ConnectionProbeCoordinator.swift:158`；`InstallerHost/ConnectionExperimentView.swift:129` | `testDiscoveryCanBeAddedAfterQueryOrRouteBlockWithoutChangingConclusions`；`testDiscoveryConfirmationRejectsOldRunAndUnpublishedRun` | 查询完成/路由阻塞后仍可为当前显示的已发布轮次补录；必须显式 runID；开始新轮后旧 runID 拒绝；重复补录幂等；仅新增 systemDiscovery，不改任何连接/查询结论或终态。初步通过；最终同树复跑核值。 |
| R6 最终 HEAD 证据一致 | `Installer/run-stage1-local-review.py:26` | 一个入口顺序运行原完整流程、连接完整流程、Rust、真实ABI；开始/结束比较 HEAD、tree、全部受控文件摘要 | 最终证据需 status=PASS、treeUnchanged=true；core 和 connection 子证据提交均等于外层/交付 HEAD。macOS/iOS CI 仍待推送后运行，不以 Linux parse 或 ABI 合同替代 Apple 编译。 |
| R7 日志与来源记录 | `Installer/Native/README.md:8`；`Installer/Native/upstream/manifest.json` 的 loggingGuard；全套入口的原生 subscriber 扫描 | 生产集成与 Cargo 未安装 tracing subscriber；只读搜索副本确认三处敏感 tracing 仍存在；最终入口日志守卫 | 没有当前泄漏定案，也不声称上游没有敏感 tracing。启用原生日志前必须剥离 responder 身份TLV、socket 原始payload、xpc 解码等所有敏感内容，再验脱敏。来源 SHA/原摘要/补丁登记保留，不将 manifest 自洽当作独立上游认证。 |

R1/R5 主修复 `e71994a`；R2 `0f1c23f`；R3 `87d3ea2`，提交后编译自查修复 `16c9e0d`、`5939216`；R4/R7 `37d3a29`；R6/真实ABI回归 `8c568ff`。完整提交序列见文末。

## 发现策略的明确边界

沿用参考描述的 LocalDevVPN Wi-Fi 地址 `10.7.0.1`，不推导为蜂窝模式通用。优先端口在参考 `siboot-ref/minis/README.md:219` 记录过 55021；`:224` 描述动态端口可到65535。本轮覆盖完整动态候选集合，但受30秒发现窗口限制，不承诺一轮必定访问每个端口。超时固定分类 connectionTimeout；候选全部结束时，如有真实错误协议响应，返回 wrongService；否则依次为超时、其他断连、全拒绝。该聚合优先级只表示已取得证据，不能据 wrongService 推导其余端口不存在正确服务。已识别 RPPairing 后身份验证失败不会被聚合为 wrongService 或连接拒绝。

## 最终同树复跑命令与证据

最终整套命令：

```bash
PATH=/home/hatch/workspace/selfsign-tools/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:/home/hatch/workspace/selfsign-tools/rust/cargo/bin:$PATH \
RUSTUP_HOME=/home/hatch/workspace/selfsign-tools/rust/rustup \
CARGO_HOME=/home/hatch/workspace/selfsign-tools/rust/cargo \
python3 Installer/run-stage1-local-review.py \
  --evidence /home/hatch/workspace/selfsign-stage1-r1-final
```

入口会实际执行以下命令（完整 argv 和返回码写入外层 summary）：

```text
python3 Installer/run-review.py --evidence …/core
python3 Installer/run-connection-review.py --evidence …/connection
cargo test --locked --manifest-path Installer/Native/Cargo.toml
bash Installer/test-native-abi.sh …/native-abi
```

期望的最终核对值（须与最终证据一致才可报告通过）：

| 项目 | 应核对结果 |
|---|---|
| Swift 生产模块 | 77 项（原49 + 原连接20 + 本轮8）全部通过 |
| 脚本验证器 | 19 项全部通过 |
| Rust | 13 项全部通过 |
| 实际生产 Swift→C→Rust ABI | PASS；新增立即取消、无记录无授权、同 backend 下一轮、过期清理不伤新 session、失败后可重试 |
| 原两项 + 连接四项变异 | 六项各自 build=0、test=1，受控断言失败，无进程崩溃 |
| Apple API/Keychain/Bonjour/SwiftUI | 仅 Linux 核心、合同及语法检查；macOS/iOS CI 未跑 |
| 真机配对、VPN、查询、重开/重启 | NOT TESTED |

证据不会入仓库：外层 `summary.json`/`environment.json`/`source-sha256.json`；core 的 XML、19项脚本日志、两项变异日志；connection 的28项fixture与四项变异原日志；Rust日志；真实ABI日志。最终不再沿用上一轮十个文件不一致的证据。

额外检查：宿主 `swiftc -frontend -parse -D ZE_CONNECTION_EXPERIMENT InstallerHost/*.swift`、Linux 原生适配器类型检查、Python语法检查、`git -c core.whitespace=cr-at-eol diff --check 086fe18`、既有 workflow diff 为空、参考目录干净且未入提交。

## 提交记录

```text
e71994a fix(selfsign): isolate pre-start cancellation, native ownership and host callbacks by run
0f1c23f fix(selfsign): require explicit run-bound consent before creating a missing identity
87d3ea2 fix(selfsign): bound full dynamic-port discovery and preserve connection failure categories
37d3a29 fix(selfsign): allow run-bound discovery evidence after completion and document native logging guard
16c9e0d fix(selfsign): use pinned idevice IO error variant in discovery classifier
5939216 fix(selfsign): retain transport errors during saved-identity verification
8c568ff test(selfsign): freeze full local verification to one committed source tree
```
