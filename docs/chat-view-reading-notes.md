# Chat view complete reading notes

审阅日期：2026-11-06。本记录覆盖 `Views/Chat/AIChatView.swift` 全文 **1–6584 行**，包含注释、条件编译与嵌套类型。阅读方式是依顺序打印完整正文；首次大块输出中被截断的部分已重新按不重叠小段补读，随后才用声明索引核对遗漏。不是仅检索符号后声称通读。

- HEAD：`162fb247444d6bc119977895c33585a04d047497`
- 原始工作区文件 SHA256：`b944323557c804ae9bc75a126bc00221011ac3ac1351fc59c9d3aa564f01c3a4`
- 源文件状态：读取时与该 HEAD 一致。
- 这只是用户全项目阅读请求的一部分，**不是全仓库已读完**。
- 本次仅新增本笔记；未修改生产文件，未重跑 PDF，未声称任何待完成 CI 或真机测试通过。

## 完整覆盖与职责地图

下表连续覆盖整个文件，行数针对上面固定 SHA；末尾声明索引补充精确入口。

| 行范围 | 类型/函数群与实际职责 |
| --- | --- |
| 1–57 | imports（QuickLook 重复导入）；`ChatAttachmentDocumentPicker`、Coordinator 的 make/update/delegate：使用 UIKit document picker `asCopy: true` 多选，选中/取消回调交由聊天页处理，避免 fileImporter 生命周期丢失。 |
| 58–119 | `CachedViewModel.init`：历史会话 getOrCreate、stale flag 后异步加载；有 draftId 时复用草稿，否则 createDraft。weak Combine 订阅转发 VM objectWillChange；已有缓存下一主队列 tick 补发一次更新，保留 iOS16 导航重建补救。 |
| 120–152 | `ChatColors`：动态 UIKit 颜色、用户气泡及输入框专用配色。 |
| 153–231 | `SystemResourceMonitor`：start/stop 两秒 Timer、CPU tick 差值、task_vm_info 的 internal+compressed 内存、格式化。不是浏览器 CPU sensor。 |
| 232–507 | `AIChatView` identity、缓存 wrapper、输入 binding、init；所有 @State/@ObservedObject/@AppStorage，语音、搜索、分享、文件浏览、锁屏、标题、窗口和焦点状态。init 保持 StateObject autoclosure 内创建 CachedViewModel，禁止提前构造 VM。 |
| 508–724 | `body`→`chatLifecycle`；`chatLayout` 负责消息区、子代理 dock、错误/notice、状态胶囊、附件/工具/输入栏层次、菜单点击外侧取消、搜索时隐藏输入、加载与锁屏/内核覆盖。临时 notice 用捕获值核对防清掉新 notice。 |
| 725–800 | `chatNavigation`：背景、拖放、search presentation、chatSessionId environment、导航样式、返回按钮与 equatable toolbar host。 |
| 801–993 | `chatPresentations`：标题编辑、强制拉取、远端操作确认、配置导入、下载定位、缓存确认、上下文压缩/满额、新建前停止确认、清空/compact above、文件缺失提示及图片入口。原 modifier 顺序保留。 |
| 994–1017 | `chatImagePresentation`：图片 gallery、Markdown 点击、退出全屏 listener、requestComposerFocus、追加输入与重跑工具 listener、视频全屏。 |
| 1018–1040 | `chatFilePresentation`：音频、纯文本、Markdown、文档预览和文件系统分享 sheet。 |
| 1041–1120 | `chatBrowserPresentation`：网页/本地 HTML 预览与全屏间 0.4s 转场；OSC broker dropFirst 防旧事件重放，工具/终端接管优先；文件浏览和浏览器接管入口。 |
| 1121–1167 | `chatSessionPresentation`：模型、token、截图、会话分享、skills/MCP/memory。draft 的模型/skill/MCP 使用 ensureSessionReturningId closure 避免空 id 写配置。 |
| 1168–1242 | `chatCapturePresentation`：移交未发送输入、终端重挂载、相机；全屏相机自身继续 AnyView。转移先stash再清空源输入，延迟发导航通知。 |
| 1243–1320 | `chatMediaPresentation`：照片/视频同步占位、TaskGroup 并发读取、MainActor 原位完成/失败；保留图片原始编码；UIKit 文件选择器完成复制后关闭 sheet。 |
| 1321–1610 | `chatLifecycle`：onAppear 重新启用高度 seed、赋会话属性、COUNT查询、boot/load/cache reuse/草稿聚焦、分享转移注入、标题刷新、快捷流程；onDisappear 撤销焦点/录音，前后台语音键盘修复、deep link terminal、答复结束聚焦门控；最外层 environmentObject(vm)。 |
| 1611–1691 | 快捷动作：quickActionMatchId 使用 sessionId 或 draftId；observer/tryMarkWorkflowChatReady 保证目标及可见匹配；applyQuickAction 麦克风权限与摄像头单次触发。 |
| 1692–1810 | `PendingProviderImport`、providerExportJSON 验证字段；injectPendingShareIfNeeded 消费分享缓冲、复制配置文件供确认后清理源；injectPendingTransferIfNeeded 清目标旧附件并导入待移交输入。 |
| 1811–1993 | sessionExportHeader 标题/模型/日期/头像快照；trailingMenu 所有动作与toggle；open/closeChatSearch；新建时运行任务确认；runForceSync 和 runForcePull 及异步刷新/结果toast。 |
| 1994–2432 | 标题相关计算：chatNavPrincipalContent、chatToolbarKey、compact布局、Fast mode能力、navTitleKey、titleView、状态胶囊、锁定标题；refreshTitlePillSession 等待actor再MainActor核对sid写状态。 |
| 2433–2665 | 内核启动/失败覆盖、错误横幅长按复制、messagesArea：所有消息操作callback、截图与分享入口、scrollMemoryKey；新用户欢迎条件，跳转/下载按钮与底部安全高度；ScrollToBottomBackground。 |
| 2666–2772 | 浮动工具预览、hasAnyToolBlocks；浮动语音本地为EmptyView，实际全局胶囊在app root；scrollJumpButtonsHeight；DEBUG remote read-only fork banner。 |
| 2773–3070 | 所有全屏关闭；Markdown图片扫描、跨消息gallery身份、canonical/fingerprint缓存与加载；http/ze路由；外部拖放分fileURL/image/file representation并在callback内staging安全作用域副本。 |
| 3071–3351 | 附件菜单版本分支、inputBottomRow leaf擦除、三态朗读toggle、slash/edit/language按钮、voice模式切换、send/queue/stop图标；inputFieldOrWaveform三路径与文本修正异步记录。 |
| 3352–3433 | Return/Arrow/Tab/Caret键盘分派；composer展开条件与padding；updateSoftwareKeyboardVisibility 用窗口坐标判断软键盘并沿系统duration动画。 |
| 3434–3496 | inputComposerChrome：输入行边距、点击聚焦、识别文字增量、Move to入口、胶囊背景裁切与阴影。 |
| 3497–3834 | inputBar：suspended提示与composer兄弟布局；height seed/380ms debounce/320ms确认、offscreen与voice分支guard；滑动发送优先级、选择/滚动排除、硬件键盘与软键盘处理、渐变背景。 |
| 3835–4097 | popup常量与inputPopupOverlay、inputBarWindowBounds、popupOverlayContainer；slashCommandMenu与mentionMenu：独立滚动、固定224pt、思考能力分支、mention query身份和选中滚动。 |
| 4098–4225 | InputBarPopupChrome、MentionRow/iconName、附件tray 70pt初始/142pt上限、grid移除与排序。 |
| 4226–4412 | SlashMenuButtonStyle、SlashCommandRow、ContextUsageIndicator（progress/body/formatted）、thinkingLevelPicker：真实server context计数、思考自动/关闭/强度能力展示。 |
| 4413–4591 | ThinkingIntensitySlider 的selectedIndex/resting/display/label、归一化level选择、结束手势写配置、无障碍调整、限时粒子；ThinkingSliderParticles 的wrappedPhase/bounce。 |
| 4592–4697 | canSend/canEnqueue/content判断；performEnqueue、performSend（先send后clearAndRearm避免丢语音输入）、floating preview与regular最大宽900。AIChatView主体结束。 |
| 4698–4815 | ProviderImportPromptModifier、ProviderImportSheet：真bottom sheet而非iPad actionSheet；显式选择标志防onDisappear重复取消，临时文件清理。 |
| 4816–4906 | 旧SwipeToSendHint注释（实现已在其他文件）；NavTitleFrameModifier的26/legacy高度；NavBarStyleModifier的26玻璃/16–18实色背景和顶部几何测量。 |
| 4907–4992 | NavigationStatusCapsule/dotMask/restartPulse：局部动画状态、reduceMotion处理；RemoteServerAIDraftPresentationModifier。 |
| 4993–5183 | NavbarEvalStats、EquatableByValue、NavTitleKey、ChatToolbarKey、ChatToolbarHost：全部显示输入才进入key，action闭包排除；零尺寸toolbar承载和差异诊断。 |
| 5184–5318 | CompactChatInteractivePopEnabler：make/update/dismantle；Coordinator enable/cancel/install/remove、gesture判定与dismiss、responder查导航控制器；MarkerView didMoveToWindow。保留UIKit edge pop优先，更宽侧带另行dismiss。 |
| 5319–5523 | ChatTrailingMenu 的SwiftUI菜单备用实现和相等比较，版本受限iCloud行、配置toggle、搜索/分享disabled门控。 |
| 5524–5730 | 实际使用的ChatTrailingMenuButton：Key、Coordinator、make/size/update、buildMenu；UIButton实例与menu仅显示key变化重建，action每次引用最新parent。 |
| 5731–5775 | ChatSearchPresentation：safeAreaInset；onAppear绑定VM与opener owner；$isActive去重同步输入焦点和呈现；owner匹配才清理，避免旧页关闭新页opener。 |
| 5776–5938 | MoveToSessionSheet：排除当前会话、最近/搜索结果、新草稿；300ms取消式搜索、标题/预览高亮、相对日期。 |
| 5939–5953 | UIView.nearestViewController responder helper。 |
| 5954–6113 | SessionLockGateOverlay：shouldShow/gateView/evaluate/prompt/handleScene；区分离开立即锁与正idle时间、认证进行中/失败guard。 |
| 6114–6180 | MicButton：touch开始与结束都在圆内、位移<10才切换，保持无障碍button。 |
| 6181–6261 | SpeechLanguagePickerSheet：locale过滤与首选语言分组、languageRow选择。 |
| 6262–6357 | CompactSummarySheet：可选撤销压缩确认、复制；SelectableTextView make/update使用实际UITextView显示完整纯文本。 |
| 6358–6462 | TokenUsageSheet/ formatted、StatRow：上下文、思考、token、cache命中率、速度、loop统计。 |
| 6463–6531 | EmptyChatWelcomeView、LoadingDotsView、SessionLoadingCard：欢迎和局部三点动画，无重新创建VM。 |
| 6532–6584 | voiceCorrectionContext只取内存中user/assistant，assistant优先text blocks且剥附件标记，再交预算builder；DownloadLocateTarget filename身份。 |

