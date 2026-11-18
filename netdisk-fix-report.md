# SSH 凭据失效返修记录

基于 `../audit2.log` 后半段 Astra 对 `18b116f` 的确定发现，仅修 SSH 凭据变化后的版本、连接与磁盘验证失效；其它协议和功能未改。原 `.git` 只读，在独立临时 Git 元数据创建提交。

先实现提交 `dbb5da0`，再做独立只读审核与 scripts 自查。专项静态检查提交 `424c891`；审核发现的两个同一失效路径边界另作 `77106df` 修复：版本不能被服务器表单保存或主机信任保存回退；磁盘配置加载失败时禁止清验证操作覆盖原 JSON。本记录与扫描清单另作最后的文档提交。

## 修改位置及覆盖

| 位置 | 改动 |
|---|---|
| 新 `RemoteServerCredentialChange.swift` | 同步主线程统一入口：移除旧连接、清内存密码、推进 `updatedAt` 并清重连标记、清关联 SFTP 磁盘验证，最后才执行凭据写入。多项钥匙串写入部分失败也不恢复旧连接/验证。 |
| `RemoteServerStore.swift` | 凭据版本持久化；至少推进一秒以适配原 ISO8601 秒精度。编辑器保存和主机信任保存同样单调推进，避免重用旧版本。 |
| `RemoteSSHConnectionService.swift` | 同步移除连接和连接配置后异步 close，移除后无法复用；握手完成及关闭前一连接后的两次版本检查，防止旧握手重新登记。 |
| `RemoteDiskStore.swift` | 清除关联该服务器的全部 SFTP 验证记录并持久化；加载失败先报错防止覆盖。已有 status/record 的版本判断继续拒绝过期结果。 |
| 三个消费文件 | 以下四入口全部调用统一失效入口；密码弹窗使用更新后的服务器元数据连接，保存错误显示失败。 |
| `project.pbxproj` | 为新增 helper 注册唯一文件、group、Sources 引用，保留原行尾。 |
| 实现报告 SFTP 行 | 将“编辑期间旧数据/旧验证拒绝”“密码/配置版本修复经独立复核”收窄为具体版本检查及四入口源码接入，明确尚未运行验证。 |

| 凭据写入入口 | 是否覆盖 | 覆盖分支 |
|---|---|---|
| AI `remote_server_configure_credentials` | 是 | 密码；私钥及私钥口令；对侧旧凭据删除。两个事务分支。 |
| 服务器编辑表单 | 是 | 密码；私钥及口令；切换为 none 清除凭据。 |
| 服务器详情连接密码弹窗 | 是 | 密码及内存凭据，之后读取更新后的元数据发起连接。 |
| 备份页新增 SFTP | 是 | 新服务器密码及内存凭据。 |

共四入口、五个事务调用点、八条密码/私钥/口令 `save` 语句；非 SSH 的 `.remoteSecret` 不属于本次改动。删除整个服务器的既有流程继续先断连接再删配置，未改。

先失效、再改凭据是有意的失败语义：元数据或验证持久化失败则不开始钥匙串写入，返回失败；钥匙串中途失败则保留失效版本，要求后续重新连接/验证，不宣称多项 Keychain 操作具备事务原子性。关联磁盘配置损坏时拒绝操作，保留文件。

## 提交后实际检查

- `python3 scripts/verify-ssh-credential-invalidation.py`：21 项静态检查通过，扫描项目全部 literal SSH `save`，确认四入口覆盖、失效顺序、旧握手检查、版本单调、验证清除、防损坏配置覆盖、工程引用及报告收窄。
- `GIT_DIR=/tmp/netdisk-fix-commits.git python3 scripts/verify-netdisk.py --base 18b116f --scan-json /tmp/netdisk-fix-literals.json`：26 项静态检查通过；未改动行的原始 CRLF/LF 变化为 0。
- 双向扫查清单 `netdisk-fix-script-scan.json`：4610 个脚本字面，8 个本轮变更生产文件，31 处次数变化，均为增加。未删除/改名旧检查锚点。旧脚本命中是 `static func`、`errorMessage`、`in Sources` 等通用字面；核到其实际文件、block/section 边界与否定断言，未发现冲突。新增专项脚本固定的本轮字面已逐项核对，未来更改这些入口/方法时需同步回归检查。
- `python3 scripts/verify-github-connector.py`：23 项通过；`python3 scripts/verify-agent-scheduled-tools.py`：14 项通过。
- `python3 scripts/test-netdisk.py --prepare-only`：生产解析夹具准备通过，未执行 Swift。
- `git --git-dir=/tmp/netdisk-fix-commits.git -c core.whitespace=cr-at-eol diff 18b116f --check`：通过。
- 独立只读审核复核上述修复，限定缺口内未发现新的确定阻塞。

**本机无 Xcode/Swift，未编译。以上全部为源码/静态检查；真实 Keychain 保存、在途 SSH 握手取消/关闭、重新认证、旧验证状态变化和 iOS UI 仍未运行验证。五协议原有实测状态没有变化。**

## 交付

`./netdisk-fix.bundle` 以原始克隆基线 `42339dfa9a68dff11dd856ab6c6867657b851841` 为前提，保留原 `netdisk.bundle` 的 8 个提交并追加本轮提交，分支为 `netdisk-fix`。原 `netdisk.bundle` 未修改。这样在只包含原始基线的仓库中也能导入完整提交链：

```sh
git bundle verify ./netdisk-fix.bundle
git fetch ./netdisk-fix.bundle netdisk-fix
git log --oneline 18b116f..FETCH_HEAD
```

原克隆 `.git` 未写，故其 `git status` 仍显示相对原始基线的全部改动。新提交实际保存在 bundle；该行为不是丢失提交。
