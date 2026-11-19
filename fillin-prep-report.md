# 补录准备报告

## 提交与交付

基线为 `62c8929170c21b772061cb7928eade47897de3aa`，直接采用 brief-fillin.md 给定的 #28 结果和定因，没有重新调查。仅实现简报的五项准备及其检查同步，没有下载真实产物、触发录制或改动现有 .o。

顺序：实现后先提交 `43da4230`，随后自查；自查中将其他参考 wrapper 的 exec 断言保持严格，另提交 `56516997`，该测试单项复跑通过。报告另作后续文档提交。

原克隆 `.git` 只读，直接提交报 `Unable to create .../.git/index.lock: Read-only file system`。在 `/tmp/fillin-prep-delivery` 的临时 Git 克隆提交，导出根目录 `./fillin-prep.bundle`，前置提交为 `62c89291`；工作目录保留相同改动，原克隆 HEAD 未移动。

## 五项改动

1. `scripts/aot-workloads/musl.sh`：直接取可达历史 `03284d527865:scripts/aot-workloads/musl.sh` 的原始字节恢复，未按简报代码块重打；39 行脚本与历史逐字节相同。原头注释保留 1379/4807 的来历，保留 `/usr/lib/python3.12`，没有 `/tmp/aojit` 引用，没有 node 段。现行 record-aot.py 仍按 manifest 的 `@scripts/aot-workloads/musl.sh` 读取正文、写入客户机 `/tmp/wl-musl.sh`，再 `/bin/sh` 调用；所以原脚本不需要新增 shebang、参数或 staging 接口。
2. `scripts/aot-manifest.txt`：musl 超时 10800→600；nodejs 原行加注释，前置注释说明录制成本超出作业预算、暂不录，采用十月“Node 不在 catalog、用注释保留录制行”的风格。其他原有行逐字节保留。
3. `scripts/aot-targets.json`：当前文件没有独立 schema 文件、disabled/image=false/null 等状态字段，所有消费者直接遍历 `images`，每个元素都必须有 id/path/version/build_id 等完整字段。其自身表示“不录制”的约定是不存在于 `images`；因此仅移除 nodejs 整个元素，不发明新字段或加入 null。其余 24 个元素及顶层 reference_app/reference_ish/abi 原样保留，包括 musl 的版本、build-id 和声明 workload 元数据。
4. `Agent/ISH/AOJITAcceleration.swift` 的 `static let catalog`：按十月源码移除 nodejs 的 AOJITLibrary 行，恢复目录 24 项。该结构也没有每行的 image=nil 标记，十月源码正是无 Node 行；没有改成显示一个 pending target。`imageVersions` 实际产物来源、包探测脚本和其他目录行不改。`AOJITRecordingTargets` 对不存在的 id 已返回空版本，不需要修改 helper。
5. `.github/workflows/aot-record.yml`：record matrix 恰为 `["musl", "pcre2", "ssh", "scp"]`；assemble 在原同轮下载步骤之前增加 `actions/download-artifact@v4`，带 `run-id: 44454527800`、`github-token: ${{ secrets.GITHUB_TOKEN }}`、`pattern: aot-image-*`、`merge-multiple: true`，目标同为 `.aot-new/recorded`。原同轮下载步骤完整保留，最后由四项新录制的 TARGETS.json/VERSIONS.txt 覆盖旧运行的共享声明；20 个旧成功条目的单项 RECORDED 身份不变。

第 3/4 项所要求的消费者同步：

- `scripts/record-aot.py` 仅将“25”注释/报错/成功提示改为声明集合或动态计数；manifest/targets 集合相等检查、精确版本、build-id、ABI、模块集合、翻译数、FAIL 与成功标记门禁全部保留。
- `scripts/check-aot-artifact.py` 只将成功提示的 25 改为动态计数；.S/.o 完整集合、每项 ledger、TARGETS 全文及 VERSIONS 集合相等检查原样保留，实际集合由 targets 导出，现为 24。
- `scripts/test-aojit-alignment.py`：manifest 计数 24、nodejs 不存在、musl 超时 600、musl 无上游引用；其余 wrapper 仍要求原 exec 调用，已有 ssh/scp 因需运行清理 trap，单独检查 setup source 和原训练调用。其他身份拒绝测试保持不变。
- `scripts/test-aojit-fixes.py`：App catalog 计数 24，明确无 nodejs；移除只服务于旧 Node pending 行的断言，其余实际 provenance / pending 版本约束保持。

## 先枚举的消费者与预期集合

