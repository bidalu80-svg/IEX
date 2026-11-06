# 分享会话与聊天内搜索：原版验收基准

本轮基线为 Ze `4d3d3c65df68e50220a89dfe9b124949316601ed`（Actions `42168726240` 成功）。参考固定为 `OpenMinis/OpenMinis@1a71df0f381cefde80bf912b723de6f9831bc177`，以下是源码导出的要求，不是通过声明。必须将每项的实现、实际交互、截图或导出工件分别核验；源代码结构检查不代替编译、导出或视觉验收。

参考路径均相对 `src/ios/`。原文件由 GitHub 固定提交获取，参考截图清单保存 Git blob 与 SHA256。旧记忆中的分享/搜索实现属于其他 checkout，不作为当前验收结果。

## 分享选择页

| 项目 | 原版行为及可判定验收 | 原版证据 |
| --- | --- | --- |
| 页面流程 | 先选择消息/块，点击“分享 (N)”再进入自动生成的预览页。选择页不是格式配置页。 | `Views/Chat/ChatShareSelectionView.swift`：`ChatShareSelectionView.body` |
| 快照 | 打开时冻结消息快照，流式回复在打开后增加的字不混入本次导出。 | 同文件 `ChatShareRequest.messages` |
| 选择粒度 | 用户消息、代理回传、每个正文块、工具、思考、错误分别选择；空/隐藏块不出现。连续助手消息归入同一回复单元，隐藏桥接消息不拆断单元。 | `Views/Chat/ChatShareModel.swift`：`ChatShareUnits.group`、`ChatShareCells.cells` |
| 初始范围 | 从某消息入口进入时，预选其整轮：前导用户消息到下一用户消息之前的回复/思考/工具/回传/错误；无前导用户消息时从当前回复开始。入口无目标的默认选择应追踪调用方，不能猜测。 | 同文件 `roundSelection`；入口调用方 |
| 真实行渲染 | `ChatShareCellContent` 用聊天真实行，分享页关闭聊天行内部交互；导出也用同一内容。选中增加 0.18 accent 底色和靠左 13pt 勾选标记，不另插勾选列改变布局。 | `ChatShareSelectionView.row` |
| 拖选 | 左侧 36pt 区域从任意行开始选/取消一段；手指反向拖回时还原基线选择；上下 60pt 边缘自动滚动。 | `dragStrip` |
| 向下选择 | 行长按“全选下方/取消下方”；顶部“选择下方”从浮动栏下第一个可见行开始，不能从首个已选行开始。 | `row.contextMenu`、`selectAllBelow`（遮挡阈值 56pt） |
| 工具折叠 | 初始跟随聊天折叠设置；折叠/展开保持选中语义；选中组展开选其所有覆盖块，选中任一成员折叠选组。 | `toggleFold`、`ChatShareCells.remapSelection` |
| 思考过滤 | 隐藏思考同时移出选择；再次显示不伪造恢复选中；仅该偏好持久化。 | `hideThinking`、`deselectHidden` |
| 批量操作 | 工具栏全选/取消全选，浮动清空选择；空选择禁用底部分享，数量为已选 cell 数量。 | `body`、`floatingActions` |

## 分享预览与真实导出

| 项目 | 原版行为及可判定验收 | 原版证据 |
| --- | --- | --- |
| 默认及持久化 | 只记格式；标题默认显示，表格默认聊天宽度，手机默认手机宽/iPad与Mac默认宽布局，主题跟随当前应用。宽度/表格/标题/主题不跨分享持久化，清除旧相关配置键。 | `ChatSharePreviewSheet` 状态、`ChatShareDefaults`、`ChatShareLegacyKeys` |
| 预览控件 | 顶部浮动“长图/PDF”胶囊；底部四项宽度、表格、外观、标题，各显当前值、点击切换、toast反馈。 | `controlBar`、`ChatShareFormatSwitch` |
| 格式手势 | 点击或左右滑动切换格式（12pt开始，超过20pt切换）；过长图片禁用且说明原因，不能静默截断。 | `ChatShareFormatSwitch.select`、`imageUnavailable` |
| 渲染过程 | 进入自动生成，显示分组进度；选项变化取消旧任务；旧任务取消回调不得清空新任务进度；相同参数命中缓存。 | `RenderKey`、`activeKey`、`render` |
| 分享锚点 | 生成首个工件后保留同一 ShareLink；切换渲染时旧链接暂禁用，避免系统分享弹层锚点消失。 | `ChatShareLinkTarget.resolve`、`lastShareURL` |
| 长图 | 实际PNG包含全部已选内容、正确顺序，无重复/缺块/截尾；真实 Markdown、表格、代码、附件和工具卡保持聊天渲染。需保存PNG并检查长内容首尾。 | `ChatExportRenderer` 与 `ChatShareCellContent` 调用链 |
| 图片预算 | 最大60M像素、最大50,000像素高、目标3倍；估算或实际超过预算时转PDF，不生成假成功空图。 | `ChatShareImageBudget`、`ChatShareHeightEstimate`、`render` 的 `imageTooLarge` |
| PDF分页 | 保留真实内容，按可用断点分页；检验多页首尾和中间边界，表格/代码不被随意切断。禁止只检查PDF魔数。 | `ChatSharePagination` 与 renderer |
| 标题隐藏 | 关闭标题同时从页眉、页脚、PDF元数据、文件名清除会话标题。 | 预览 `hideHeader`、renderer 路径 |
| 表格自适应 | 与普通文字宽度独立，画布最多 `max(1000, base*1.4)`；宽表继续换行，不能无限撑宽。 | `ChatShareTableWidth` |
| 缩放 | 长图初始1:1、双向滚动、缩小到适宽、最大4倍和双击；PDF保留分页、缩放和双击。 | `ChatExportImagePreview`、`ChatExportPDFPreview` |
| 后台/错误 | 后台系统快照的主题切换不触发换主题重导出；真实错误显示，取消不伪装错误。 | `ChatShareAppearance.followed`、`render` |

