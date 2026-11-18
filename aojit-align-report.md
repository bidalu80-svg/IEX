# Ze AOJIT 对齐交付报告

日期：2026-11-19。基线 Ze `2e0fdee44bf45c2fd1cbb531a14c5dd072a23bc3`；参考 OpenMinis `1a71df0f381cefde80bf912b723de6f9831bc177`，声明的 ish 子模块 `0fd17a135e78b7a0cf08a4f5831217bbb76ed22f`。逐项依据原始 `aojit-compare.md`。

**已完成可落实的应用层及录制配置修改；二进制镜像尚未对齐。** 本轮没有生成或替换任何真实 AOT `.o`，24 个现存对象与基线逐字节一致，Node 仍没有对象。25 项下一轮录制目标不能作为当前已链接 25 镜像的证据。也没有运行 iOS 编译、设备速度测试或真实包恢复。

## 提交顺序与交付方式

先恢复工作区进度并本地提交，再补完实现并提交，随后自查；发现问题另起修复提交：

1. `403be74a`：保存上轮中断的启动同步、统计和状态接线进度。这是中途检查点，探测文件当时尚未补齐。
2. `97b6bebc`：补齐 ELF 探测、25 项精确录制配置、受镜像身份约束的核心包 Restore。此提交后开始自查。
3. `12d595b4`：自查修复探测缓存辅助函数、库 soname 探测、Restore 所属 target、录制 ABI 来源及矩阵任务，并加入回归检查。
4. 本报告及录制导入回归测试补充另行提交；最终提交集合以 bundle 的 `refs/heads/aojit-align` 为准。

环境将原 `.git` 挂载为只读，原仓库提交命令创建 `index.lock` 被文件系统拒绝。因此本地提交保存在克隆根目录 **`./aojit-align-git.git`** 的独立可写 Git 元数据中；没有修改原 `.git` 的 HEAD/index。用 `git --git-dir=./aojit-align-git.git log` 查看提交。`./aojit-align.bundle` 包含从基线之后的全部本轮提交，前提是接收仓库已有上述 Ze 基线。没有 push 或发布远程变更。

在有可写 `.git`、包含该基线的接收克隆内导入：

```sh
git bundle verify ./aojit-align.bundle
git fetch ./aojit-align.bundle refs/heads/aojit-align:refs/heads/aojit-align
```

`aojit-compare.md` 和 `openminis-ref/` 是保留的输入材料，没有将整个参考克隆提交进交付。

## 对应原报告差异 1–10