## 类型擦除改动的行为核对

1. 新旧会话共用这棵页面；当前 `body` 经过 layout、navigation、presentations、image、file、browser、session、capture、media、lifecycle 共十个真实 `AnyView` 计算属性边界。当前提交比最初审查的五段版本拆得更细。
2. 输入行的附件、命令、发送在HStack builder之前变为AnyView；编辑、朗读位于原来的条件slot内。HStack spacing仍0/6，field.frame仍maxWidth infinity/leading。
3. `inputComposerChrome` 仍是inputBar里suspension banner之后的兄弟；原frame/padding/geometry/swipe修饰composer，keyboard notifications/background仍修饰整个inputBar。
4. 所有 @State、@StateObject、bindings、actions保留在原所有者；没有新增 `.id(UUID())` 或改变条件分支的选择规则。新增AnyView本身不引入新版OS API。
5. 前一版差异审查通过脚本把边界去掉后，整个body与inputBar均与改前逐字符一致。当前版本增加五个presentation边界，需以其HEAD复查；下面的“验证记录”明确本轮实际核验结果。
6. 类型擦除减少编译期传播的复杂树；运行时是否已消除真机栈溢出必须看实际iOS18.1新建/历史页和CI完整页面smoke。静态阅读不是运行验收。

## 必须保留的运行时与 iOS16 约束

