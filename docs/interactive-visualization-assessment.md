# Ze 正文交互可视化方案评估

日期：2026-11-07。代码基线：`f3eb01464255a1607594ad306b85d7009989e6fd`，分支 `codex/aojit-real`。

状态：研究与接入设计，尚未实现或验证新的 iOS 图表组件。

参考原稿：`C:\Users\Administrator\Desktop\chatgpt.md`，SHA256：`7523b96e45ab55b1d29ad706c4c3b4b1ece01bbad17fecb3d9bc088fecabbd1f`。原稿完整阅读，保持原件不变；本文是面向现有 Ze 的修订评估，不把原稿中的新建应用指令直接作为修改要求。

## 结论与证据边界

原稿的“结构化数据 → 固定组件 → 交互事件”方向可用，足以指导指标卡、数据表和常见交互图表。它不是可直接执行的完整集成方案，需要补上 iOS 16、现有正文架构、真实数据来源、流式解析、持久化、分享、搜索与性能设计。

截图中的油价展示可以用标题、副标题、圆角描边容器、两列指标网格、大号数值、次级标签和卡片外来源链接实现。静态截图只证明外观，未证明点击后的行为；第三张分类示意也不能证明所有列出的类别都是某次产品更新已经上线的功能。精确字号、留白和动态行为仍需以实际参考画面核对。

已读取 OpenAI 官方开源 Apps SDK 示例，确认其提供工具返回结构化结果、独立 UI 资源、组件状态和 UI 调用工具的公开实现。这是可借鉴的架构，不能当作 ChatGPT 内置油价卡或 iOS 客户端的内部源码。未获得证据确认截图对应的具体近期更新日期或内置渲染库。

访问 OpenAI 产品公告、帮助中心和开发文档时收到 HTTP 403；Learn 页面超时，公开文本代理也超时。搜索结果未提供足够直接证据，因此不把搜索摘要写成已核实的产品发布事实。

## 官方来源

OpenAI 官方仓库读取时的提交：`18cc38e78a968712c357bacdc3c79fead5bfc6b4`。