| 原条目 | 结论 | 本轮落实及边界 |
|---|---|---|
| **1 SQLite** | **应用层自洽已修复；libsqlite3 镜像待录制** | `AOJITModuleProbe` 读取真实链接对象元数据；当前 `aot_sqlite.o` 含 `_sqlite3` 时，catalog 名称、路径、`imageMatch`、包归属均指向 Python binding，版本使用当前实物的 `python3 3.12.16-r0`。不再把它描述成 libsqlite3。`aot/VERSIONS.txt` 删除不能代表该对象归属的 sqlite-libs 项。下一轮 manifest selector 改为 **`libsqlite3.so`**，调用参考的 `net/sqlite_train.sh`；`aot-targets.json` 指定 `/usr/lib/libsqlite3.so.0.8.6`、`sqlite-libs=3.48.0-r4` 和 `0cd2f33152f67d2b77c8468184bbe0cef1d7e7f2`。新对象替换后，catalog 根据实际元数据切换为 libsqlite3。当前仍是 Python binding，不能写成已与参考 SQLite 镜像一致。 |
| **2 Node 镜像集合** | **目录、有效清单、录制配置已对齐；对象待录制** | 加入第 25 个 catalog 项 `/usr/bin/node`，精确目标 `nodejs 22.23.2-r0`；有效 manifest 的 nodejs 行不再注释，使用参考 `node/node_train.sh`，超时 10800 秒。旧 `node.sh` 也改为严格参考负载包装器。Node 使用引擎默认模式，不带 jitless override。删除旧 VERSIONS 中仅代表安装、无镜像的 Node 记录。安装了 Node 但无链接对象显示 **No Image**，不会伪造项目链接项。工作流按镜像分作业。 |
| **3 包版本与模块身份** | **下一轮版本及身份声明已对齐；现存 14 项不同输入待录制** | `scripts/aot-targets.json` 保存参考全部 25 项 package/version/path/build-id/family。录制前逐一验证精确包及 ELF build-id；移除 musl/busybox 升级到仓库最新版的录制逻辑，安装任一精确版本失败即停止。当前 Swift `imageVersions` 与 `aot/VERSIONS.txt` 继续描述当前对象，没有把 r12/r14/3.12.16/PCRE r1 擅改成 r8/r8/3.12.15/r0。`sync-aot-objects.py` 在正式导入一套新对象及其 VERSIONS 时同步链接列表和实际版本表。 |
| **4 训练与质量门槛** | **录制配置已改；实际训练、覆盖及镜像待录制** | 有效 manifest 的 25 项都指向参考声明的训练负载；可取得的 PCRE2 负载原样复制。其他负载依赖缺失的 pinned ish benchmark suite，准备脚本/工作流获取并要求该版本、执行其文档中的 installer，不以旧 Ze workload 顶替。TLS 使用 host 生成证书、guest requests、本地 TLS 套件；crypto/ssl/PCRE2 dry-run 和 recording 均拒绝 FAIL/缺标记，设置 15000/5800/4100 translations 下限。新独立录制流程的所有 workload 非零退出均失败。修复轮另已移除主构建内联录制路径：无现存对象时硬失败，不受 AOT_FULL 影响；旧 vendor record.sh 入口也明确禁用并报错，不能绕过参考负载准备、精确身份检查及新 recorder。逐镜像输出隔离，25 个对象/汇编及身份 ledger 齐全才汇总 artifact；保留核心 exact/family 命中检查。当前参考 suite 源码与旧 APK 尚未取得并运行，installer 接口、fixtures 及全部真实录制流程仍待实跑；现存覆盖范围和性能不宣称一致。 |
| **5 开关启动同步** | **必经路径已修复；设备复现未做** | `ISHKernel.bootWithRootPath` 在 `become_first_process()` 前同步读取持久化 key `aojit.enabled`，无条件应用 true 或 false；setter 先强制完成 native `jit_init`，避免 init 覆盖 saved false。store 初始化也同步一次，coordinator 的一次性诊断不再被 isEnabled 条件挡住。底层 setter 同时同步 `jit_control` 的 AOT admission 和 Ze 原有 `jit_on` 回读。保留 Ze 已有偏好 key，不破坏用户保存值；并未宣称两个项目的变量或接口完全相同。静态启动顺序及生产 C setter 冷启动 false/后续开关回归通过；设备上的首条 guest 指令行为尚未实测。 |
| **6 探测与状态证据** | **实现口径已对齐；iOS 运行验证未做** | 新文件 `Agent/ISH/AOJITModuleProbe.swift` 在 host 读取 guest ELF 前 64 KiB，按 PT_NOTE/GNU build-id 校验，最多跟随四次 fakefs/实际 symlink；对常见库从 soname 找当前实际文件，避免只读旧版本全路径。由 native 新增只读元数据接口取得**实际链接对象**的 build-id/family，不拿未来目标冒充现存镜像。Available 要求 build-id 匹配且有可用链接镜像；family 为 Partial，另列 Mismatch、Rejected、No Image、Not Installed。Rejected 优先。移除包版本相等和 runtime path fallback 推出 Available 的分支；探测不依赖 boot，包版本缓存只供文字参考。另修正 Python math 的路径匹配，防止误撞 NumPy 的 `_umath`。 |
| **7 设备 Recording / Rebuild** | **误导行为及文案已修正** | 移除自动设备 warm-up 调用和旧 recorder 实现，删除 Recording 状态/文案，改为 Checking；说明明确新镜像需要 host 录制、编译和新 App build。旧 JSON 的时间/耗时字段保留为历史兼容数据，既不生成镜像，也不决定 Available；`rebuild()` 仅清历史后刷新，注释明确无录制含义。No Image 行用 Recording target 标签，避免对 Node 声称 Recorded from。 |
| **8 在线 Fix / 核心 Restore** | **在线精确版本已对齐；Restore 已移植，启用及实跑受待录制约束** | repair 只执行 `apk add package=targetVersion`，删除无版本 fallback，并核对安装后的完整 `package-version` 才成功；每次在线 Fix 都确认，kernel 未 boot 提示先开终端。核心项不再走在线 Fix。新 `AOJITRestore.swift`、文件 staging、确认入口及 app Resources 接线移植参考 Restore；脚本和 5 个 APK 原样保留，含 rollback 下载、world 保存、simulate、健康检查及退出码 11/12/13/14 说明。**当前 musl r12/busybox r14 镜像与随包 r8 APK 不对应，因此入口保持不可用**；只有链接对象 build-id 真正变为参考 r8 才提供 Restore，避免宣称安装 r8 修好了当前镜像。没有在本轮安装/回滚任何 guest 包。 |
| **9 统计** | **分母和逐命令接入已修复；Swift/设备日志验证未做** | 设置页改为 **hits / total block attempts**，不再把 hits 重复加入分母，与 ConfigRegistry `hit_rate` 统一。移植 `AOJITShellStats`、`AOJITRuntimeStatus`，在 `shell_execute` 实际执行前 begin、正常或 catch 得到结果后 end；解析 host `jit_describe`，记录开关状态、耗时、exit、overlap、blocks/installs/moved 和逐模块增量/比例。保留 100 字符截断、负增量钳零、非满额不显示 100% 的参考行为。统计仍是全局快照差，终端/后台和并发活动可混入；不是 CPU 时间。Ze 双变量关闭后 total 尝试的原生行为没有改写成 OpenMinis 整个引擎，不能用 off 的零计数推断没执行 guest 工作。 |
| **10 原生核心** | **最小必要接口已改；完整源码同一性未做/无法确认** | 仅增加读取注册镜像元数据的接口，并把 Ze setter 同步到既有 `jit_control`；没有改 `aot_module`/translation 布局、gadgets 或 JIT_CODE_VERSION，未故意更改镜像 ABI。参考 `deps/ish` 为空，无法对其匹配算法、生成器、gadgets、计数实现完整直接 diff，也没有声称 native 源码或二进制相同。缺失源码与参考镜像实物的边界仍存在。 |