- 262：StateObject wrappedValue保持autoclosure惰性，禁止在init先建局部CachedViewModel。
- 63、1321：iOS16 NavigationStack重建时可能暂空VM；保留缓存转发与异步补发、load等待重试。
- 508、3105、3263、3434、3497：不要把叶子和所有presentation重新内联成长opaque类型；历史注释的metadata崩溃与本次真实主线程STACK GUARD栈属于同类路径，但单凭注释不能声称本次修复通过。
- 3076：附件按钮iOS16使用confirmationDialog，iOS17+ Menu，避免旧HStack菜单垂直偏移。
- 1936、2525、5410、5650附近：iCloud v2调用与菜单受iOS17门控。
- 1997、2101、4839、4867：保留19/26标题与导航样式分支；新AnyView不改这些分支。onGeometryChange是原代码使用的回部署API，不能仅因新SDK提供就推定最低版本被提高；最终由deployment16编译和旧系统运行共同确认。
- 3497：高度测量优先取窗口坐标，seed立即写、后续debounce，前后台取消过期任务；语音内容先发送再clearAndRearm；菜单/返回/焦点修复不要随重构简化。
- 5118、5524：toolbar `.equatable()` 和UIKit按钮实例稳定性是流式menu保持打开的约束。key必须覆盖显示字段，Coordinator每次更新parent确保回调不捕获旧state。
- 5738：搜索owner保护保留，旧页onDisappear不得清掉新页opener；首开isActive=false时相等guard阻止冗余binding写。

