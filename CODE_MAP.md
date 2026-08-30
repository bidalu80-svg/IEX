# Ze 项目代码地图

本文档是 Ze iOS 工程的维护入口。它描述主要目录、关键类型、数据流、构建流程和常见改动落点。新增代码或重构后，应同步更新本文件，保持路径和职责说明准确。

## 1. 工程总览

```text
Ze.xcodeproj                 Xcode 工程、Target、Build Phase 和 SPM 配置
ZeApp.swift                  应用入口与根环境注入
AppDelegate.swift            UIApplication 生命周期、后台任务和系统事件
Views/                       SwiftUI 页面与可复用视图
Agent/                       对话、智能体循环、工具调用、同步和后台编排
Providers/                   模型服务商协议、模型目录、OAuth 和配置存储
Shared/                      跨模块共享模型、通知、样式和工具类型
NativeOffloads/              Objective-C/C 原生能力封装
iSH/                         终端运行时和命令执行桥接
WebApp/                      Web 内容与快捷入口相关实现
FileProvider/                文件提供器扩展
ShareExtension/              系统分享扩展
AgentWidget/                 Widget 与 Live Activity 相关代码
Resources/                   静态资源、模板和辅助数据
Assets.xcassets/             图片、颜色、图标资源
Localizable.xcstrings        多语言字符串目录（含 zh-Hans/zh-Hant）
ZeTests/                     单元测试
ZeUITests/                   UI 测试
scripts/                     构建、依赖和诊断脚本
.github/workflows/           GitHub Actions 编译工作流
Vendor/                      第三方或原生依赖源码
```

## 2. 应用启动与根视图

### 启动链

1. `ZeApp.swift` 创建 SwiftUI `App`，配置持久化容器、全局状态对象和根窗口。
2. `AppDelegate.swift` 接收后台刷新、通知、URL Scheme、分享扩展和系统生命周期事件。
3. 根视图进入 `Views/ContentView.swift`，根据当前会话、侧边栏状态和深链目标选择页面。
4. 全局对象通过 `@EnvironmentObject`、单例或通知中心向子视图传递状态。

### 维护要点

- 新增全局状态时，优先放入已有的 ViewModel/Store，避免在页面中创建第二份真源。
- 新增 URL Scheme 或深链时，同时检查 `DeepLinkCoordinator`、`ContentView` 和设置页面的目标枚举。
- 生命周期相关改动要同时验证前台、后台、挂起恢复和冷启动四种路径。

## 3. SwiftUI 页面层（`Views/`）

### 3.1 聊天与消息

| 路径 | 职责 | 维护入口 |
| --- | --- | --- |
| `Views/Chat/` | 聊天页面、输入框、消息气泡、思考块、工具步骤和流式状态 | `AIChatView`、`AssistantBlockView` |
| `Views/MessageList/` | 消息列表布局、滚动定位、分页和上下文菜单 | 消息行和列表容器 |
| `Views/Markdown/` | Markdown 渲染、代码块、链接和复制操作 | Markdown 根视图 |
| `Views/Session/` | 会话列表、会话详情和会话切换 | Session 列表/详情视图 |
| `Views/Shell/` | 命令执行面板、终端输出和工具结果 | Shell 工具视图 |
| `Views/BrowserUse/` | 浏览器工具状态、网页快照和交互面板 | Browser 工具视图 |
| `Views/Offload/` | 图片、音频、地图等原生卸载能力的结果展示 | Offload 结果视图 |

`Views/Chat/AssistantBlockView.swift` 是思考块和工具步骤视觉表现的集中位置：

- 思考内容、思考耗时、展开箭头和扫光效果在同一组件链中维护。
- 工具步骤的状态、耗时、停止按钮、详情面板和 VoiceOver 文案在 `ToolCapsuleView` 中维护。
- 修改扫光时必须同时检查浅色/深色主题、减少动态效果设置、流式中/结束后三种状态。
- 修改布局时要验证列表复用，避免旧行残留、位置跳动和重影。

### 3.2 服务商与模型配置