## 待录制

**以下 25 项均未在本轮重新录制。** 其中 14 项 guest build-id 不同、SQLite 目标模块不同、Node 缺对象；另外 9 项虽按原报告输入身份相同，也没有覆盖/原生代码同一性证据，需以参考训练负载重录后验证。具体精确 build-id/family/workload 全表见 `scripts/aot-targets.json`，本表列出包版本及原因。

| 目标 | 下一轮精确包版本 | 当前边界 |
|---|---|---|
| musl | `musl=1.2.5-r8` | guest build-id 不同 |
| busybox | `busybox=1.37.0-r8` | guest build-id 不同 |
| python3 | `python3=3.12.15-r0` | guest build-id 不同 |
| nodejs | `nodejs=22.23.2-r0` | 当前没有 Node 镜像 |
| pillow | `py3-pillow=11.0.0-r0` | 输入身份相同；训练/覆盖及原生代码未证同一 |
| libwebp | `libwebp=1.4.0-r0` | 输入身份相同；训练/覆盖及原生代码未证同一 |
| libjpeg | `libjpeg-turbo=3.0.4-r0` | 输入身份相同；训练/覆盖及原生代码未证同一 |
| numpy | `py3-numpy=2.1.3-r0` | 输入身份相同；训练/覆盖及原生代码未证同一 |
| zlib | `zlib=1.3.1-r2` | 输入身份相同；训练/覆盖及原生代码未证同一 |
| sqlite | `sqlite-libs=3.48.0-r4` | 当前是 Python _sqlite3，需换录 libsqlite3 本体 |
| libcrypto | `libcrypto3=3.3.2-r4` | 输入身份相同；训练/覆盖及原生代码未证同一 |
| libssl | `libssl3=3.3.2-r4` | 输入身份相同；训练/覆盖及原生代码未证同一 |
| pcre2 | `pcre2=10.43-r0` | guest build-id 不同 |
| ssh | `openssh-client-default=9.9_p2-r0` | 输入身份相同；训练/覆盖及原生代码未证同一 |
| scp | `openssh-client-common=9.9_p2-r0` | 输入身份相同；训练/覆盖及原生代码未证同一 |
| pyjson | `python3=3.12.15-r0` | guest build-id 不同 |
| pyhashlib | `python3=3.12.15-r0` | guest build-id 不同 |
| pyblake2 | `python3=3.12.15-r0` | guest build-id 不同 |
| pystruct | `python3=3.12.15-r0` | guest build-id 不同 |
| pydatetime | `python3=3.12.15-r0` | guest build-id 不同 |
| pybinascii | `python3=3.12.15-r0` | guest build-id 不同 |
| pymath | `python3=3.12.15-r0` | guest build-id 不同 |
| pyzlib | `python3=3.12.15-r0` | guest build-id 不同 |
| pysocket | `python3=3.12.15-r0` | guest build-id 不同 |
| pyselect | `python3=3.12.15-r0` | guest build-id 不同 |

