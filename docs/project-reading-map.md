# 项目阅读地图与未完成清单

更新时间：2026-11-06。索引基线：`b5a0e9830066f13c02298bc1ccf570bb0ecb1b10`。

**状态：未完成全项目逐文件阅读。** 此文是当前真实源码的定点阅读记录和后续阅读地图，不是“已完整读取”的证明，也不是整仓正确性审计。文件枚举、符号搜索、已有文档描述、函数内容阅读、运行验证分别记账。之前的模块实现和 CI 结果不能替代尚未阅读的代码。

本次只读任务没有改生产代码。Actions `42212609421` 由主代理跟进；本文编写时不宣称该运行通过，不将旧运行结论转移到当前提交。

## 1. 枚举方法和范围

使用 `rg --files` 枚举实际文件，排除 `Vendor/`、`vendor/`、`build/`、`DerivedData/`、`Assets.xcassets/`、`node_modules/` 等依赖、构建和大资源目录，再选取 Swift/C/Objective-C/Python/shell/YAML/Markdown 等文本候选。一次枚举得到 635 个候选文件：Agent 113、Views 109、Providers 68、Shared 67、NativeOffloads 64、scripts 104，其余为入口、扩展、诊断和文档等。

这个数字仅表示该次过滤命令列出的候选数，不是阅读数；普通 `rg --files` 默认不包含隐藏目录，所以 `.github/workflows/build.yml` 另行直接读取。JSON 模型目录、工程配置、资源、本地化和被排除的原生依赖也仍属于项目，不能从候选数推导完整覆盖率。

路径以当前树为准：消息列表真实位于 `Agent/MessageList/CollectionViewMessageListV3.swift`；Markdown 主实现位于 `Views/Chat/SelectableMarkdownView.swift`；会话内搜索位于 `Views/Chat/ChatSearch.swift`。旧记忆中 `ConversationShareRenderer.swift`、`ChatSearchModel.swift` 在当前路径不存在，不能据此声称已阅读当前实现。

## 2. 真实主链及定点阅读结论

下表“内容阅读”均指所列区域，未标为全文件通读。只枚举/搜索定位的文件明确保留待读状态。

