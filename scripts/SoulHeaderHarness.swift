extension Notification.Name { static let soulMdChanged = Notification.Name("ZeSoulMdChanged") }
enum SoulStore { static var cachedMetadata = SoulMetadata.default }
enum SoulAvatarStore { static func load() -> UIImage? { nil } }
private struct FixtureSession { let id: String }
private struct FixtureVM { let fallbackTrigger = 0 }
private struct ChatCallLayoutMarker: UIViewRepresentable {
    let identifier: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.accessibilityIdentifier = identifier
        view.isUserInteractionEnabled = false; return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

private struct SoulHeaderFixture: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SoulAppearancePreferences.headerAvatarSizeKey) private var headerAvatarSize = 56.0
    @State private var chatViewportWidth: CGFloat = 0
    @State private var topInset: CGFloat = 0
    @State private var overflow: CGFloat = 84
    @State private var inputFocused = false
    @State private var showSoulSettings = false
    @State private var showModelPicker = false
    @State private var titlePillEditSession: FixtureSession?
    @State private var fallbackPulseOpacity: Double = 0
    private let titlePillSession: FixtureSession? = nil
    private let titleIsVisuallyLocked = false
    private let vm = FixtureVM()
    private let soulName = "Ze"
    private var navigationProvider: ProviderInstance? {
        ProviderInstance(id: "sample", label: ProcessInfo.processInfo.arguments.contains("--long-name")
                         ? "这是一个很长的服务商名称用于检查胶囊边界" : "WorkBuddy", providerType: .workBuddy)
    }
    private var voiceCallButton: some View {
        Button {} label: { Image(systemName: "phone").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44) }
            .buttonStyle(.plain).accessibilityIdentifier("fixture.phone")
    }
    private var trailingMenu: some View {
        Button {} label: { Image(systemName: "gearshape").font(.system(size: 14, weight: .medium)).frame(width: 44, height: 44) }
            .buttonStyle(.plain).accessibilityIdentifier("fixture.gear")
    }
    private var leadingControl: some View {
        // PRODUCTION_LEADING
    }
    private var trailingControls: some View {
        // PRODUCTION_TRAILING
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(0..<40) { i in
                        Text("\(i + 1). 说个具体的活儿，我直接开跑。\n整理聊天记录、生成图片、分析数据。")
                            .font(.system(size: 20)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 20).padding(.top, overflow + 8)
            }
            .background(ChatColors.background)
            .background(GeometryReader { g in Color.clear.onAppear { chatViewportWidth = g.size.width } })
            .modifier(NavBarStyleModifier(topSafeAreaInset: $topInset, providerBadge: AnyView(chatNavPrincipalContent),
                                         headerSize: chatHeaderSize, onHeaderOverflow: { overflow = $0 }))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { leadingControl }.sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }.sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { trailingControls }.sharedBackgroundVisibility(.hidden)
            }
            .sheet(isPresented: $showSoulSettings) {
                NavigationStack { SoulSizeFixture().toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { showSoulSettings = false } } } }
            }
            .sheet(isPresented: $showModelPicker) { Text("模型选择入口").accessibilityIdentifier("fixture.models") }
        }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : .light)
    }
    // PRODUCTION_HEADER
}

private struct SoulSizeFixture: View {
    @AppStorage(SoulAppearancePreferences.headerAvatarSizeKey) private var headerAvatarSize = 56.0
    private let avatarImageData: Data? = nil
    private let rawEmoji = ""
    private let name = "Ze"
    private let style = ""
    var body: some View {
        Form {
            Section { previewCard }
            Section {
                // PRODUCTION_SLIDER
            }
        }.navigationTitle("灵魂")
    }
    // PRODUCTION_PREVIEW
}

@main struct SoulHeaderHarnessApp: App {
    init() { UserDefaults.standard.set(56.0, forKey: SoulAppearancePreferences.headerAvatarSizeKey) }
    var body: some Scene { WindowGroup { SoulHeaderFixture() } }
}
