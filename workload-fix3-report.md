# 录制 #28 修复轮 3

## 基线、顺序与交付

基线：`aaca23873667b5bb2e9993ab2a1f13e630541074`。

先定位 pcre2 的随机字节错误、实现两项修复，再立即提交代码 `ec6467acf8bfccf8712bfe68c64b1da0310de536`；下文逐行自查、局部测试及 scripts 双向扫查均在该提交之后进行。报告另作后续文档提交。本轮不管理运行、不触发录制。

原克隆 `.git` 只读，`git add` 报 `Unable to create .../.git/index.lock: Read-only file system`。在 `/tmp/workload-fix3-delivery` 的临时 Git 克隆提交，成果导出到根目录 `./workload-fix3.bundle`，前置提交为 `aaca2387`；原工作目录保留对应改动，原分支 HEAD 未移动。没有重写任何已有提交。

## 失败一：SSH/SCP 传输输入遗漏

改动：`scripts/aot-reference-workloads/ssh_keys.sh` 第 30–32 行，在密钥和账户准备之后补齐上游 keys.sh 同时承担的 fixture 准备：

```sh
mkdir -p /tmp/aojit/ssh
[ -f /tmp/aojit/ssh/blob1m ] || head -c 1048576 /dev/urandom > /tmp/aojit/ssh/blob1m
```

目录不存在先创建，文件不存在才读取 1048576 字节，已有文件不覆盖。原密钥准备逐字节保留。未改 ssh_train.sh、sshd_setup.sh 或 wrappers。

录制边界不变：工作流 `Prepare SSH keys outside recording` 在 Stage 之后、Record 之前，仅对 ssh/scp 执行；通过 `env -u ISH_JIT_RECORD -u ISH_JIT_RECORD_MOD` 启动独立 ish。blob 创建与密钥准备位于同一录制外进程。录制器随后才为训练 run_guest 设置 ISH_JIT_RECORD / ISH_JIT_RECORD_MOD；新增 head 的路径也不含 `/usr/bin/ssh`，不引入上一轮 keygen 混录问题。

## 失败二：定因为客户机随机设备缺失，修复其准备与打开链

结论选择候选②：Git 在生成临时文件名所需随机字节时打开客户机随机设备失败。没有同时增加 TMPDIR 覆盖、Git 对象目录补建等无证据的兜底。

### 定因证据

1. 用户给出的首条错误是 `unable to get random bytes for temporary file: No such file or directory`，随后才是 create temporary file、insert into database。首个失败在随机字节获取阶段，不能把后续“临时文件失败”直接等同于 TMPDIR 或 objects 目录失败。
2. 候选①已由 CLI 源码排除。record-aot.py 的 run_guest 确实把宿主环境交给宿主 ish 进程，但 macOS CLI 实际入口为 main.c（meson.build 第 1803 行）。`Vendor/ZeNative/ish/main.c` 第 367–378 行重新构造传给客户机的 envp：TERM、HOME=/root、固定 Linux PATH，ARM64 另加 PYTHONMALLOC。没有复制宿主 environ，也没有 TMPDIR。`xX_main_Xx.h` 第 190–205 行复制的是这个显式 envp；后续注入表及 kernel/exec.c 第 877 行起的注入表均不包含 TMPDIR。宿主 JIT 环境变量供引擎自身读取，不能据此推断宿主 TMPDIR 已传入客人。
3. 录制器所有客户机调用使用 `ish -r <root>`。`Vendor/ZeNative/ish/xX_main_Xx.h` 第 58–67 行选择 realfs；第 97–107 行明确仅在非 realfs 时创建 /dev/urandom 等设备节点。工作流从 minirootfs 解压后，在本轮前没有创建 urandom backing path；prepare-aot-workloads.sh 也没有准备该路径。
4. `Vendor/ZeNative/ish/fs/real.c` 第 101–105 行：realfs_open 先 openat 客户机根目录下的实际路径；缺少 /dev/urandom 时直接返回 ENOENT，不会自动变成虚拟随机设备。realfs_mknod 对字符设备返回 EPERM（同文件 realfs_mknod），所以不能指望客户机 mknod 补出来。
5. 源码还显示一个必须同时处理的实现缺口：原 realfs_stat 虽把已存在的 /dev/urandom 映射成字符设备，但 `fs/generic.c` 第 61 行起通过 mount->fs->fstat 决定 fd 类型，第 90–100 行据此执行 dev_open。原 realfs_fstat 仅拷贝宿主 fstat，空占位文件会被识别为普通文件，读到 EOF；因此只 touch 文件仍不足以恢复随机源。
6. 真正随机源已实现：`fs/devices.h` 的 MEM_MAJOR=1、DEV_URANDOM_MINOR=9；`fs/dev.c` 的 dev_open 将 major 1 交给 mem_dev；`fs/mem.c` 将 minor 9 交给 random_dev，random_read 调 get_random；`kernel/random.c` 在 macOS 使用 CCRandomGenerateBytes。随机源自身失败返回 EIO，不是日志中的 ENOENT。ARM64 的 getrandom syscall 也已接到 sys_getrandom（kernel/arch/arm64/calls.c 的 [278]），并不要求伪造随机内容。
7. 候选③不是本次首错的解释：用户已确认样本解压且 init 完成，日志先报随机字节获取失败。没有证据表明缺 objects；本轮不添加 mkdir .git/objects，也不改 g add -A 或提交内容。

