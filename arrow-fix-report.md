# 下滑箭头锚定修复报告

## 范围与交付顺序

仅修改回到底部箭头的锚点登记与选择。按简报先实现、先本地提交；审核在提交之后另行进行，本轮不开展审核。

## 动手前枚举：原有纵向位置的全部输入

- `AIChatView.chatComposerContent` 在输入区上方预留 `36 + 12 = 48pt` 点击区域，使用 `ChatScrollArrowAnchorKey` 收集后代锚点。
- `FloatingToolBar` 登记工具状态条和黑卡（`previewThumbnail`）的可见边界。`LiveFloatingToolBar` 只有在存在未压缩的 assistant 工具块时才挂载工具视图；外层还要求浮条或预览开关至少一个开启。
- `ChatToolPreviewLayout` 按 `toolStatusBarEnabled`、`toolPreviewEnabled` 分别挂载状态条、黑卡，两者可以独立或同时出现；组合布局与附件共用空间，状态条和黑卡底部对齐，所以黑卡顶部可高于状态条。
- `inputBar` 登记 `inputComposerChrome` 的边界；该外壳包含输入行、引用和自动压缩提示。任务暂停时额外登记等待提示。DEBUG 只读模式不挂载输入框，登记 `forkBanner` 替代输入区。
- `InputAttachmentGridView` 登记附件卡片、视频加载卡片；`AttachmentChip` 的文件、缩略图、视频加载路径还登记向上偏移 4pt 的删除按钮。
- `attachmentPreviewTray` 为附件锚点登记裁剪区。解析锚点时先将卡片/删除按钮边界与滚动区求交，丢弃空边界，再对所有来源的 `minY` 取最小值。
- 箭头只在消息非空且 `!vm.isNearBottom` 时出现；按钮圆形为 36pt，底部 padding 为 12pt，定位中心为 `visibleTop - (36 + 12) / 2`，因此圆形底边位于锚点顶部上方 12pt。显隐沿用原有透明度/缩放过渡与动画。
- 父级 `ChatKeyboardViewport` 的键盘/安全区底部约束、工具区/附件/输入框实际高度和间距决定锚点坐标。`hasFloatingPreview` 决定附件独立显示还是传入工具区。`maxContentWidth` 及水平 padding 影响布局宽度、换行和最终高度。
- `inputBarHeight`、`floatingBarHeight`、`standaloneAttachmentTrayHeight` 没有直接进入这颗箭头的纵向公式；它们仍用于原有宿主刷新、消息列表、下载按钮、弹出菜单等路径。
- 原有定位未区分锚点职责：黑卡、附件或等待提示只要比浮条/输入框更高，就会被选为箭头锚点。

## 文件与行为变更

| 文件 | 变更行为 |
| --- | --- |
| `Views/Chat/ChatInputBar.swift` | 为箭头锚点增加 `toolStatusBar` / `inputBar` 两种明确类型；删除附件、加载卡片及删除按钮的箭头锚点登记；移除不再需要的附件锚点裁剪字段。所有附件视图自身布局与操作保持原代码。 |
| `Views/Chat/ToolLiveSheet.swift` | 工具状态条登记为 `toolStatusBar`；黑卡不再登记箭头锚点。状态条与黑卡的挂载条件、尺寸、排列、动画、点击与 sheet 行为均未改动。 |
| `Views/Chat/AIChatView.swift` | 从同一布局遍的有效锚点中优先选择实际挂载的状态条，否则选择输入区；输入外壳及 DEBUG 替代输入区登记为 `inputBar`；删除等待提示的箭头锚点登记和附件专用锚点裁剪；更新箭头注释。36pt 按钮、12pt 间距、预留点击空间、显隐与回底操作均沿用原代码。 |
| `arrow-fix-report.md` | 记录动手前枚举、修改范围、规则对照和验证限制。 |
| `arrow-fix.bundle`（交付附件，不纳入提交） | 保存以本克隆当前 HEAD 为父节点的本地修复提交，供可写 Git 环境导入。 |

## 锚定规则改前 / 改后

| 场景 | 改前 | 改后 |
| --- | --- | --- |
| 浮条和黑卡均可见 | 取全部锚点最高处，黑卡较高时锚到黑卡 | 浮条顶部上方 12pt |
| 只有浮条可见 | 可能被更高的附件/删除按钮抬高 | 浮条顶部上方 12pt |
| 浮条不可见，只有黑卡可见 | 黑卡顶部上方 | 输入框可见外壳顶部上方 12pt |
| 浮条不可见，有附件/等待提示 | 可能锚到附件、删除按钮或等待提示 | 输入框可见外壳顶部上方 12pt |
| 浮条、黑卡均不可见 | 取输入区及其他附件锚点最高处 | 输入框可见外壳顶部上方 12pt |
| DEBUG 只读模式 | 替代输入区与其他锚点共同取最高处 | 浮条优先；浮条不存在时使用原有替代输入区 |

浮条是否存在以当次布局实际发布的状态条锚点为准，不使用预览开关或缓存高度推断。

## 验证与限制

- 使用逐段字节替换写入 Swift 文件，保留原有混合 CRLF/LF；行尾计数：AIChatView 为 CRLF 7012→7013、LF 772→768；ToolLiveSheet 为 CRLF 2771→2771、LF 16→15；ChatInputBar 为纯 LF 1736→1734，无整文件行尾翻转。
- `git -c core.whitespace=cr-at-eol diff --check` 通过。提交前仅作行尾与补丁空白检查，不开展审核。
- 当前 Linux 环境无 `swift`、`xcodebuild` 和 iOS 模拟器，未运行 Swift 编译、应用 UI 测试或真机验证；不能将本次实现报告视为真机验证结论。
- 独立审核及设备验证留待本地提交之后另行进行。

## 本地提交的环境限制与交付方式

标准 `git add` / `git commit` 被文件系统拒绝：`.git/index.lock: Read-only file system`。本克隆 `.git` 只读，不能更新当前分支，也不能在当前克隆暂存文件。

因此在 `/tmp` 的独立可写 Git 仓库创建本地提交，以本克隆当前 HEAD 为父节点，只纳入上述三个 Swift 文件和本报告；通过根目录 `arrow-fix.bundle` 持久保存该提交。原克隆 HEAD 不变，工作区修改保留。提交包包含 `refs/heads/arrow-fix`，依赖本克隆已有的父提交。

在 `.git` 可写的同一基线克隆中导入（若使用此工作区，先保存/清理相同的未提交修改）：

```bash
git fetch ./arrow-fix.bundle refs/heads/arrow-fix:refs/heads/arrow-fix
```

该导入操作不会自动切换或更新当前分支。提交哈希由执行结果提供；本轮没有进行提交后的审核。