## 搜索语义、交互与显示

| 项目 | 原版行为及可判定验收 | 原版证据 |
| --- | --- | --- |
| 查询语义 | 仅去首尾空白，内部空格保留；整串字面子串匹配，大小写和变音符不敏感。`apple pie` 不匹配 `apple … pie`。 | `Search/ChatSearchEngine.swift`：`ChatSearchMatcher` |
| 命中身份 | 每次非重叠出现均独立计数；同一行、同一消息重复句不去重；身份是 message/block/field + ordinal，不能只按message或行。 | `ChatSearchUnitKey`、`ChatSearchMatch`、`ranges` |
| 上限 | 每单元200、全会话2000；确有丢弃时显示 `2000+`；空查询返回空，无死循环。 | `ChatSearchEngine.search` |
| 范围 | 用户可见文字和文件名，助手渲染后Markdown，信息行，工具胶囊可见标题，子代理标题/状态，已回答问答卡主题/摘要，展开时问题文字，错误和系统/压缩分隔行。思考、原始工具日志、未呈现的卡片字段不索引。 | `Search/ChatSearchUnits.swift`：`snapshot`、`addUserAsk` |
| Markdown一致性 | 渲染后的可见字串与索引保持一致，含链接文本、代码、表格、图片替代文本和流式表格尾部；UTF16范围与ordinal一致。 | `ChatSearchMarkdownText`、`resolveMarkdown`、TextKit高亮 |
| 防抖/取消 | 输入250ms；快照主线程，解析匹配后台；过期任务不得覆盖较新查询；关闭后不回写结果。 | `ChatSearchController.scheduleSearch/runSearch` |
| 初始/导航 | 新查询落最新命中；向下更新、向上更旧，首尾循环并短时提示；Enter下一条、Shift+Enter上一条，键盘保留。 | `ChatSearchNavigation`、`ChatSearchBar` |
| 流式刷新 | 最多300ms刷新，按身份保留当前命中，不自动滚动；选中位置已移除时按原索引夹紧。 | `observeContent`、`relocate` |
| 搜索栏UI | 搜索框36pt/字体15，左右12pt、上下8pt、HStack8；清空/计数仅非空查询显示；等待无结果显示spinner，无结果显文字；导航按钮30×36；完成15pt semibold；背景.bar+Divider。 | `Views/Chat/AIChatView/Overlays/ChatSearchBar.swift` |
| 入口/结束 | 页面菜单和选中文字入口；选中文字预填立即搜索；完成/离开清结果和高亮；输入框隐藏停交互防止抢键盘，保留草稿。会话隔离且owner安全。 | `ChatSearchHostModifier`、`activate/deactivate` |
| 精确定位 | 展开包含命中的折叠工具组；助手正文定位实际TextKit对应ordinal矩形；超长用户消息用位置比例；舒适可见则不抖动，必要时定位可见区1/3处。 | `Coordinator/MessageListV3Coordinator+Search.swift` |
| 滚动模式 | 导航退出自动跟底，流式更新不得把用户拉回底部；布局测量后校正且手指优先；宽度变化后保留当前命中。关闭不回折刚展开工具组。 | `scrollToSearchMatch`、`keepSearchMatchAfterWidthChange` |
| 高亮 | 普通黄色/当前橙色；步进只更新前后两个单元；Markdown基于既有文字存储添加，关闭精确恢复既有背景（如代码背景），不清空所有backgroundColor。 | `ChatSearchHighlights.swift`、`SelectableMarkdownTextView+SearchHighlight.swift` |

## 本轮独立参考工件范围

`scripts/extract-share-search-reference.py` 拉取并记录原版源码哈希，抽取原始完整 `ChatSearchBar`、`ChatSearchFormatSwitch` 以及实际 counter/notice 格式化。仅给 iOS26 glass 分支加编译器条件，旧系统材质分支保持原文。

`scripts/test-share-search-reference-ui.sh` 在真实模拟器窗口生成20张浅深参考图：搜索空/无结果/有结果/截断/等待/首尾循环7态，分享长图/PDF/长图受限3态。状态对象是夹具，按钮动作若意外执行会失败。这组图仅证明上述控件的原版视觉；**不覆盖整个分享选择页、预览工具栏、实际导出、真实搜索跳转或键盘交互**。这些完整链路需要生产交互和导出测试另行验证，不应由控件截图通过推定完成。

Windows只执行提取和静态校验。Swift编译/模拟器生成/像素或人工对比/完整应用编译/IPA审计须记录最终commit和Actions run，旧run成功不得转移到新修改。