## 本轮发现的已有问题与未证明项

- **已证实注释陈旧**：5524前注释称ChatTrailingMenuButton currently unused，但1834实际构建它；SwiftUI ChatTrailingMenu为备用。Fast mode部分注释称仅OAuth，2063实际也接受openAIResponses+gpt。注释不能作为实现事实。
- **已证实门控覆盖不全，影响待复现**：467 hasOverlayPresented没有包含showSessionShare/showChatSearch及多种预览sheet。答复结束/草稿延迟聚焦使用该门控；目前不能声称分享/搜索时一定不会被聚焦。此次AnyView没有改变该表达式。
- **潜在Unicode高亮问题，待运行复现**：5885 MoveToSessionSheet.buildHighlighted在lowercased副本中求String.Index，再用于原文切片。大小写映射可改变标量数量，索引跨字符串使用存在错位/越界风险。属于移动目标列表的旧实现，与新聊天metadata栈不同，不归因为此次闪退。
- **代码范围事实**：2735 remote只读fork UI位于DEBUG，release输入栏没有同一只读展示分支。是否有VM写入保护要读依赖后判断，本轮没有把UI差异等同数据可修改。
- **缓存与sheet identity**：没有发现本次新增动作或身份变化；AnyView内嵌具体树稳定仍需覆盖切换搜索、sheet dismiss、编辑/语音、现有会话返回重进。主线程栈证据与截图验收不能由文本一致性代替。

## 已读与未读依赖边界

本轮完整读取只有这一个文件。此前同会话读过ChatSearch.swift与ChatSearchPresentation调用、部分ContentView导航、collection message list差异、导出路径；这不等于以下依赖已完整审计：ViewModelCache、AIChatViewModel所有扩展、ChatStore、PastableTextView、VoiceInputViewModel/InlineVoiceInputView、SessionLockStore/BiometricAuth、QuickActionWorkflow、CollectionViewMessageListV3全文、SessionShareSheet及全部renderer、provider实现、原生kernel。

文中对这些依赖只陈述本文件调用点和传参，不保证其线程安全、完整功能、权限或性能。UIKit/iOS16/iOS18.1真机运行、导航新旧会话与最终截图由主线测试补齐。

## 验证记录

- 基线 `cd7e` 的AIChatView与当前 `162fb247444d6bc119977895c33585a04d047497` 对比：从当前源码移除十段新增AnyView/属性边界，再比对整个body，逐字符相等 `True`。
- 将当前inputComposerChrome重新嵌回inputBar并移除新增AnyView壳，与同一基线完整inputBar逐字符相等 `True`。
- inputBottomRow叶子擦除单独人工核对，保留条件、顺序、spacing与action引用。
- 本机Windows未运行Swift/UIKit；CI `42215553877` 正在主线跟踪，本文不预填其结果。

