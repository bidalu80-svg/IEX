import SwiftUI

// UI-only integration. The host owns navigation and the scheduler's lifecycle.
// JIT DAG: settings conventions + picker contract -> implementation -> static audit.
@MainActor
struct ScheduledTasksView: View {
    let currentSessionId: String?

    @ObservedObject private var store = ScheduledTaskStore.shared
    @State private var page: ScheduledTasksPage = .runs
    @State private var editor: ScheduledTaskEditorRequest?
    @State private var selectedRun: ScheduledTaskRunSelection?
    @State private var pendingDelete: ScheduledTaskDefinition?
    @State private var clearFinishedRunsPresented = false
    @State private var operationError: ScheduledTasksOperationError?

    var body: some View {
        VStack(spacing: 0) {
            Picker("定时任务分类", selection: $page) {
                Text("运行记录").tag(ScheduledTasksPage.runs)
                Text("已定时").tag(ScheduledTasksPage.tasks)
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityHint(Text("选择分类，也可以在下方内容区域左右滑动切换"))

            TabView(selection: $page) {
                runsPage.tag(ScheduledTasksPage.runs)
                tasksPage.tag(ScheduledTasksPage.tasks)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("定时任务")
        .navigationBarTitleDisplayMode(.inline)
        // Intentionally no NavigationStack or custom back button here.
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if page == .runs {
                    Button {
                        clearFinishedRunsPresented = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!store.runs.contains { $0.status != .running })
                    .accessibilityLabel(Text("清除已结束记录"))
                    .accessibilityHint(Text("仅清除已结束的运行记录，保留正在执行的记录、定时任务和对话"))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: createTask) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("新建定时任务"))
                .accessibilityHint(Text("打开定时任务表单"))
            }
        }
        .sheet(item: $editor) { request in
            ScheduledTaskEditorView(
                task: request.task,
                isEditing: request.isEditing,
                currentSessionId: currentSessionId
            )
        }
        .sheet(item: $selectedRun) { selection in
            ScheduledTaskRunDetailView(runId: selection.id)
        }
        .confirmationDialog("删除定时任务？", isPresented: deletePresented,
                            titleVisibility: .visible, presenting: pendingDelete) { task in
            Button("删除任务", role: .destructive) { delete(task) }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { task in
            Text("删除“\(task.displayName)”后将停止后续调度，并同时取消此任务正在进行的执行。已有运行记录会保留。")
        }
        .confirmationDialog("清除已结束的运行记录？", isPresented: $clearFinishedRunsPresented,
                            titleVisibility: .visible) {
            Button("清除已结束记录", role: .destructive) { clearFinishedRuns() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除已结束的运行记录。正在执行的记录、定时任务和关联对话都会保留。")
        }
        .alert(item: $operationError) { error in
            Alert(
                title: Text("操作未完成"),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var runsPage: some View {
        Group {
            if store.runs.isEmpty {
                emptyPage(title: String(localized: "尚无运行记录"), symbol: "clock")
            } else {
                List {
                    storeErrorSection
                    Section {
                        ForEach(store.runs.sorted { $0.startedAt > $1.startedAt }) { run in
                            VStack(alignment: .leading, spacing: 12) {
                                Button {
                                    selectedRun = ScheduledTaskRunSelection(id: run.id)
                                } label: {
                                    ScheduledTaskRunRow(run: run)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint(Text("查看运行状态、结果摘要及错误详情"))
                                if run.status == .running {
                                    Button("取消执行", role: .destructive) {
                                        store.cancelRun(id: run.id)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(Text("取消执行：\(run.taskName)"))
                                }
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if run.status != .running {
                                    Button("删除记录", role: .destructive) { deleteRun(id: run.id) }
                                }
                            }
                        }
                    } footer: {
                        ScheduledTasksSchedulingNotice()
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var tasksPage: some View {
        Group {
            if store.tasks.isEmpty {
                emptyPage(title: String(localized: "尚无定时任务"), symbol: "calendar.badge.clock")
            } else {
                List {
                    storeErrorSection
                    Section {
                        ForEach(store.tasks.sorted { $0.createdAt > $1.createdAt }) { task in
                            taskRow(task)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("删除", role: .destructive) { pendingDelete = task }
                                    Button("编辑") { edit(task) }
                                        .tint(.accentColor)
                                }
                        }
                    } footer: {
                        ScheduledTasksSchedulingNotice()
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func taskRow(_ task: ScheduledTaskDefinition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { store.tasks.first(where: { $0.id == task.id })?.isEnabled ?? false },
                set: { enabled in
                    do {
                        try store.setEnabled(id: task.id, enabled: enabled)
                    } catch {
                        operationError = ScheduledTasksOperationError(
                            message: String(localized: "任务状态保存失败，请稍后重试。")
                        )
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.displayName).font(.headline)
                    Text(ScheduledTasksText.schedule(task))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(Text("启用任务：\(task.displayName)"))
            .accessibilityHint(Text("关闭后暂停后续调度、取消当前执行并结束对应实况，不影响其他任务或对话"))

            if !task.isEnabled {
                Label("已暂停", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let next = task.nextRunAt {
                Text("下次计划时间：\(ScheduledTasksText.dateTime(next))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("暂无下次执行时间，请编辑任务检查日期")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                Button("编辑") { edit(task) }
                    .accessibilityLabel(Text("编辑任务：\(task.displayName)"))
                Spacer(minLength: 0)
                Button("删除", role: .destructive) { pendingDelete = task }
                    .accessibilityLabel(Text("删除任务：\(task.displayName)"))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func emptyPage(title: String, symbol: String) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    if let error = store.lastError {
                        ScheduledTasksErrorMessage(
                            message: String(localized: "调度操作未完成，请检查任务设置后重试。"),
                            details: error
                        )
                    }
                    Spacer(minLength: 0)
                    ScheduledTasksEmptyState(title: title, symbol: symbol, create: createTask)
                    Spacer(minLength: 0)
                    ScheduledTasksSchedulingNotice()
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - 48))
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private var storeErrorSection: some View {
        if let error = store.lastError {
            Section {
                ScheduledTasksErrorMessage(
                    message: String(localized: "调度操作未完成，请检查任务设置后重试。"),
                    details: error
                )
            }
        }
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func createTask() {
        editor = ScheduledTaskEditorRequest(task: ScheduledTaskDefinition(), isEditing: false)
    }

    private func edit(_ task: ScheduledTaskDefinition) {
        editor = ScheduledTaskEditorRequest(task: task, isEditing: true)
    }

    private func deleteRun(id: UUID) {
        // Recheck the current store value rather than a stale row snapshot.
        guard store.runs.contains(where: { $0.id == id && $0.status != .running }) else { return }
        do {
            try store.deleteRun(id: id)
        } catch {
            operationError = ScheduledTasksOperationError(
                message: String(localized: "删除运行记录失败，记录仍保留。请稍后重试。")
            )
        }
    }

    private func clearFinishedRuns() {
        do {
            // The store/model rechecks statuses at confirmation time. A run
            // still executing is protected even if the dialog remained open.
            try store.clearFinishedRuns()
        } catch {
            operationError = ScheduledTasksOperationError(
                message: String(localized: "清除运行记录失败，记录仍保留。请稍后重试。")
            )
        }
    }

    private func delete(_ task: ScheduledTaskDefinition) {
        do {
            try store.delete(id: task.id)
            pendingDelete = nil
        } catch {
            operationError = ScheduledTasksOperationError(
                message: String(localized: "删除失败，任务仍保留。请稍后重试。")
            )
        }
    }
}

private enum ScheduledTasksPage: Hashable { case runs, tasks }

private struct ScheduledTaskEditorRequest: Identifiable {
    let id = UUID()
    let task: ScheduledTaskDefinition
    let isEditing: Bool
}

private struct ScheduledTaskRunSelection: Identifiable { let id: UUID }

private struct ScheduledTasksOperationError: Identifiable {
    let id = UUID()
    let message: String
}

private struct ScheduledTasksSchedulingNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iOS 后台调度由系统决定，执行可能延后，不保证准点。恢复后，每个任务最多补执行一次，不会逐次补跑所有错过的计划。")
            Text("启用任务可显示灵动岛实况；后台持续执行沿用“增强后台运行”设置与系统权限，实况本身不保证准点或永久后台运行。")
            Text("关闭任务会取消当前执行并结束对应实况，不影响其他任务或对话。")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ScheduledTasksEmptyState: View {
    let title: String
    let symbol: String
    let create: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 48

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Button(action: create) {
                Label("新建定时任务", systemImage: "plus")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ScheduledTasksErrorMessage: View {
    let message: String
    let details: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.red)
            if let details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Runtime/provider error payloads are user data, not translation keys.
                DisclosureGroup("错误详情（原始信息）") {
                    Text(verbatim: details)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Draft editor

@MainActor
private struct ScheduledTaskEditorView: View {
    let isEditing: Bool
    let currentSessionId: String?
    private let original: ScheduledTaskDefinition

    @ObservedObject private var store = ScheduledTaskStore.shared
    @ObservedObject private var models = ProviderConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScheduledTaskDefinition
    @State private var timeExpanded = false
    @State private var showModelPicker = false
    @State private var showDiscardConfirmation = false
    @State private var saveError: String?
    @State private var saveErrorDetails: String?
    @State private var isSaving = false
    @State private var rememberedEndDate: Date

    init(task: ScheduledTaskDefinition, isEditing: Bool, currentSessionId: String?) {
        let session = ScheduledTasksText.nonempty(currentSessionId)
        var value = task
        if !isEditing && session == nil {
            value.runMode = .newConversation
            value.sessionId = nil
        } else if value.runMode == .currentConversation,
                  ScheduledTasksText.nonempty(value.sessionId) == nil {
            value.sessionId = session
        }
        self.isEditing = isEditing
        self.currentSessionId = session
        self.original = value
        _draft = State(initialValue: value)
        _rememberedEndDate = State(initialValue: value.endDate ?? max(Date(), value.oneTimeDate))
    }

    var body: some View {
        NavigationStack {
            // Re-evaluate expiry while the sheet is open, including across midnight.
            // save() also validates against a fresh Date; the store is authoritative.
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                editorForm(now: context.date)
                    .navigationTitle(isEditing ? String(localized: "编辑定时任务") : String(localized: "新建定时任务"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { close() }
                                .disabled(isSaving)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") { save() }
                                .disabled(isSaving || validationMessage(at: context.date) != nil)
                                .accessibilityHint(Text(validationMessage(at: context.date) ?? String(localized: "保存定时任务并关闭表单")))
                        }
                    }
            }
            .sheet(isPresented: $showModelPicker) {
                NavigationStack {
                    UnifiedModelPicker(config: modelPickerConfig)
                }
            }
            .confirmationDialog("放弃未保存的修改？", isPresented: $showDiscardConfirmation,
                                titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            } message: {
                Text("关闭后，本次表单中的修改不会保存。")
            }
        }
        .interactiveDismissDisabled(draft != original || saveError != nil || isSaving)
    }

    private func editorForm(now: Date) -> some View {
        Form {
            Section {
                TextField("任务名（可选）", text: $draft.name)
                    .accessibilityLabel(Text("任务名，可选"))
            } footer: {
                Text("留空时会根据提示词显示任务名称。")
            }

            scheduleSection
            endDateSection

            Section {
                TextField("输入希望定时执行的提示词", text: $draft.prompt, axis: .vertical)
                    .lineLimit(4...12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("提示词"))
                    .accessibilityHint(Text("必填，支持多行输入"))
            } header: {
                Text("提示词")
            }

            advancedSection

            Section {
                if let reason = validationMessage(at: now) {
                    Label {
                        Text(reason)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .foregroundStyle(.secondary)
                }
                if let next = candidate.nextOccurrence(after: now) {
                    LabeledContent("下次计划时间") {
                        Text(ScheduledTasksText.dateTime(next))
                            .multilineTextAlignment(.trailing)
                    }
                    if !draft.isEnabled {
                        Text("此任务已暂停。保存后仍保持暂停，启用后才会参与调度。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("计划预览")
            } footer: {
                ScheduledTasksSchedulingNotice()
            }

            if let saveError {
                Section {
                    ScheduledTasksErrorMessage(message: saveError, details: saveErrorDetails)
                } header: {
                    Text("保存未完成")
                } footer: {
                    Text("表单内容已保留，请检查后重试。")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var scheduleSection: some View {
        Section {
            Picker("重复", selection: $draft.repeatRule) {
                ForEach(ScheduledTaskRepeat.allCases, id: \.self) { rule in
                    Text(ScheduledTasksText.repeatName(rule)).tag(rule)
                }
            }
            .pickerStyle(.menu)

            switch draft.repeatRule {
            case .daily:
                EmptyView()
            case .weekly:
                Picker("星期", selection: $draft.weekday) {
                    ForEach(ScheduledTasksText.orderedWeekdays, id: \.self) { day in
                        Text(ScheduledTasksText.weekday(day)).tag(day)
                    }
                }
                .pickerStyle(.menu)
            case .monthly:
                Picker("每月日期", selection: $draft.monthDay) {
                    ForEach(1...31, id: \.self) { day in
                        Text("\(day)日").tag(day)
                    }
                }
                .pickerStyle(.menu)
            case .once:
                DatePicker("执行日期", selection: $draft.oneTimeDate, displayedComponents: .date)
                    .environment(\.locale, ScheduledTasksText.chineseLocale)
            }

            DisclosureGroup(isExpanded: $timeExpanded) {
                DatePicker("执行时间", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, ScheduledTasksText.chineseLocale)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("执行时间，小时和分钟"))
            } label: {
                LabeledContent("时间") {
                    Text(String(format: "%02d:%02d", draft.hour, draft.minute))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("执行计划")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("日期和时间按设备当前时区计算。")
                if draft.repeatRule == .monthly {
                    Text("每月所选日期超过当月天数时，按当月最后一天运行。")
                }
            }
        }
    }

    private var endDateSection: some View {
        Section {
            Toggle("无结束时间", isOn: Binding(
                get: { draft.endDate == nil },
                set: { noEnd in
                    if noEnd {
                        if let date = draft.endDate { rememberedEndDate = date }
                        draft.endDate = nil
                    } else {
                        draft.endDate = rememberedEndDate
                    }
                }
            ))
            if draft.endDate != nil {
                DatePicker("截止日期", selection: Binding(
                    get: { draft.endDate ?? rememberedEndDate },
                    set: { date in
                        draft.endDate = date
                        rememberedEndDate = date
                    }
                ), displayedComponents: .date)
                .environment(\.locale, ScheduledTasksText.chineseLocale)
            }
        } header: {
            Text("结束条件")
        } footer: {
            Text("截止日期包含当天，按设备当前时区计算。不重复的任务仅执行一次。")
        }
    }

    private var advancedSection: some View {
        Section {
            Picker("运行方式", selection: $draft.runMode) {
                Text("当前会话")
                    .tag(ScheduledTaskRunMode.currentConversation)
                    .disabled(!isEditing && currentSessionId == nil)
                Text("新建会话").tag(ScheduledTaskRunMode.newConversation)
            }
            .pickerStyle(.menu)
            .onChange(of: draft.runMode) { mode in
                // An existing task owns its binding independently of the host page.
                // Switching away and back restores that binding rather than rebinding.
                draft.sessionId = mode == .currentConversation ? currentConversationSessionId : nil
            }

            Button { showModelPicker = true } label: {
                LabeledContent("服务商模型") {
                    HStack(spacing: 6) {
                        Text(selectedModelName)
                            .multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityLabel(Text("选择服务商模型，\(selectedModelName)"))
            .accessibilityHint(Text("选择一个模型条目，不使用模型组"))
        } header: {
            Text("高级设置")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !isEditing && currentSessionId == nil {
                    Text("当前没有可用会话，仅可选择新建会话。")
                }
                if draft.runMode == .currentConversation {
                    if isEditing && ScheduledTasksText.nonempty(original.sessionId) != nil {
                        Text("运行时继续此任务原先绑定的会话，不依赖当前页面是否有会话。编辑时会保留原绑定。")
                    } else if currentConversationSessionId == nil {
                        Text("此任务没有可用的会话绑定，请选择新建会话。")
                    } else {
                        Text("运行时继续当前会话，并使用所选模型。")
                    }
                } else {
                    Text("每次运行时新建会话，并使用所选模型。")
                }
                Text("仅绑定单个模型条目，不绑定模型组。")
            }
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                // Anchor only the wheel, not the schedule, to a day without a DST gap.
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .current
                return calendar.date(from: DateComponents(
                    year: 2001, month: 1, day: 15, hour: draft.hour, minute: draft.minute
                )) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = parts.hour ?? 8
                draft.minute = parts.minute ?? 0
            }
        )
    }

    private var currentConversationSessionId: String? {
        if isEditing, let bound = ScheduledTasksText.nonempty(original.sessionId) {
            return bound
        }
        return currentSessionId
    }

    private var candidate: ScheduledTaskDefinition {
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        value.modelEntryId = draft.modelEntryId.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.runMode == .newConversation {
            value.sessionId = nil
        } else {
            value.sessionId = ScheduledTasksText.nonempty(draft.sessionId) ?? currentConversationSessionId
        }
        // nextRunAt is computed by ScheduledTaskStore.save, never trusted from the draft.
        return value
    }

    private var selectedModelName: String {
        guard !draft.modelEntryId.isEmpty else { return String(localized: "请选择模型") }
        guard let entry = models.entry(for: draft.modelEntryId) else {
            return String(localized: "原模型已不可用，请重新选择")
        }
        let providerName = models.instance(for: entry.providerInstanceId)?.label
            ?? String(localized: "已移除的服务商")
        let name = String(localized: "\(providerName) · \(entry.model.displayName)")
        return isUsableModel(entry) ? name : String(localized: "\(name)（当前不可用）")
    }

    private func isUsableModel(_ entry: ModelEntry) -> Bool {
        guard !entry.isHidden,
              entry.model.capabilities.supportedModalities.contains(.textOutput),
              let provider = models.instance(for: entry.providerInstanceId),
              provider.isEnabled, provider.hasAnyCredential else { return false }
        return true
    }

    private var modelPickerConfig: ModelPickerConfig {
        // A value snapshot keeps the picker's nonisolated filter free of actor access.
        // Observing ProviderConfigStore refreshes this config when its models change.
        let selectableIDs = Set(models.modelEntries.filter { isUsableModel($0) }.map(\.id))
        return ModelPickerConfig(
            title: "选择服务商模型",
            mode: .single,
            groupScope: .none,
            candidateFilter: { selectableIDs.contains($0.id) },
            headerNote: String(localized: "仅显示未隐藏、支持文本输出且服务提供方已启用并已配置凭据的模型条目，不绑定模型组。"),
            showGroups: false,
            showCreateGroup: false,
            dismissOnSelect: true,
            currentEntryId: { draft.modelEntryId.isEmpty ? nil : draft.modelEntryId },
            onSelect: { entry in
                guard isUsableModel(entry) else {
                    saveError = String(localized: "此模型当前不可用，请检查服务提供方和凭据，或选择其他支持文本输出的模型。")
                    saveErrorDetails = nil
                    return
                }
                draft.modelEntryId = entry.id
            }
        )
    }

    private func validationMessage(at now: Date) -> String? {
        let value = candidate
        if value.prompt.isEmpty { return String(localized: "请输入提示词。") }
        if value.modelEntryId.isEmpty { return String(localized: "请选择模型。") }
        guard let entry = models.entry(for: value.modelEntryId), isUsableModel(entry) else {
            return String(localized: "所选模型不可用。请选择未隐藏、支持文本输出且服务提供方已启用并已配置凭据的模型。")
        }
        if value.runMode == .currentConversation && value.sessionId == nil {
            return String(localized: "没有可用的会话绑定，请选择新建会话。")
        }
        if value.nextOccurrence(after: now) == nil {
            return String(localized: "没有下次执行时间，请检查执行日期、时间和截止日期。")
        }
        return nil
    }

    private func save() {
        guard !isSaving else { return }
        if let reason = validationMessage(at: Date()) {
            saveError = reason
            saveErrorDetails = nil
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try store.save(candidate)
            dismiss()
        } catch {
            // Keep the draft and sheet intact even when persistence fails.
            saveError = String(localized: "保存失败，请稍后重试。")
            saveErrorDetails = error.localizedDescription
        }
    }

    private func close() {
        if draft != original || saveError != nil {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }
}

// MARK: - Run history

private struct ScheduledTaskRunRow: View {
    let run: ScheduledTaskRun

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(run.taskName).font(.headline).foregroundStyle(.primary)
            ScheduledTaskStatusLabel(status: run.status)
            Text("计划时间：\(ScheduledTasksText.dateTime(run.scheduledAt))")
                .font(.caption).foregroundStyle(.secondary)
            if !run.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: run.summary)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let error = ScheduledTasksText.nonempty(run.error) {
                Text("错误摘要：\(error)")
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(2)
            }
            Label("查看详情", systemImage: "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct ScheduledTaskRunDetailView: View {
    let runId: UUID
    @ObservedObject private var store = ScheduledTaskStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var operationError: ScheduledTasksOperationError?

    private var run: ScheduledTaskRun? { store.runs.first { $0.id == runId } }

    var body: some View {
        NavigationStack {
            Form {
                if let run {
                    Section("运行信息") {
                        LabeledContent("任务", value: run.taskName)
                        ScheduledTaskStatusLabel(status: run.status)
                        LabeledContent("计划时间", value: ScheduledTasksText.dateTime(run.scheduledAt))
                        LabeledContent("开始时间", value: ScheduledTasksText.dateTime(run.startedAt))
                        if let finished = run.finishedAt {
                            LabeledContent("结束时间", value: ScheduledTasksText.dateTime(finished))
                        }
                    }
                    Section("结果摘要") {
                        if run.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(run.status == .running ? String(localized: "正在执行，尚无结果摘要。") : String(localized: "暂无结果摘要。"))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: run.summary).textSelection(.enabled)
                        }
                    }
                    if let error = ScheduledTasksText.nonempty(run.error) {
                        Section("错误详情（原始信息）") {
                            Text(verbatim: error).textSelection(.enabled)
                        }
                    }
                    if run.status == .running {
                        Section {
                            Button("取消执行", role: .destructive) { store.cancelRun(id: run.id) }
                        } footer: {
                            Text("取消请求提交后，状态将在执行结束时更新。")
                        }
                    } else {
                        Section {
                            Button("删除记录", role: .destructive) { deleteRun() }
                        } footer: {
                            Text("仅删除这条运行记录，定时任务和关联对话都会保留。")
                        }
                    }
                    if let error = store.lastError {
                        Section {
                            ScheduledTasksErrorMessage(
                                message: String(localized: "调度操作未完成，请稍后重试。"),
                                details: error
                            )
                        }
                    }
                } else {
                    Section { Text("此运行记录已不存在。") }
                }
            }
            .navigationTitle("运行详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert(item: $operationError) { error in
                Alert(
                    title: Text("操作未完成"),
                    message: Text(error.message),
                    dismissButton: .default(Text("好"))
                )
            }
        }
    }

    private func deleteRun() {
        guard let current = run, current.status != .running else { return }
        do {
            try store.deleteRun(id: current.id)
            dismiss()
        } catch {
            // Preserve the detail sheet on persistence failure.
            operationError = ScheduledTasksOperationError(
                message: String(localized: "删除运行记录失败，记录仍保留。请稍后重试。")
            )
        }
    }
}

private struct ScheduledTaskStatusLabel: View {
    let status: ScheduledTaskRunStatus

    var body: some View {
        Label(ScheduledTasksText.status(status), systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(color)
            .accessibilityLabel(Text("运行状态：\(ScheduledTasksText.status(status))"))
    }

    private var symbol: String {
        switch status {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .interrupted: return "pause.circle"
        }
    }

    private var color: Color {
        switch status {
        case .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .interrupted: return .secondary
        }
    }
}

// All generated UI strings have Chinese extraction keys. Model names, prompts,
// summaries and raw provider errors are deliberately preserved as runtime data.
private enum ScheduledTasksText {
    static let chineseLocale = Locale(identifier: "zh_Hans_CN")

    static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    static func repeatName(_ rule: ScheduledTaskRepeat) -> String {
        switch rule {
        case .daily: return String(localized: "每天")
        case .weekly: return String(localized: "每周")
        case .monthly: return String(localized: "每月")
        case .once: return String(localized: "不重复")
        }
    }

    static var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }

    static func weekday(_ day: Int) -> String {
        switch day {
        case 1: return String(localized: "星期日")
        case 2: return String(localized: "星期一")
        case 3: return String(localized: "星期二")
        case 4: return String(localized: "星期三")
        case 5: return String(localized: "星期四")
        case 6: return String(localized: "星期五")
        case 7: return String(localized: "星期六")
        default: return String(localized: "请选择星期")
        }
    }

    static func status(_ status: ScheduledTaskRunStatus) -> String {
        switch status {
        case .running: return String(localized: "正在执行")
        case .succeeded: return String(localized: "执行成功")
        case .failed: return String(localized: "执行失败")
        case .interrupted: return String(localized: "执行已中断")
        }
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.locale(chineseLocale).year().month().day().hour().minute())
    }

    static func schedule(_ task: ScheduledTaskDefinition) -> String {
        let time = String(format: "%02d:%02d", task.hour, task.minute)
        switch task.repeatRule {
        case .daily:
            return String(localized: "每天 \(time)")
        case .weekly:
            let day = weekday(task.weekday)
            return String(localized: "每周 · \(day) \(time)")
        case .monthly:
            return String(localized: "每月\(task.monthDay)日 \(time)（超出当月天数按最后一天）")
        case .once:
            let day = task.oneTimeDate.formatted(.dateTime.locale(chineseLocale).year().month().day())
            return String(localized: "不重复 · \(day) \(time)")
        }
    }
}