- [Apps SDK 示例说明](https://github.com/openai/openai-apps-sdk-examples/blob/18cc38e78a968712c357bacdc3c79fead5bfc6b4/README.md)：工具契约、结构化结果、UI 资源，以及列表、轮播、地图等示例。
- [交互组件](https://github.com/openai/openai-apps-sdk-examples/blob/18cc38e78a968712c357bacdc3c79fead5bfc6b4/src/kitchen-sink-lite/kitchen-sink-lite.tsx)：`toolOutput`（98 行）、`setWidgetState`（163 行）、`callTool`（195 行）分别用于数据、状态和操作。这里是网页组件，不是 SwiftUI 组件。
- [工具服务端](https://github.com/openai/openai-apps-sdk-examples/blob/18cc38e78a968712c357bacdc3c79fead5bfc6b4/kitchen_sink_server_node/src/server.ts)：HTML 资源 MIME（51 行）、`structuredContent`（264、279 行）。
- [Apple ChartProxy](https://developer.apple.com/documentation/charts/chartproxy)：官方文档 JSON 的 `metadata.platforms` 确认 iOS 16.0 起可用。
- [Apple SectorMark](https://developer.apple.com/documentation/charts/sectormark)：官方文档 JSON 确认 iOS 17.0 起可用，用于饼图、环形图。
- [Apple SwiftData](https://developer.apple.com/documentation/swiftdata)：官方文档 JSON 确认 iOS 17.0 起可用。

Apple 可机器读取证据路径：`https://developer.apple.com/tutorials/data/documentation/charts/chartproxy.json`、`charts/sectormark.json`、`swiftdata.json`（后两项同一 documentation 根路径）。

## 原方案逐项处理

| 原方案 | 评估与修订 |
| --- | --- |
| AI 选择组件并输出 JSON | 保留。使用版本化、有限组件集合与严格校验，模型选择内容和呈现类型，App 决定具体布局。 |
| 新建 SmartUI 应用和聊天层 | 接入现有 Ze，不重建聊天、登录、工具或存储体系。 |
| SwiftData | 改用现有 SQLite 存储，保留 iOS 16。 |
| Swift Charts 折线、柱状、面积与多序列 | 适合原生实现。选择手势用 iOS 16 可用的 overlay/ChartProxy 路线；逐个审查所用 API availability。 |
| Swift Charts 饼图 | `SectorMark` 要 iOS 17。iOS 16 用自定义 Shape/Canvas 扇区和命中测试，或全版本采用同一自定义实现。 |
| 触点提示、范围切换、缩放 | 是需要实现的交互，不会因为使用 Swift Charts 自动全部具备。正文优先点选/长按；复杂缩放放大图页，避免抢聊天滚动手势。 |
| `data_source: fuel_price_history` | 只是符号，不是可运行数据源。需要已有工具提供实际点列，或注册真实数据适配器并处理凭据、时间范围、失败、配额。 |
| 股票、天气、汇率等实时数据 | 展示组件可复用；每种实时数据仍需单独接入来源，记录地点、时区、单位、有效日期和取得时间。 |
| 自动刷新 | 历史消息保留快照；用户明确点击刷新后才请求来源。禁止滚动复用、重新打开历史或重绘时隐式刷新。 |
| 新闻、日程、地图、WidgetKit | 作为后续独立功能验收，不能用卡片外壳代表数据和操作已完成。 |

## Ze 当前入口（E1）

- `Agent/Markdown/ZeMarkdownParser.swift`：`BlockNode` 有 table/codeBlock/htmlBlock 等，无仪表盘或图表节点。
- `Views/Chat/AssistantBlockView.swift:136`：正文使用 `SelectableMarkdownView`。
- `Views/Chat/SelectableMarkdownView.swift:468`：`MarkdownNSRenderer.renderBlock` 分发；837 行为表格附件；989 行 `renderHTMLBlock` 输出普通 attributed string；5563 行起更新附件视图。模型吐出 HTML 本身不会在此执行为交互图表。
- `Agent/Chat/ChatModels.swift`：`AssistantBlock` 保存正文、解析缓存和渲染缓存；`AssistantBlockKind` 尚无可视化类型。
- `Agent/Chat/AIChatViewModel+SSEStream.swift` 和 `AIChatViewModel.swift`：流式解析、最终 flush、历史加载均会生成 Markdown 缓存，新类型必须经过这些路径。
- `Agent/Chat/AIChatViewModel+ToolDefinitions.swift:16`：现有工具定义入口；`AIChatViewModel.swift` 使用 `SystemPromptBuilder` 并拼装能力说明。
- `Agent/Chat/ChatStore.swift:2`：现有 SQLite 存储。
- `Views/Chat/ChatSearch.swift`：`ChatSearchMarkdownText.appendBlock` 构建与真实渲染一致的可搜索文本。
- `Views/Chat/SessionExport/ChatExportRenderer.swift`：实际分享布局、表格宽度、绘制与 PDF 文本路径，需要同步支持可视化附件。
- `Agent/MessageList/MessageListInfrastructure.swift`：消息单元复用、附件宽度与高度失效路径。
- `Ze.xcodeproj/project.pbxproj`：主应用 deployment target 为 iOS 16.0，版本 1.1.4。

## 建议接入方式（设计，不是已完成代码）

第一版采用正文中专用 `ze-visualization` fenced block，载荷是版本化 JSON。通过既有 Markdown `.codeBlock` 入口识别，再交给独立的解码、校验和可视化附件实现，避免第一步就改变所有消息类型与历史存储格式。普通 code block 行为保留。不要将所有两列表格自动转换成油价卡。

工具能力允许时，可补充 `present_visualization` 展示工具，最终仍归一到同一载荷和渲染组件；展示工具必须与实际取数工具分开。无工具调用能力的服务商走正文协议，校验失败时展示可读回退。即使模型有结构化输出能力，客户端仍需校验；不同服务商不能假定拥有相同的 JSON Schema 支持程度。

数据流：真实来源/用户数据 → 标准化数据与来源记录 → 模型选择组件 → 验证载荷 → 正文附件 → 原生组件。交互状态单独保存；范围切换、图例隐藏和排序在本地完成，需要新数据的刷新才走既有工具执行器。

建议新增独立文件组：

- `Agent/Visualization/VisualizationDocument.swift`：Codable 模型、schema 版本、有限类型。
- `Agent/Visualization/VisualizationValidator.swift`：资源上限、数值、引用和类型检查。
- `Agent/Visualization/VisualizationProjection.swift`：复制、朗读、搜索、无障碍使用的统一可读文本。
- `Views/Chat/Visualization/VisualizationAttachment.swift`：TextKit 尺寸、挂载、复用、快照。
- `Views/Chat/Visualization/VisualizationView.swift`：组件注册与布局。
- `Views/Chat/Visualization/MetricGridView.swift`、`InteractiveChartView.swift`、`InteractiveTableView.swift`：具体组件。

上述是计划路径，当前未创建这些 Swift 文件。

## 载荷契约与示例

公共字段至少包含：`schemaVersion`、稳定 `id`、`title`、`subtitle`、`sources`、`components`。数据源记录区分 observation/effective time 与 retrieved time；每个数据集有单位、时区（如适用）和 source IDs。时间序列允许明确缺失值，缺失不自动变成零或补出趋势。

示例仅为协议演示，数值标记为演示数据，不代表当前官方油价：

```json
{
  "schemaVersion": 1,
  "id": "fuel-demo",
  "title": "油价指标展示示例",
  "subtitle": "元/升 · 演示数据，非实时价格",
  "sources": [
    {"id": "demo", "kind": "demo", "label": "布局演示数据"}
  ],
  "components": [
    {
      "id": "fuel-metrics",
      "type": "metric_grid",
      "columns": 2,
      "unit": "元/升",
      "sourceIDs": ["demo"],
      "items": [
        {"id": "92", "label": "92号汽油", "value": 8.91, "precision": 2},
        {"id": "95", "label": "95号汽油", "value": 9.65, "precision": 2},
        {"id": "98", "label": "98号汽油", "value": null, "missingReason": "暂无数据"},
        {"id": "diesel", "label": "0号柴油", "value": 8.60, "precision": 2}
      ]
    }
  ]
}
```

图表另定义有类型的轴（时间/数值/类别）、点列与序列 ID；不采用含糊的通用 `data` 字典。禁止仅给 `data_source` 名称就显示随机走势。图表切换选项按数据语义提供：负值、非占比数据不能随意切成饼图。占比应使用有效分母和明确处理零总和；时间断档保留空缺，重复时间点按明确规则处理。

建议初始资源预算（待设备实测调整）：单个载荷 256 KiB、最多 12 个组件、每图最多 8 条序列/总计 2,000 个显示点。超限先给可读降级和打开详情入口；如以后实现抽稀，应保留原始数据供导出，并标注显示采样。数字必须有限且通过所选图表的范围约束；未知版本/组件、重复 ID、无效引用都走确定性回退。

## 功能与 UI 验收矩阵（E2）

| 类型 | 首版外观 | 真实交互验收 |
| --- | --- | --- |
| 指标网格 | 参考油价图的两列网格、层级和间距，浅深色适配 | 点击有明细时展开单位、日期、来源；无明细不显示虚假的可点击状态；数值可复制。 |
| 折线/面积 | 轴标签、单位、图例、合理空态 | 点选或长按读数，范围切换只显示真实已有数据，多序列显隐，打开大图。 |
| 柱状 | 类别轴、值轴、分组/堆叠语义明确 | 点选柱子，图例过滤，横向类别过多时在详情查看。 |
| 饼/环形 | 扇区、图例、百分比和总量 | 点选扇区查看值；0、缺失、异常值不导致崩溃或假比例。iOS 16 实测。 |
| 交互表格 | 标题、表头、行、单位 | 数字按数值排序；筛选、横向滚动、查看原始数据和导出。 |
| 信息卡 | 标题、字段、日期、来源 | 展开详情/打开来源；刷新只在绑定真实数据源时出现。 |

正文中的图表高度有边界；小屏、横屏、大字体允许单列或详情模式。触摸优先保持聊天纵向滚动，读数手势避免全卡抢占。颜色之外还提供文字/图例区分，VoiceOver 能逐项读取数值、单位和来源。动态图表支持减少动态效果。

## 集成与性能验收（E3）

1. 流式 JSON 不完整时使用稳定占位，不逐 token 重建图表；完成或满足完整边界时一次校验替换。中断后给可读未完成状态，绝不 force unwrap。
2. 解析/验证在非主线程完成，UI 挂载在主线程。缓存 key 包含消息/块/组件 ID、内容版本、宽度、字体与主题；复用后交互状态不串到其他消息。
3. 无网络打开历史记录仍显示保存的数据。重新打开、应用升级和历史迁移测试覆盖普通消息、新协议、未知版本和损坏载荷。
4. 复制得到标题、数据、单位、来源；搜索定位到实际卡片/字段并正确恢复高亮，不能只搜索原始 JSON 字段名。
5. 分享图片/PDF使用同一数据与组件；静态输出显示明确的范围与图例状态，内容不留白、不截断、不漏来源；PDF保留可搜索文本或相应数据表。
6. 在 iOS 16 与较新系统验证长对话混合卡片、流式更新、滚动、旋转、后台恢复；对比修改前后的主线程耗时、卡顿和内存峰值。没有实测前不宣称“不卡顿”。
7. 原生固定组件优先；每张卡片新建 WKWebView 会增加生命周期、内存、导出与手势成本，第一版无需这条路线。复杂网页制品若另行支持，应使用独立、受控的详情容器。
8. 上线验收必须同时有载荷/降级测试、iOS 16 编译检查、现有 macOS CI 的构建与运行结果，以及实机/模拟器实际交互截图。Windows 静态检查不代表 Xcode 或设备通过。

## 交付顺序与本次状态

先打通指标网格与通用载荷的完整链路（生成、流式、显示、历史、复制、搜索、分享），用用户油价参考图逐项核对；随后在同一链路增加折线、柱状、面积、多序列、饼/环形、交互表格；最后增加绑定真实数据的天气/行情等信息卡和刷新动作。不能把只有卡片外观的版本当作实时仪表盘交付。

本次产出为这份修订评估。未修改应用代码，未提交推送或触发构建；没有新增图表已安装可用的结论。原文件及应用基线均保留。若只撤销本次产出，删除本新增评估文档即可，无应用回滚步骤。
