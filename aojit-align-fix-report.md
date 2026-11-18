# AOJIT astra 审核修复报告

日期：2026-11-19。仅处理本轮指定的 3 条缺口。修复起点 `44184c9677dfb891a75428819b3e3c1bd9e765ad`；全部交付的原始基线仍为 `2e0fdee44bf45c2fd1cbb531a14c5dd072a23bc3`。

实现先提交为 **`0d8727ce`**（`fix(aojit): close alternate recording path and isolate pending target versions`），之后才进行本轮自查和新增回归测试；未发现需要另起代码修复提交的问题。测试和本报告另行提交。所有提交位于 **`./aojit-align-git.git` 的 `aojit-align` 分支**，没有修改原只读 `.git`，没有推送。

## 1. 主构建备用录制入口：已修复

- `.github/workflows/build.yml:973` 将旧内联录制步骤替换为 `Require committed AOT objects`，移除 `continue-on-error`。存在已提交对象时只导出链接列表；没有对象时直接失败，`AOT_FULL=0` 或 `1` 均不能触发录制，也不再消费 manifest。
- `Vendor/ZeNative/ish/tools/jit_aot/record.sh` 明确禁用，打印原因并退出 1，不再调用 recorder/generator，也不能吞掉 workload 失败后生成镜像。
- 支持的录制工作流仍为 `.github/workflows/aot-record.yml`，使用参考负载准备、精确包版本与 ELF 身份检查，以及 `scripts/record-aot.py`；workload 非零退出即失败。旧入口不能绕过这些步骤静默生成对象。
- 已同步修正 `aojit-align-report.md` 差异 4 的说明，区分独立严格录制流程与已禁用的旧路径。

新增测试实际执行主构建的 YAML run-block：空目录下两种 `AOT_FULL` 均失败且不产物；有 marker 对象时只导出对象列表、原文件不变。另实际调用旧入口，验证返回失败、伪 recorder 未被调用、无输出镜像。marker 是临时文本测试材料，不是真实录制对象。

## 2. Node 安装确认文案：已修复

`Agent/ISH/AOJITAcceleration.swift:113` 新增 `hasRecordedImage`，依据实际链接镜像元数据和该项 `imageMatch` 判断，不依据安装状态或历史版本缓存。`Views/Rootfs/AOJITSection.swift:242` 的确认框使用此证据：有镜像仍写 recorded version；无镜像写 **recording target**，并明确 **No AOJIT image has been recorded for this target**。行内标签也使用同一判断。

因此 Node 未安装时仍可按精确目标安装，但不会把这个待录制目标称为已录制版本。测试检查了证据来源和两条文案分支；这是静态检查，未编译或实际操作 SwiftUI 确认框。

## 3. 参考版本字面与现存对象版本：已修复

`Agent/ISH/AOJITAcceleration.swift` 的现存对象 catalog 不再保存重复的版本常量，`repairVersion` 统一解析 `imageVersions[实际包名]`，旧 SQLite binding 分支同样解析 `python3`。当前仍为 musl r12、busybox r14、Python 3.12.16、PCRE2 r1；没有把现存对象声明改成下一轮参考版本。

Node 与未来 libsqlite3 分支通过新文件 `Agent/ISH/AOJITRecordingTargets.swift` 读取 **`scripts/aot-targets.json`**。在 `Ze.xcodeproj/project.pbxproj` 中将该原始录制配置加入 app Resources，将 helper 加入 app Sources，生产 Swift 不再复制下一轮版本字面。实际 `imageVersions` 始终优先；配置缺失或版本未知时返回空值并关闭在线安装入口，不能退为无版本安装。原有精确 `apk add package=version` 约束保持。

本轮涉及的未来专属完整版本字面 `1.2.5-r8`、`1.37.0-r8`、`3.12.15-r0`、`10.43-r0`、`22.23.2-r0`、`3.48.0-r4` 在生产 AOJIT Swift 中均无残留。保留的相关值及理由逐项如下，不能视为现存对象已换录：