| 路径 | 职责 |
| --- | --- |
| `Views/Providers/AddProviderView.swift` | 新增服务商、选择协议、API Key/OAuth、Base URL 和模型初始化 |
| `Views/Providers/ProviderInstanceDetailView.swift` | 编辑现有服务商实例、认证、模型列表和高级参数 |
| `Views/Providers/ProviderInstancesView.swift` | 服务商实例列表、分组和状态 |
| `Views/Providers/ModelGroupsView.swift` | 模型分组列表、排序、左滑编辑/删除 |
| `Views/Providers/ModelGroupDetailView.swift` | 模型分组成员、回退和负载策略 |
| `Views/Providers/UnifiedModelPicker.swift` | 全局模型选择器和模型搜索 |
| `Views/Providers/KimiDeviceLoginSheet.swift` | Kimi 设备码登录界面 |
| `Views/Providers/ThinkingRulesSection.swift` | 思考规则与级别配置 |

服务商页面的新增可见文案必须使用 `String(localized:)` 或本地化 `Text`，并在 `Localizable.xcstrings` 中提供 `zh-Hans`。

### 3.3 设置、同步和备份

| 路径 | 职责 |
| --- | --- |
| `Views/Settings/` | 通用设置、权限、语言、外观、后台能力和诊断入口 |
| `Views/Backup/ICloudBackupView.swift` | iCloud 备份、加密便携备份导出/恢复、内容选择、本地文件夹/SFTP 目标和进度显示 |
| `Views/Sync/` | 同步状态、迁移、冲突和设备状态 |
| `Views/Skills/` | 技能列表、编辑和导入导出 |
| `Views/Servers/` | MCP/外部服务器配置和连接状态 |
| `Views/Alarms/` | 定时任务、提醒和后台触发配置 |
| `Views/Rootfs/` | 根文件系统和终端环境管理 |

便携备份格式当前使用 `.zebak`。修改格式时必须同步更新：

- `Agent/Sync/ICloudBackupManager.swift` 的格式头、密钥派生信息和导入校验；
- `Views/Backup/ICloudBackupView.swift` 的导出/恢复文案；
- `Localizable.xcstrings` 的中英文键；
- 备份相关测试和 CI 产物审计。

备份恢复维护要点：

- `ICloudBackupManager.BackupSelection` 保存聊天、共享文件、技能、记忆与灵魂、服务商、MCP 和环境变量开关；选择写入 `ze.backup.selection.v1`。
- `exportEncryptedBackup` 只把选择的内容写入临时 ZIP，再用 AES-GCM 生成 `.zebak`；服务商凭据只存在加密载荷中。
- `BackupDestination` 持久化本地 security-scoped bookmark 或已有 SSH/SFTP 服务器 ID，不保存密码和私钥。
- SFTP 恢复通过 `RemoteSSHConnectionService.listDirectory/downloadFile` 获取 `.zebak`，本地文件夹使用 bookmark 访问。
- `ze.backup.deviceName` 控制 iCloud 备份设备目录；`ze.backup.maxFileSizeMB` 控制文件夹内容的单文件上限，超限文件会跳过并记录日志。

## 4. Agent 编排层（`Agent/`）

### 4.1 对话主流程

```text
Views/Chat/AIChatView
        │ 用户发送消息
        ▼
Agent/Chat/AIChatViewModel
        │ 创建会话、拼装上下文、选择模型
        ▼
Providers/LLMProviderFactory
        │ 返回具体服务商实现
        ▼
Providers/*Provider
        │ 流式文本、思考、工具调用事件
        ▼
Agent/Chat/AIChatViewModel
        │ 解析事件、更新 AssistantBlock、持久化消息
        ▼
Views/Chat/AssistantBlockView + MessageList
```

### 4.2 关键目录

| 路径 | 职责 |
| --- | --- |
| `Agent/Chat/` | 聊天 ViewModel、消息发送、流式事件、重试和消息删除桥接 |
| `Agent/Chat/AIChatViewModel+ToolPreflight.swift` | 工具调用前置检查、权限和能力判断 |
| `Agent/Chat/AIChatViewModel+*.swift` | 按主题拆分的聊天扩展，避免主文件继续膨胀 |
| `Agent/Tools/` | 工具注册、参数校验、执行和结果归一化 |
| `Agent/BrowserUse/` | 浏览器工具编排和快照管理 |
| `Agent/ISH/` | iSH 命令执行、后台保持和终端桥接 |
| `Agent/Speech/` | 语音输入输出、纠错和播报队列 |
| `Agent/Sync/` | iCloud 数据同步、备份、迁移和冲突处理 |
| `Agent/Background/` | 后台任务、Live Activity 和任务保持 |
| `Agent/MCP/` | MCP 工具发现、协议交互和服务器状态 |

