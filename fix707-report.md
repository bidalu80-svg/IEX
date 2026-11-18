# #707 网络磁盘设置页类型检查超时修复

基线：`2e0fdee4`，即用户提供的 #707 合并树。原错误位于 `Views/Servers/RemoteDiskSettingsView.swift:166:22`：Swift 编译器无法在合理时间内完成表达式类型检查。

## 修改范围与提交顺序

先实现并提交 `66005bc8`（`fix(netdisk): split disk detail view expressions for Swift type checking`），然后才做自查。生产代码只改 `Views/Servers/RemoteDiskSettingsView.swift`，没有改其它源码、协议、凭据处理或工程文件。本报告是用户要求的交付文档，另作文档提交。

原克隆 `.git` 只读，提交使用 `/tmp/fix707-commits.git` 的独立可写 Git 元数据创建；克隆根目录的 `fix707.bundle` 保存基线之后的提交，分支名 `fix707`。原克隆 git status 仍会显示相对基线的改动。

## 怎么拆

- `body` 只组合 `diskContent` 和 alert，不再把整个 List、条件分支、Binding 推断与消息拼接塞在同一个表达式中。
- `diskContent` 保留原 Group 和“磁盘存在/已删除”条件；`diskDetails(_:)` 返回原 List、导航标题和编辑 sheet；`verificationSection(for:)` 单独返回原验证区。每个 `some View` 函数或属性分别形成类型检查边界。
- alert 的内联 `Binding(get:set:)` 提取为 `hostTrustPresented: Binding<Bool>`，显式固定类型。
- message 提取为 `hostTrustMessage: String`，算法、指纹、提示前缀各是显式 String 局部变量，再在普通 String 计算属性里拼接。alert message 只构造 `Text(hostTrustMessage)`。
- “信任并重试”的 do/catch 原文移入 `trustHostAndRetry()`，alert action 仅调用该方法。

## 为什么行为不变

- 未引入新的 View 类型或新的状态存储。拆分后的属性/方法仍使用同一 `RemoteDiskDetailView` 中的 State、ObservedObject 和 diskID。
- Group、List、Section 的内容和顺序不变；导航标题和编辑 sheet 仍修饰磁盘存在分支的同一个 List；alert 仍修饰外层 Group 内容，磁盘不存在时也保留原挂载位置。
- Binding 的 get 仍是 `pendingHost != nil`；set 仅在 false 时清 `pendingHost`，true 时不写状态，与原闭包一致。
- 消息仍严格等于“请与服务器管理员核对：”加换行、算法（nil 时空串）、换行、指纹（nil 时空串），没有新增缓存或改变文案。
- 信任动作仍依次检查 host/server ID、调用 setKnownHost、清 pendingHost、重新取磁盘并 verify；错误仍写同一个 error。取消动作仍只清 pendingHost。
- 原 `verify(_:)` 方法及文件末尾、其他三个视图的内容均通过逐字节比较确认未变；验证按钮、busy 禁用条件及异步任务均保留。

## 提交后实际自查

- `GIT_DIR=/tmp/fix707-commits.git python3 scripts/verify-netdisk.py --base 2e0fdee4 --scan-json /tmp/fix707-script-scan.json`：26 项静态检查通过。
- `python3 scripts/verify-ssh-credential-invalidation.py`：21 项静态检查通过。
- scripts 双向扫描：4704 个脚本字面、1 个生产文件；唯一次数变化是通用 `    private func ` 从 2 次增加到 5 次。它被 `extract-provider-chat-chrome.py` 用于其它目标代码的提取，未影响本次文件；没有删除/改名旧锚点或命中否定断言。原主机信任检查要求的 hostKeyUntrusted、setKnownHost、信任并重试字面均保留，检查已通过。
- `git --git-dir=/tmp/fix707-commits.git diff 2e0fdee4 --check`：通过。
- 原文件和新文件均无 CR（全部 LF）；脚本逐行比较确认未修改文本的原始行尾没有变化，没有整文件行尾翻转。
- 已逐项比较上述 Binding、消息、信任/取消回调和 modifier 位置；未改业务逻辑。

**本机无 `swiftc` / `xcodebuild`，未编译，未运行 iOS UI。上述检查属于源码与静态验证，不能声称 #707 的编译错误已经由 Xcode 复验消除。需要后续 Xcode 构建确认，并核对指纹弹窗的展示、信任重试和取消行为。**

## 导入

在已有基线 `2e0fdee4` 的仓库中：

```sh
git bundle verify ./fix707.bundle
git fetch ./fix707.bundle fix707
git log --oneline 2e0fdee4..FETCH_HEAD
```

bundle 会做有效性检查，并从原基线的临时克隆实际导入，核对提交内容与本克隆工作文件逐字节相同。无需改动原 `.git`。