| 位置 | 保留内容 | 理由 |
|---|---|---|
| `Agent/ISH/AOJITAcceleration.swift:182` | py3-pillow `11.0.0-r0` | 现存对象真实版本，恰与参考相同；属于 `imageVersions` 来源表。 |
| 同文件 :183 | py3-numpy `2.1.3-r0` | 同上，不能为隔离字面而删除真实来源。 |
| 同文件 :184 | zlib `1.3.1-r2` | 同上。 |
| 同文件 :186 | libwebp `1.4.0-r0` | 同上。 |
| 同文件 :187 | libjpeg-turbo `3.0.4-r0` | 同上。 |
| 同文件 :188 | libcrypto3 `3.3.2-r4` | 同上。 |
| 同文件 :189 | libssl3 `3.3.2-r4` | 同上。 |
| 同文件 :191 | openssh-client-default `9.9_p2-r0` | 同上。 |
| 同文件 :192 | openssh-client-common `9.9_p2-r0` | 同上。 |
| `AOJITRestore/musl-1.2.5-r8.apk`、`musl-utils-1.2.5-r8.apk` | 两个原有 r8 APK 的文件名和包内容 | 参考 Restore 资源实物，未改动，非在线 repair/install fallback。 |
| `AOJITRestore/busybox-1.37.0-r8.apk`、`busybox-binsh-1.37.0-r8.apk`、`ssl_client-1.37.0-r8.apk` | 三个原有 r8 APK 的文件名和包内容 | 同上。当前核心镜像身份不匹配，Restore 仍不可用。 |
| `Agent/ISH/AOJITRestore.swift:3` | 注释中的 r8 / r12 / r14 简写，及函数内两个参考 build-id | 说明并实施 Restore 的实物身份门槛，不是版本兜底；只有真正换录匹配镜像后才启用。 |
| `scripts/test-aojit-alignment.py:244`、`:248` | `22.23.2-r0` | 原有合成录制导入 fixture 和断言，不进入生产版本表；保留导入目标版本的回归覆盖。 |

完整下一轮目标仍只由录制配置声明；报告内的版本是说明文字。没有静默保留其他未来专属生产版本 fallback。

## 提交后自查结果

- `python3 scripts/verify-aojit-status.py`：**54 checks passed**。
- `python3 scripts/test-aojit-alignment.py`：**16 tests passed**，包括全部 24 个真实 `aot/*.o` 对原始基线的逐字节比较、精确身份/负载失败、录制导入和既有启动/统计断言。
- `python3 scripts/test-aojit-fixes.py`：**6 tests passed**，覆盖本轮拒绝录制路径、实际镜像证据/文案、全部 25 项版本来源及配置资源接线。UI 和 Swift 相关断言是结构检查，不是运行验证。
- Python 脚本语法检查通过；两份工作流 YAML 可解析，主构建 **63** 个、独立录制 **13** 个 shell run-block 的 `bash -n` 通过。相关录制/Restore shell 语法及 `AOJITHarness.c` 的 `cc -std=c11 -Wall -Werror -fsyntax-only` 通过。
- 对 `scripts/` 做双向 `rg` 扫查：新增 `hasRecordedImage` / `AOJITRecordingTargets` / recording target 文案，以及旧步骤名、`AOT_FULL`、`repairVersion`、recorded version 文案、旧 `record.sh` 路径、被移除的未来版本字面；同时逐一检查 `assertNotIn` / `assertNotRegex` 等否定断言。没有脚本依赖被移除的旧步骤名或宽松录制实现；旧路径在新测试中仅作拒绝执行和否定断言，旧 recorded version 文案保留给真正有镜像的分支。旧状态、warm-up、分母的否定断言继续通过。
- 扫查全部工作流及录制脚本调用点，实际支持的生产录制入口仍只走独立工作流的准备和严格 recorder。新旧脚本锚点未出现改名后漏查或把否定断言误判为正向依赖的情况。
- 对比修复前 `44184c96`，所有修改过的既有文件保留文本行的原始行尾均一致，包括原混合 CRLF/LF。`git --git-dir=aojit-align-git.git -c core.whitespace=cr-at-eol diff 44184c96 --check` 通过；未翻转整文件行尾。
- `scripts/test-kernel-runtime.py --prepare-only` 仅完成声明抽取；`bash scripts/test-aojit-swift.sh` 返回 **77 / SKIP**，本地无 Swift 编译器。

**未验证：Swift 编译、Xcode/iOS 构建、设备 UI/运行行为、真实录制、guest 安装和 Restore/rollback。** 24 个现存 `.o` 未改动；Node 仍无对象、SQLite 仍是 Python binding，原报告全部待录制边界不变。

## 交付

`./aojit-align.bundle` 包含从原始基线到 `refs/heads/aojit-align` 的全部提交（含上一轮四个提交与本轮实现/验证提交）。接收仓库必须已有基线。生成后检查 bundle 完整性，并在临时接收仓库导入、比较分支树及本报告内容。

```sh
git bundle verify ./aojit-align.bundle
git fetch ./aojit-align.bundle refs/heads/aojit-align:refs/heads/aojit-align
```