| 消费者 | 依据及结果 |
| --- | --- |
| record-aot.py | manifest() 要求活动行 id 集合恰等于 targets.images；--only choices 和 preflight 均从该数组导出。现在 24，实际只录 matrix 四项。 |
| check-aot-artifact.py | names 从 targets.images 得到，要求 .S、.o 都恰等于它；现在 24，无额外 Node。 |
| aot-record.yml 的包预检/安装/build-id 检查 | 均直接遍历 targets.images，去掉 Node 后只检查剩余声明；fix3 的随机设备和密钥步骤保持原字节。 |
| AOJITRecordingTargets.swift | 解码 images 的 id/version 为字典，没有条目即无 pending target；未知版本返回空。 |
| AOJITAcceleration.swift | static catalog 现为相同 24 个 id；Node 无目录行，其他行保持。 |
| build.yml 的 id:aot 步（979–992） | 只链接当前 aot/*.o，动态统计 count；对象为空才报错，没有硬编码 25 或 Node 必须存在条件，不消费 next targets，也不内联录制。原样保留。 |
| build.yml 的 status 步（505–511） | 调用 verify-aojit-status.py 并解析 Swift；校验实际 imageVersions 来源，不要求 25 行，原样保留。 |
| build.yml 的链接/section 检查（1020、1115 起） | 对象传给 App 链接目标、验证 __ish_aot section 有效；没有 25 个对象断言，原样保留。 |
| scripts/sync-aot-objects.py | glob aot/*.o、动态生成 ZE_AOT_OBJECTS 和实际版本表；没有 25/Node 必有约束，原样保留，未在真实仓库运行导入。 |
| Ze.xcodeproj/project.pbxproj | targets 资源仍被 App 打包；现有对象列表没有 Node，且原有 24 个对象未变，本轮无需修改。 |

## 提交后的双向字面扫查清单

扫查了 build.yml、aot-record.yml 和 scripts/ 的 `nodejs`、`musl`、独立 `25`/`24`、matrix、期望集合与计数断言。先保存全部相关断言命中，再扩大到 scripts 全目录检查旧字面引用；没有只查新增行。

```sh
rg -n 'nodejs|musl|\b25\b|\b24\b|matrix|len\(|count|expected|exact|assert' \
  .github/workflows/build.yml .github/workflows/aot-record.yml \
  scripts/record-aot.py scripts/check-aot-artifact.py scripts/aot-manifest.txt \
  scripts/test-aojit-alignment.py scripts/test-aojit-fixes.py scripts/sync-aot-objects.py
rg -n 'nodejs|musl|\b25\b|\b24\b|aot-targets|aot-manifest|aot-image|image.*count|catalog.*count' scripts
```

逐条结论（行号以本轮最终文本为准）：

| 文件与命中 | 断言/字面与结论 |
| --- | --- |
| build.yml 全文件 | nodejs/musl/独立25/独立24 的字面搜索零命中；AOJIT 动态 count、对象路径和 section 检查另已枚举，无 25 阻碍；不改文件。 |
| aot-record.yml:48 | 唯一 record matrix 已改为四个指定 id，顺序 musl/pcre2/ssh/scp。 |
| aot-record.yml:68–94、174、201–217 | targets 数组驱动包版本及模块身份检查，计数动态；现在以 24 个目标为输入。 |
| aot-record.yml:175/183/221/234 | SSH server、root-owned empty、fix3 随机设备及录制外密钥条件保留；没有 Node 依赖。 |
| aot-record.yml:246/255/272 | --only、成功 aot-image 名与失败 aot-log 名来自四项 matrix；没有第五项。 |
| aot-record.yml:284–296 | 跨轮和同轮下载均用 aot-image-*，旧→新顺序；失败的 aot-log-* 不会混入。 |
| aot-record.yml:297–298 | 原步骤显示名称仍为 `Require the complete, exact 25-image recording set`，它是旧标签，不是检查条件；实际执行的 checker 已动态要求 24。简报第5(c)项要求除 matrix/下载外其余字节不动，因此明确保留此显示文字。 |
| aot-record.yml:356–357 | musl/busybox 核心身份断言仍使用这两项 targets，不要求 Node，也不计 25；保持。 |
| aot-record.yml:369/374、402–405 | 旧注释“24 unusable images”没有计数断言；核心两镜像链接及跨版本 musl/busybox 检查保持。 |
| record-aot.py:135/176/196 | 原25字面改声明集合/动态提示；真正集合相等谓词未改。ABI 探针 ld-musl 和模块集合门禁保留。 |
| check-aot-artifact.py:12–26 | 全部集合来自 targets，24；只同步成功提示，完整性门禁未改。 |
| aot-manifest.txt:5/8–10 | musl=600；Node 仅为注释；没有活动 nodejs 行。其余活动行不变。 |
| test-aojit-alignment.py:70–96 | 活动条目24、无Node、musl600、自有脚本不引用/tmp/aojit；身份 fixture 遍历24个声明。 |
| test-aojit-alignment.py:104–161 | musl 精确包失败、错误build-id/ABI、缺 workload、FAIL/成功标记、损坏ELF、缺产物、混合 ledger 拒绝检查保持，无25硬编码。 |
| test-aojit-alignment.py:244–258 | 临时目录创建 Node marker 是“未来导入任意对象能刷新链接列表/版本表”的 fixture，不表示真实目录含Node；只作用临时目录，测试保留。 |
| test-aojit-alignment.py:263–270 | 已提交对象必须24且无aot_nodejs.o、所有对象原样；与本轮24决定一致，保留。 |
| test-aojit-fixes.py:89–106 | catalog计数25→24并明确无Node；其余 provenance/未来版本字面检查保持。 |
| test-aojit-fixes.py:19–68/108起 | 主构建无对象必须失败、有对象仅链接、legacy recorder禁用、资源归属、未知版本禁修复等检查均保持；ld-musl仅为legacy测试selector。 |
| verify-aojit-status.py:133起 | 要求实际版本表覆盖musl/busybox/python3，无Node或25要求，保留；54项检查通过。 |
| sync-aot-objects.py:25–58 | 对象数和实际包数为动态计数，满足24对象；保留。 |
| prepare-aot-workloads.sh、aot-workloads/pcre2.sh、targets资源路径 | 文件/调用名称未删除，musl仍由原manifest @路径契约读取，其他wrapper调用不变，无重命名造成断言断裂。 |
| aot-reference-workloads/README.md:10/30/34 | 遗留25条与旧完整录制说明是说明文档，没有被脚本作为断言读取。本轮不扩展五项范围改写该文档；实际行为由上表已同步的schema/checker确定。 |
| scripts/ 其余25/24/musl命中 | UI字号/动画帧数/小时/测试数据及独立ish回归示例，不消费AOJIT目标/目录计数，逐项检视后未改。 |

反向扫查也覆盖旧活动 Node 行、旧 catalog Node pending 断言、musl_train.sh、原25计数与测试名：活动 Node 仅在本轮三处（manifest/targets/catalog）退出；原 nodejs.sh/node.sh 文件不删除、不修改；musl 上游 wrapper 的断言仅对新的自有 musl 特判，其余 workload 的旧约束保留。App 中尚有 Node 路径匹配/包探测兼容代码，但没有 catalog 条目消费它们，不代表镜像或pending target，没有扩大范围清理。

## 自查结果

- `python3 scripts/test-aojit-alignment.py`：16项通过；`python3 scripts/test-aojit-fixes.py`：6项通过；`python3 scripts/verify-aojit-status.py`：54项通过。随后测试断言细化提交后，仅重跑受影响的 `RecordingTests.test_reference_table_and_effective_manifest`，通过。
- PyYAML 6.0.1 成功解析 aot-record.yml，核对 matrix 正好四项，两次下载的 with 字段、顺序与同一目录；所有 run 块替换 GitHub 表达式后 `bash -n` 通过；musl `sh -n` 通过；修改的 Python 文件 AST 解析通过。
- 独立检查 manifest id集合 = targets id集合 = App catalog id集合，长度均24且无Node。除删除Node元素外，整个targets结构与基线完全相同。
- musl全文与历史03284d527865逐字节一致；其他负载全部逐字节未变。build.yml、ssh_keys.sh、sshd_setup.sh、real.c均与62c89291逐字节相同。
- 把 aot-record.yml 的新下载步骤删去、matrix还原，得到的字节流与基线完全相同；因此fix3随机设备/录制外密钥步骤和其他字节未被触碰。
- 对record-aot.py、check-aot-artifact.py的前后AST排除诊断print/报错文字后完全相同，未改变任何身份/完整性门禁。原有完整测试还检查了错误身份/缺项拒绝。
- 临时目录模拟20旧+4新：旧TARGETS含25项，四项新产物写24项声明，按工作流下载顺序覆盖共享元数据，checker接受24个完整S/o及ledger。把旧25项TARGETS改回或加额外aot_nodejs.o均被拒绝。这是合成marker测试，没有生成AOT原生代码或下载真实产物。
- `git diff --check`通过；实现差异9个文件、72增/40删。musl只恢复39行历史脚本，App只删除7行Node条目，targets只删除13行Node元素，workflow只改matrix/增加下载。未发生整文件换行翻转。
- bundle检查及导入检查在报告提交后执行；交付文件与bundle提交树逐字节比对。

本地未执行macOS/iSH完整录制、真实#28产物下载/合并、Swift编译或设备实测；当前环境没有swiftc。本报告中的成功结果仅限所列静态检查和宿主局部测试，不表示补录或真实组装已运行通过。