以上是日志与仓库源码链条的定因。本地没有 #28 的原客户机 rootfs、Git 源码或完整运行环境，未进行该作业原现场的系统调用跟踪；未声称直接观测到了它的 openat。尝试获取 Git wrapper.c 也因代理不可连接而失败。已明确区分可直接检查的 iSH 源码事实和日志定位依据。

### 修复位置及为什么在这两层

- `.github/workflows/aot-record.yml` 第 220–227 行，新增 `Prepare the random device for SSH and PCRE workloads`：只在 matrix.image 为 ssh/scp/pcre2 时，于 Stage 之前在宿主 mkdir 客户机 dev 目录并 touch urandom backing path。staging 拥有并负责构造真实 rootfs，这是补齐缺少路径的位置；ssh 新增 blob 也需要这个随机源。其他 22 个任务跳过该步骤；原有安装集合、包检查、build-id 检查、录制及上传步骤完全不改。
- `Vendor/ZeNative/ish/fs/real.c` 第 109–115 行：只对精确路径 `/dev/urandom`，在打开的 fd 上保留 guest 字符设备 mode 与 rdev=1:9；第 183–187 行：fstat 将此标记写回提供给 generic_openat 的 statbuf。这样 generic_openat 才会调用现有 dev_open/random_read，而不是读取宿主的空 backing file。
- 随机设备的数据仍由现有 get_random 生成，没有写固定随机样本、没有截短随机读取、没有将占位文件当成熵源。普通文件、其他设备映射及 getrandom syscall 均未改。
- 这里必须补 realfs 的打开后元数据；单改录制器环境与实际故障无关，单改 staging 的 touch 也不够。没有为了 Git 改动训练语义或增加私有临时文件名算法。

注意作用范围：工作流的路径准备限定三个任务；realfs 修正属于共享文件系统实现，任何调用者打开精确 `/dev/urandom` 路径都会得到该修正。它没有条件化到 pcre 名称，避免引入按负载改变文件系统语义的开关。其他镜像的负载脚本与流程没有修改，但共享 realfs 行为本身属于本轮变更，需后续完整环境检查。

## 提交后逐行自查

