# 实时录制输出交付报告

执行顺序：先实现并提交，再自查；自查发现的问题另起修复提交。

## 提交与交付

本克隆 `.git` 只读，直接 `git add` 报 `index.lock: Read-only file system`。使用 `/tmp` 中的独立 Git 元数据完成提交，并将两个提交打包到克隆根目录 `./progress.bundle`；本克隆 HEAD 未移动。

- 基线：`bfd1b120c48a4cfae23db9e4cc0b2523fc8a7e51`。
- 首次实现：`572e6798004e7536e12ffd4a24b44de65d622541`，在任何自查测试之前完成。
- 自查后的修复：`6660715cc747dd23035f0352b3e556794a29777b`。
- Bundle 引用：`refs/heads/progress`；需要上述基线。报告单独保存在 `./progress-report.md`。

## 改动范围

1. `scripts/record-aot.py` 的 `run_guest` 新增可选 `log_path`。负载执行时合并 stdout/stderr，使用 selector 按可读块接收，不等待整行；每块立即写入并 flush 控制台与日志，同时保留完整文本作为 `CompletedProcess.stdout`。增量解码沿用子进程原编码、严格解码与通用换行规则，处理跨块字符和 CRLF。
2. dry run 和正式录制分别传入原有的 `<id>.dry.log`、`<id>.record.log` 路径；日志在启动前打开并持续写入，失败或超时也保留已有内容。
3. `.github/workflows/aot-record.yml` 只为 `Upload images` 增加 `if: ${{ always() }}`，使录制步骤失败后仍尝试上传已有日志。原 artifact 名称、文件范围（包括 `*.log`）及其他流程不改。这一行直接用于交付失败录制的日志。

## 原判定如何保持等价

- 原逻辑在 stdout 中合并 stderr，并在结束后检查完整输出；新实现保持同样的合并方式和文本解码，返回完整、无额外前缀的输出以及客户机真实退出码。
- `check_output` 原文不变：退出码非零、任意位置含 `FAIL`、或缺少任一 `ok_marker`，都抛出原有错误，仍展示末尾 6000 字符。跨块出现的标记在完整输出中判定，不逐块判定、不提前认定成功。
- 仅有 `ok_markers` 的镜像执行 dry run，且 dry run 成功后才正式录制；其余镜像仍只录制一次。预检调用未传 `log_path`，继续走原来的 `subprocess.run` 收集路径。
- 原环境设置保留：强制 `ISH_JIT_PIC=1`，移除 `ISH_NODE_MODE`，保留调用方的录制路径和模块 selector。
- 原 timeout 参数直接用于总截止时间，涵盖输出读取和等待退出；不因收到新输出而重置。超时仍 kill、排空输出、等待回收，并抛 `TimeoutExpired`，其 `output` 保存原始字节。自查发现截断 UTF-8 会覆盖超时异常，修复提交仅在超时后的诊断流解码中允许替换截断字符，正常完成仍严格解码。
- `guest_file`、`build_id`、`preflight`、`manifest`、`check_output` 源码逐字比对相同；正式录制的 `check_output` 及其后的代码逐字相同。因此模块集合、翻译下限、build-id、ABI 门禁原文未改。targets、manifest、workload wrappers、Vendor 代码未改，全部 timeout 数值未改。

## 提交后自查结果

- 受控自查：`PYTHONDONTWRITEBYTECODE=1 python3 /tmp/test-aot-streaming.py`，最终 13 项通过。临时测试使用宿主机受控程序模拟客户机，不代表真实 ish/AOT 运行。
- 实时性：让客户机输出 stdout/stderr（均无换行）后等待外部放行；放行前读取到了录制进程输出和磁盘日志，且客户机仍未退出。
- 等价性：与基线 `run_guest` 对照完整 stdout/stderr、返回码及错误消息，覆盖成功、缺标记、FAIL、非零退出、空输出和换行转换；另测跨块 UTF-8、跨块成功/失败标记及 4 MB 输出。
- 超时：覆盖静默、已有输出、输出管道先关闭但进程仍在运行、UTF-8 字符被截断；均保持超时失败和已接收日志。测试使用独立的 0.2 秒参数，没有修改生产配置。
- 主流程：用受控客户机和模拟 preflight/recording loader 检查 dry run 选择、正式录制调用及三份对应日志；不作为真实门禁或录制结果的证据。
- 现有回归：`PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-aojit-alignment.py`，16 项中 15 项通过、1 项失败。失败为 `test_reference_table_and_effective_manifest` 要求 SSH wrapper 包含 `exec /bin/sh /tmp/aojit/ssh/ssh_train.sh`，实际 wrapper 先加载 sshd setup 再运行脚本，没有该 `exec` 字面。换回基线 recorder 单独运行同一测试，复现同样失败；相关文件本次未改，不顺手修复。
- 静态/交付检查：AST 语法解析、`git diff --check` 通过；workflow 与基线相比仅新增上述一行。`git bundle verify progress.bundle` 通过，并在另一份临时 Git 元数据中导入 bundle，确认最终提交和两个改动文件与工作区一致。

## 未实测范围

未运行真实 AOT 录制、musl/nodejs 训练或 GitHub Actions；环境缺少 `build-macos/ish`、`.aot-upstream` 和 `/tmp/rootfs`。artifact 的实际远端上传未实测，仅检查了 workflow 条件和现有日志路径匹配。客户机程序自身尚未写出或仍留在内部缓冲区的内容，不能由此转发器提前显示；本次不改训练脚本和其输出行为。