| 模块 | 此次实际内容阅读 | 已确认的结论与后续边界 |
| --- | --- | --- |
| 应用入口 | `ZeApp.swift` 的入口、`init`、根 `WindowGroup` 和根 `onAppear`（约 1–170、264–308） | `@UIApplicationDelegateAdaptor` 挂接 AppDelegate；启动先安装 TextKit guard 和属性查询记录器、应用语言覆盖、预读 Soul、预热 KaTeX/生物认证，再创建真实 ContentView。根出现后另做配置注册、Provider 迁移/模型刷新、默认组创建、后台管理、网络监视和 FileProvider 注册。因此“窗口存在”不等于所有初始化任务结束。后续 scenePhase、URL、共享目录迁移未逐段全读。 |
| UIKit 生命周期入口 | `AppDelegate.swift` 开头至 SceneDelegate 声明（约 1–90） | DEBUG 验证通过启动参数派发异步 MainActor task；真实应用仍由 SwiftUI 拥有 root controller。快捷操作/通知/计划任务/PiP 初始化发生在 didFinishLaunching。完整 SceneDelegate 和系统事件组合仍待审。 |
| 启动画面 | `Views/Launch/LaunchCoordinator.swift` 约 1–140 | 单例状态为 playing/fading/finished；首帧 coreReady 与最小显示时间共同控制退出，工具注册、shell warm-up 等不作为退出门槛。代码包含 1.4 秒最小显示、2.5 秒降级和 0.45 秒淡出；这些是配置值，不是本轮实测启动时延。后台恢复段待完整阅读。 |
| 主导航 | `Views/ContentView.swift` 的 newChat/openSession 通知、手机 NavigationStack destination、启动 `.task`、`handleNewChatRequest`、`popToHomeForQuickAction`、`openSession`；约 410–580、743–850、1087 附近、1994–2110 | 手机通过 navigationPath 承载字符串会话 ID，宽布局使用 selectedSessionId；新聊生成稳定 draft ID。通知目标、快捷操作、已处理分享优先于普通启动默认页；启动任务存在 await 后重新判断导航状态的约束。新聊通知替换手机路径，历史通知先回退再打开。设置页/会话列表全部交互尚未通读。 |
| 聊天 VM 持有 | `Views/Chat/AIChatView.swift` 的 CachedViewModel、init、body/layout/navigation 区域及输入栏接入；约 60–115、262–293、512–780 | `StateObject(wrappedValue: CachedViewModel(...))` 保留延迟构造，避免 ContentView 重算时重复创建包装器和 Combine 订阅；历史走 cache，草稿按 draftId 复用；缓存 stale 标记可调度 reload。完整页面不仅是 collection，也包括输入栏、工具栏、overlay 和大量生命周期修饰器。该大文件仍不是全文件逐行审计。 |
| VM 缓存与切换 | `Agent/Chat/ChatLifecycleSupport.swift` 的 ViewModelCache（约 348–515） | 历史缓存、草稿缓存、stale 标记和内存告警淘汰是不同路径；softCap 为 6，处理中的历史 VM 不应随普通淘汰取消。`get(for:)` 可检查实际会话实例；重开保留 VM 不能被测试用新建临时 VM 替代。文件其余生命周期辅助类型待全读。 |
| 聊天状态 | `Agent/Chat/AIChatViewModel.swift` 的 init 通知注册、模型思考配置和流式暂停状态片段（约 178 起、1020 起）及 send 符号定位 | VM 有后台同步释放、前后台浏览器提示、恢复列表快照等观察者；思考 UI 依赖会话 binding、resolved entry 和 Provider 类型。流式暂停存在待恢复快照，不应以一个输入状态覆盖全会话生命周期。发送/工具循环数千行仍待系统性全读。 |
| 历史加载/持久化 | `Agent/Chat/AIChatViewModel+Persistence.swift` 的 `loadSession` 开头（约 137–196）；`Agent/Chat/ChatStore.swift` 的 RawMessage、createSession、appendMessages、读取消息构造片段 | `loadSession(activate:false)` 会检查后台加载是否仍空闲，防止覆盖输入/队列；重新进入会清理遗留 streamingUIUpdatesSuspended。ChatStore 是 actor；历史夹具用真实 SQLite 会话/消息路径。appendMessages 会丢弃完全无实质内容的助手消息。完整 schema migration、恢复、跨设备合并和数据库损坏修复尚未完整审计。 |
| 真输入框 | `Views/Chat/ChatInputBar.swift` 中 PastableUITextView/PastableTextView、makeUIView 部分及 textViewDidChange 定位（约 806、1179、1220–1280、1470） | UIKit 文本视图是实际 composer；`insertText` 和 delegate binding 路径可验证输入触达 VM。placeholder、换行模式和键盘配置来自该实现。全部粘贴、拖放、语音、硬件键盘分支待全读。 |
| 列表与 Markdown | `Agent/MessageList/CollectionViewMessageListV3.swift`、`Views/Chat/SelectableMarkdownView.swift` 为真实路径；本次以验证文件调用及符号定位为主 | 已确认测试必须检查 production collection 内的渲染文字，单看 messages 数组不够。本次未重新全文阅读两个大文件，不能声称所有复用、排版、TextKit、滚动分支已核实。 |
| Provider 创建 | `Providers/LLMProviderFactory.swift` 开头约 1–145；`Agent/Chat/AIChatViewModel+ProviderFactory.swift` 工厂开头 | 入口先从 ModelEntry 找 ProviderInstance，再按 ProviderType 路由；普通 LLM 与 AgentProvider 包装有各自工厂。API key/OAuth、自定义 base/UA、Azure 等条件影响最终请求，新增模型目录不等于请求协议已兼容。所有厂商请求序列化和 OAuth 刷新尚待逐项完整复核。 |
| 模型目录与兼容规则 | `docs/compatibility-v1.1.4.md` 的模型证据与限制段；`LLMTypes`、`ModelsDevAPI`、`ThinkingLevelCatalog` 等仅路径/调用定位 | 文档说明更新路径是 fallback + models.dev enrichment + bundled JSON；公开目录能力与具体 OAuth/账户可用性分开。本文没有重新访问厂商官网，也没有实发推理请求，因此不把文档模型表视为此次重新核实的新事实。 |
| shell/内核边界 | `Agent/ISH/ISHExecutionCoordinator.swift` 开头约 1–75；`docs/kernel-parity-audit.md` 的实现/验证范围；`Agent/ISH/ZeFsRouter.swift` 路径确认 | coordinator 为 actor；命令使用独立进程和 fs_context token，inflight 用于 stop/owner bookkeeping。文件顶部并发说明与下方遗留“同会话一次一条”的注释不一致，后者不能直接当作实际行为。此前原生工作记录在单独 audit，本次没有重新逐文件阅读 Vendor。 |
| 浏览器 | `Agent/BrowserUse/BrowserUseManager.swift` 开头约 1–65；`BrowserTabPool.swift` 开头约 1–75 | 实际引擎为 WKWebView；manager 主线程持有当前导航/错误/窗口回调；pool registry 的进程总上限为 8，并有跨会话回收及内存告警路径。上限配置不能证明真机内存安全，下载、弹窗、Cookie 与 JS 所有分支仍待完整阅读。 |
| MCP/连接器 | `Agent/Session/MCPStore.swift` 开头配置模型；`docs/github-connector-audit.md` 的操作及验证边界；GitHub 实现文件枚举 | MCP HTTP/STDIO 配置与 guest 共享 servers.json，会话覆盖复用 SQLite；GitHub 核心真实路径在 `Shared/GitHub/`。GitHubRepositoryClient/AccountStore/AIToolGateway 此次未全文阅读；文档中权限、非强推和竞态说明是已有审计记录，不是本轮线上 API 验证。 |
| 分享 | `Views/Chat/SessionExport/ChatShareModel.swift` 开头分组逻辑、`ChatExportRenderer.swift` 开头快照逻辑；分享验收文档 | 隐藏桥接行不应拆断连续助手单元；打开分享需冻结消息及其 block 引用状态，避免流式/折叠变化污染导出。当前主链为 ChatShareSelectionView → ChatShareSnapshot/ChatExportRenderer；目录内旧 SessionExport* 文件仍需核对实际调用范围，不能只因名称相似认定全部淘汰。 |
| 会话内搜索 | `Views/Chat/ChatSearch.swift` 开头 unit/key/match/matcher；搜索验收文档；ConversationSearchVerification 实际主体 | 命中身份包含 message/block/field + ordinal，字面整串匹配只裁两端空白，大小写/变音符不敏感。组件 harness 验证真实 model/TextKit/collection，但它创建独立 UIHostingController，因此不覆盖完整 AIChatView 的输入栏泛型构建。完整搜索控制器和滚动实现仍需单列全读。 |
| 完整页面回归 | `ConversationChatVerification.swift` 全部新写内容与 `scripts/test-share-search-application.sh` 主流程 | 新验证保留真实 root，经 ContentView 导航打开新聊/历史，检查 composer、历史可见文本和输入 binding，重复返回/重开；先写 progress 再导航。它补上了组件测试遗漏的入口，但模拟器系统与用户 iOS 18.1 真机仍是不同边界。 |
| 构建/打包 | `.github/workflows/build.yml` 的 trigger/job、模拟器调用、MinimumOSVersion 检查、上传门禁片段；`Ze.xcodeproj/project.pbxproj` 新文件登记及版本/部署目标行；构建测试脚本 | push 和 PR branches 均为 `**`，另有 workflow_dispatch；设备 build 与 conversation-application 分开，IPA 上传前查询同 run 应用任务结论。主 app 16.0、版本 1.1.4；测试 target/扩展存在各自最低版本，不能混为主 app 系统要求。工作流其他依赖打包步骤未全文重审。 |