- ssh_keys.sh 新增注释说明 fixture 用途；mkdir 保证父目录；`-f` 条件与用户给出的上游行为一致；head 的字节数精确为 1048576。脚本原有 set -eu 和录制环境拒绝检查仍在，准备失败不会进入录制。
- workflow 新步骤只允许 ssh/scp/pcre2；set -euo pipefail 保证 mkdir/touch 错误立即停止；只创建 backing path，不声称空文件本身提供随机数；步骤在 Stage、密钥准备、训练之前。
- realfs_open 保留原 openat、错误返回和 close 生命周期，仅为精确 urandom 设置 fd->stat 标记；fd_create 将 fd 初始化为零，普通文件不会带该标记。
- realfs_fstat 保留原 fstat 失败处理及 copy_stat 的 inode、UID、时间等元数据，仅在字符设备标记及 rdev=1:9 均符合时覆盖 mode/rdev。generic_openat 随后用这个 metadata 进入已有设备分派；fd 的宿主 backing fd 仍由原 realfs_close 关闭。未增加新 fd 字段或改变结构大小。
- pcre_train.sh 全文与 aaca2387 逐字节相同，safe.directory、g init/add/commit、五轮 refactor 和全部正则用例均不动。

## scripts/ 双向扫查

在提交后执行两组 rg，并检查所有命中：

```sh
rg -n 'realfs|urandom|blob1m|ssh_keys|pcre_train|Prepare SSH|Stage reference|unable to get random|safe.directory|sample repo' scripts
rg -n 'realfs_open|realfs_fstat|copy_stat|fd->stat|fd->dir = NULL|realfs_devnum_for_path|blob1m|head -c 1048576|passwd -d root|ssh_keys.sh|Prepare SSH keys|Prepare the random device' scripts
```

正向：blob1m 仅新增创建行；prepare 仍将同一个 pcre_train.sh 复制到 minis/pcre_train.sh；targets 与 pcre2 wrapper 仍引用同一路径；没有新增训练内 keygen 或 helper 调用。

反向：没有删除或重命名符号、文件、工作流旧步骤或脚本调用。检查新增块两侧旧锚点 `passwd -d root`、`fd->dir = NULL`、copy_stat、realfs_fstat、Prepare SSH keys/Stage reference 等，没有发现 scripts 中要求旧相邻布局的断言。scripts/test-kernel-locks.py 的确读取 real.c，已实际运行通过；没有因此放宽其断言。

## 检查结果与限制

- sh -n：ssh_keys.sh、pcre_train.sh 通过；bash -n：prepare-aot-workloads.sh 通过。提取全部 workflow run 块、替换 GitHub 表达式后 bash -n 通过。
- git diff --check 通过。
- 与 aaca2387 比较，删除新增随机设备步骤后整个工作流逐字节等于基线；其他任务原有流程与安装集合没有变更。
- targets、record-aot.py、manifest、pcre_train.sh、prepare、sshd_setup 和 ssh/scp wrappers 逐字节等于基线。门禁未改，所有钉版版本与 build-id 未改。
- 宿主执行新增 blob 片段（仅将目录替换为临时测试目录）：创建缺失父目录和精确 1048576 字节；再次执行后内容保持相同。未在宿主运行整个密钥脚本或修改宿主 root 账户。
- 在 `/tmp/workload-fix3-check-realfs.py` 的局部 C harness 中直接抽取生产 realfs_open、copy_stat、realfs_fstat、generic_openat、dev.c、mem.c、get_random，使用真实临时空文件；周边路径解析、锁、inode 和 fd 分配为测试桩。cc -std=c11 -Wall -Wextra -Werror 编译通过；character-device 分派正确，两次读取各返回 1048576 字节且内容不同；普通文件仍返回原八字节，缺失文件仍返回 ENOENT。
- 同一 harness 换回 aaca2387 的原 realfs_open/fstat 后，以预期退出码 42 失败：占位文件仍是普通文件。这是针对实际生产函数的负对照，不是完整客户机或 macOS 运行。
- python3 scripts/test-kernel-locks.py 通过。
- git bundle verify ./workload-fix3.bundle 通过；最终另检查 bundle 可导入，并比对提交树与交付文件。

本地没有完整 macOS/iSH AOT 录制环境，未实测客户机 Git、SSH/SCP 训练、cc 在 macOS 的完整工程构建或 AOT 重录。本次局部 C harness 在 Linux 宿主运行，其 get_random 路径使用 Linux syscall；生产 macOS 使用 CommonCrypto 的路径仅做源码检查。上述局部检查不能替代完整录制结果。