录制前仍需取得 pinned upstream suite、其输入 fixtures 及全部精确旧 APK（当前 Alpine 仓库可能已移除这些版本）。缺输入会明确失败，不能退到最新版或弱负载后标记完成。本轮没有执行网络拉取该子模块、耗时录制或 `.o` 汇编。未来导入应整套替换 `.o` + 同批 VERSIONS，运行 `scripts/sync-aot-objects.py`，再做 App 编译和设备命中/速度验证。Restore 的核心 r8 入口也须在对应新镜像到位后验证。

## 提交后验证

- `python3 scripts/verify-aojit-status.py`：**54 checks passed**。
- `python3 scripts/test-aojit-alignment.py`：**16 tests passed**。覆盖精确版本不可得、同包版本错误 build-id、错误 emitting ABI、缺负载、TLS 标记/FAIL/exit、残缺及混合 ledger 拒收、导入版本/链接列表、资源 target、静态启动顺序和全部 24 个现存对象未变。合成测试使用临时 ELF/文本 marker，不是新录出的真实镜像。
- 其中 C 开关测试提取实际生产 `jit_control` / `ish_jit_set_enabled` / getter，经 gcc 编译并运行，验证初始化会先置 on 的情况下 saved false 仍关闭，后续开关双变量同步，无代码区和镜像时保持 off。初始化/环境边界使用 fixture；不冒充完整 guest 或 iOS 运行测试。
- Python 语法编译、工作流 YAML（25 项矩阵）及所有 run-block 的 `bash -n`、录制/Restore shell 语法、Swift harness C 边界 fixture 的 `cc -fsyntax-only` 均通过。
- `git -c core.whitespace=cr-at-eol diff 2e0fdee4 --check` 通过；逐个比对所有保留文本行的原行尾，**最终内容保留原 CRLF/LF，包括原混合行尾文件**。中断检查点里的 project 行尾扩散已在后续提交还原。
- Restore 脚本、5 个 APK、PCRE2 workload 与参考文件逐字节一致。
- `scripts/test-kernel-runtime.py --prepare-only` 完成生产声明抽取，**没有执行 Swift 编译或运行**。
- `bash scripts/test-aojit-swift.sh` 返回 **77 / SKIP**：当前 Linux 环境没有 Swift 编译器。该脚本准备了编译真实 production probe/report/stats 的独立 harness，但本轮未运行其 Swift 断言。**未执行 Xcode/iOS 完整编译、设备重启 false 首命令验证、真实在线 Fix/Restore/rollback、全部模块命中验证或速度测试**。

新增功能主要放在新文件中。最终交付只把已实现的代码/配置称为已修改，所有真实镜像及设备行为验证保留上述待办边界。
