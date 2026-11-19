# 聊天前台恢复与流式呈现修复

基准：`86df37370a5aac09bc008ee5fbdb341c6e2f7da7`。施工期间新增的 `evidence-update-1601.md` 也已阅读：验收包括正文、头像动画、服务商胶囊轮替、等待动画，不能仅以正文恢复为完成。已全文阅读 `fg-refresh-diagnosis.md` 并查看原图 `evidence-fg-refresh.jpg`。以下门控盘点在修改生产代码之前完成。没有 #714 真机运行日志，不能把静态缺口说成已证实的唯一根因。

## 施工前四层盘点

| 层次 | 门控 / 缓存、全部写入清除面 | 对照诊断及处置 |
|---|---|---|
| 内容进入 block | SSE 取消检查；正文 0.2–2 秒节流、短正文换行快速路径；MainActor 按 message/block 下标写入 | 已核实；保留网络、节流、执行与持久化行为 |
| 内容进入 block | `streamingUIUpdatesSuspended` 初始 false；普通暂停 / 会话切换置 true；唯一 clear 方法置 false。inactive 缓存 VM 批量暂停、拖动暂停；active、发送、滚底、settle、loadSession、会话切换结束恢复 | 已核实；恢复先排空 deferred text 再清标志、再通知。补当前挂载列表直接恢复所持 VM，覆盖 cache 以外对象；不改 cache/草稿管理 |
| 内容进入 block | deferred text 按 messageId/blockId 覆盖最新值；排空清数组，按 ID 找对象；持久化前也排空；流尾 / 转工具还有直接补写 | 已核实；保留现有入口，不从 DB 重载，不重启请求 |
| 内容进入 block | `transitionSuspended` 会话切换置/清；VM invalidation 延后；任务结束 `needsSnapshotReloadOnResume` 在 active、clear、onAppear 消费 | 已核实；前台补偿避开 outgoing transition；保留任务完成信号 |
| 内容进入 block | thinking 非 Published buffer 按 0.3/0.6/1 秒节流写 Published content；工具状态 / 参数 / 问答卡独立发布 | 已核实；前台恢复不能只按正文字符数判定，不改执行逻辑 |
| item 进入 snapshot | attach/bind；VM 对象变更清订阅；`$messages`、processing=true 重订阅最后 assistant；message.objectWillChange；blocks.count 去重；终止取消订阅 | 已核实；前台重新绑定最后 assistant，覆盖同 ID 新对象 / 旧订阅；正文仍由 block 独立观察 |
| item 进入 snapshot | `hasPendingSnapshot` loading / suspended 置位；load 完成、flush 清；flush 原先先清再 apply，可能被 loading 拒绝 | 已核实；flush 只有可应用时才消费标志，前台恢复也保留 loading 延迟刷新请求 |
| item 进入 snapshot | snapshot 只比较有序 item ID；`snapshotMessages` / lookup 先更新；ID 不变跳过 diffable apply | 已核实；保留正常去重，前台主动重配（含 ID 不变），不把一次 invalidateLayout 当作重配 |
| item 进入 snapshot | processing/retry/countdown/canResume bridge 去重；折叠、usage、footer 条件；工具分组设置 | 已核实；前台重建采用现有 applySnapshot 规则，保留业务条件 |
| 宿主 → TextView | content/composer render key；content 动画期 pendingUpdate 只留最新；host dirty、尺寸差 >0.5 门控；600ms fallback / 120ms settle，begin/schedule/end/deinit 替换或取消工作 | 已核实 `a6ca6c42` / `16419902` / `faf6b070`；补正文/输入宿主 scenePhase、正文 VM identity、独立顶栏 scenePhase，active 收尾键盘事务；保持逐帧几何门控 |
| 宿主 → TextView | `AssistantBlockView` 观察 block/message，空正文不创建 Markdown；VM 只在 empty→filled 发 reconfigure 信号 | 已核实；保留空内容条件，前台无字数门槛重配全部现有 item |
| TextView 内容 | lastMarkdown/字号第一门；background 或 inactive≥30s 保存最新 pending render，didBecomeActive 重放；内容 hash 第二门；图片选择 / 字号重置 | 已核实已有 foreground handler；补空 TextView 恢复及 deferred replay 绕过两道去重、清过期 pending；不移除后台绘制保护 |
| TextView 尺寸 | 宽度桶 + 原文长度缓存；TextKit storageLen/width/tableGeneration 指纹；滚动 defer 的 600ms 重试；附件恢复 / 尺寸通知 | 已核实；保持正常尺寸计算与附件逻辑；真实重绘清尺寸桶，前台清 cell/layout 缓存 |
| cell / layout | cell 50ms dedup；离屏无 window/configuration 防崩；scroll/stream 非流式 item 同宽缓存；streaming precalc；seed；super 前同宽缓存；super 后另一无限同宽缓存；ObjC exception/lifetime 防护 | 已核实 `7b65a4d5`；限制键盘缓存适用期、移除后置无期限返回；明确失效连 seed 一并清。保留短窗与防崩保护 |
| cell / layout | `lastComputedHeight/Width/time` 在配置 / clear / reuse 清；seed 在配置与首次命中清，原 clear 未清 seed；clipsToBounds=true | 已核实；保留裁剪，通过正确失效恢复测量 |
| cell / layout | Layout heightCache、precalc、estimated、content-key memo、deferredHeights、geometryConfirmed；宽度变化 / clearHeightCache 清高度缓存，但 clearHeightCache 不清 deferredHeights；前台恢复由 applyDeferredHeights() 先排空 deferredHeights 队列；普通 invalidateHeight 不清 precalc；invalidateLayout 不清上述内容 | 已核实；前台清高度缓存再从当前模型建快照；正文实际 TextKit 高度变化同时淘汰其旧 precalc，避免 streaming precalc 再把旧高度带回 |
| cell / layout | `deferSelfSizing` 拖动置 true、settle 清 false；键盘标志由 viewport begin/end 写；任务完成 / usage / canResume、空→非空、字号、附件、thinking/问答卡、展开各有显式失效 | 已核实；补前台清遗留 defer 和应用 deferred heights，键盘 settle 清可见 cell 缓存及对应 layout 高度 |
| 非正文门控 | 顶栏头像键、标题键、Toolbar/原生菜单键、回复/工具 EquatableContextMenu 键、输入测量 text/width/font | 已逐项对照诊断字段表与定义；原正文诊断中顶栏不控制正文，但补充证据把顶栏也纳入验收：顶栏宿主同样捕获旧环境，补其键的 scenePhase。标题/菜单/输入测量不修改 |