## 声明定位索引

以下索引在完整正文阅读后生成，便于下次找到具体函数；不是阅读覆盖的替代品。body/make/update类通用函数职责跟随其所属类型，私有局部函数跟随上表功能段。

```text
21: private struct ChatAttachmentDocumentPicker: UIViewControllerRepresentable {
25: func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
34: func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
36: func makeCoordinator() -> Coordinator {
40: final class Coordinator: NSObject, UIDocumentPickerDelegate {
44: init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
49: func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
53: func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
63: private final class CachedViewModel: ObservableObject {
71: init(sessionId: String?, draftId: String? = nil) {
122: enum ChatColors {
155: class SystemResourceMonitor: ObservableObject {
162: func start() {
173: func stop() {
178: private func sampleCPU() {
202: private func updateMemory() {
218: var formattedCPU: String {
222: func formattedMem(compact: Bool = false) -> String {
234: struct AIChatView: View {
249: private var vm: AIChatViewModel { cached.vm }
252: private var isReadOnly: Bool { remoteDeviceId != nil }
255: private var inputTextBinding: Binding<String> {
262: init(sessionId: String? = nil, draftId: String? = nil, remoteDeviceId: String? = nil, initialGroupId: String? = nil) {
385: private var voiceInputActive: Bool {
428: private var chatSearchModel: ChatSearchModel { vm.chatSearch }
467: private var hasOverlayPresented: Bool {
501: private var compactNavigationGestureSupport: some View {
512: var body: some View { chatLifecycle }
514: private var chatLayout: AnyView {
725: private var chatNavigation: AnyView {
801: private var chatPresentations: AnyView {
994: private var chatImagePresentation: AnyView {
1018: private var chatFilePresentation: AnyView {
1041: private var chatBrowserPresentation: AnyView {
1121: private var chatSessionPresentation: AnyView {
1168: private var chatCapturePresentation: AnyView {
1243: private var chatMediaPresentation: AnyView {
1264: struct PickJob { let id: UUID; let item: PhotosPickerItem; let isVideo: Bool; let ext: String?; let date: Date? }
1321: private var chatLifecycle: AnyView {
1619: private var quickActionMatchId: String? { sessionId ?? draftId }
1621: private var quickActionObserver: QuickActionObserverModifier {
1634: private func tryMarkWorkflowChatReady(reason: String) {
1645: private func applyQuickAction(_ action: ChatLaunchAction) {
1694: struct PendingProviderImport: Identifiable {
1708: static func providerExportJSON(at url: URL) -> String? {
1721: private func injectPendingShareIfNeeded() {
1787: private func injectPendingTransferIfNeeded() {
1815: private var sessionExportHeader: SessionExportHeader {
1834: private var trailingMenu: some View {
1909: private func openChatSearch() {
1914: private func closeChatSearch() {
1926: private func requestNewChatFromMenu() {
1936: private func runForceSync() {
1955: private func runForcePull() {
1997: private var chatNavPrincipalContent: some View {
2032: private var chatToolbarKey: ChatToolbarKey {
2051: private var showsCompactToolbarNavigation: Bool {
2063: private var activeModelSupportsFastMode: Bool {
2076: private var navTitleKey: NavTitleKey {
2101: private var titleView: some View {
2389: private var navigationStatusCapsule: some View {
2400: private var titleIsVisuallyLocked: Bool {
2407: private func refreshTitlePillSession() {
2436: private var kernelBootOverlay: some View {
2478: private func errorBanner(_ error: String) -> some View {
2507: private var messagesArea: some View {
2638: private func scrollFloatingButtonLabel(_ systemName: String) -> some View {
2659: private struct ScrollToBottomBackground: View {
2661: var body: some View {
2669: private var floatingToolPreview: some View {
2701: private var hasAnyToolBlocks: Bool {
2715: private var floatingSpeechButton: some View { EmptyView() }
2720: private var scrollJumpButtonsHeight: CGFloat {
2735: private var forkBanner: some View {
2793: private func dismissAllOwnedImmersiveCovers() {
2802: private func handleMarkdownImageTap(_ note: Notification) {
2813: struct MarkdownImageRef {
2881: private static func loadMarkdownImage(source: String, fingerprintKey: String) async -> UIImage? {
2900: private func handleZeURLTap(_ url: URL) -> OpenURLAction.Result {
2963: private func handleDropProviders(_ providers: [NSItemProvider]) {
3050: private func stageDroppedFile(_ sourceURL: URL, index: Int) -> URL? {
3076: private var attachmentMenuButton: some View {
3105: private var inputBottomRow: AnyView {
3132: private var readAloudToolbarToggle: some View {
3166: private var slashMenuButton: some View {
3184: private var editExitButton: some View {
3197: private var languageBadgeButton: some View {
3208: private func toggleVoiceInput() {
3223: private var sendButton: some View {
3249: private func composerActionIcon(_ systemName: String, isEnabled: Bool = true) -> some View {
3263: private var inputFieldOrWaveform: AnyView {
3356: private func handleReturnKey() {
3363: private func handleArrowUp() -> Bool {
3370: private func handleArrowDown() -> Bool {
3377: private func handleTabKey() -> Bool {
3384: private func handleCaretChange(_ caret: Int) {
3391: private var usesExpandedComposerChrome: Bool {
3396: private var composerVerticalPadding: CGFloat {
3404: private var composerHorizontalPadding: CGFloat {
3411: private func updateSoftwareKeyboardVisibility(from notification: Notification) {
3434: private var inputComposerChrome: AnyView {
3497: private var inputBar: AnyView {
3856: private var inputPopupOverlay: some View {
3883: private func inputBarWindowBounds() -> CGRect {
3908: private func popupOverlayContainer<Content: View>(
3932: private var slashCommandMenu: some View {
3997: private var mentionMenu: some View {
4099: private struct InputBarPopupChrome<Content: View>: View {
4103: var body: some View {
4119: private struct MentionRow: View {
4124: var body: some View {
4159: private var iconName: String {
4174: private var hasPendingAttachmentPreviews: Bool {
4179: private var attachmentPreviewTray: some View {
4199: private var attachmentTrayHeight: CGFloat {
4215: private var inputAttachmentGrid: some View {
4229: private struct SlashMenuButtonStyle: ButtonStyle {
4231: func makeBody(configuration: Configuration) -> some View {
4238: private struct SlashCommandRow: View {
4255: var body: some View {
4327: private var thinkingIconColor: Color {
4339: private struct ContextUsageIndicator: View {
4345: private var progress: Double {
4350: var body: some View {
4398: private func formatted(_ value: Int) -> String {
4405: private var thinkingLevelPicker: some View {
4417: private struct ThinkingIntensitySlider: View {
4427: private var selectedIndex: Int? {
4431: private var restingProgress: CGFloat {
4438: private var displayProgress: CGFloat {
4442: private var visibleLabel: String {
4446: var body: some View {
4538: private func normalizedProgress(_ x: CGFloat, width: CGFloat) -> CGFloat {
4543: private func level(for progress: CGFloat) -> ThinkingLevel {
4549: private func triggerMaxParticles() {
4562: private struct ThinkingSliderParticles: View {
4567: var body: some View {
4581: private func wrappedPhase(_ value: CGFloat) -> CGFloat {
4586: private func bounce(for travel: CGFloat, index: Int) -> CGFloat {
4592: private var canSend: Bool {
4602: private var canEnqueue: Bool {
4609: private var hasComposerContent: Bool {
4617: private var hasMovableShareContent: Bool {
4623: private func performEnqueue() {
4648: private func performSend() {
4686: private var hasFloatingPreview: Bool {
4692: private var maxContentWidth: CGFloat? {
4703: private struct ProviderImportPromptModifier: ViewModifier {
4711: func body(content: Content) -> some View {
4761: private struct ProviderImportSheet: View {
4770: var body: some View {
4839: private struct NavTitleFrameModifier: ViewModifier {
4840: func body(content: Content) -> some View {
4867: private struct NavBarStyleModifier: ViewModifier {
4870: func body(content: Content) -> some View {
4907: private struct NavigationStatusCapsule: View {
4913: var body: some View {
4951: private var dotMask: some View {
4961: private func restartPulse() {
4982: private struct RemoteServerAIDraftPresentationModifier: ViewModifier {
4985: func body(content: Content) -> some View {
5026: enum NavbarEvalStats {
5034: private struct EquatableByValue<Key: Equatable, Content: View>: View, Equatable {
5038: static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
5041: var body: some View {
5061: private struct NavTitleKey: Equatable {
5091: private struct ChatToolbarKey: Equatable {
5118: private struct ChatToolbarHost<Leading: View, Title: View, Trailing: View>: View, Equatable {
5124: static func == (lhs: Self, rhs: Self) -> Bool {
5161: var body: some View {
5184: private struct CompactChatInteractivePopEnabler: UIViewRepresentable {
5187: func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }
5189: func makeUIView(context: Context) -> MarkerView {
5198: func updateUIView(_ uiView: MarkerView, context: Context) {
5203: static func dismantleUIView(_ uiView: MarkerView, coordinator: Coordinator) {
5207: final class Coordinator: NSObject, UIGestureRecognizerDelegate {
5213: init(onDismiss: @escaping () -> Void) {
5218: func enable(from marker: UIView) {
5241: func cancelPendingEnable() {
5250: private func installLeftSideDismissGesture(on navigationController: UINavigationController) {
5264: private func removeLeftSideDismissGesture() {
5271: func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
5286: @objc private func handleLeftSidePan(_ gesture: UIPanGestureRecognizer) {
5297: private func nearestNavigationController(from view: UIView) -> UINavigationController? {
5309: final class MarkerView: UIView {
5312: override func didMoveToWindow() {
5345: private struct ChatTrailingMenu: View, Equatable {
5376: static func == (lhs: Self, rhs: Self) -> Bool {
5389: var body: some View {
5524: private struct ChatTrailingMenuButton: UIViewRepresentable {
5557: struct Key: Equatable {
5570: private var key: Key {
5580: final class Coordinator {
5583: init(parent: ChatTrailingMenuButton) { self.parent = parent }
5586: func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
5588: func makeUIView(context: Context) -> UIButton {
5604: func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
5608: func updateUIView(_ button: UIButton, context: Context) {
5622: private static func buildMenu(key: Key, coordinator: Coordinator) -> UIMenu {
5738: private struct ChatSearchPresentation: ViewModifier {
5746: func body(content: Content) -> some View {
5776: private struct MoveToSessionSheet: View {
5788: private var isSearching: Bool { !searchText.isEmpty }
5790: private var displayedSessions: [ChatSession] {
5796: var body: some View {
5856: private func scheduleSearch() {
5876: private func highlightedText(_ text: String, font: Font, color: Color) -> some View {
5885: private func buildHighlighted(_ text: String, query: String, font: Font, color: Color) -> Text {
5910: private func relativeDate(_ date: Date) -> String {
5944: var nearestViewController: UIViewController? {
5963: private struct SessionLockGateOverlay: View {
5976: var body: some View {
6010: private var shouldShow: Bool {
6015: private var gateView: some View {
6060: private func evaluate(reason: String) {
6070: private func promptForBiometricUnlock() {
6087: private func handleScene(_ phase: ScenePhase) {
6118: private struct MicButton: View {
6126: var onTap: () -> Void = {}
6135: var body: some View {
6174: private static func isInside(_ p: CGPoint) -> Bool {
6183: private struct SpeechLanguagePickerSheet: View {
6188: private var filteredLocales: [Locale] {
6199: private var preferredCodes: Set<String> {
6203: var body: some View {
6239: private func languageRow(_ loc: Locale) -> some View {
6265: struct CompactSummarySheet: View {
6275: var body: some View {
6334: private struct SelectableTextView: UIViewRepresentable {
6337: func makeUIView(context: Context) -> UITextView {
6351: func updateUIView(_ tv: UITextView, context: Context) {
6360: private struct TokenUsageSheet: View {
6364: var body: some View {
6428: private func formatted(_ n: Int) -> String {
6435: private struct StatRow: View {
6441: var body: some View {
6467: private struct EmptyChatWelcomeView: View {
6468: var body: some View {
6492: struct LoadingDotsView: View {
6497: var body: some View {
6525: private struct SessionLoadingCard: View {
6526: var body: some View {
6543: func voiceCorrectionContext(from messages: [ChatMessage]) -> ConversationContext {
6581: struct DownloadLocateTarget: Identifiable {
6583: var id: String { filename }
```