### 4.3 工具调用状态

工具状态通常沿着以下方向传播：

```text
Provider 流事件
  → AIChatViewModel 更新 AssistantBlock
  → AssistantBlock.toolStatus/toolDuration/toolSummary
  → ToolCapsuleView 展示状态、耗时、扫光和停止按钮
  → detailBlock 打开主机面板或工具详情
```

修改工具状态时，要同时覆盖 `running`、`streaming`、`success`、`failed`、`cancelled` 和 `none`，并检查退出应用后恢复的数据是否仍保留耗时和首字时间。

## 5. Provider 层（`Providers/`）

### 5.1 核心协议与工厂

- `Providers/ProviderTypes.swift`：服务商类型、显示名、协议说明、默认模型和默认模态。
- `Providers/LLMProvider.swift`：统一模型请求协议和流式事件接口。
- `Providers/LLMProviderFactory.swift`：根据 `ProviderType` 创建具体实现。
- `Providers/ProviderConfigStore.swift`：服务商实例、模型条目、分组关系和持久化。
- `Providers/ModelEntry.swift`：模型条目、显示名、能力覆盖和上下文参数。
- `Providers/ModelGroup.swift` / `ModelGroupRouter.swift`：模型分组和路由策略。
- `Providers/ProviderKeychainHelper.swift`：API Key、OAuth Token 和敏感配置的 Keychain 存取。

### 5.2 服务商目录

| 目录 | 主要内容 |
| --- | --- |
| `Providers/OpenAI/` | OpenAI 兼容协议、Chat Completions、Responses API 和图片能力 |
| `Providers/Anthropic/` | Anthropic 协议、OAuth、流式事件和刷新协调器 |
| `Providers/Gemini/` | Gemini 请求、流式解析和多模态 |
| `Providers/Antigravity/` | 兼容 Gemini 的认证和模型实现 |
| `Providers/OpenRouter/` | 聚合服务商 OAuth 和模型目录 |
| `Providers/xAI/` | xAI OAuth、模型目录和兼容请求 |
| `Providers/Kimi/` | Kimi Code/Coding Plan 模型目录和设备码 OAuth |
| `Providers/Voice/` | 语音服务商和系统语音适配 |
| `Providers/AgentProvider.swift` | 智能体专用 provider 包装和工具循环适配 |

### 5.3 Kimi 认证调用链

```text
KimiDeviceLoginSheet
  → KimiOAuthManager.login
  → KimiDeviceFlow 请求设备码
  → 用户打开验证页面并输入验证码
  → KimiOAuthManager 轮询 Token
  → ProviderKeychainHelper 保存 KimiTokenStorage
  → OpenAI 兼容请求携带 Bearer Token
```

Kimi 错误文案位于 `KimiOAuthManager.swift`、`KimiDeviceFlow.swift` 和 `KimiOAuthRefreshCoordinator.swift`。新增错误必须使用本地化键，不要直接把英文字符串显示给用户。

## 6. 数据、同步与持久化

### 本地数据

- 会话和消息：由 Chat Store/Session Store 管理，具体实现位于 `Agent/Chat/` 和 `Agent/Sync/`。
- 服务商配置：`ProviderConfigStore` 管理实例、模型、分组和能力覆盖。
- 敏感凭据：统一通过 Keychain helper，禁止写入 UserDefaults、日志或普通 JSON。
- 设置项：使用现有 `@AppStorage` 键命名空间，新增键要记录默认值和迁移策略。

### iCloud 同步

- `Agent/Sync/CloudSyncEngine.swift`：同步调度、冲突合并和版本推进。
- `Agent/Sync/V2/`：新版本同步水合器、模型转换和兼容逻辑。
- `Agent/Sync/ICloudBackupManager.swift`：iCloud 文件备份和 `.zebak` 加密便携备份。
- `Views/Sync/` 和 `Views/Backup/`：状态展示、恢复确认和错误处理。

同步字段变更必须考虑旧版本数据、重复合并、设备离线后再上线以及删除 tombstone 的生命周期。

## 7. 原生、终端和扩展

### 原生桥接

- `NativeOffloads/`：地图、位置、媒体和其他 Objective-C/C 能力。
- `ZeApp-Bridging-Header.h`：Swift 与原生代码的桥接声明。
- `iSH/`：终端运行时、文件系统、进程和 shell 执行。
- `Agent/ISH/ISHExecutionCoordinator.swift`：Swift 侧命令执行协调、超时和后台保持。
- `Vendor/ZeNative/`：原生依赖源码，修改前先确认是否需要同步上游或更新构建脚本。