同一模型的其他写入者（发送/编辑/重试/恢复/停止/排队、Persistence 整体替换、Compaction 插删、Misc 撤回删除、清空会话）已检索；没有用户在故障期间执行这些动作的证据，本次只补呈现失效。计时器为独立 `TimelineView`，继续跳动不能证明正文链路正常。

## 实现与验证

### 逐文件、逐处行为变化

1. `Agent/MessageList/MessageListInfrastructure.swift`
   - super 前同宽缓存原用于阻止键盘逐帧反复进入 SwiftUI/TextKit；条件改为当前 layout 确实 `isKeyboardTransitioning`，DEBUG 计数不再是唯一检查此标志的地方。
   - 删除 super 后另一个无时限同宽返回，避免前一道修完后仍被后一道旧高度盖回。改后普通静止/流式内容允许重新测量；保留 50ms 去重、离屏防崩、滚动/流式专用防重入、precalc、ObjC exception 和 extended lifetime 保护。
   - `clearCachedHeight()` 同时清 seed/seedWidth。原用途是下次重测，原实现却允许旧 seed 再度短路。影响是显式失效一定摆脱旧内容 seed，正常复用播种仍保留。

2. `Agent/MessageList/MessageListLayout.swift`
   - 新增 `invalidateContentHeight(at:)`：同时清实测高度、content memo、geometry 标志、precalc 和该项 deferred height。只在正文实际高度变化、键盘 settle 和前台补偿中调用；普通 `invalidateHeight` 的既有策略不扩大改变。
   - 新增 `finishKeyboardTransition()`：解除键盘标志、清可见 cell（含 seed）和对应 layout 内容高度，再 invalidate。原来结束时仅改标志与 invalidate，不能保证被动画门控留下的旧高度失效。影响是动画期间保护仍在，动画结束付出一次可见区真实测量。

3. `Views/Chat/ChatKeyboardViewport.swift`
   - Representable 观察 scenePhase；传给 controller 的正文/输入 display key 加一层 `EnvironmentRenderKey(display, phase)`。原 render-key 门控用于压住纯几何 body pass；改后生命周期变化可以替换显式注入环境的 root，几何字段仍不进入键。nil key 的旧 harness 行为保留。
   - 监听 didBecomeActive，显式调用既有键盘事务收尾，排空 pending 最新正文；不等键盘下一次动作或 fallback。600ms fallback、120ms settle、composer 即时更新、正文动画期间合并继续保留。
   - 收尾调用 layout 的新方法，保持已提交 composer 几何与结束通知的原顺序，释放旧高度。
   - hosted-layout dirty/尺寸门控保留；生命周期 root 更新会置 dirty，未添加逐帧强制布局。

