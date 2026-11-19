# ssh/scp 修复轮：P1 + P2

## 交付与提交顺序

基线 `bfd1b120c48a4cfae23db9e4cc0b2523fc8a7e51`。先实现并提交 `919c96d6a3538aa41b675f0145ac682836b31be6`，然后进行本报告的自查。

原克隆 `.git` 是只读挂载，直接提交失败：`Unable to create .../.git/index.lock: Read-only file system`。代码在 `/tmp/workload-fix2-delivery` 的临时克隆内提交，导出 `./workload-fix2.bundle`；bundle 的前置提交为现有 `bfd1b120`。报告另作后续文档提交收入同一 bundle。原工作目录保留对应改动，原分支 HEAD 未移动。

## 改动文件与段落

1. `.github/workflows/aot-record.yml`，第 172–177 行（Install 步）：基础 PKGS 恢复为 targets 表钉版集合加 `py3-requests git ripgrep pcre2-tools bzip2`；只有 matrix.image 为 ssh 或 scp 时追加 `openssh-server=9.9_p2-r1`。原有只针对 ssh/scp 的宿主 `/var/empty` 准备保留。包版本和 build-id 的现有检查段未改动。
2. 同文件，第 224–232 行（新增 `Prepare SSH keys outside recording`）：放在 Stage 之后、Record 之前，仅对 ssh/scp 执行。复制仓库自有 ssh_keys.sh 到客户机，再以 `env -u ISH_JIT_RECORD -u ISH_JIT_RECORD_MOD build-macos/ish ...` 启动独立客户机进程。失败立即停止作业。
3. `scripts/aot-reference-workloads/ssh_keys.sh`（新增），第 1–28 行：承接全部 host/client 密钥准备，包括 `ssh-keygen -A`、三类标准客户端私钥生成、`ssh-keygen -y`、authorized_keys 写入、权限设置和 root 账户解锁。开头拒绝在带非空 `ISH_JIT_RECORD` 的环境执行，不作录制内补救。
4. `scripts/aot-reference-workloads/sshd_setup.sh`，原第 26–48 行改为现在第 26–32 行：删去全部密钥生成和导出公钥调用；录制内只检查准备好的七个密钥/授权文件非空，缺失就输出 FAIL 并退出。sshd 配置、启动、验活、训练前接线和清理保持原样。

`prepare-aot-workloads.sh`、ssh.sh、scp.sh 不改；本轮没有修改 `.aot-upstream`，没有替换训练正文。

## 录制内外边界依据

判据是 ish 进程启动时引擎读取的录制环境，而不是“是否执行在 ish 内”。`jit.c` 第 3409–3410 行读取 `ISH_JIT_RECORD` / `ISH_JIT_RECORD_MOD`；第 3083–3086 行的 module_path_has 用 `strstr`，第 2120–2121 行用它决定是否录制模块。

| 阶段 | 调用点与环境 | 密钥准备是否执行 |
| --- | --- | --- |
| Stage | 工作流调用 prepare-aot-workloads.sh；其 suite/install.sh 会启动 ish，但没有为训练设置 ssh/scp 录制变量 | 本轮不在此阶段执行新 key 脚本 |
| Stage 中 check-only | prepare 最后调用 record-aot.py --check-only；先 preflight，再在第 135–137 行提前返回，不进入 workload 循环 | 不执行 wrapper、setup 或 key 脚本 |
| ABI 探针（须单独区分） | preflight 第 89–96 行确实为独立 `:` 调用设置了临时 ISH_JIT_RECORD，selector 是 ld-musl；它只检查 ABI | 不执行任何 keygen；不与训练录制共享进程或文件 |
| 新增密钥步 | Stage 返回后、Record 步之前，独立 ish 调用；宿主 env -u 明确删除两个录制变量 | 全部 keygen 仅在这里执行；进程退出后才开始录制步 |
| 实际训练录制 | record-aot.py 第 156–158 行创建带 ISH_JIT_RECORD=目标 jsonl、ISH_JIT_RECORD_MOD=目标 selector 的 env，再 run_guest 启动 wrapper | setup 仅检查密钥；不调用新 key 脚本 |
| 模块门禁 | record-aot.py 第 171–173 行要求模块集合恰为 `{t['path']}` | 原样保留，没有忽略、过滤或接纳污染模块 |

ssh/scp 的 ok_markers 都为空，当前不会先跑 dry-run。即使以后增加 dry-run，setup 仍只消费已准备密钥，不生成密钥。录制外准备阶段未启动持续存活的 sshd；sshd 仍由录制内 wrapper 启动和回收。

## 逐二进制 strstr 自查

以下两列严格计算完整路径是否包含 `/usr/bin/ssh` 或 `/usr/bin/scp`。它们不按 basename 或目录名中的单独 ssh 字样判断。

