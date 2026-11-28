# 阶段 1 首轮 macOS CI 修复记录

输入：run 46091122663，远端头 2d15fb6b；只读日志在 `/home/hatch/workspace/selfsign-stage1-ci/`。本地修复基线 c715667。未推送；任何 workflow、pbxproj、生产 Swift/Rust 后端、siboot-ref 与 vendor-ref 均未改动。流程为先实现提交，再自查；发现问题另起提交。

## 失败 1：SIGBUS 尚未定位，补足下一轮所需取证

证据：`job-140811994715.log:613` 报 Bus error，`:618` 返回138；原 `native-abi/contract.json` 为0字节。Rust、Swift、链接都完成，随后运行失败。原契约只有最终一次 stdout，因此空文件不能证明没有进入 Swift main，更不能定位到某个 FFI 调用。

代码链：`Installer/Native/SwiftABIContract.swift` 原流程先检查无授权拒绝和预执行取消（两者不会调用原生）；第一次允许新身份的 prepare 才会通过 `InstallerHost/NativePairingBackend.swift:85` 分配 NativeSession，其 init 调 `ze_connection_new`；随后异步 worker 调 `ze_connection_run("prepare")`。`Installer/Native/src/lib.rs:212` 的 new 创建 Tokio current-thread runtime；run 的 block_on 才进入身份生成、密码学及 JSON 应答。new/free 不在 run 的 catch_unwind 内；即使 run 内也不能用 catch_unwind 捕捉 SIGBUS。这是待定位路径，不是根因定案。

ring 0.17.14 的 `build.rs:199` 将 APPLE_ABI + AARCH64 一律映射到 `perlasm_format: "ios64"`，`:264` 的 APPLE_ABI 包含 macos 与 ios。因此 `*-ios64.o` 名字本身不是“把 iOS 目标误链进 macOS”的证据。日志中的 macOS15.5/15.0 部署版本警告也没有给出崩溃 PC；本轮没有据此改 ring 或 runtime。

改动：

- `Installer/Native/SwiftABIContract.swift:9`：固定标签立即写 stderr，15个进度点。首先单独 new/cancel/free 原生 runtime，再执行原有全部断言；保留原断言强度。无身份、PIN、密钥、payload 日志。
- `Installer/test-native-abi.sh:32`：契约带调试信息；Darwin 保存归档成员列表、可执行文件 Mach-O load commands，尝试生成 dSYM（失败记录日志，不替换原运行结果）。记录 Rust/Swift/主机/提交信息。
- `Installer/run-native-contract.py:45`：分别保存 stdout `contract.json` 与即时 stderr `contract-stderr.log`；`contract-result.json` 记录原始 returncode、signal、shell退出码。Darwin SIGBUS仍返回138，不因成功导出日志而通过；退出0但没有合法PASS契约也失败。
- 同文件 `:69`：失败保留契约二进制；最多等20秒，收集 `~/Library/Logs/DiagnosticReports/native-contract*.ips` / `*.crash` 中属于本次时间窗口的新报告；尝试限时45秒的 LLDB诊断重跑，保存 `thread backtrace all`。诊断重跑不改变第一次运行结果。如果系统未产报告、LLDB受限制或超时，结果文件如实记录，不伪造回溯。
- `Installer/test-native-ci.py`：模拟SIGBUS，验证原退出码、空stdout、stderr进度及保留二进制；构造Darwin报告目录，验证不采旧报告与其他进程报告。

Linux实际运行无法复现：修改后的真实 Swift→C→Rust 契约15个进度点全部走完，identityRoundtrip / listenerCancellation 全通过。**SIGBUS根因仍需下一轮macOS的最后进度点、崩溃PC/回溯来定位，本轮不声称修好了崩溃。**

## 失败 2：符号读取器与生产者不兼容

根因已定位：原 `Installer/build-native-ios.sh:24` 使用 Apple `xcrun nm -gU` 读取 Rust静态归档。`job-140811994530.log:407` 起明确报 Producer LLVM23.1.5-rust-1.100.1-stable / Reader Apple LLVM，不认识部分属性（Not an int attribute / Unknown attribute kind105），set-e因此中止。项目的 embed-bitcode=no 与关闭LTO并不能保证预构建Rust sysroot归档成员完全没有bitcode，不能据此称整份归档是Apple旧读取器都能读的对象。