4. `Views/Chat/AIChatView.swift`
   - 正文 key 新增 `ObjectIdentifier(vm)`，同 session / 相同首尾 ID 的新 VM 也能送达下层已有 rebind 机制，避免其因外层 key 相等而永远不可达。
   - 独立顶栏 `ChatNavigationHeaderKey` 增加 scenePhase，调用处传入当前 phase。顶栏也注入完整 EnvironmentValues，原键用于键盘防卡，但漏掉生命周期；改后 active 能送到 `SoulHeaderAvatarSurface` 与其余顶栏状态视图。
   - 直接证据：头像 `playing: scenePhase == .active && !reduceMotion`、等待动画 `paused: reduceMotion || scenePhase != .active`；这解释为什么旧环境值得优先修复。服务商/模型 3 秒轮替是 `SoulHeaderActivityText` 自有 task，并非单凭此键便可静态证明已恢复，必须真机验收。

5. `Agent/MessageList/CollectionViewMessageListV3.swift`
   - 删除后台记录长度 / willEnterForeground 增长≥200 字门槛。原用途是省无明显增长时的布局成本，但不覆盖短增量、工具状态、thinking、环境或 deferred buffer，且读取早于 VM 释放。
   - 改为 didBecomeActive 记录待刷新，`refreshAfterForegroundIfNeeded()` 仅在 active、当前 VM 不在加载/切换中、列表有 window 时处理；加载完成和 updateUIVC 有补偿入口，不提前丢掉一次被 loading 挡住的恢复。
   - 先清遗留 scroll defer、应用 deferred heights、直接恢复当前列表的 VM（包括未进入 cache 的 draft）；然后重订阅最后 assistant，清 layout/高度 memo、测量缓存和可见 cell 缓存，从当前模型建 snapshot，再主动 reconfigure（现有该 helper 实际标记所有 item）。因此没有 pending 标志也恢复，ID 不变也重配。不会 DB reload 或重新请求网络。
   - 下一个主队列 tick 再清可见 cell/layout 内容高度，让异步 UIHostingConfiguration 提交后的新内容能重测；仅原本 autoScrolling 时排原有合并滚底，不修改浏览模式。
   - pending snapshot flush 新增 loading/suspend 可应用条件，防止先消费标志、后被 applySnapshot 的 loading guard 拒绝。正常 ID 去重、折叠、分组、footer 条件保留。

6. `Views/Chat/SelectableMarkdownView.swift`
   - 原文/字号去重及 hash 去重在“非空原文却没有 attributedText”时允许恢复，避免只记录空渲染诊断后继续返回。
   - 活跃的最新 update 取消旧 pending frame；deferred replay 用 `forceNextRender` 穿过原文门控并清 hash。包含空 frame 清除旧文本的情况；保留 background / inactive≥30 秒保护与 didBecomeActive 重放时机。
   - 真正接受重绘时清宽度尺寸桶，避免同长度替换命中旧尺寸；保留正常文本去重与绘制、附件算法。
   - TextKit 确认高度变化后，除了清 cell，还按其 indexPath 调用新的内容高度失效方法，再 invalidateLayout，避免 streaming precalc 把旧高度再次带回。原有 reentry/fingerprint/defer 重试保护保留。

7. `scripts/KeyboardViewportHarness.swift`
   - 既有键盘 fixture 的 layout stub 补 `finishKeyboardTransition()` 接口，保持该 fixture 可以组装。它仍不测试真实消息 layout，不把它当整页恢复证据。

8. `scripts/ForegroundRefreshHarness.swift`、`scripts/test-fg-refresh.py`
   - 新增 iOS simulator 行为回归：使用不改写的生产 host、SelfSizingCell 和 MessageListLayout，检查相同 display key 的 active 环境更新、键盘 pending 提前释放、同宽原位正文增长、键盘缓存保留/结束释放、streaming precalc 淘汰、seed 清理。
   - logger、ObjC exception bridge、消息数据为 fixture；不含生产 VM/coordinator/Markdown，也不证明真机后台与输入法性能。脚本记录来源 SHA256，并支持 Linux `--prepare-only` 生成源文件供后续编译。

### 本地检查结果