## 3. 与本次聊天入口崩溃直接相关的初始化链

```text
ZeApp.init / AppDelegate.didFinishLaunching
  → SwiftUI WindowGroup / ContentView
  → 启动默认页或 newChatRequested / openSessionFromIntent
  → 手机 NavigationStack destination（或宽布局 selectedSessionId）
  → AIChatView.init / 延迟 StateObject(CachedViewModel)
  → ViewModelCache：历史复用、草稿复用或新建 AIChatViewModel
  → AIChatView.body → 页面修饰器组 → chatLayout
  → inputBar → composer chrome → inputBottomRow → 真实输入控件
  → onAppear / 历史 loadSession / collection hydrate
```

关键含义：新聊与历史在数据库加载是否完成之前，都要构建完整输入栏的 SwiftUI 类型元数据。现有 crash 审计记录的栈为 `inputBottomRow → inputBar → body`，因此仅构建分享选择页或搜索 collection 的 harness 没经过故障点；即便其截图和数据断言通过，也不能推出聊天入口正常。

历史约束需要保留：CachedViewModel 应在 StateObject autoclosure 内构造；toolbar 的 `.equatable()` gate 用于阻止流式刷新重建打开的菜单；状态更新遵守 MainActor；缓存与后台流式任务生命周期独立于视图销毁；新聊/通知/分享/快捷操作入口优先级不可被延迟启动任务覆盖。这些约束是此次阅读看到的实现与注释，具体性能效果仍需运行证据。

`docs/chat-entry-crash-2026-11-06.md` 保存设备日志哈希、已符号化栈和修复说明。本次阅读了该记录，但没有重新独立符号化原始 IPS。实际修复将页面和 composer 分段为返回 AnyView 的边界；“提取为 some View 属性”自身不应被当作已经切断运行时泛型深度。最终仍以完整聊天路径实际运行结果确认。

## 4. 已有文档：可复用信息与局限

