// The UI and counter/notice formatting are original upstream declarations.
// This state adapter only supplies reproducible values; it does not establish
// production search, selection, export, navigation or keyboard correctness.
func AppLocalized(_ key: String) -> String { NSLocalizedString(key, comment: "") }
struct ChatExportOptions { enum Format { case image, pdf } }
@MainActor final class ChatSearchController: ObservableObject {
    enum Notice { case wrappedToFirst, wrappedToLast }
    @Published var query = ""
    @Published var matchCount = 0
    @Published var currentIndex: Int?
    @Published var isTruncated = false
    @Published var isSearching = false
    @Published var notice: Notice?
    @Published var focusRequest = 0
    var normalizedQuery: String { ChatSearchMatcher.normalizedQuery(query) }
    func next() { preconditionFailure("Reference screenshots never invoke search actions") }
    func previous() { preconditionFailure("Reference screenshots never invoke search actions") }
    func deactivate() { preconditionFailure("Reference screenshots never invoke search actions") }
    // ORIGINAL_NOTICE_TEXT
}

@MainActor private struct ShareSearchReferenceScene: View {
    let search: ChatSearchController
    let scenario: String
    var body: some View {
        VStack(spacing: 0) {
            if scenario.hasPrefix("search-") {
                ChatSearchBar(search: search, onDone: {})
            } else {
                ChatShareFormatSwitch(format: scenario == "share-image" ? .image : .pdf,
                                      imageUnavailable: scenario == "share-blocked",
                                      onSelect: { _ in preconditionFailure("Reference control actions not exercised") },
                                      onBlockedImage: { preconditionFailure("Reference control actions not exercised") })
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .ignoresSafeArea()
    }
}

@main private final class ShareSearchReferenceHarness: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var screenshots: [[String: Any]] = []
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in await captureAll() }
        return true
    }
    @MainActor private func captureAll() async {
        do {
            guard let window else { throw failure("Missing window") }
            for scheme in [ColorScheme.light, .dark] {
                for scenario in ["search-empty", "search-none", "search-results", "search-truncated", "search-loading", "search-wrap-first", "search-wrap-last", "share-image", "share-pdf", "share-blocked"] {
                    let search = ChatSearchController()
                    search.query = scenario == "search-empty" ? "" : "油价"
                    search.matchCount = ["search-empty", "search-none", "search-loading"].contains(scenario) ? 0 : scenario == "search-truncated" ? 2000 : 12
                    search.currentIndex = search.matchCount > 0 ? 2 : nil
                    search.isTruncated = scenario == "search-truncated"
                    search.isSearching = scenario == "search-loading"
                    if scenario == "search-wrap-first" { search.notice = .wrappedToFirst; search.currentIndex = 0 }
                    if scenario == "search-wrap-last" { search.notice = .wrappedToLast; search.currentIndex = 11 }
                    let host = UIHostingController(rootView: ShareSearchReferenceScene(search: search, scenario: scenario).environment(\.colorScheme, scheme))
                    host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                    window.rootViewController = host
                    window.frame.size.width = 390
                    host.view.frame = window.bounds
                    window.makeKeyAndVisible()
                    host.view.layoutIfNeeded()
                    try await Task.sleep(nanoseconds: 550_000_000)
                    host.view.layoutIfNeeded()
                    CATransaction.flush()
                    let format = UIGraphicsImageRendererFormat(); format.scale = 2
                    let bounds = CGRect(x: 0, y: 0, width: 390, height: 150)
                    var drew = false
                    let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    guard drew, let data = image.pngData(), data.count > 1000 else { throw failure("Empty capture: \(scenario)") }
                    let name = "reference-\(scheme == .dark ? "dark" : "light")-\(scenario).png"
                    try data.write(to: docs.appendingPathComponent(name))
                    screenshots.append(["file": name, "scenario": scenario, "width": 390, "height": 150, "pngBytes": data.count])
                    host.view.endEditing(true)
                    window.rootViewController = UIViewController()
                }
            }
            try write(["success": true, "screenshots": screenshots, "scope": "Original search bar and share format selector only. Search fields may show blinking caret. No full sharing page, export or real search interaction claim."])
        } catch { try? write(["success": false, "error": error.localizedDescription, "screenshots": screenshots]) }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "ShareSearchReference", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func write(_ result: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: docs.appendingPathComponent("reference-ui-result.json"))
    }
}