- `git -c core.whitespace=cr-at-eol diff --check`：通过。需保留 CRLF，未用默认 whitespace 设置把 CR 当空白问题后再统一换行。
- 按 git HEAD 与工作树逐行对齐，所有未修改行原始字节完全一致；LF 文件保持 LF，两个混合文件仅局部插入/替换沿用原片段换行。无整文件行尾翻转。
- `python3 scripts/verify-user-message-collapse.py`：16 项结构检查通过（只是与既有展开/锚定逻辑的兼容检查）。
- 新 foreground harness 与既有 keyboard harness 均已成功组装到 `/tmp`；新 Python runner 语法检查通过。
- `python3 scripts/test-fg-refresh.py`：明确 SKIP。此 Linux 环境没有 swift/swiftc/xcrun/xcodebuild，**没有执行 Swift 编译、iOS simulator 断言、真机后台恢复或键盘性能测试**，不把组装通过当作运行通过。

### 待执行的验收（非本轮已通过项）

在 Xcode 主机运行 `python3 scripts/test-fg-refresh.py`，并运行现有整应用键盘回归。随后在真机留在原聊天页验证：

- 流式正文（含不足 200 字、空→非空、多段 Markdown/表格/代码）每个既有节流 flush 后持续可见增长；cell 高度同步。
- 输出时退后台回前台、输出在后台结束、后台新增工具/thinking、拖动或键盘动画期间退后台，原地立即追上当前内容，不经主页重进。
- 同页逐项确认：正文刷新、头像动画、服务商↔模型轮替（空闲且名称不同时每 3 秒）、等待动画。启用减少动态效果或自定义静态头像时按原产品条件验收。
- 多次往返、草稿、历史会话、加载中返回、浏览旧消息、iPad 宽度变化及键盘 show/hide/keyplane，确认浏览锚点与键盘防卡没有明显回退。

本轮是实现交付，不是独立审核结论。按简报先本地提交，审核另行进行。没有推送、部署或触发外部 CI。

### 本地提交的沙箱限制与交付位置

直接在本克隆执行 `git add` 时失败：`.git/index.lock: Read-only file system`。当前环境明确把本克隆 `.git` 设为只读，且禁止请求提升权限；没有修改该权限，也没有更新本克隆 HEAD/index。

为完成“先本地提交”的交付，在允许写入的 `/tmp/ze-fg-fix-commit.*` 隔离 Git 克隆中，以本克隆 HEAD 为精确父提交，提交上述文件；提交工作树取自本克隆的已实现文件。根目录 `fg-fix.bundle` 保存该本地 `fg-fix` 分支相对基准的提交，可以在有 Git 写权限时导入。bundle 是持久交付物，不依赖临时 Git 目录长期存在。原有 brief、诊断、截图及新增证据作为输入材料保留，不纳入修复提交。

验证/导入方式（需要本克隆 Git 可写时才执行 fetch）：

```sh
git bundle verify ./fg-fix.bundle
git fetch ./fg-fix.bundle fg-fix
# FETCH_HEAD 即修复提交；先审核，再按实际分支流程集成。
```

此处只完成本地实现和提交，未进行提交后的独立审核。


## 第二轮：provider harness 编译接口补齐

父提交：`716032cd80c2a1c3a9e6f21aa2ca1dae2b764fc9`。根据 `brief-fg-fix2.md`，仅修改两个文件：

- `scripts/ProviderChatChromeHarness.swift`：桩 `MessageListLayout` 补 `finishKeyboardTransition()`，与 keyboard harness 桩一致，先将 `isKeyboardTransitioning` 置 false，再 `invalidateLayout()`；更新上方过时注释。生产 viewport 与此桩拼接时，现在具备调用所需的方法。
- `fg-fix-report.md`：纠正盘点表中的清理描述；`clearHeightCache()` 不清 `deferredHeights`，前台恢复先调用 `applyDeferredHeights()` 排空队列。没有修改对应生产实现。

上一轮的键盘事务提前收尾、可见 cell/seed/高度失效、非键盘阶段移除无限同宽缓存、生命周期替换 root 均保留。**键盘回退待真机验证。**

本轮本地验证：执行 provider chrome 原有提取脚本，检查拼接源中的 viewport 调用与桩方法，以及未修改行的原始字节。Linux 无 Xcode，未执行 Swift/iOS 编译；提取成功不代表 CI 或真机验证通过。按要求先实现、先本地提交，独立审核另行进行。

沿用上一轮隔离 Git 提交方式，原克隆 `.git` 仍只读；导出根目录 `fg-fix2.bundle`，包含第一轮及本轮提交，依赖原基准 `86df3737`，可在原基准克隆中验证并导入 `fg-fix2` 分支。未修改原克隆 HEAD，未推送或触发 CI。
