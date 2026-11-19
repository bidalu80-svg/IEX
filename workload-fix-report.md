# ssh/scp 录制修复报告

## 交付与顺序

基线：`9833997722b50b185ebb0faaee390e68466d1bac`。进入本轮时，祖先提交 `6834a6f1` 已包含 `openssh-server=9.9_p2-r1`、sshd_setup.sh、两个 wrapper 的启动调用及 staging 复制。本轮在其上补齐实际启动、认证和生命周期条件，没有重做或改写 `e112d7d9`、`98339977`。

按“先实现、先提交，再自查”执行：

1. `a024aaa513670fe5c1248a0293604e9ec30d43a8`：实现后立即提交，随后开始自查。
2. `021bab31`：自查发现安装步未启用 errexit，补充宿主目录准备失败时退出，单独提交。
3. 本报告在上述代码提交及自查之后写入，随最终 bundle 交付。

原克隆 `.git` 为只读挂载，直接 `git add` 失败：`Unable to create .../.git/index.lock: Read-only file system`。因此在 `/tmp/workload-fix-delivery` 的临时 Git 克隆内提交，导出根目录 `./workload-fix.bundle`；原工作目录保留相同文件改动。bundle 以现有 `98339977` 为前置提交，只包含本轮新增提交，没有重新打包、改写两个已完成修复。原克隆分支 HEAD 未移动。

## 文件与位置

- `.github/workflows/aot-record.yml`，`Install the workload packages`（第 172 行起）：保留现有 `PKGS` 尾部的精确版本 `openssh-server=9.9_p2-r1`，独立于从 targets 表生成的包集合；修正注释中的 client 包名。新增仅限 matrix.image 为 ssh/scp 的宿主目录准备：`sudo install -d -o 0 -g 0 -m 755 /tmp/rootfs/var/empty`，失败立即退出。iSH realfs 的 stat 返回宿主 UID/GID（`Vendor/ZeNative/ish/fs/real.c` 的 copy_stat），普通 macOS runner 在客户机里不能把宿主目录改成 uid 0，故在宿主准备。现有活索引目标包检查和目标模块 build-id 检查段逐字节保留。
- `scripts/aot-reference-workloads/sshd_setup.sh`，第 9 行起：准备 `/var/empty`、运行目录、sshd 用户/组；不再吞掉建用户/组错误；已有正确 root 所有权时跳过 chown；`ssh-keygen -A` 生成 host keys。
- 同文件，第 29 行起：补齐 root 的 RSA/ECDSA/Ed25519 标准私钥（包含日志缺失的 `/root/.ssh/id_rsa`），把对应公钥加入 authorized_keys；解锁临时客户机的 root 账户，专用 sshd 配置只接受公钥，禁用口令和空口令认证。
- 同文件，第 50 行起：生成独立配置 `/tmp/aojit/ssh/sshd_config`，只监听 `127.0.0.1:2222`，允许 root 公钥登录，启用 internal-sftp 供默认 scp 使用。`StrictModes no` 仅用于此临时录制服务，适配 realfs 中 home/key 文件保留 macOS runner UID 的情况。先 `sshd -t`，再后台运行 `/usr/sbin/sshd -D -e`，日志写入 `/tmp/aojit/ssh/sshd.log`。
- 同文件，第 71 行起：wrapper 退出时 kill/wait 自己启动的 sshd；最多十次实际公钥认证并执行远程 `:`，检查成功且 sshd 仍存活后才进入参考负载。启动/认证失败输出 `FAIL` 和诊断日志并退出。
- `scripts/aot-workloads/ssh.sh`、`scripts/aot-workloads/scp.sh`，第 4 行起：改为 source setup，然后调用原 `/tmp/aojit/ssh/ssh_train.sh`；保留 wrapper 进程以执行清理 trap，不再 exec 掉 wrapper。
- `scripts/prepare-aot-workloads.sh`，第 15–17 行：已有 mkdir 和复制 setup 到客户机 `/tmp/aojit/ssh/` 的逻辑，足够接线，本轮未改动。

未修改 `.aot-upstream`；本地没有该 checkout，尝试下载固定 revision 的 ssh_train.sh 也因代理不可连接而失败，未声称完整复核过其正文。两个 wrapper 和 targets 均指向原参考负载路径；没有替换训练正文。

## openssh-server 版本证据及网络限制

首先尝试：

```sh
curl --fail --location --retry 2 --connect-timeout 15 --max-time 60 \
  https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/APKINDEX.tar.gz \
  -o /tmp/workload-fix-APKINDEX.tar.gz
```

本轮请求失败：`curl: (7) Failed to connect to hatch-egress-proxy port 3128`。随后普通直连尝试（`--noproxy '*'`）失败：`curl: (6) Could not resolve host: dl-cdn.alpinelinux.org`。因此本轮无法完成“curl 成功获取当前活索引”的要求，不能把缓存说成本轮活索引结果。

使用环境中事先存在的 `/tmp/main-apkindex.tar.gz` 和 `/tmp/main-index.tar.gz` 补充核对，二者 SHA-256 一致：

`5e066e7ad07b0984564e32a3fbd81d65062a3fff2cf61e5158f1a92e4432170f`

缓存 APKINDEX 中 server 条目的关键字段原文：

```text
C:Q1s2mQvzpW0cXI/9MU4UWYVG3UyGM=
P:openssh-server
V:9.9_p2-r1
A:aarch64
S:574818
I:1447352
T:OpenSSH server
o:openssh
t:1793869250
c:bbdd8314c8fb57b71e9d29366b7b7820245d1ce7
D:openssh-keygen=9.9_p2-r1 openssh-server-common=9.9_p2-r1 /bin/sh so:libc.musl-aarch64.so.1 so:libcrypto.so.3 so:libz.so.1
p:cmd:sshd=9.9_p2-r1
```

同一缓存的 `openssh-client-common`、`openssh-client-default` 也都是 `V:9.9_p2-r1`、`A:aarch64`，与 targets 表一致。该证据支持保留已有 server 精确版本，但缓存的下载来源与新鲜度在本轮无法独立确认。工作流仍在每次运行时获取活索引检查目标包，并以精确等号安装 server；版本不可用将停止录制。

## 提交后自查

- `sh -n`：sshd_setup.sh、ssh.sh、scp.sh 通过；`bash -n`：prepare-aot-workloads.sh 通过。
- 从工作流提取各 run 段，替换 GitHub 表达式后执行 `bash -n`，通过。这是 shell 语法检查，不是 GitHub Actions 或 macOS 实跑。
- `git diff --check` 通过。
- `git bundle verify ./workload-fix.bundle` 通过，前置提交为 `98339977`。
- 与 `98339977` 逐字节比对：`scripts/aot-targets.json`、`scripts/record-aot.py`、`scripts/aot-manifest.txt`、pcre_train.sh、prepare-aot-workloads.sh 均未变；版本、build-id、录制门禁、两个已有修复原样保留。
- 活索引目标包检查和目标模块 build-id 检查段逐字节未变；仅 ssh/scp wrapper 和专用 setup 改动，宿主目录准备由 matrix.image 限定。其他镜像负载与流程未改动。
- 缓存 APKINDEX 的三个 OpenSSH 包版本/架构字段解析比对通过。

本地没有完整 AOT 录制环境，没有 build-macos/ish，也没有可直接运行的本机 sshd。未实际执行 apk add、macOS sudo 目录准备、客户机 sshd 启动、公钥登录、scp 传输或 AOT 录制。以上仅为静态自查与交付文件检查，运行结果需完整录制环境实测。
