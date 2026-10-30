import SwiftUI
import SwiftData
import WidgetKit
import UIKit

struct TaskDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    let taskID: UUID
    let initialTitle: String

    @State private var selectedOccurrenceDate: Date?
    @State private var preferredExecutionRecordID: UUID?
    @State private var parentDetailDraft = ""
    @State private var isEditingParentDetail = false
    @State private var isSavingParentDetail = false
    @State private var persistenceErrorMessage: String?
    @State private var subtaskEditorTarget: SubtaskEditorTarget?
    @State private var isCreatingSubtask = false
    @State private var isSavingQuickSubtask = false
    @State private var isSavingSubtaskEditor = false
    @State private var isSavingTaskState = false
    @State private var isHistoryExpanded = false
    @State private var pendingDeletedSubtask: TaskSubitemProjection?
    @State private var pendingDeletionTask: Task<Void, Never>?
    @State private var pendingSubtaskOrder: [UUID]?
    @State private var orderPersistenceTask: Task<Void, Never>?
    @State private var isOrderPersistenceInFlight = false
    @State private var quickSubtaskOccurrenceDate: Date?
    @State private var subtaskTitleDraft = ""
    @State private var subtaskNoteDraft = ""
    @State private var subtaskDetailDraft = ""
    @State private var subtaskCompletedDraft = false
    @State private var weekOffset: Int = 0
    @State private var occurrenceSnapshotState = OccurrenceSnapshotState.empty
    @State private var occurrenceSnapshotRefreshTask: Task<Void, Never>?
    @State private var detailDataActivationTask: Task<Void, Never>?
    @State private var deferredPersistenceTask: Task<Void, Never>?
    @State private var completionPersistenceTask: Task<Void, Never>?
    @State private var isCompletionPersistenceInFlight = false
    @State private var isDetailDataActive = false
    @State private var isRefreshInFlight = false
    @State private var needsRefreshAfterCurrent = false
    @State private var completionMutationVersion = 0
    @State private var isSyncingSelectedOccurrenceDate = false
    @State private var isTaskUnavailable = false
    @State private var pendingSubtaskCompletionMutations: [UUID: PendingSubtaskCompletionMutation] = [:]
    @State private var pendingOccurrenceCompletionMutations: [Date: PendingOccurrenceCompletionMutation] = [:]
    @State private var allSubtasks: [TaskSubitemProjection] = []
    @State private var allExecutionRecords: [TaskExecutionRecordProjection] = []
    @State private var currentOccurrenceSubtasks: [TaskSubitemProjection] = []
    @State private var currentExecutionRecord: TaskExecutionRecordProjection? = nil
    @State private var taskProjection: TaskProjection

    init(taskID: UUID, initialTitle: String) {
        self.taskID = taskID
        self.initialTitle = initialTitle
        _taskProjection = State(initialValue: TaskProjection(id: taskID, title: initialTitle))
    }

    init(task: TaskItem) {
        self.init(taskID: task.id, initialTitle: task.title)
        _taskProjection = State(initialValue: TaskProjection(task))
    }

    private struct SubtaskEditorTarget: Identifiable {
        let id = UUID()
        let subtaskID: UUID?
    }

    private struct PendingSubtaskCompletionMutation: Sendable {
        let occurrenceDate: Date
        let status: TaskExecutionStatus
        let completedAt: Date?
        let actionID: String
        let startedAt: CFTimeInterval
    }

    private struct PendingOccurrenceCompletionMutation: Sendable {
        let occurrenceDate: Date
        let isReopening: Bool
        let actionID: String
        let startedAt: CFTimeInterval
    }

    private enum CompletionPersistenceOutcome: Sendable {
        case saved
        case failed(String)
    }

    private struct OccurrenceSnapshotState: Sendable {
        let pending: [TaskOccurrenceSnapshot]
        let completed: [TaskOccurrenceSnapshot]
        let upcoming: [TaskOccurrenceSnapshot]

        static let empty = OccurrenceSnapshotState(
            pending: [],
            completed: [],
            upcoming: []
        )

        var selection: [TaskOccurrenceSnapshot] {
            pending + upcoming + completed
        }

        var timeline: [TaskOccurrenceSnapshot] {
            pending + upcoming + completed
        }
    }

    // MARK: - Computed Properties
    
    private var canRenderLiveContent: Bool {
        scenePhase == .active
    }

    private var canReadDetailQueries: Bool {
        canRenderLiveContent && isDetailDataActive
    }

    private var isRecentPlan: Bool {
        taskProjection.timingMode == .flexibleDeadline
    }

    private var pendingOccurrences: [TaskOccurrenceSnapshot] { occurrenceSnapshotState.pending }
    private var completedOccurrences: [TaskOccurrenceSnapshot] { occurrenceSnapshotState.completed }
    private var upcomingOccurrences: [TaskOccurrenceSnapshot] { occurrenceSnapshotState.upcoming }
    private var selectionSnapshots: [TaskOccurrenceSnapshot] { occurrenceSnapshotState.selection }
    private var timelineSnapshots: [TaskOccurrenceSnapshot] { occurrenceSnapshotState.timeline }

    private var selectedSnapshot: TaskOccurrenceSnapshot? {
        guard let resolvedDate = Self.resolvedSelectedOccurrenceDate(in: selectionSnapshots, requestedDate: selectedOccurrenceDate) else {
            return nil
        }
        return selectionSnapshots.first {
            Calendar.current.isDate($0.occurrenceDate, inSameDayAs: resolvedDate)
        }
    }

    private var currentOccurrenceDate: Date? {
        Self.resolvedSelectedOccurrenceDate(in: selectionSnapshots, requestedDate: selectedOccurrenceDate)
    }

    private var subtaskProgressText: String? {
        guard !currentOccurrenceSubtasks.isEmpty else { return nil }
        let completed = currentOccurrenceSubtasks.filter { $0.status == .completed }.count
        return "\(completed)/\(currentOccurrenceSubtasks.count) 子任务已完成"
    }

    private var subtaskProgressValue: Double {
        guard !currentOccurrenceSubtasks.isEmpty else { return 0 }
        let completed = currentOccurrenceSubtasks.filter { $0.status == .completed }.count
        return Double(completed) / Double(currentOccurrenceSubtasks.count)
    }

    private var occurrenceHistory: [TaskOccurrenceSnapshot] {
        completedOccurrences.sorted { $0.occurrenceDate > $1.occurrenceDate }
    }

    private var currentOccurrenceHasSubtaskNotes: Bool {
        currentOccurrenceSubtasks.contains {
            !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var isCurrentOccurrenceFuture: Bool {
        guard let date = currentOccurrenceDate else { return false }
        return isFutureOccurrence(date: date)
    }

    private func isFutureOccurrence(date: Date) -> Bool {
        date > TaskExecutionSupport.day(for: .now)
    }

    private func isFutureOccurrence(_ snapshot: TaskOccurrenceSnapshot) -> Bool {
        isFutureOccurrence(date: snapshot.occurrenceDate)
    }

    nonisolated private static func resolvedSelectedOccurrenceDate(
        in snapshots: [TaskOccurrenceSnapshot],
        requestedDate: Date?
    ) -> Date? {
        if let requestedDate,
           snapshots.contains(where: { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: requestedDate) }) {
            return TaskExecutionSupport.day(for: requestedDate)
        }
        return defaultOccurrenceDate(in: snapshots)
    }

    nonisolated private static func defaultOccurrenceDate(in snapshots: [TaskOccurrenceSnapshot]) -> Date? {
        let today = TaskExecutionSupport.day(for: .now)
        let pending = snapshots
            .filter { !$0.isCompleted && $0.occurrenceDate < today }
            .sorted { $0.occurrenceDate < $1.occurrenceDate }
        if let date = pending.first?.occurrenceDate {
            return date
        }

        let upcoming = snapshots
            .filter { !$0.isCompleted && $0.occurrenceDate >= today }
            .sorted { $0.occurrenceDate < $1.occurrenceDate }
        if let date = upcoming.first?.occurrenceDate {
            return date
        }

        return snapshots
            .filter(\.isCompleted)
            .sorted { $0.occurrenceDate > $1.occurrenceDate }
            .first?
            .occurrenceDate
    }

    nonisolated private static func perfMark(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
#if DEBUG
        DebugPerf.mark("TaskDetailView \(message)", file: file, line: line)
#endif
    }

    nonisolated private static func perfWatchMainThread(_ label: String, threshold: TimeInterval = 0.6) {
#if DEBUG
        DebugPerf.watchMainThread("TaskDetailView \(label)", threshold: threshold)
#endif
    }

    nonisolated private static func perfMillis(since startedAt: CFTimeInterval) -> String {
        String(format: "%.1fms", (CACurrentMediaTime() - startedAt) * 1000)
    }

    nonisolated private static func perfDateLabel(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return date.formatted(.dateTime.year().month().day())
    }

    // MARK: - Body
    
    var body: some View {
        List {
            if isTaskUnavailable {
                unavailableStateSection
            } else {
                summarySection

                if isDetailDataActive {
                    if isRecentPlan {
                        if let snapshot = selectedSnapshot {
                            recentPlanStatusSection(snapshot)
                            subtasksSection
                        } else {
                            emptyStateSection
                        }
                    } else {
                        occurrenceCalendarGrid

                        if let snapshot = selectedSnapshot {
                            currentOccurrenceSection(snapshot)
                            subtasksSection
                        } else {
                            emptyStateSection
                        }

                        if !pendingOccurrences.isEmpty {
                            occurrenceSwitcherSection(title: "待处理记录", snapshots: pendingOccurrences)
                        }

                        if !upcomingOccurrences.isEmpty {
                            occurrenceSwitcherSection(title: "未来待办", snapshots: upcomingOccurrences)
                        }

                        if !occurrenceHistory.isEmpty {
                            occurrenceHistorySection
                        }
                    }
                } else {
                    detailLoadingSection
                }
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if currentOccurrenceSubtasks.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        TaskEditorLoaderView(taskID: taskID, fallbackTitle: taskProjection.title)
                    } label: {
                        Label("编辑任务", systemImage: "square.and.pencil")
                    }

                    if taskProjection.recurrence.kind != .once {
                        Button {
                            toggleTaskPause()
                        } label: {
                            Label(
                                taskProjection.isPaused ? "启用循环任务" : "暂停循环任务",
                                systemImage: taskProjection.isPaused ? "play.fill" : "pause.fill"
                            )
                        }
                        .disabled(isSavingTaskState)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            Self.perfMark("onAppear task=\(taskProjection.title)")
            activateDetailDataAfterNavigationSettles()
        }
        .onDisappear {
            Self.perfMark("onDisappear task=\(taskProjection.title)")
            detailDataActivationTask?.cancel()
            occurrenceSnapshotRefreshTask?.cancel()
            deferredPersistenceTask?.cancel()
            flushPendingSubtaskOrderOnExit()
            commitPendingDeletion()
            flushPendingCompletionMutationsOnExit()
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDataDidChange)) { _ in
            Self.perfMark("received appDataDidMutate")
            requestDetailRefresh(reason: "appDataDidMutate")
        }
        .onChange(of: selectedOccurrenceDate) { _, _ in
            if isSyncingSelectedOccurrenceDate {
                isSyncingSelectedOccurrenceDate = false
                return
            }
            let t0 = CACurrentMediaTime()
            Self.perfMark("selectedOccurrenceDate changed to=\(Self.perfDateLabel(selectedOccurrenceDate))")
            syncCalendarToSelectedDate()
            if !applyCachedSelection() {
                requestDetailRefresh(reason: "selectedOccurrenceDate cache miss")
            }
            Self.perfMark("selectedOccurrenceDate main path end elapsed=\(Self.perfMillis(since: t0))")
        }
        .onChange(of: weekOffset) { _, _ in
            guard isDetailDataActive else { return }
            requestDetailRefresh(reason: "weekOffset")
        }
        .sheet(isPresented: $isEditingParentDetail) { parentDetailEditorSheet }
        .sheet(item: $subtaskEditorTarget) { target in subtaskEditorSheet(target) }
        .safeAreaInset(edge: .bottom) {
            if let pendingDeletedSubtask {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                    Text("已删除“\(pendingDeletedSubtask.title)”")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Button("撤销") { undoPendingDeletion() }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
                .padding(.bottom, 6)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
        }
        .alert("保存失败", isPresented: Binding(get: { persistenceErrorMessage != nil }, set: { if !$0 { persistenceErrorMessage = nil } })) {
            Button("知道了") { persistenceErrorMessage = nil }
        } message: { Text(persistenceErrorMessage ?? "发生未知错误") }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(taskProjection.title)
                    .font(.title3.weight(.bold))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { summaryMetadata }
                    VStack(alignment: .leading, spacing: 6) { summaryMetadata }
                }

                if taskProjection.isPaused {
                    Label("循环已暂停，今天已有的任务仍然保留", systemImage: "pause.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                if !taskProjection.note.isEmpty {
                    Divider()
                    Label {
                        Text(taskProjection.note)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "note.text")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        }
    }

    @ViewBuilder
    private var summaryMetadata: some View {
        if isRecentPlan {
            Label("近期计划", systemImage: "calendar.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.blue)

            if let deadline = taskProjection.deadline {
                Label(
                    "截止 \(deadline.formatted(.dateTime.year().month().day()))",
                    systemImage: "flag.checkered"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else {
            Label(taskProjection.recurrenceLabel, systemImage: taskProjection.recurrence.kind == .once ? "1.circle" : "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let effectiveDateRangeLabel = taskProjection.effectiveDateRangeLabel {
                Label(effectiveDateRangeLabel, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if taskProjection.skipPolicy == .unskippable {
                Label("不可跳过", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func toggleTaskPause() {
        guard !isSavingTaskState else { return }
        isSavingTaskState = true
        let targetTaskID = taskID
        let container = modelContext.container

        Task {
            let result: Result<TaskProjection, Error> = await Task.detached(priority: .userInitiated) {
            return PersistentStoreAccessGate.withAccess {
                do {
                    let context = ModelContext(container)
                    let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate<TaskItem> { $0.id == targetTaskID })
                    guard let task = try context.fetch(descriptor).first else {
                        throw CocoaError(.fileNoSuchFile)
                    }

                    let calendar = Calendar.current
                    let today = calendar.startOfDay(for: .now)
                    if task.isPaused {
                        task.resume(on: today)
                    } else {
                        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
                        task.pause(starting: tomorrow)
                    }
                    try context.save()
                    return .success(TaskProjection(task))
                } catch {
                    return .failure(error)
                }
                }
        }.value

            isSavingTaskState = false
            switch result {
            case let .success(projection):
                taskProjection = projection
                WidgetCenter.shared.reloadAllTimelinesInBackground()
                AppDataChangeCenter.post()
                requestDetailRefresh(reason: "task pause state changed")
            case let .failure(error):
                persistenceErrorMessage = error.localizedDescription
            }
        }
    }

    private var detailLoadingSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在加载...").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    private var occurrenceCalendarGrid: some View {
        Section("选择日期") {
            VStack(spacing: 12) {
                headerView
                weekdayLabels
                dateGrid
            }
            .padding(.vertical, 6)
        }
    }

    private var headerView: some View {
        HStack(spacing: 10) {
            Button { withAnimation { weekOffset -= 1 } } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.quaternary))
            }
            .accessibilityLabel("前一周")

            Spacer()

            VStack(spacing: 2) {
                Text(calendarMonthYearLabel)
                    .font(.headline)
                if weekOffset != 0 {
                    Button("回到今天") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            weekOffset = 0
                            selectTodayOrNearestOccurrence()
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            Spacer()

            Button { withAnimation { weekOffset += 1 } } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.quaternary))
            }
            .accessibilityLabel("后一周")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }

    private var weekdayLabels: some View {
        HStack {
            ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                Text(day).font(.caption2.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private var dateGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(gridDates, id: \.self) { date in
                calendarCell(for: date)
            }
        }
    }

    private var gridStartDate: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        let startOfWeek = calendar.date(from: components)!
        return calendar.date(byAdding: .day, value: weekOffset * 7, to: startOfWeek)!
    }

    private var gridDates: [Date] {
        (0..<14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: gridStartDate) }
    }

    private var calendarMonthYearLabel: String {
        let middleDate = Calendar.current.date(byAdding: .day, value: 7, to: gridStartDate)!
        return middleDate.formatted(.dateTime.year().month())
    }

    private func calendarCell(for date: Date) -> some View {
        let snapshot = timelineSnapshots.first { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: date) }
        let isSelected = currentOccurrenceDate.map { Calendar.current.isDate(date, inSameDayAs: $0) } ?? false
        let isToday = Calendar.current.isDateInToday(date)
        let canSelect = snapshot != nil
        
        return Button {
            guard canSelect else { return }
            withAnimation(.spring(response: 0.3)) { selectedOccurrenceDate = date }
        } label: {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 16, weight: isToday ? .black : .medium, design: .rounded))
                .foregroundStyle(isSelected ? .white : cellContentColor(snapshot))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? cellContentColor(snapshot) : cellBackgroundColor(snapshot))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
        .accessibilityLabel(calendarAccessibilityLabel(for: date, snapshot: snapshot))
        .accessibilityValue(isSelected ? "已选择" : "")
    }

    private func cellBackgroundColor(_ snapshot: TaskOccurrenceSnapshot?) -> Color {
        guard let s = snapshot else { return Color(uiColor: .systemGray6).opacity(0.4) }
        if s.isCompleted { return .green.opacity(0.15) }
        if s.occurrenceDate < TaskExecutionSupport.day(for: .now) { return .red.opacity(0.14) }
        if Calendar.current.isDateInToday(s.occurrenceDate) { return .orange.opacity(0.16) }
        return .blue.opacity(0.15)
    }

    private func cellContentColor(_ snapshot: TaskOccurrenceSnapshot?) -> Color {
        guard let s = snapshot else { return .secondary.opacity(0.4) }
        if s.isCompleted { return .green }
        if s.occurrenceDate < TaskExecutionSupport.day(for: .now) { return .red }
        if Calendar.current.isDateInToday(s.occurrenceDate) { return .orange }
        return .blue
    }

    private func calendarAccessibilityLabel(for date: Date, snapshot: TaskOccurrenceSnapshot?) -> String {
        let dateText = date.formatted(.dateTime.year().month().day().weekday())
        guard let snapshot else { return "\(dateText)，没有任务安排" }
        let status = snapshot.isCompleted ? "已完成" : (isFutureOccurrence(snapshot) ? "未开始" : "待处理")
        if let progress = snapshot.subtaskProgressText {
            return "\(dateText)，\(status)，\(progress)"
        }
        return "\(dateText)，\(status)"
    }

    private func selectTodayOrNearestOccurrence() {
        let today = TaskExecutionSupport.day(for: .now)
        if let todaySnapshot = timelineSnapshots.first(where: { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: today) }) {
            selectedOccurrenceDate = todaySnapshot.occurrenceDate
        } else if let nearest = timelineSnapshots.min(by: {
            abs($0.occurrenceDate.timeIntervalSince(today)) < abs($1.occurrenceDate.timeIntervalSince(today))
        }) {
            selectedOccurrenceDate = nearest.occurrenceDate
        }
    }

    private func currentOccurrenceSection(_ snapshot: TaskOccurrenceSnapshot) -> some View {
        Section("当前处理") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot.occurrenceDate.formatted(.dateTime.year().month().day()))
                            .font(.headline)

                        HStack(spacing: 6) {
                            Text(snapshot.isCompleted ? "已完成" : (isFutureOccurrence(snapshot) ? "未来" : "待处理"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(snapshot.isCompleted ? .green : (isFutureOccurrence(snapshot) ? .blue : .orange))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    (snapshot.isCompleted ? Color.green.opacity(0.14) : (isFutureOccurrence(snapshot) ? Color.blue.opacity(0.12) : Color.orange.opacity(0.14))),
                                    in: Capsule()
                                )

                            if snapshot.hasDetail {
                                noteBadge("有说明")
                            }

                            if currentOccurrenceHasSubtaskNotes {
                                noteBadge("子任务有备注")
                            }
                        }
                    }

                    Spacer()

                    Button {
                        isEditingParentDetail = true
                    } label: {
                        Label(
                            snapshot.hasDetail ? "编辑说明" : "添加说明",
                            systemImage: snapshot.hasDetail ? "square.and.pencil" : "plus.bubble"
                        )
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if let subtaskProgressText {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(subtaskProgressText)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(subtaskProgressValue == 1 ? "全部完成" : "继续加油")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: subtaskProgressValue)
                            .tint(subtaskProgressValue == 1 ? .green : .blue)
                    }
                }

                if isCurrentOccurrenceFuture {
                    Text("可以先为这一天准备子任务和备注，完成要等到当天。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(currentOccurrenceCardBackground(for: snapshot))
        }
    }

    private func recentPlanStatusSection(_ snapshot: TaskOccurrenceSnapshot) -> some View {
        let deadline = taskProjection.deadline ?? taskProjection.startDate
        let state = RecentPlanSupport.deadlineState(deadline: deadline)
        let statusColor: Color = {
            switch state.kind {
            case .overdue:
                return .red
            case .dueToday:
                return .orange
            case .upcoming:
                return state.dayCount <= 7 ? .orange : .blue
            }
        }()

        return Section("计划状态") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(deadline.formatted(.dateTime.year().month().day().weekday(.wide)))
                            .font(.headline)
                        Text(snapshot.isCompleted ? "已完成" : state.statusText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(snapshot.isCompleted ? .green : statusColor)
                    }

                    Spacer()

                    if !snapshot.hasSubtasks {
                        Button {
                            toggleOccurrenceCompletion(snapshot)
                        } label: {
                            Label(
                                snapshot.isCompleted ? "重新打开" : "完成计划",
                                systemImage: snapshot.isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle.fill"
                            )
                            .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(snapshot.isCompleted ? .blue : .green)
                    }
                }

                if snapshot.hasSubtasks, let subtaskProgressText {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(subtaskProgressText)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(snapshot.isCompleted ? "计划已完成" : "完成全部子任务后自动完成")
                                .font(.caption)
                                .foregroundStyle(snapshot.isCompleted ? .green : .secondary)
                        }
                        ProgressView(value: subtaskProgressValue)
                            .tint(snapshot.isCompleted ? .green : .blue)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var subtasksSection: some View {
        Section(isRecentPlan ? "计划子任务" : "本次子任务") {
            if !isCreatingSubtask {
                Button { startQuickSubtaskCreation() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(isRecentPlan ? "添加计划子任务" : "添加本次子任务")
                                .foregroundStyle(.primary)
                            Text(
                                isRecentPlan
                                    ? "完成全部子任务后，近期计划会自动完成"
                                    : "这条子任务只属于 \((quickSubtaskOccurrenceDate ?? currentOccurrenceDate)?.formatted(.dateTime.month().day()) ?? "当前日期")"
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(subtaskRowInsets)
            } else {
                quickCreateSubtaskRow
                    .listRowInsets(subtaskRowInsets)
            }

            if currentOccurrenceSubtasks.isEmpty {
                Text(
                    isRecentPlan
                        ? "还没有计划子任务，可以添加执行步骤并逐条完成。"
                        : "这一天还没有子任务。你可以先添加需要执行的步骤，再逐条完成。"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(currentOccurrenceSubtasks) { subtask in
                    subtaskRow(subtask)
                        .listRowInsets(subtaskRowInsets)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { stageSubtaskDeletion(subtask) } label: { Label("删除", systemImage: "trash") }
                        }
                }
                .onMove(perform: moveSubtasks)
            }
        }
    }

    private var subtaskRowInsets: EdgeInsets {
        EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12)
    }

    private func subtaskRow(_ subtask: TaskSubitemProjection) -> some View {
        let isDone = subtask.status == .completed
        return HStack(alignment: .center, spacing: 12) {
            Button {
                toggleSubtaskCompletion(subtask)
            } label: {
                Image(systemName: leadingSymbol(for: subtask, isDone: isDone))
                    .font(.title3)
                    .foregroundStyle(leadingColor(for: subtask, isDone: isDone))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCurrentOccurrenceFuture)
            .accessibilityLabel(isDone ? "将“\(subtask.title)”标记为未完成" : "将“\(subtask.title)”标记为已完成")
            .transaction { transaction in
                transaction.animation = nil
            }

            Button {
                openEditSubtaskEditor(subtaskID: subtask.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(subtask.title)
                        .strikethrough(isDone)
                        .foregroundStyle(isDone ? .secondary : .primary)

                    if !subtask.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(subtask.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if !subtask.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(subtask.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    openEditSubtaskEditor(subtaskID: subtask.id)
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }

                Button {
                    moveSubtaskUp(subtask)
                } label: {
                    Label("上移", systemImage: "arrow.up")
                }
                .disabled(isFirstSubtask(subtask))

                Button {
                    moveSubtaskDown(subtask)
                } label: {
                    Label("下移", systemImage: "arrow.down")
                }
                .disabled(isLastSubtask(subtask))

                Divider()

                Button(role: .destructive) {
                    stageSubtaskDeletion(subtask)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("“\(subtask.title)”的更多操作")
        }
    }

    private var quickCreateSubtaskRow: some View {
        QuickSubtaskInputView(
            isSaving: isSavingQuickSubtask,
            onSave: { title in
                saveQuickSubtask(title: title)
            },
            onCancel: {
                cancelQuickSubtaskCreation()
            }
        )
    }

    private func occurrenceSwitcherSection(title: String, snapshots: [TaskOccurrenceSnapshot]) -> some View {
        Section(title) {
            ForEach(snapshots) { snapshot in
                occurrenceSwitcherRow(snapshot)
            }
        }
    }

    private var occurrenceHistorySection: some View {
        Section {
            DisclosureGroup(isExpanded: $isHistoryExpanded) {
                ForEach(occurrenceHistory) { snapshot in
                    occurrenceSwitcherRow(snapshot)
                }
            } label: {
                HStack(spacing: 10) {
                    Label("已完成历史", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    Text("\(occurrenceHistory.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if !isHistoryExpanded {
                Text("展开后可查看已经完成的执行记录。")
            }
        }
    }

    private func occurrenceSwitcherRow(_ snapshot: TaskOccurrenceSnapshot) -> some View {
        HStack(spacing: 12) {
            occurrenceLeadingButton(snapshot)

            Button {
                selectedOccurrenceDate = snapshot.occurrenceDate
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        occurrenceRow(snapshot)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer()

                    if isSelected(snapshot) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .listRowBackground(occurrenceListCardBackground(for: snapshot))
    }

    private var emptyStateSection: some View {
        Section {
            ContentUnavailableView(
                "还没有执行记录",
                systemImage: "checklist",
                description: Text("任务开始后，这里会显示每次执行情况和本次子任务。")
            )
        }
    }

    private var unavailableStateSection: some View {
        Section {
            ContentUnavailableView(
                "任务不存在",
                systemImage: "exclamationmark.triangle",
                description: Text("这个任务可能已经被删除，或当前数据还没有同步完成。")
            )
        }
    }

    // MARK: - Sheets

    private var parentDetailEditorSheet: some View {
        NavigationStack {
            Form {
                Section("本次说明") {
                    TextEditor(text: $parentDetailDraft)
                        .frame(minHeight: 180)

                    Text("这里记录这一次执行的情况；长期固定补充仍然放在任务备注里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑本次说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        isEditingParentDetail = false
                        refreshParentDetailDraft()
                    }
                    .disabled(isSavingParentDetail)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveParentDetail()
                    } label: {
                        if isSavingParentDetail {
                            ProgressView()
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(isSavingParentDetail)
                }
            }
        }
    }

    private func subtaskEditorSheet(_ target: SubtaskEditorTarget) -> some View {
        NavigationStack {
            Form {
                Section("子任务名称") {
                    TextField("例如：检查作业、签字、整理书包", text: $subtaskTitleDraft)
                }

                Section("子任务备注") {
                    TextField("相对固定的补充说明（可选）", text: $subtaskNoteDraft, axis: .vertical)
                }

                Section("这次说明") {
                    TextEditor(text: $subtaskDetailDraft)
                        .frame(minHeight: 150)
                }

                if !isCurrentOccurrenceFuture {
                    Section("完成状态") {
                        Toggle("标记为已完成", isOn: $subtaskCompletedDraft)
                    }
                } else {
                    Section {
                        Text("未来日期可以先写子任务和备注，但不能提前完成。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(target.subtaskID == nil ? "添加子任务" : "编辑子任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        subtaskEditorTarget = nil
                    }
                    .disabled(isSavingSubtaskEditor)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveSubtaskEditor(target)
                    } label: {
                        if isSavingSubtaskEditor {
                            ProgressView()
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(isSavingSubtaskEditor || subtaskTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func occurrenceLeadingButton(_ snapshot: TaskOccurrenceSnapshot) -> some View {
        let canToggle = !snapshot.hasSubtasks && !isFutureOccurrence(snapshot)

        return Button {
            guard canToggle else {
                selectedOccurrenceDate = snapshot.occurrenceDate
                return
            }
            selectedOccurrenceDate = snapshot.occurrenceDate
            toggleOccurrenceCompletion(snapshot)
        } label: {
            Image(systemName: leadingSymbol(for: snapshot))
                .font(.title3)
                .foregroundStyle(leadingColor(for: snapshot))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    private func leadingSymbol(for snapshot: TaskOccurrenceSnapshot) -> String {
        if isFutureOccurrence(snapshot) && !snapshot.isCompleted {
            return "clock"
        }
        if snapshot.hasSubtasks {
            return snapshot.isCompleted ? "checkmark.circle.fill" : "list.bullet.circle"
        }
        return snapshot.isCompleted ? "checkmark.circle.fill" : "circle"
    }

    private func leadingColor(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if isFutureOccurrence(snapshot) && !snapshot.isCompleted {
            return .blue
        }
        if snapshot.isCompleted {
            return .green
        }
        return .secondary
    }

    private func occurrenceRow(_ snapshot: TaskOccurrenceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(snapshot.occurrenceDate.formatted(.dateTime.year().month().day()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(snapshot.isCompleted ? "已完成" : (isFutureOccurrence(snapshot) ? "未来" : "待处理"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.isCompleted ? .green : (isFutureOccurrence(snapshot) ? .blue : .orange))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (snapshot.isCompleted ? Color.green.opacity(0.14) : (isFutureOccurrence(snapshot) ? Color.blue.opacity(0.12) : Color.orange.opacity(0.14))),
                        in: Capsule()
                    )

                if snapshot.hasDetail {
                    noteBadge("有说明")
                }
            }

            if let subtaskProgressText = snapshot.subtaskProgressText {
                Text(subtaskProgressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !snapshot.executionDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(snapshot.executionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func isSelected(_ snapshot: TaskOccurrenceSnapshot) -> Bool {
        guard let currentOccurrenceDate else { return false }
        return Calendar.current.isDate(snapshot.occurrenceDate, inSameDayAs: currentOccurrenceDate)
    }

    private func occurrenceListCardBackground(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if isSelected(snapshot) {
            return Color.blue.opacity(0.08)
        }
        if snapshot.isCompleted {
            return Color.green.opacity(0.05)
        }
        if isFutureOccurrence(snapshot) {
            return Color.blue.opacity(0.04)
        }
        return Color(.secondarySystemGroupedBackground)
    }

    private func occurrenceListCardBorder(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if isSelected(snapshot) {
            return Color.blue.opacity(0.45)
        }
        if snapshot.isCompleted {
            return Color.green.opacity(0.12)
        }
        if isFutureOccurrence(snapshot) {
            return Color.blue.opacity(0.12)
        }
        return Color.black.opacity(0.05)
    }

    // MARK: - Logic & Actions

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active {
            if !isDetailDataActive {
                activateDetailDataAfterNavigationSettles()
            } else {
                requestDetailRefresh(reason: "scenePhase active")
            }
        } else if phase == .background {
            flushPendingCompletionMutationsOnExit()
            flushPendingSubtaskOrderOnExit()
            commitPendingDeletion()
            isDetailDataActive = false
            occurrenceSnapshotRefreshTask?.cancel()
            isRefreshInFlight = false
            needsRefreshAfterCurrent = false
        }
    }

    private func activateDetailDataAfterNavigationSettles() {
        detailDataActivationTask?.cancel()
        Self.perfMark("activateDetailDataAfterNavigationSettles requested")
        Self.perfWatchMainThread("activateDetailDataAfterNavigationSettles", threshold: 0.5)
        detailDataActivationTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            isDetailDataActive = true
            Self.perfMark("activateDetailDataAfterNavigationSettles firing refresh")
            requestDetailRefresh(reason: "activateDetailDataAfterNavigationSettles")
        }
    }

    private func requestDetailRefresh(reason: String) {
        guard canRenderLiveContent else { return }

        if isRefreshInFlight {
            needsRefreshAfterCurrent = true
            Self.perfMark("refresh queued reason=\(reason)")
            return
        }

        refreshDetailModelsAndSnapshot(reason: reason)
    }

    private func scheduleDeferredDetailRefresh(after delay: TimeInterval = 0.9, reason: String) {
        deferredPersistenceTask?.cancel()
        deferredPersistenceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if isCompletionPersistenceInFlight ||
                !pendingSubtaskCompletionMutations.isEmpty ||
                !pendingOccurrenceCompletionMutations.isEmpty {
                Self.perfMark(
                    "refresh reconcile deferred reason=\(reason) pendingSubtasks=\(pendingSubtaskCompletionMutations.count) pendingOccurrences=\(pendingOccurrenceCompletionMutations.count) inFlight=\(isCompletionPersistenceInFlight)"
                )
                scheduleDeferredDetailRefresh(after: 0.25, reason: reason)
                return
            }
            requestDetailRefresh(reason: reason)
        }
    }

    private func scheduleCompletionPersistenceFlush(after delay: TimeInterval = 0.25) {
        completionPersistenceTask?.cancel()
        completionPersistenceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard !isCompletionPersistenceInFlight else { return }
            await persistPendingCompletionMutations()
        }
    }

    @MainActor
    private func flushPendingCompletionMutationsOnExit() {
        completionPersistenceTask?.cancel()
        guard !pendingSubtaskCompletionMutations.isEmpty || !pendingOccurrenceCompletionMutations.isEmpty else { return }
        Task { @MainActor in
            await persistPendingCompletionMutations(scheduleReconcile: false)
        }
    }

    @MainActor
    private func queueSubtaskCompletionPersistence(
        subtaskID: UUID,
        occurrenceDate: Date,
        status: TaskExecutionStatus,
        completedAt: Date?,
        actionID: String,
        startedAt: CFTimeInterval
    ) {
        pendingSubtaskCompletionMutations[subtaskID] = PendingSubtaskCompletionMutation(
            occurrenceDate: TaskExecutionSupport.day(for: occurrenceDate),
            status: status,
            completedAt: completedAt,
            actionID: actionID,
            startedAt: startedAt
        )
        scheduleCompletionPersistenceFlush()
    }

    @MainActor
    private func queueOccurrenceCompletionPersistence(
        occurrenceDate: Date,
        isReopening: Bool,
        actionID: String,
        startedAt: CFTimeInterval
    ) {
        let day = TaskExecutionSupport.day(for: occurrenceDate)
        pendingOccurrenceCompletionMutations[day] = PendingOccurrenceCompletionMutation(
            occurrenceDate: day,
            isReopening: isReopening,
            actionID: actionID,
            startedAt: startedAt
        )
        scheduleCompletionPersistenceFlush()
    }

    @MainActor
    private func persistPendingCompletionMutations(scheduleReconcile: Bool = true) async {
        guard !isCompletionPersistenceInFlight else { return }
        let subtaskMutations = pendingSubtaskCompletionMutations
        let occurrenceMutations = pendingOccurrenceCompletionMutations
        guard !subtaskMutations.isEmpty || !occurrenceMutations.isEmpty else { return }

        pendingSubtaskCompletionMutations = [:]
        pendingOccurrenceCompletionMutations = [:]
        isCompletionPersistenceInFlight = true

        let tid = taskID
        let container = modelContext.container
        let batchID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        Self.perfMark(
            "completion batch requested id=\(batchID) subtasks=\(subtaskMutations.count) occurrences=\(occurrenceMutations.count)"
        )

        let outcome = await Task.detached(priority: .utility) {
            return PersistentStoreAccessGate.withAccess {
            let backgroundStartedAt = CACurrentMediaTime()
            let ctx = ModelContext(container)
            guard let task = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first else {
                return CompletionPersistenceOutcome.failed("任务已不存在")
            }

            var executionRecords = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid }))) ?? []
            let subtasks = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
            var affectedExecutionIDs: Set<UUID> = []

            for (subtaskID, mutation) in subtaskMutations {
                guard let targetSubtask = subtasks.first(where: { $0.id == subtaskID }) else {
                    continue
                }

                let record: TaskExecutionRecord
                if let executionID = targetSubtask.taskExecutionID,
                   let existingRecord = executionRecords.first(where: { $0.id == executionID }) {
                    record = existingRecord
                } else {
                    record = TaskExecutionSupport.ensureExecutionRecord(
                        for: task,
                        occurrenceDate: mutation.occurrenceDate,
                        existingExecutions: executionRecords,
                        modelContext: ctx
                    )
                    if !executionRecords.contains(where: { $0.id == record.id }) {
                        executionRecords.append(record)
                    }
                    targetSubtask.taskExecutionID = record.id
                }

                targetSubtask.status = mutation.status
                targetSubtask.completedAt = mutation.completedAt
                targetSubtask.updatedAt = .now
                affectedExecutionIDs.insert(record.id)
            }

            for executionID in affectedExecutionIDs {
                guard let record = executionRecords.first(where: { $0.id == executionID }) else { continue }
                TaskExecutionSupport.syncExecutionStatus(
                    record: record,
                    task: task,
                    subtasks: subtasks,
                    modelContext: ctx
                )
            }

            if !occurrenceMutations.isEmpty {
                let sortedMutations = occurrenceMutations.values.sorted { $0.occurrenceDate < $1.occurrenceDate }
                for mutation in sortedMutations {
                    executionRecords = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid }))) ?? executionRecords
                    if mutation.isReopening {
                        TaskExecutionSupport.reopenTaskCompletion(
                            task: task,
                            occurrenceDate: mutation.occurrenceDate,
                            existingExecutions: executionRecords,
                            modelContext: ctx
                        )
                    } else {
                        TaskExecutionSupport.markTaskCompleted(
                            task: task,
                            occurrenceDate: mutation.occurrenceDate,
                            existingExecutions: executionRecords,
                            modelContext: ctx
                        )
                    }
                }
            }

            do {
                try ctx.save()
                Self.perfMark("completion batch bg saved id=\(batchID) elapsed=\(Self.perfMillis(since: backgroundStartedAt))")
                return CompletionPersistenceOutcome.saved
            } catch {
                return CompletionPersistenceOutcome.failed(error.localizedDescription)
            }
            }
        }.value

        Self.perfMark("completion batch main reconcile id=\(batchID) total=\(Self.perfMillis(since: startedAt))")
        isCompletionPersistenceInFlight = false

        switch outcome {
        case .saved:
            WidgetCenter.shared.reloadAllTimelinesInBackground()
            AppDataChangeCenter.post()
        case let .failed(message):
            persistenceErrorMessage = message
        }

        let hasQueuedMutations = !pendingSubtaskCompletionMutations.isEmpty || !pendingOccurrenceCompletionMutations.isEmpty
        if hasQueuedMutations {
            scheduleCompletionPersistenceFlush(after: 0.05)
        } else if scheduleReconcile {
            scheduleDeferredDetailRefresh(after: 0.2, reason: "completion batch reconcile")
        }
    }

    private func refreshDetailModelsAndSnapshot(reason: String) {
        occurrenceSnapshotRefreshTask?.cancel()
        guard canRenderLiveContent else { return }
        isRefreshInFlight = true
        
        let tid = taskID
        let container = modelContext.container
        let requestedSelectedDate = selectedOccurrenceDate
        let visibleGridEndDate = gridDates.last ?? TaskExecutionSupport.day(for: .now)
        let mutationVersionAtRequest = completionMutationVersion
        let refreshID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()

        Self.perfMark("refresh requested id=\(refreshID) reason=\(reason) selected=\(Self.perfDateLabel(requestedSelectedDate))")
        Self.perfWatchMainThread("refresh \(refreshID)", threshold: 0.45)
        
        occurrenceSnapshotRefreshTask = Task(priority: .userInitiated) {
            typealias RefreshResult = (
                TaskProjection?,
                [TaskOccurrenceSnapshot],
                [TaskSubitemProjection],
                [TaskExecutionRecordProjection],
                [TaskSubitemProjection],
                TaskExecutionRecordProjection?,
                Date?
            )
            
            let results: RefreshResult? = await Task.detached(priority: .userInitiated) {
                PersistentStoreAccessGate.withAccess {
                let backgroundStartedAt = CACurrentMediaTime()
                Self.perfMark("refresh bg begin id=\(refreshID)")
                let ctx = ModelContext(container)
                let t = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first
                guard let t else {
                    Self.perfMark("refresh bg missing task id=\(refreshID)")
                    return (nil, [], [], [], [], nil, nil)
                }
                let taskProjection = TaskProjection(t)
                let detailLookaheadDay = Calendar.current.date(
                    byAdding: .day,
                    value: 7,
                    to: TaskExecutionSupport.day(for: .now)
                ) ?? TaskExecutionSupport.day(for: .now)
                let refreshUpperBound = max(
                    detailLookaheadDay,
                    TaskExecutionSupport.day(for: visibleGridEndDate),
                    requestedSelectedDate.map(TaskExecutionSupport.day(for:)) ?? TaskExecutionSupport.day(for: .now)
                )
                
                let records = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid }))) ?? []
                let subtasks = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
                let scheduledToday = t.scheduledOccurrenceDates(upTo: TaskExecutionSupport.day(for: .now)).contains {
                    Calendar.current.isDate($0, inSameDayAs: .now)
                }
                
                var snapshots = TaskExecutionSupport.occurrenceSnapshots(
                    for: t,
                    executions: records,
                    subtasks: subtasks,
                    subtaskExecutions: [],
                    on: refreshUpperBound
                )
                let todayDay = TaskExecutionSupport.day(for: .now)
                let scheduledDates = taskProjection.scheduledOccurrenceDates(upTo: refreshUpperBound)
                let existingSnapshotDays = Set(
                    snapshots.map { TaskExecutionSupport.day(for: $0.occurrenceDate) }
                )
                let missingScheduledSnapshots = scheduledDates
                    .map(TaskExecutionSupport.day(for:))
                    .filter { $0 >= todayDay && !existingSnapshotDays.contains($0) }
                    .map { occurrenceDate in
                        TaskOccurrenceSnapshot(
                            taskID: taskProjection.id,
                            occurrenceDate: occurrenceDate,
                            isCompleted: false,
                            overdueOriginText: nil,
                            executionRecordID: nil,
                            executionDetail: "",
                            hasDetail: false,
                            totalSubtaskCount: 0,
                            completedSubtaskCount: 0
                        )
                    }
                if !missingScheduledSnapshots.isEmpty {
                    snapshots.append(contentsOf: missingScheduledSnapshots)
                    snapshots.sort { $0.occurrenceDate < $1.occurrenceDate }
                }
                let subProjections = TaskExecutionSupport.deduplicatedSubtasks(
                    subtasks.filter { !$0.isArchived }.map(TaskSubitemProjection.init)
                )
                let recProjections = records.map(TaskExecutionRecordProjection.init)
                
                let resolvedSelectedDate = Self.resolvedSelectedOccurrenceDate(in: snapshots, requestedDate: requestedSelectedDate)
                let resolvedSnapshot = resolvedSelectedDate.flatMap { targetDate in
                    snapshots.first { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: targetDate) }
                }
                let curRec: TaskExecutionRecordProjection?
                if let executionRecordID = resolvedSnapshot?.executionRecordID {
                    curRec = recProjections.first { $0.id == executionRecordID }
                } else if let resolvedSelectedDate {
                    let targetDay = TaskExecutionSupport.day(for: resolvedSelectedDate)
                    curRec = recProjections.first { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: targetDay) }
                } else {
                    curRec = nil
                }
                
                let curSubProjections: [TaskSubitemProjection]
                curSubProjections = TaskExecutionSupport.executionSubtasks(
                    for: curRec,
                    in: subProjections
                )

                let snapshotSummary = snapshots
                    .map { "\(Self.perfDateLabel($0.occurrenceDate)):\($0.isCompleted ? "done" : "pending")" }
                    .joined(separator: ",")
                let recordSummary = records
                    .map { "\(Self.perfDateLabel($0.occurrenceDate)):\($0.status.rawValue)" }
                    .joined(separator: ",")
                
                Self.perfMark(
                    "refresh bg end id=\(refreshID) elapsed=\(Self.perfMillis(since: backgroundStartedAt)) taskID=\(t.id.uuidString.prefix(6)) archived=\(t.isArchived) start=\(Self.perfDateLabel(t.startDate)) end=\(Self.perfDateLabel(t.endDate)) scheduledToday=\(scheduledToday) snapshots=\(snapshotSummary) records=\(recordSummary) subtasks=\(subtasks.count) currentSubtasks=\(curSubProjections.count)"
                )
                return (taskProjection, snapshots, subProjections, recProjections, curSubProjections, curRec, resolvedSelectedDate)
                }
            }.value
            
            guard !Task.isCancelled, let res = results else {
                await MainActor.run {
                    isRefreshInFlight = false
                }
                return
            }
            
            await MainActor.run {
                let applyStartedAt = CACurrentMediaTime()
                Self.perfMark("refresh main apply begin id=\(refreshID)")
                guard mutationVersionAtRequest == completionMutationVersion else {
                    Self.perfMark("refresh main apply skipped stale id=\(refreshID) requestedVersion=\(mutationVersionAtRequest) currentVersion=\(completionMutationVersion)")
                    isRefreshInFlight = false
                    needsRefreshAfterCurrent = false
                    requestDetailRefresh(reason: "stale completion refresh")
                    return
                }

                guard pendingSubtaskCompletionMutations.isEmpty,
                      pendingOccurrenceCompletionMutations.isEmpty,
                      !isCompletionPersistenceInFlight else {
                    Self.perfMark("refresh main apply deferred id=\(refreshID) pendingSubtasks=\(pendingSubtaskCompletionMutations.count) pendingOccurrences=\(pendingOccurrenceCompletionMutations.count) inFlight=\(isCompletionPersistenceInFlight)")
                    isRefreshInFlight = false
                    needsRefreshAfterCurrent = false
                    scheduleDeferredDetailRefresh(after: 0.2, reason: "pending completion refresh")
                    return
                }

                if let projection = res.0 {
                    taskUnavailableApplyReset(using: projection, result: res)
                } else {
                    isTaskUnavailable = true
                    occurrenceSnapshotState = .empty
                    allSubtasks = []
                    allExecutionRecords = []
                    currentOccurrenceSubtasks = []
                    currentExecutionRecord = nil
                    isDetailDataActive = true
                }
                Self.perfMark(
                    "refresh main apply end id=\(refreshID) apply=\(Self.perfMillis(since: applyStartedAt)) total=\(Self.perfMillis(since: startedAt)) pending=\(occurrenceSnapshotState.pending.count) completed=\(occurrenceSnapshotState.completed.count) upcoming=\(occurrenceSnapshotState.upcoming.count)"
                )
                isRefreshInFlight = false
                if needsRefreshAfterCurrent {
                    needsRefreshAfterCurrent = false
                    refreshDetailModelsAndSnapshot(reason: "coalesced")
                }
            }
        }
    }

    private func taskUnavailableApplyReset(
        using projection: TaskProjection,
        result: (
            TaskProjection?,
            [TaskOccurrenceSnapshot],
            [TaskSubitemProjection],
            [TaskExecutionRecordProjection],
            [TaskSubitemProjection],
            TaskExecutionRecordProjection?,
            Date?
        )
    ) {
        taskUnavailableApplyProjection(projection)
        let todayDay = TaskExecutionSupport.day(for: .now)
        occurrenceSnapshotState = OccurrenceSnapshotState(
            pending: result.1.filter { !$0.isCompleted && $0.occurrenceDate <= todayDay },
            completed: result.1.filter { $0.isCompleted }.sorted { $0.occurrenceDate > $1.occurrenceDate },
            upcoming: result.1.filter { !$0.isCompleted && $0.occurrenceDate > todayDay }
        )
        allSubtasks = result.2
        allExecutionRecords = result.3
        currentOccurrenceSubtasks = result.4
        currentExecutionRecord = result.5
        isDetailDataActive = true
        if let resolvedSelectedDate = result.6,
           selectedOccurrenceDate.map({ !Calendar.current.isDate($0, inSameDayAs: resolvedSelectedDate) }) ?? true {
            isSyncingSelectedOccurrenceDate = true
            selectedOccurrenceDate = resolvedSelectedDate
        }
    }

    private func taskUnavailableApplyProjection(_ projection: TaskProjection) {
        isTaskUnavailable = false
        taskProjection = projection
    }

    private func syncCalendarToSelectedDate() {
        guard let date = selectedOccurrenceDate else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let diff = calendar.dateComponents([.weekOfYear], from: today, to: date).weekOfYear ?? 0
        if diff < weekOffset || diff >= weekOffset + 2 { withAnimation { weekOffset = diff } }
    }

    private func refreshParentDetailDraft() { parentDetailDraft = selectedSnapshot?.executionDetail ?? "" }

    @discardableResult
    private func applyCachedSelection() -> Bool {
        guard let snapshot = selectedSnapshot else { return false }

        if let executionRecordID = snapshot.executionRecordID {
            currentExecutionRecord = allExecutionRecords.first { $0.id == executionRecordID }
        } else {
            currentExecutionRecord = allExecutionRecords.first {
                Calendar.current.isDate($0.occurrenceDate, inSameDayAs: snapshot.occurrenceDate)
            }
        }

        currentOccurrenceSubtasks = TaskExecutionSupport.executionSubtasks(
            for: currentExecutionRecord,
            in: allSubtasks
        )
        parentDetailDraft = snapshot.executionDetail
        return true
    }

    private func applyOptimisticSubtaskProjectionUpdate(
        subtaskID: UUID,
        status: TaskExecutionStatus
    ) {
        if let index = allSubtasks.firstIndex(where: { $0.id == subtaskID }) {
            var updated = allSubtasks[index]
            updated.status = status
            allSubtasks[index] = updated
        }
    }

    private func applyOptimisticOccurrenceSnapshotUpdate(for occurrenceDate: Date) {
        guard let existingSnapshot = timelineSnapshots.first(where: {
            Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
        }) else {
            return
        }

        let totalSubtaskCount = currentOccurrenceSubtasks.count
        let completedSubtaskCount = currentOccurrenceSubtasks.filter { $0.status == .completed }.count
        let updatedIsCompleted = totalSubtaskCount > 0
            ? completedSubtaskCount == totalSubtaskCount
            : existingSnapshot.isCompleted

        let updatedSnapshot = TaskOccurrenceSnapshot(
            taskID: existingSnapshot.taskID,
            occurrenceDate: existingSnapshot.occurrenceDate,
            isCompleted: updatedIsCompleted,
            overdueOriginText: updatedIsCompleted ? nil : existingSnapshot.overdueOriginText,
            executionRecordID: existingSnapshot.executionRecordID,
            executionDetail: existingSnapshot.executionDetail,
            hasDetail: existingSnapshot.hasDetail,
            totalSubtaskCount: totalSubtaskCount,
            completedSubtaskCount: completedSubtaskCount
        )

        var remainingPending = occurrenceSnapshotState.pending.filter {
            !Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
        }
        var remainingUpcoming = occurrenceSnapshotState.upcoming.filter {
            !Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
        }
        var remainingCompleted = occurrenceSnapshotState.completed.filter {
            !Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
        }

        let today = TaskExecutionSupport.day(for: .now)
        if updatedSnapshot.isCompleted {
            remainingCompleted.append(updatedSnapshot)
            remainingCompleted.sort { $0.occurrenceDate > $1.occurrenceDate }
        } else if updatedSnapshot.occurrenceDate < today {
            remainingPending.append(updatedSnapshot)
            remainingPending.sort { $0.occurrenceDate < $1.occurrenceDate }
        } else {
            remainingUpcoming.append(updatedSnapshot)
            remainingUpcoming.sort { $0.occurrenceDate < $1.occurrenceDate }
        }

        occurrenceSnapshotState = OccurrenceSnapshotState(
            pending: remainingPending,
            completed: remainingCompleted,
            upcoming: remainingUpcoming
        )
    }

    private func saveParentDetail() {
        guard !isSavingParentDetail, let date = currentOccurrenceDate else { return }
        isSavingParentDetail = true
        let tid = taskID
        let container = modelContext.container
        let noteDraft = parentDetailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        Self.perfMark("saveParentDetail requested id=\(actionID) date=\(Self.perfDateLabel(date)) noteLength=\(noteDraft.count)")
        
        Task.detached(priority: .utility) {
            let backgroundStartedAt = CACurrentMediaTime()
            let ctx = ModelContext(container)
            do {
                try PersistentStoreAccessGate.withAccess {
                guard let task = try ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })).first else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let records = try ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid }))
                let record = TaskExecutionSupport.ensureExecutionRecord(
                    for: task,
                    occurrenceDate: date,
                    existingExecutions: records,
                    modelContext: ctx
                )

                record.detail = noteDraft
                record.updatedAt = .now

                let subtasks = try ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))
                TaskExecutionSupport.syncExecutionStatus(record: record, task: task, subtasks: subtasks, modelContext: ctx)
                try ctx.save()
                Self.perfMark("saveParentDetail bg end id=\(actionID) elapsed=\(Self.perfMillis(since: backgroundStartedAt))")
                }
                await MainActor.run {
                    isSavingParentDetail = false
                    isEditingParentDetail = false
                    Self.perfMark("saveParentDetail main refresh id=\(actionID) total=\(Self.perfMillis(since: startedAt))")
                    WidgetCenter.shared.reloadAllTimelinesInBackground()
                    AppDataChangeCenter.post()
                    requestDetailRefresh(reason: "saveParentDetail")
                }
            } catch {
                await MainActor.run {
                    isSavingParentDetail = false
                    persistenceErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func toggleSubtaskCompletion(_ subtask: TaskSubitemProjection) {
        guard !isCurrentOccurrenceFuture, let date = currentOccurrenceDate else { return }
        
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        let targetSID = subtask.id
        let targetStatus: TaskExecutionStatus = (subtask.status == .completed) ? .pending : .completed
        let targetCompletedAt: Date? = (targetStatus == .completed) ? .now : nil
        Self.perfMark("subtask toggle tap id=\(actionID) subtask=\(subtask.title) to=\(targetStatus.rawValue) date=\(Self.perfDateLabel(date))")
        Self.perfWatchMainThread("subtask toggle \(actionID)", threshold: 0.35)
        completionMutationVersion += 1
        
        // 1. UI 立即响应投影数据变化（Optimistic UI）
        if let idx = currentOccurrenceSubtasks.firstIndex(where: { $0.id == targetSID }) {
           var updated = currentOccurrenceSubtasks[idx]
           updated.status = targetStatus
           currentOccurrenceSubtasks[idx] = updated
        }
        applyOptimisticSubtaskProjectionUpdate(subtaskID: targetSID, status: targetStatus)
        applyOptimisticOccurrenceSnapshotUpdate(for: date)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Self.perfMark("subtask toggle optimistic id=\(actionID) elapsed=\(Self.perfMillis(since: startedAt))")

        queueSubtaskCompletionPersistence(
            subtaskID: targetSID,
            occurrenceDate: date,
            status: targetStatus,
            completedAt: targetCompletedAt,
            actionID: actionID,
            startedAt: startedAt
        )
    }

    private func startQuickSubtaskCreation() {
        guard !isCreatingSubtask else { return }
        quickSubtaskOccurrenceDate = currentOccurrenceDate
        withAnimation(.easeInOut(duration: 0.2)) {
            isCreatingSubtask = true
        }
    }

    private func cancelQuickSubtaskCreation() {
        quickSubtaskOccurrenceDate = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            isCreatingSubtask = false
        }
    }

    private func saveQuickSubtask(title: String) {
        guard !isSavingQuickSubtask else { return }
        guard let date = quickSubtaskOccurrenceDate ?? currentOccurrenceDate else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        isSavingQuickSubtask = true
        let tid = taskID
        let container = modelContext.container
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        Self.perfMark("quickSubtask save requested id=\(actionID) date=\(Self.perfDateLabel(date)) titleLength=\(trimmedTitle.count)")
        
        Task.detached(priority: .userInitiated) {
            let backgroundStartedAt = CACurrentMediaTime()
            do {
                try PersistentStoreAccessGate.withAccess {
            let ctx = ModelContext(container)
            guard let task = try ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            let ed = FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid })
            let recs = (try? ctx.fetch(ed)) ?? []
            let record = TaskExecutionSupport.ensureExecutionRecord(for: task, occurrenceDate: date, existingExecutions: recs, modelContext: ctx)
            
            // 下发子任务
            let allS = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
            let occurrenceS = allS.filter { $0.taskExecutionID == record.id && !$0.isArchived }
            
            let newSub = TaskSubitem(
                parentTaskID: tid,
                taskExecutionID: record.id,
                title: trimmedTitle,
                note: "",
                detail: "",
                status: .pending,
                sortOrder: occurrenceS.count
            )
            ctx.insert(newSub)
            
            // 同步状态并存储
            let updatedAllS = allS + [newSub]
            TaskExecutionSupport.syncExecutionStatus(record: record, task: task, subtasks: updatedAllS, modelContext: ctx)
            
                try ctx.save()
                Self.perfMark("quickSubtask bg saved id=\(actionID) elapsed=\(Self.perfMillis(since: backgroundStartedAt))")
                }
                await MainActor.run {
                    isSavingQuickSubtask = false
                    selectedOccurrenceDate = date
                    cancelQuickSubtaskCreation()
                    Self.perfMark("quickSubtask main refresh id=\(actionID) total=\(Self.perfMillis(since: startedAt))")
                    WidgetCenter.shared.reloadAllTimelinesInBackground()
                    AppDataChangeCenter.post()
                    requestDetailRefresh(reason: "saveQuickSubtask")
                }
            } catch {
                await MainActor.run {
                    isSavingQuickSubtask = false
                    persistenceErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func openEditSubtaskEditor(subtaskID: UUID) {
        // 先找到对应的投影来初始化编辑器状态（草图相关可以暂时放在主线程）
        if let proj = allSubtasks.first(where: { $0.id == subtaskID }) {
            subtaskTitleDraft = proj.title
            subtaskNoteDraft = proj.note
            subtaskDetailDraft = proj.detail
            subtaskCompletedDraft = proj.status == .completed
            subtaskEditorTarget = SubtaskEditorTarget(subtaskID: subtaskID)
        }
    }

    private func saveSubtaskEditor(_ target: SubtaskEditorTarget) {
        guard !isSavingSubtaskEditor, let sid = target.subtaskID else { return }
        let trimmedTitle = subtaskTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        isSavingSubtaskEditor = true
        let tid = taskID
        let container = modelContext.container
        let (note, detail, isCompleted) = (subtaskNoteDraft, subtaskDetailDraft, subtaskCompletedDraft)
        
        Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            do {
                try PersistentStoreAccessGate.withAccess {
                let descriptor = FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.id == sid })
                guard let sub = try ctx.fetch(descriptor).first else {
                    throw CocoaError(.fileNoSuchFile)
                }
                sub.title = trimmedTitle
                sub.note = note
                sub.detail = detail
                sub.status = isCompleted ? .completed : .pending
                sub.completedAt = isCompleted ? .now : nil
                sub.updatedAt = .now
                
                // 给 execution 同步
                if let rid = sub.taskExecutionID {
                    let er = try ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.id == rid })).first
                    let t = try ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })).first
                    let allS = try ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))
                    if let er, let t {
                        TaskExecutionSupport.syncExecutionStatus(record: er, task: t, subtasks: allS, modelContext: ctx)
                    }
                }
                
                try ctx.save()
                }
                await MainActor.run {
                    isSavingSubtaskEditor = false
                    subtaskEditorTarget = nil
                    WidgetCenter.shared.reloadAllTimelinesInBackground()
                    AppDataChangeCenter.post()
                    requestDetailRefresh(reason: "saveSubtaskEditor")
                }
            } catch {
                await MainActor.run {
                    isSavingSubtaskEditor = false
                    persistenceErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func stageSubtaskDeletion(_ subtask: TaskSubitemProjection) {
        if pendingDeletedSubtask != nil {
            commitPendingDeletion()
        }

        pendingDeletionTask?.cancel()
        pendingDeletedSubtask = subtask
        withAnimation(.easeInOut(duration: 0.2)) {
            currentOccurrenceSubtasks.removeAll { $0.id == subtask.id }
            allSubtasks.removeAll { $0.id == subtask.id }
        }
        if let date = currentOccurrenceDate {
            applyOptimisticOccurrenceSnapshotUpdate(for: date)
        }

        pendingDeletionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, pendingDeletedSubtask?.id == subtask.id else { return }
            pendingDeletedSubtask = nil
            persistSubtaskDeletion(subtask)
        }
    }

    private func undoPendingDeletion() {
        pendingDeletionTask?.cancel()
        pendingDeletionTask = nil
        pendingDeletedSubtask = nil
        requestDetailRefresh(reason: "undo subtask deletion")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func commitPendingDeletion() {
        pendingDeletionTask?.cancel()
        pendingDeletionTask = nil
        guard let subtask = pendingDeletedSubtask else { return }
        pendingDeletedSubtask = nil
        persistSubtaskDeletion(subtask)
    }

    private func persistSubtaskDeletion(_ sub: TaskSubitemProjection) {
        let sid = sub.id
        let tid = taskID
        let container = modelContext.container
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        Self.perfMark("deleteSubtask requested id=\(actionID) subtask=\(sub.title)")
        
        Task.detached(priority: .utility) {
            let backgroundStartedAt = CACurrentMediaTime()
            let ctx = ModelContext(container)
            do {
                try PersistentStoreAccessGate.withAccess {
                let descriptor = FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.id == sid })
                guard let target = try ctx.fetch(descriptor).first else { return }
                // 如果有关联的执行记录，同步一下状态
                let rid = target.taskExecutionID
                SyncDeletionStore.delete(target, in: ctx)

                if let rid {
                    let remaining = try ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))
                        .filter { $0.taskExecutionID == rid && !$0.isArchived }
                        .sorted {
                            if $0.sortOrder == $1.sortOrder {
                                return $0.createdAt < $1.createdAt
                            }
                            return $0.sortOrder < $1.sortOrder
                        }
                    for (index, item) in remaining.enumerated() {
                        item.sortOrder = index
                        item.updatedAt = .now
                    }
                }
                
                if let rid {
                    let er = try ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.id == rid })).first
                    let t = try ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })).first
                    let allS = try ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))
                    if let er, let t {
                        TaskExecutionSupport.syncExecutionStatus(record: er, task: t, subtasks: allS, modelContext: ctx)
                    }
                }
                
                try ctx.save()
                Self.perfMark("deleteSubtask bg saved id=\(actionID) elapsed=\(Self.perfMillis(since: backgroundStartedAt))")
                }
                await MainActor.run {
                    Self.perfMark("deleteSubtask main refresh id=\(actionID) total=\(Self.perfMillis(since: startedAt))")
                    WidgetCenter.shared.reloadAllTimelinesInBackground()
                    AppDataChangeCenter.post()
                    requestDetailRefresh(reason: "deleteSubtask")
                }
            } catch {
                await MainActor.run {
                    persistenceErrorMessage = error.localizedDescription
                    requestDetailRefresh(reason: "deleteSubtask error")
                }
            }
        }
    }

    private func moveSubtaskUp(_ subtask: TaskSubitemProjection) {
        guard let index = currentOccurrenceSubtasks.firstIndex(where: { $0.id == subtask.id }), index > 0 else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            let moving = currentOccurrenceSubtasks.remove(at: index)
            currentOccurrenceSubtasks.insert(moving, at: index - 1)
        }

        queueSubtaskOrderPersistence()
    }

    private func moveSubtaskDown(_ subtask: TaskSubitemProjection) {
        guard let index = currentOccurrenceSubtasks.firstIndex(where: { $0.id == subtask.id }),
              index < currentOccurrenceSubtasks.count - 1 else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            let moving = currentOccurrenceSubtasks.remove(at: index)
            currentOccurrenceSubtasks.insert(moving, at: index + 1)
        }

        queueSubtaskOrderPersistence()
    }

    private func moveSubtasks(from source: IndexSet, to destination: Int) {
        withAnimation(.easeInOut(duration: 0.18)) {
            currentOccurrenceSubtasks.move(fromOffsets: source, toOffset: destination)
        }
        queueSubtaskOrderPersistence()
    }

    private func queueSubtaskOrderPersistence() {
        for index in currentOccurrenceSubtasks.indices {
            currentOccurrenceSubtasks[index].sortOrder = index
            let itemID = currentOccurrenceSubtasks[index].id
            if let allIndex = allSubtasks.firstIndex(where: { $0.id == itemID }) {
                var updated = allSubtasks[allIndex]
                updated.sortOrder = index
                allSubtasks[allIndex] = updated
            }
        }
        pendingSubtaskOrder = currentOccurrenceSubtasks.map(\.id)
        guard !isOrderPersistenceInFlight else { return }
        orderPersistenceTask?.cancel()
        orderPersistenceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await persistPendingSubtaskOrder()
        }
    }

    @MainActor
    private func flushPendingSubtaskOrderOnExit() {
        orderPersistenceTask?.cancel()
        orderPersistenceTask = nil
        guard pendingSubtaskOrder != nil else { return }
        Task { @MainActor in
            await persistPendingSubtaskOrder()
        }
    }

    @MainActor
    private func persistPendingSubtaskOrder() async {
        guard !isOrderPersistenceInFlight, let orderedIDs = pendingSubtaskOrder else { return }
        pendingSubtaskOrder = nil
        isOrderPersistenceInFlight = true
        let tid = taskID
        let container = modelContext.container
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        Self.perfMark("subtask order requested id=\(actionID) count=\(orderedIDs.count)")

        let errorMessage: String? = await Task.detached(priority: .utility) {
            return PersistentStoreAccessGate.withAccess {
            let backgroundStartedAt = CACurrentMediaTime()
            let ctx = ModelContext(container)
            let descriptor = FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid })

            do {
                let allSubtasks = try ctx.fetch(descriptor)
                let byID = Dictionary(uniqueKeysWithValues: allSubtasks.map { ($0.id, $0) })
                for (index, id) in orderedIDs.enumerated() {
                    guard let item = byID[id] else { continue }
                    item.sortOrder = index
                    item.updatedAt = .now
                }
                try ctx.save()
                Self.perfMark("subtask order bg saved id=\(actionID) elapsed=\(Self.perfMillis(since: backgroundStartedAt))")
                return nil
            } catch {
                return error.localizedDescription
            }
            }
        }.value

        isOrderPersistenceInFlight = false
        if let errorMessage {
            persistenceErrorMessage = errorMessage
            requestDetailRefresh(reason: "subtask order error")
        } else {
            Self.perfMark("subtask order main saved id=\(actionID) total=\(Self.perfMillis(since: startedAt))")
            WidgetCenter.shared.reloadAllTimelinesInBackground()
            AppDataChangeCenter.post()
        }

        if pendingSubtaskOrder != nil {
            await persistPendingSubtaskOrder()
        }
    }

    private func isFirstSubtask(_ subtask: TaskSubitemProjection) -> Bool {
        currentOccurrenceSubtasks.first?.id == subtask.id
    }

    private func isLastSubtask(_ subtask: TaskSubitemProjection) -> Bool {
        currentOccurrenceSubtasks.last?.id == subtask.id
    }

    private func leadingSymbol(for subtask: TaskSubitemProjection, isDone: Bool) -> String {
        if isCurrentOccurrenceFuture {
            return "clock"
        }
        return isDone ? "checkmark.circle.fill" : "circle"
    }

    private func leadingColor(for subtask: TaskSubitemProjection, isDone: Bool) -> Color {
        if isCurrentOccurrenceFuture {
            return .blue
        }
        return isDone ? .green : .secondary
    }

    private func noteBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.12), in: Capsule())
    }

    private func currentOccurrenceCardBackground(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if snapshot.isCompleted {
            return Color.green.opacity(0.10)
        }
        if isFutureOccurrence(snapshot) {
            return Color.blue.opacity(0.08)
        }
        return Color.orange.opacity(0.10)
    }

    private func currentOccurrenceCardBorder(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if snapshot.isCompleted {
            return Color.green.opacity(0.25)
        }
        if isFutureOccurrence(snapshot) {
            return Color.blue.opacity(0.25)
        }
        return Color.orange.opacity(0.28)
    }

    private func toggleOccurrenceCompletion(_ snapshot: TaskOccurrenceSnapshot) {
        guard !isFutureOccurrence(snapshot) else { return }
        
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        // 1. 主线程 UI 抢跑：直接修改本地内存快照状态以实现瞬时反馈
        let isReopening = snapshot.isCompleted
        let occurrenceDate = snapshot.occurrenceDate
        Self.perfMark("occurrence toggle tap id=\(actionID) date=\(Self.perfDateLabel(occurrenceDate)) reopening=\(isReopening)")
        Self.perfWatchMainThread("occurrence toggle \(actionID)", threshold: 0.35)
        completionMutationVersion += 1
        
        var nextPending = occurrenceSnapshotState.pending
        var nextCompleted = occurrenceSnapshotState.completed
        
        if isReopening {
            if let idx = nextCompleted.firstIndex(where: { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate) }) {
                var item = nextCompleted.remove(at: idx)
                item.isCompleted = false
                nextPending.append(item)
                nextPending.sort { $0.occurrenceDate < $1.occurrenceDate }
            }
        } else {
            if let idx = nextPending.firstIndex(where: { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate) }) {
                var item = nextPending.remove(at: idx)
                item.isCompleted = true
                nextCompleted.append(item)
                nextCompleted.sort { $0.occurrenceDate > $1.occurrenceDate }
            }
        }
        
        occurrenceSnapshotState = OccurrenceSnapshotState(
            pending: nextPending,
            completed: nextCompleted,
            upcoming: occurrenceSnapshotState.upcoming
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Self.perfMark("occurrence toggle optimistic id=\(actionID) elapsed=\(Self.perfMillis(since: startedAt))")

        queueOccurrenceCompletionPersistence(
            occurrenceDate: occurrenceDate,
            isReopening: isReopening,
            actionID: actionID,
            startedAt: startedAt
        )
    }

}