### 扩展 Target

- `AgentWidget/`：Widget、锁屏和 Live Activity 展示；与主 App 共享模型时要保持 Codable 兼容。
- `FileProvider/`：文件提供器枚举、读取和写入权限。
- `ShareExtension/`：系统分享入口和内容转交。
- `WebApp/`：Web 内容缓存、快捷入口和相关生命周期。

扩展不能直接依赖主 App 的 UI 状态；共享数据应使用 App Group、共享容器或 Codable 消息。

## 8. 本地化与产品命名

- 主资源文件：`Localizable.xcstrings`。
- 简体中文键：`zh-Hans`；繁体中文键：`zh-Hant`。
- 新增可见文案优先使用 `String(localized:)`，不要把英文硬编码在 `Text`、`Button`、错误提示或 VoiceOver 标签中。
- 产品名称统一使用 Ze。第三方服务商名称仅在描述对应协议或登录服务时保留。
- 新增文案完成后运行 JSON 解析和本地化键审计：

```powershell
Get-Content Localizable.xcstrings -Raw | ConvertFrom-Json -AsHashtable | Out-Null
git diff --check
```

## 9. 常见改动落点

| 需求 | 首先检查 | 还要同步检查 |
| --- | --- | --- |
| 修改思考/工具扫光 | `Views/Chat/AssistantBlockView.swift` | 深色主题、减少动态效果、列表复用 |
| 修改输入框或浮条 | `Views/Chat/`、`Views/ContentView.swift` | 键盘通知、动画状态、横竖屏 |
| 新增服务商 | `ProviderTypes.swift`、`LLMProviderFactory.swift`、对应 `Providers/*` | 添加/详情页、Keychain、模型目录、本地化 |
| 修改 Kimi 登录 | `Providers/Kimi/OAuth/`、`KimiDeviceLoginSheet.swift` | 错误本地化、刷新并发、Keychain |
| 修改模型分组 | `ModelGroup.swift`、`ModelGroupRouter.swift`、`ModelGroupsView.swift` | 左滑操作、删除语义、同步字段 |
| 修改备份格式 | `ICloudBackupManager.swift`、`ICloudBackupView.swift` | 加密头、导入校验、进度取消、文案 |
| 修改消息删除/长按 | `AIChatViewModel`、消息列表视图 | 通知桥、持久化、同步和撤销行为 |
| 修改版本号 | `Info.plist`、工程 Build Settings、CI 审计脚本 | About 页面和构建产物 |
| 修改原生终端 | `iSH/`、`Agent/ISH/`、`Vendor/ZeNative/ish` | 原生依赖构建、后台权限、路径安全 |

## 10. 测试与构建

### 本地静态检查

```powershell
git diff --check
Get-Content Localizable.xcstrings -Raw | ConvertFrom-Json -AsHashtable | Out-Null
git status --short
```

### 测试目录

- `ZeTests/`：纯逻辑、协议解析、刷新竞态、语音和数据转换测试。
- `ZeUITests/`：页面呈现、输入、导航、长按和关键交互测试。

### CI 工作流

`.github/workflows/` 中的 **Build iOS App** 工作流负责：

1. 准备 Xcode 和 Provider 配置；
2. 构建原生依赖；
3. 解析 SPM 依赖；
4. 执行 Debug 无签名构建；
5. 打包 unsigned IPA；
6. 审计 IPA Bundle；
7. 上传 IPA 和构建日志。

提交前先完成一次集中修改，统一提交并推送，避免同一批功能产生多个并行 Run。构建失败时应以 Run 日志中的第一处真实编译错误为准修复，不能只根据后续连锁错误猜测。

## 11. 维护纪律

- 保持现有分支和 Target 结构，不创建平行项目。
- 修改前先定位真实调用链，优先做最小范围变更。
- 用户可见功能必须有简体中文；错误、空状态、加载状态和辅助功能文案也属于用户可见内容。
- 敏感数据不得写日志；网络错误可以保留服务端错误码，但前缀必须本地化。
- 涉及持久化、同步、备份或协议格式的修改必须考虑旧数据和回滚路径。
- 完成后记录提交、CI Run、验证命令和产物位置，方便后续追踪。