改动：`Installer/build-native-ios.sh:27` 调 `Installer/check-native-symbols.py:23`，用 rustup为当前活动工具链安装 llvm-tools-preview，按同一rustc的sysroot与host解析配套llvm-nm。执行：

```text
<active-rust-sysroot>/lib/rustlib/<host>/bin/llvm-nm \
  --extern-only --defined-only --format=bsd <real-static-library>
```

读取器非0直接失败；记录工具路径、完整版本、原始符号与stderr。`:11` 精确要求全部五个外部代码定义（T）：`_ze_connection_new`、`_ze_connection_cancel`、`_ze_connection_free`、`_ze_connection_run`、`_ze_connection_string_free`。未定义引用、本地小写符号、相似名字均不能充数。比原来只grep一个名字更严格。

既有 workflow 中后续 `build-host-experiment.sh`（Ze OFF/ON完整模拟器编译/链接）、`build-device-experiment.sh`（真机目标链接及unsigned IPA）原样保留；最终Ze二进制仍需校验符号。修复读取器阻断后将继续到这些真实链接步骤，**本地Linux不能证明Apple链接器最终接受完整Rust归档**，这仍是下一轮CI必须取得的证据。

## 提交与本地实际验证

提交：`e8100cc` 实现崩溃取证、符号校验和回归；`7cc2b52` 提交后自查修复stderr管道未关闭警告；`8672b8f` 保存脚本回归日志并澄清sysroot bitcode边界。报告另行提交。

工具环境：Linux x86_64，Swift6.0.3；本机Rust1.100.1 / LLVM23.1.5，符号读取器与CI失败生产者同一版本轴。

| 实际检查 | 命令 / 证据 | 结果与边界 |
|---|---|---|
| 新脚本回归 | `python3 -W error::ResourceWarning Installer/test-native-ci.py` | 5/5通过；模拟SIGBUS受控、无管道泄漏警告；缺符号/读取器错误拒绝 |
| 原review脚本回归 | `python3 Installer/test-review.py` | 19/19通过 |
| 真实Linux契约 | 下方命令；`/home/hatch/workspace/selfsign-stage1-ci-fix-linux-final/` | PASS，15个stderr进度点，原始exit0；不是macOS崩溃已修复的证据 |
| 真实Rust归档符号 | `python3 Installer/check-native-symbols.py Installer/Native/target/debug/libze_connection.a /home/hatch/workspace/selfsign-stage1-ci-fix-symbols --elf` | 配套LLVM23读取成功，全部五个外部T定义存在 |
| Apple符号格式 | Linux clang分别以`-target arm64-apple-ios16.0`与`-target arm64-apple-ios16.0-simulator`编译五个C导出的真实Mach-O对象，ar打包，再执行同一check-native-symbols（不带--elf） | device/simulator两种对象均通过；只是符号命令形状及Mach-O解析验证，非完整Rust iOS构建或Ze链接 |
| shell/Python语法 | `bash -n Installer/{test-native-abi,build-native-ios,build-host-experiment,build-device-experiment}.sh`；Python py_compile | 通过 |
| 提交后差异/纪律 | `git -c core.whitespace=cr-at-eol diff --check c715667`；workflow/参考目录差异及参考仓库status | 通过；workflow差异为空，参考仓库干净 |

真实契约命令：

```bash
PATH=/home/hatch/workspace/selfsign-tools/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:/home/hatch/workspace/selfsign-tools/rust/cargo/bin:$PATH \
RUSTUP_HOME=/home/hatch/workspace/selfsign-tools/rust/rustup \
CARGO_HOME=/home/hatch/workspace/selfsign-tools/rust/cargo \
bash Installer/test-native-abi.sh /home/hatch/workspace/selfsign-stage1-ci-fix-linux-final
```

本轮未重跑未修改的77项Swift与13项Rust及变异全套，不把输入CI的通过结果算作本轮本地实测。下一轮需macOS实际契约/CrashReporter/LLDB取证、完整Rust iOS归档符号读取、Ze OFF/ON模拟器构建和真机链接。真实设备配对与查询仍未测。

无需编辑 `connection-experiment-review.yml`：既有两个job已经调用修复脚本，且 `if: always()` 上传 `stage1-connection-evidence/`，新取证全部写进该目录。没有workflow提交，也没有覆盖远端文件。