- `README.md` 已读全文短文：产品名 Ze、本地化、`.zebak`、沿用分支与工作流约定。其“受保护分支触发”描述不够精确，当前 YAML 实际 push 匹配所有分支。
- `CODE_MAP.md` 已读前部至 Agent 目录说明：可用作职责线索，但有空的启动章节、重复章节编号，以及 `Views/MessageList`、`Views/Markdown` 等与实际树不一致的路径。本文未据此认定代码存在，旧地图待独立校正。
- `docs/share-search-acceptance.md` 已读验收项目：分享选择/预览/真实导出、搜索语义/UI/高亮/定位分开验收；原版控件截图没有覆盖整页和完整交互。该文是判据，不是“全部已通过”列表。
- `docs/compatibility-v1.1.4.md`、`docs/kernel-parity-audit.md`、`docs/github-connector-audit.md` 已定点读取；旧记录中的“待 CI/待真机”必须对照新 run 更新判断，不能自动升级为完成。
- `docs/share-parity-audit.md`、`docs/search-parity-audit.md`、`docs/browser-parity-audit.md`、`docs/fork-admission-audit.md`、`docs/rootfs-recovery-audit.md`、`docs/simulator-webkit-overlay.md` 已定位；本次未逐篇完整重读。来源 manifest 和 third-party attribution/license 已确认文件存在，本次没有逐项重新校验全部 blob/hash。

## 5. 明确保留的未完成项

- [ ] 全仓文本候选逐文件阅读并记录结论；当前没有“635/635 已读”结论。
- [ ] AIChatView、AIChatViewModel、ContentView、ChatStore 四个大文件全段梳理，以及所有 extension 调用边界。
- [ ] 列表 snapshot/self-sizing/滚动复用、完整 TextKit/Markdown/附件生命周期审计。
- [ ] 所有厂商请求、流式解码、工具结果回放、OAuth 刷新与迁移；真实账户能力验证。
- [ ] 同步/备份恢复、数据库 migration、文件共享与 FileProvider、通知/快捷操作/后台调度全链。
- [ ] 全部 NativeOffloads、iSH bridge、guest kernel Vendor、rootfs 和外部文件挂载路径；真实 guest 并发与设备内存/CPU 测量。
- [ ] 浏览器下载/Cookie/弹窗/JS/后台恢复和连接器授权/写操作完整实现重审。
- [ ] 语音输入输出、相机/相册、WebApp、Widget、ShareExtension、App Lock 和无障碍完整交互。
- [ ] iOS 16 最低系统与用户 iPhone 15/iOS 18.1 真机入口回归；新模拟器运行不能替代。
- [ ] 当前最终 SHA 对应 CI、导出工件/截图人工检查、性能测量逐项对账。

继续阅读时，每项应记录文件实际内容区域、调用者/被调用者、状态所有者、线程/取消/持久化约束、运行证据与剩余问题。仅新增文件名、运行 grep 或看到旧文档中的“通过”不算完成该项。

## 6. 主代理本轮补读（等待 CI 期间）

- 完整阅读 `AIChatViewModel.swift` 的 init/deinit（178–491）：字体缓存、前后台恢复、脱离视图的 agent 完成回调、同步合并、语音状态各有观察者；同步/快照刷新以当前 activeSessionId 和 processing 状态为条件。没有在此次修复中更改订阅或状态来源。
- 阅读 `AIChatViewModel+Misc.swift` 的 ensureKernelBooted（12–56）：onAppear 后才派发启动任务，执行 rootfs 安装、内核启动、文件变更 hook、路径路由 hook 与默认挂载。这条任务未出现在本次 supplied IPS 的故障调用栈中；其主线程耗时仍是独立未测项目。
- 阅读 `AIChatViewModel+Persistence.swift` 的 loadSession（137–301）：后台加载先检查是否空闲，在 await 后复查；清理残留 UI 暂停、记录 DB sortOrder/count，空历史和有历史均保留挂载行为。后续消息块转换未全读，未声称其完整正确。
- 阅读 `ChatLifecycleSupport.swift` ViewModelCache（约 344–630）：历史 LRU 软上限 6，运行中/前台会话不得淘汰；draft 独立缓存、转正式会话后移除草稿别名；前后台 suspend/resume 与视图生命周期分开。草稿淘汰策略的详细行为尚未运行验证。
- 阅读 `ChatSearch.swift` 1–240：字面量子串、大小写/变音符忽略、UTF-16 范围、单单元 200/全局 2000 上限、取消检查与结果重新定位；后续控制器和全部 Markdown 投影还未在本轮完整阅读。

当前运行基线已更新为 162fb247444d6bc119977895c33585a04d047497。
42212609421 在 chatMediaPresentation 类型检查阶段失败；42215553877 的完整模拟器应用已经编译通过并开始运行检查。此记录不将开始运行写成通过。