| 二进制/命令 | ssh selector | scp selector | 调用与结论 |
| --- | --- | --- | --- |
| `/usr/bin/ssh-keygen` | 匹配（原 P1） | 不匹配 | -A、-q -t、-y 全部移至独立密钥步；录制 setup 没有执行调用 |
| `/usr/sbin/sshd` | 不匹配 | 不匹配 | 录制内配置检查 -t 和后台 -D -e，安全于这两个 selector |
| `/usr/lib/ssh/sshd-session` | 不匹配 | 不匹配 | OpenSSH 9.9 的会话子进程；路径由本地缓存的 9.9_p2-r1 包中二进制字符串和文件清单交叉检查 |
| `/usr/bin/ssh` | 匹配目标模块 | 不匹配 | 录制内验活及原 SSH 训练；它是目标本身。scp 通过该客户端传输也不会污染 scp selector |
| `/usr/bin/scp` | 不匹配 | 匹配目标模块 | 原 SCP 训练；只有 scp 任务收录此模块 |
| `/bin/sh`（Alpine 为 BusyBox） | 不匹配 | 不匹配 | wrapper、训练 shell 和验活远程命令 `:` 的 shell |
| `mkdir`（BusyBox applet） | 不匹配 | 不匹配 | setup 准备目录 |
| `stat`（BusyBox applet） | 不匹配 | 不匹配 | setup 检查 /var/empty 所有权和模式 |
| `chown`（BusyBox applet） | 不匹配 | 不匹配 | setup 条件修正所有权 |
| `chmod`（BusyBox applet） | 不匹配 | 不匹配 | setup 条件修正目录模式 |
| `grep`（BusyBox applet） | 不匹配 | 不匹配 | setup 检查 sshd 组和用户 |
| `addgroup`（BusyBox applet） | 不匹配 | 不匹配 | setup 缺组时执行 |
| `adduser`（BusyBox applet） | 不匹配 | 不匹配 | setup 缺用户时执行，-D 不交互设置密码 |
| `cat`（BusyBox applet） | 不匹配 | 不匹配 | setup 写配置、失败时打印日志 |
| `sleep`（BusyBox applet） | 不匹配 | 不匹配 | setup 验活重试 |
| `[`, `echo`, `kill`, `wait`, `.`, `trap`, `exit` | 无额外目标 ELF | 无额外目标 ELF | shell 内建；即使某 BusyBox applet走外部执行，路径也不含两个 selector |
| `internal-sftp` | 无独立 ELF | 无独立 ELF | 配置的 scp 服务端子系统，在 sshd 会话进程中执行；不调用外部 sftp-server |
| `/usr/lib/ssh/ssh-sk-helper` | 不匹配 | 不匹配 | 缓存 server 包二进制中存在的辅助路径；本轮普通 RSA/ECDSA/Ed25519 软件密钥不使用 FIDO key |
| `/usr/bin/passwd`, `/usr/bin/xauth` | 不匹配 | 不匹配 | 缓存 sshd/session 二进制中存在的其他程序路径；本轮不请求改密或 X11；账户解锁调用已移至录制外 |

动态库与加载器（如 `/lib/ld-musl-aarch64.so.1`、`/usr/lib/libcrypto.so.3`）路径不含上述两个完整 selector。录制内自有 setup 没有调用 ssh-agent、ssh-add、ssh-keyscan 或 ssh-keysign；前三者若从 `/usr/bin/ssh-*` 执行会匹配 ssh selector，不能因它们是“SSH 工具”就放过。

### 上游训练正文自查尚未闭合

本地没有 `.aot-upstream`，在可读 workspace 搜索也没有找到 ssh_train.sh。对固定 revision 原始 URL 的下载失败：`curl: (7) Failed to connect to hatch-egress-proxy port 3128`。因此上表已完整列出本轮自有 setup 的命令，并检查已知 sshd 会话辅助路径、ssh 和 scp 的 selector 关系；不能据此声称完整枚举了上游训练正文及其递归调用的每个二进制。

已请求提供该固定 revision 的 ssh_train.sh 及其调用的 SSH 脚本正文，以补齐这一项。若训练自身另有 `/usr/bin/ssh-*` 调用，仍须在拿到正文后处理；不会放宽模块集合门禁。此处是待补的源码自查条件，不是实际录制结果。

## 提交后检查结果与范围

- `sh -n`：ssh_keys.sh、sshd_setup.sh、ssh.sh、scp.sh 通过；`bash -n`：prepare-aot-workloads.sh 通过。
- 提取所有工作流 run 段、替换 GitHub 表达式后执行 `bash -n`，通过。
- 实际执行 Install 中的 PKGS 构造片段，遍历 targets 中全部 25 个 matrix 值：仅 ssh/scp 比基础集合多 server，其余 23 个均精确等于钉版集合加原五个附加包。没有执行 apk add。
- 在宿主用无副作用的 Python 子进程检查 env -u：即使父环境含两个录制变量，子进程中也不存在它们。
- 用带非空 ISH_JIT_RECORD 的宿主 `/bin/sh` 调用新 key 脚本：在 keygen 之前以退出码 1 拒绝执行；此检查没有生成真实密钥。
- 对所有已列出完整程序路径执行与 C strstr 等价的 Python 子串计算，结果如表。
- 对比 `bfd1b120`，targets、record-aot.py、manifest、pcre_train.sh、prepare、两个 SSH wrapper 逐字节未改；活索引目标包检查和 build-id 检查段逐字节未改。其他镜像的负载未改。
- `git diff --check`、`git bundle verify ./workload-fix2.bundle` 通过。

本地没有完整录制环境，没有运行 macOS/iSH 客户机、sshd、实际 SSH/SCP 训练或 AOT 录制。以上均为静态自查、宿主局部检查与 bundle 交付检查，未实测。上游训练调用链的源码缺口另如上明确列出。
