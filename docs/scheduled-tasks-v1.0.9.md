# v1.0.9 定时任务

## 入口与界面

设置 → 智能体运行时 → 定时任务（SF Symbols `clock`）。原生导航栏返回、添加；“运行记录 / 已定时”分段与左右滑动；空态时钟与“＋ 新建定时任务”胶囊按钮。

新建/编辑包含可选名称、重复周期、08:00 默认时间与滚轮、无结束时间开关/到期日、提示词、运行方式、服务商模型。模型选择复用现有 picker，只接受已启用、有凭据、未隐藏且支持文本输出的条目。文案加入 `Localizable.xcstrings`，简体中文完整覆盖。

## 调度与数据

- 每天、每周（选星期）、每月（选日期）、不重复（选日期）。每月缺少的日期取当月最后一天。
- 按设备本地日历/时区计算；夏令时不存在的时间向后移到有效时间，重复小时仅执行一次；到期日期包含当天。
- 前台每 15 秒检查。后台用 `BGProcessingTaskRequest` 请求系统机会，要求网络连接；系统决定唤醒时间，关闭后台刷新、系统挂起或强制退出后不承诺准点运行。
- 恢复时每个任务最多补一次，错过多个周期不批量补跑；超过截止日期不补跑。
- 执行前先将本次运行记录与下次时间原子写入同一 JSON；进程中断后将 running 记为 interrupted，不自动重放可能已计费的请求。
- 单进程串行调度；当前会话忙、编辑中、有草稿/附件、压缩中、待确认或被锁时延后。删除会话/模型失效写中文失败提示，不悄悄换模型。
- 使用 `ViewModelCache` 和 `AIChatViewModel` 真实执行；新会话在后台建立，不切换用户前台选中的会话。上下文已满时记录失败，避免后台弹交互提示。
- 单次运行最多 15 分钟；手动取消、删除正在运行的任务、后台时间到期时取消执行并记录中断。
- 状态文件：应用沙箱 `Library/Application Support/ScheduledTasks/state.json`；最多保留 200 条运行记录，摘要最多 8,000 字符。不修改服务商密钥存储，不跨设备同步定时任务。
- 数据损坏时保留原文件并停止调度，避免空数据覆盖或重复发送。

## 验证

Windows 本地执行 `python scripts/verify-scheduled-tasks.py` 检查资源 JSON、版本、后台声明、工程引用、本地化覆盖及关键集成点。

macOS CI 在构建前运行真实 Swift/Foundation 日历与持久化测试：

```sh
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" Agent/Background/ScheduledTaskModels.swift scripts/ScheduledTaskTests.swift -o /tmp/ze-scheduled-task-tests
/tmp/ze-scheduled-task-tests
xcrun swiftc -frontend -parse Agent/Background/ScheduledTaskStore.swift Views/Settings/ScheduledTasksView.swift
```

随后执行已有 iOS 真正 SDK 编译、未签名 IPA 打包及版本/资源/框架审核。CI 构建验证不替代真机上系统后台调度、VoiceOver、深浅色和实际服务商请求的验收。

### 真机验收清单

1. 中文系统/应用语言下打开上述入口，检查空态和左右切换；浅色、深色、大字号各检查一次。
2. 选一个已配置模型，新建不重复任务（设为下一分钟）；前台等待并检查运行记录、消息、模型与新会话。
3. 同样创建“当前会话”任务，验证写入保存时绑定的会话；已有草稿不被发送或覆盖。
4. 删除/停用所选模型、删除会话、断网：记录中文错误；模型不回退到其他提供商。
5. 暂停/启用/编辑/删除；取消运行；重启应用，任务和记录保留，中断运行不自动重放。
6. 开关无结束时间、截止当日/已过期、每月31日、跨时区分别验证。
7. 后台与锁屏单独观察系统实际调度延迟，不按“精确到点”验收。

## 版本与回滚

主 App 及扩展统一 marketing version **1.0.9**，build **3**；CI IPA audit 同步。

变更前源代码 ZIP 与 SHA256 在工作区外 `C:\Users\Administrator\Desktop\ios-v1.0.9-audit`。源代码回滚用 `git revert <本次功能提交>`，不覆盖用户其他改动。运行数据回滚前先导出上述 JSON；旧版本忽略该独立文件，保留它可重新升级恢复。
