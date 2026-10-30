import SwiftUI
import SwiftData
import WidgetKit
import UIKit

private struct TasksSnapshotDisplayItem: Identifiable {
    let task: TaskProjection
    let section: TodayTaskDisplaySection
    let occurrenceDate: Date
    let isCompleted: Bool
    let pendingOccurrenceCount: Int
    let overdueOriginText: String?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int

    init(task: TaskProjection, projection: TodayTaskProjectionResult) {
        self.task = task
        section = projection.section
        occurrenceDate = projection.occurrenceDate
        isCompleted = projection.isCompleted
        pendingOccurrenceCount = projection.pendingOccurrenceCount
        overdueOriginText = projection.overdueOriginText
        totalSubtaskCount = projection.totalSubtaskCount
        completedSubtaskCount = projection.completedSubtaskCount
    }

    init(
        task: TaskProjection,
        section: TodayTaskDisplaySection,
        occurrenceDate: Date,
        isCompleted: Bool,
        pendingOccurrenceCount: Int,
        overdueOriginText: String?,
        totalSubtaskCount: Int,
        completedSubtaskCount: Int
    ) {
        self.task = task
        self.section = section
        self.occurrenceDate = occurrenceDate
        self.isCompleted = isCompleted
        self.pendingOccurrenceCount = pendingOccurrenceCount
        self.overdueOriginText = overdueOriginText
        self.totalSubtaskCount = totalSubtaskCount
        self.completedSubtaskCount = completedSubtaskCount
    }

    var id: String {
        "\(task.id.uuidString)-\(occurrenceDate.timeIntervalSince1970)"
    }
}

private struct ScheduleItemProjection: Identifiable, Hashable {
    let id: UUID
    let title: String
    let note: String
    let startTime: Date
    let endTime: Date
    let repeatRule: ScheduleRepeatRule
    let weekdays: [Int]
    let effectiveStartDate: Date
    let effectiveEndDate: Date?
    let isArchived: Bool

    init(_ schedule: ScheduleItem) {
        id = schedule.id
        title = schedule.title
        note = schedule.note
        startTime = schedule.startTime
        endTime = schedule.endTime
        repeatRule = schedule.repeatRule
        weekdays = schedule.weekdays
        effectiveStartDate = schedule.effectiveStartDate
        effectiveEndDate = schedule.effectiveEndDate
        isArchived = schedule.isArchived
    }

    func shouldAppear(on date: Date) -> Bool {
        guard !isArchived else { return false }

        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)
        let startDay = calendar.startOfDay(for: startTime)
        let effectiveStartDay = calendar.startOfDay(for: effectiveStartDate)
        let effectiveEndDay = effectiveEndDate.map { calendar.startOfDay(for: $0) }

        switch repeatRule {
        case .once:
            return calendar.isDate(targetDay, inSameDayAs: startDay)
        case .daily:
            guard targetDay >= effectiveStartDay else { return false }
            if let effectiveEndDay, targetDay > effectiveEndDay { return false }
            return true
        case .weekly:
            guard targetDay >= effectiveStartDay else { return false }
            if let effectiveEndDay, targetDay > effectiveEndDay { return false }
            let weekday = calendar.component(.weekday, from: date)
            return weekdays.contains(weekday)
        }
    }

    func timeRangeText(on date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)

        let displayStart = calendar.date(
            bySettingHour: startComponents.hour ?? 0,
            minute: startComponents.minute ?? 0,
            second: 0,
            of: date
        ) ?? startTime
        let displayEnd = calendar.date(
            bySettingHour: endComponents.hour ?? 0,
            minute: endComponents.minute ?? 0,
            second: 0,
            of: date
        ) ?? endTime

        return "\(formatter.string(from: displayStart)) - \(formatter.string(from: displayEnd))"
    }

    var startTimeMinutes: Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    var repeatRuleLabel: String {
        switch repeatRule {
        case .once:
            return "单次"
        case .daily:
            return "每天"
        case .weekly:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let days = weekdays.sorted().compactMap { weekday -> String? in
                guard weekday >= 1, weekday <= 7 else { return nil }
                return "周\(names[weekday - 1])"
            }
            return "每周 \(days.joined(separator: "、"))"
        }
    }

    var effectiveDateRangeLabel: String? {
        guard repeatRule != .once, let effectiveEndDate else { return nil }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: effectiveStartDate)
        let endDay = calendar.startOfDay(for: effectiveEndDate)
        if calendar.isDate(startDay, equalTo: endDay, toGranularity: .year) {
            return "\(startDay.formatted(.dateTime.month().day())) - \(endDay.formatted(.dateTime.month().day()))"
        }
        return "\(startDay.formatted(.dateTime.year().month().day())) - \(endDay.formatted(.dateTime.year().month().day()))"
    }
}

private struct TasksPageSnapshot {
    var displayItems: [TasksSnapshotDisplayItem]
    var taskProjectionsByID: [UUID: TaskProjection]
    var scheduleProjectionsByID: [UUID: ScheduleItemProjection]
    var activeTaskIDs: [UUID]
    var archivedTaskIDs: [UUID]
    var todayScheduleIDs: [UUID]
    var otherScheduleIDs: [UUID]
    var archivedScheduleIDs: [UUID]

    var isEmpty: Bool {
        displayItems.isEmpty &&
        activeTaskIDs.isEmpty &&
        archivedTaskIDs.isEmpty &&
        todayScheduleIDs.isEmpty &&
        otherScheduleIDs.isEmpty &&
        archivedScheduleIDs.isEmpty
    }

    static let empty = TasksPageSnapshot(
        displayItems: [],
        taskProjectionsByID: [:],
        scheduleProjectionsByID: [:],
        activeTaskIDs: [],
        archivedTaskIDs: [],
        todayScheduleIDs: [],
        otherScheduleIDs: [],
        archivedScheduleIDs: []
    )
}

@MainActor
private enum TasksPageSnapshotMemoryCache {
    private static var snapshot: TasksPageSnapshot?
    private static var storedAt: Date?

    static func current(referenceDate: Date = .now) -> TasksPageSnapshot? {
        guard let snapshot, let storedAt else { return nil }
        guard Calendar.current.isDate(storedAt, inSameDayAs: referenceDate) else {
            self.snapshot = nil
            self.storedAt = nil
            return nil
        }
        return snapshot
    }

    static func store(_ snapshot: TasksPageSnapshot, at date: Date = .now) {
        self.snapshot = snapshot
        storedAt = date
    }
}

struct DeferredTasksHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReady = false
    @State private var activationTask: Task<Void, Never>?

    private var canActivate: Bool {
        scenePhase == .active
    }

    var body: some View {
        Group {
            if isReady {
                TasksView()
            } else {
                List {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在打开任务管理...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("任务管理")
                .navigationBarTitleDisplayMode(.large)
            }
        }
        .onAppear {
            #if DEBUG
            DebugPerf.mark("DeferredTasksHomeView onAppear")
            #endif
            activateAfterNavigationSettles()
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG
            DebugPerf.mark("DeferredTasksHomeView scenePhase=\(newPhase)")
            #endif
            if newPhase == .active {
                activateAfterNavigationSettles()
            } else {
                activationTask?.cancel()
                isReady = false
            }
        }
        .onDisappear {
            #if DEBUG
            DebugPerf.mark("DeferredTasksHomeView onDisappear")
            #endif
            activationTask?.cancel()
        }
    }

    private func activateAfterNavigationSettles() {
        #if DEBUG
        DebugPerf.mark("DeferredTasksHomeView activateAfterNavigationSettles requested")
        DebugPerf.watchMainThread("DeferredTasksHomeView activation")
        #endif
        activationTask?.cancel()
        guard !isReady else { return }
        guard canActivate else { return }

        activationTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            guard canActivate else { return }
            #if DEBUG
            DebugPerf.mark("DeferredTasksHomeView showing TasksView")
            #endif
            isReady = true
        }
    }
}

struct TasksView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<TaskItem> { !$0.isArchived }, sort: \TaskItem.createdAt, order: .reverse) private var activeTasks: [TaskItem]
    @Query(filter: #Predicate<TaskItem> { $0.isArchived }, sort: \TaskItem.createdAt, order: .reverse) private var archivedTasks: [TaskItem]
    @Query(filter: #Predicate<ScheduleItem> { !$0.isArchived }, sort: \ScheduleItem.startTime) private var activeSchedules: [ScheduleItem]
    @Query(filter: #Predicate<ScheduleItem> { $0.isArchived }, sort: \ScheduleItem.startTime) private var archivedSchedules: [ScheduleItem]
    
    // Performance Optimization: Cache computed results in a local snapshot
    @State private var pageSnapshot: TasksPageSnapshot = .empty
    @State private var snapshotRefreshTask: Task<Void, Never>?
    @State private var deferredSaveTask: Task<Void, Never>?
    @State private var isSnapshotLoaded = false
    @State private var isViewVisible = false
    @State private var isSnapshotRefreshInFlight = false
    @State private var needsSnapshotRefreshAfterCurrent = false
    @State private var activeAddRoute: AddRoute?

    init() {
        let cachedSnapshot = TasksPageSnapshotMemoryCache.current()
        _pageSnapshot = State(initialValue: cachedSnapshot ?? .empty)
        _isSnapshotLoaded = State(initialValue: cachedSnapshot != nil)
    }

    private struct TaskDetailRoute: Hashable {
        let taskID: UUID
        let title: String
    }

    private enum AddRoute: String, Identifiable {
        case task
        case schedule

        var id: String { rawValue }
    }

    private var canRenderLiveContent: Bool {
        scenePhase == .active && isViewVisible
    }

    private var taskModelsByID: [UUID: TaskItem] {
        Dictionary(
            (activeTasks + archivedTasks).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var scheduleModelsByID: [UUID: ScheduleItem] {
        Dictionary(
            (activeSchedules + archivedSchedules).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var todayPending: [TasksSnapshotDisplayItem] {
        pageSnapshot.displayItems
            .filter { $0.section == .todayPending }
    }
    
    private var historicalPending: [TasksSnapshotDisplayItem] {
        pageSnapshot.displayItems
            .filter { $0.section == .historicalPending }
            .sorted { lhs, rhs in
                if lhs.occurrenceDate == rhs.occurrenceDate {
                    return lhs.task.createdAt < rhs.task.createdAt
                }
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
    }

    private var upcomingPending: [TasksSnapshotDisplayItem] {
        pageSnapshot.displayItems
            .filter { $0.section == .upcomingPending }
            .sorted { lhs, rhs in
                if lhs.occurrenceDate == rhs.occurrenceDate {
                    return lhs.task.createdAt < rhs.task.createdAt
                }
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
    }
    
    private var todayDone: [TasksSnapshotDisplayItem] {
        pageSnapshot.displayItems
            .filter { $0.section == .todayDone }
    }

    private var allTasks: [TaskProjection] {
        pageSnapshot.activeTaskIDs.compactMap { pageSnapshot.taskProjectionsByID[$0] }
    }

    private var regularTasks: [TaskProjection] {
        allTasks.filter { $0.timingMode == .scheduled }
    }

    private var activeRecentPlans: [TaskProjection] {
        allTasks
            .filter {
                guard $0.timingMode == .flexibleDeadline, let deadline = $0.deadline else {
                    return false
                }
                return RecentPlanSupport.isInHomeVisibilityWindow(deadline: deadline)
            }
            .sorted(by: sortRecentPlans)
    }

    private var laterRecentPlans: [TaskProjection] {
        allTasks
            .filter {
                guard $0.timingMode == .flexibleDeadline, let deadline = $0.deadline else {
                    return false
                }
                return !RecentPlanSupport.isInHomeVisibilityWindow(deadline: deadline)
            }
            .sorted(by: sortRecentPlans)
    }

    private var todaySchedules: [ScheduleItemProjection] {
        pageSnapshot.todayScheduleIDs.compactMap { pageSnapshot.scheduleProjectionsByID[$0] }
    }

    private var otherSchedules: [ScheduleItemProjection] {
        pageSnapshot.otherScheduleIDs.compactMap { pageSnapshot.scheduleProjectionsByID[$0] }
    }

    private var archivedTaskProjections: [TaskProjection] {
        pageSnapshot.archivedTaskIDs.compactMap { pageSnapshot.taskProjectionsByID[$0] }
    }

    private var archivedScheduleProjections: [ScheduleItemProjection] {
        pageSnapshot.archivedScheduleIDs.compactMap { pageSnapshot.scheduleProjectionsByID[$0] }
    }

    var body: some View {
        taskList
            .navigationTitle("任务管理")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    addMenu
                }
            }
            .onAppear {
                isViewVisible = true
                #if DEBUG
                DebugPerf.mark("TasksView onAppear")
                #endif
                requestSnapshotRefresh(reason: "onAppear")
            }
            .onChange(of: scenePhase) { _, newPhase in
                #if DEBUG
                DebugPerf.mark("TasksView scenePhase=\(newPhase)")
                #endif
                if newPhase == .active {
                    requestSnapshotRefresh(reason: "scenePhase active", delay: pageSnapshot.displayItems.isEmpty ? 0.08 : 0.02)
                } else {
                    snapshotRefreshTask?.cancel()
                }
            }
            .onChange(of: activeTasks) { _, _ in
                requestSnapshotRefresh(reason: "activeTasks")
            }
            .onChange(of: archivedTasks) { _, _ in
                requestSnapshotRefresh(reason: "archivedTasks")
            }
            .onChange(of: activeSchedules) { _, _ in
                requestSnapshotRefresh(reason: "activeSchedules")
            }
            .onChange(of: archivedSchedules) { _, _ in
                requestSnapshotRefresh(reason: "archivedSchedules")
            }
            .onReceive(NotificationCenter.default.publisher(for: .appDataDidChange)) { _ in
                #if DEBUG
                DebugPerf.mark("TasksView received appDataDidMutate")
                #endif
                requestSnapshotRefresh(reason: "appDataDidMutate")
            }
            .navigationDestination(for: TaskDetailRoute.self) { route in
                DeferredTaskDetailView(route: route)
            }
            .navigationDestination(item: $activeAddRoute) { route in
                switch route {
                case .task:
                    AddTaskView()
                case .schedule:
                    AddScheduleView()
                }
            }
            .onDisappear {
                isViewVisible = false
                #if DEBUG
                DebugPerf.mark("TasksView onDisappear")
                #endif
                snapshotRefreshTask?.cancel()
            }
    }

    private var taskList: some View {
        List {
            taskListContent
        }
    }

    @ViewBuilder
    private var taskListContent: some View {
        if !isSnapshotLoaded {
            statusSection(
                title: canRenderLiveContent ? "正在加载任务安排..." : "正在恢复任务内容...",
                debugLabel: canRenderLiveContent ? "loading" : "recovery"
            )
        } else {
            if !canRenderLiveContent {
                statusSection(title: "正在恢复任务内容...", debugLabel: "recovery")
            }

            if pageSnapshot.isEmpty {
                emptyStateSection
            } else {
                activeSections
                archivedSections
            }
        }
    }

    private func statusSection(title: String, debugLabel: String) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .onAppear {
                #if DEBUG
                DebugPerf.mark("TasksView status section appear \(debugLabel)")
                #endif
            }
        }
    }

    private var emptyStateSection: some View {
        Section {
            ContentUnavailableView {
                Label("还没有任务和日程", systemImage: "checklist")
            } description: {
                Text("点右上角添加每日任务、作业提醒和日程安排。")
            }
        }
    }

    @ViewBuilder
    private var activeSections: some View {
        if !todaySchedules.isEmpty {
            scheduleSection("今日日程", schedules: todaySchedules)
        }

        if !todayPending.isEmpty {
            todayTaskSection("今日待完成", items: todayPending)
        }

        if !historicalPending.isEmpty {
            todayTaskSection("历史待完成", items: historicalPending)
        }

        if !upcomingPending.isEmpty {
            todayTaskSection("未来一周", items: upcomingPending)
        }

        if !activeRecentPlans.isEmpty {
            recentPlanSection("近期计划", plans: activeRecentPlans)
        }

        if !laterRecentPlans.isEmpty {
            recentPlanSection("稍后计划", plans: laterRecentPlans)
        }

        if !todayDone.isEmpty {
            todayTaskSection("今日已完成", items: todayDone)
        }

        if !regularTasks.isEmpty {
            otherTaskSection("任务管理", tasks: regularTasks)
        }

        if !otherSchedules.isEmpty {
            scheduleSection("日程管理", schedules: otherSchedules)
        }
    }

    @ViewBuilder
    private var archivedSections: some View {
        if !archivedTaskProjections.isEmpty {
            archivedTaskSection
        }

        if !archivedScheduleProjections.isEmpty {
            archivedScheduleSection
        }
    }

    private var archivedTaskSection: some View {
        Section("已归档") {
            ForEach(archivedTaskProjections, id: \.id) { task in
                archivedTaskRow(task)
            }
        }
    }

    private var archivedScheduleSection: some View {
        Section("已归档日程") {
            ForEach(archivedScheduleProjections, id: \.id) { schedule in
                archivedScheduleRow(schedule)
            }
        }
    }

    @ViewBuilder
    private var addMenu: some View {
        if #available(iOS 18.0, *) {
            Menu {
                NavigationLink {
                    AddTaskView()
                } label: {
                    Label("新增任务", systemImage: "checklist")
                }

                NavigationLink {
                    AddScheduleView()
                } label: {
                    Label("新增日程", systemImage: "calendar.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
            }
        } else {
            HStack(spacing: 14) {
                Button {
                    activeAddRoute = .task
                } label: {
                    Image(systemName: "checklist")
                }
                .buttonStyle(.plain)

                Button {
                    activeAddRoute = .schedule
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func archivedTaskRow(_ task: TaskProjection) -> some View {
        HStack {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Text(archivedTaskMetadata(task))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .iOS17SafeSwipeActions {
            if let liveTask = taskModelsByID[task.id] {
                Button(
                    task.timingMode == .flexibleDeadline ? "重新打开" : "恢复",
                    systemImage: "arrow.uturn.backward"
                ) {
                    restoreArchivedTask(liveTask)
                    pageSnapshot = TasksPageSnapshot(
                        displayItems: pageSnapshot.displayItems,
                        taskProjectionsByID: pageSnapshot.taskProjectionsByID,
                        scheduleProjectionsByID: pageSnapshot.scheduleProjectionsByID,
                        activeTaskIDs: [task.id] + pageSnapshot.activeTaskIDs.filter { $0 != task.id },
                        archivedTaskIDs: pageSnapshot.archivedTaskIDs.filter { $0 != task.id },
                        todayScheduleIDs: pageSnapshot.todayScheduleIDs,
                        otherScheduleIDs: pageSnapshot.otherScheduleIDs,
                        archivedScheduleIDs: pageSnapshot.archivedScheduleIDs
                    )
                    saveAndReloadWidgetsDeferred()
                }
                .tint(.blue)

                Button("彻底删除", systemImage: "trash", role: .destructive) {
                    deleteTask(liveTask)
                }
            }
        }
    }

    private func archivedTaskMetadata(_ task: TaskProjection) -> String {
        guard task.timingMode == .flexibleDeadline else {
            return task.recurrenceLabel
        }
        if let deadline = task.deadline {
            return "近期计划 · 截止 \(deadline.formatted(.dateTime.year().month().day()))"
        }
        return "近期计划"
    }

    private func restoreArchivedTask(_ task: TaskItem) {
        if task.timingMode == .flexibleDeadline {
            let taskID = task.id
            let executions = (try? modelContext.fetch(
                FetchDescriptor<TaskExecutionRecord>(
                    predicate: #Predicate<TaskExecutionRecord> { $0.taskID == taskID }
                )
            )) ?? []
            if executions.contains(where: { $0.status == .completed }) {
                TaskExecutionSupport.reopenTaskCompletion(
                    task: task,
                    occurrenceDate: task.startDate,
                    existingExecutions: executions,
                    modelContext: modelContext
                )
            } else {
                task.isArchived = false
            }
        } else {
            task.isArchived = false
        }
        task.updatedAt = .now
        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelinesInBackground()
        AppDataChangeCenter.post()
    }

    private func scheduleSection(_ title: LocalizedStringKey, schedules: [ScheduleItemProjection]) -> some View {
        Section(title) {
            ForEach(schedules, id: \.id) { schedule in
                scheduleRow(schedule)
            }
        }
    }

    private func todayTaskSection(_ title: LocalizedStringKey, items: [TasksSnapshotDisplayItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                todayTaskRow(item)
            }
        }
    }

    private func otherTaskSection(_ title: LocalizedStringKey, tasks: [TaskProjection]) -> some View {
        Section(title) {
            ForEach(tasks, id: \.id) { task in
                taskRow(
                    task,
                    liveTask: taskModelsByID[task.id],
                    isDone: false,
                    showActions: false,
                    allowsArchive: true
                )
            }
        }
    }

    private func recentPlanSection(_ title: LocalizedStringKey, plans: [TaskProjection]) -> some View {
        Section(title) {
            ForEach(plans, id: \.id) { plan in
                taskRow(
                    plan,
                    liveTask: taskModelsByID[plan.id],
                    isDone: false,
                    showActions: false,
                    allowsArchive: true
                )
            }
        }
    }

    private func sortRecentPlans(_ lhs: TaskProjection, _ rhs: TaskProjection) -> Bool {
        guard let lhsDeadline = lhs.deadline else { return false }
        guard let rhsDeadline = rhs.deadline else { return true }
        let lhsState = RecentPlanSupport.deadlineState(deadline: lhsDeadline)
        let rhsState = RecentPlanSupport.deadlineState(deadline: rhsDeadline)
        if lhsState.urgencyRank != rhsState.urgencyRank {
            return lhsState.urgencyRank < rhsState.urgencyRank
        }
        if lhsDeadline != rhsDeadline {
            return lhsDeadline < rhsDeadline
        }
        return lhs.createdAt < rhs.createdAt
    }
    
    private func requestSnapshotRefresh(reason: String, delay: TimeInterval = 0.08) {
        #if DEBUG
        DebugPerf.mark("TasksView requestSnapshotRefresh reason=\(reason) delay=\(delay)")
        #endif
        guard canRenderLiveContent else { return }
        if isSnapshotRefreshInFlight {
            needsSnapshotRefreshAfterCurrent = true
            #if DEBUG
            DebugPerf.mark("TasksView refresh queued reason=\(reason)")
            #endif
            return
        }
        scheduleSnapshotRefresh(delay: delay)
    }

    private func scheduleSnapshotRefresh(delay: TimeInterval = 0.08) {
        #if DEBUG
        DebugPerf.mark("TasksView scheduleSnapshotRefresh delay=\(delay)")
        #endif
        snapshotRefreshTask?.cancel()
        guard canRenderLiveContent else { return }
        
        let container = modelContext.container

        snapshotRefreshTask = Task(priority: .utility) {
            let referenceDate = Date()
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard canRenderLiveContent else { return }
            await MainActor.run {
                isSnapshotRefreshInFlight = true
            }
            
            let refreshedSnapshot = await Task.detached(priority: .utility) {
                PersistentStoreAccessGate.withAccess {
                #if DEBUG
                DebugPerf.mark("TasksView background snapshot begin")
                #endif
                let backgroundContext = ModelContext(container)
                let calendar = Calendar.current
                
                // 完全在后台线程里进行取数据和投影，绝对不阻塞主线程
                let tasksDesc = FetchDescriptor<TaskItem>()
                let executesDesc = FetchDescriptor<TaskExecutionRecord>()
                let subtasksDesc = FetchDescriptor<TaskSubitem>(predicate: #Predicate<TaskSubitem> { !$0.isArchived })
                let schedulesDesc = FetchDescriptor<ScheduleItem>()
                
                let allTasks = (try? backgroundContext.fetch(tasksDesc)) ?? []
                let safeExecutions = (try? backgroundContext.fetch(executesDesc)) ?? []
                let safeSubtasks = (try? backgroundContext.fetch(subtasksDesc)) ?? []
                let allSchedules = (try? backgroundContext.fetch(schedulesDesc)) ?? []
                let deduplicatedTasks = TaskDedupSupport.deduplicatedTasks(allTasks)

                let autoArchivedCompletedAtByTaskID = Dictionary(
                    safeExecutions.compactMap { record -> (UUID, Date)? in
                        guard record.status == .completed,
                              let completedAt = record.completedAt,
                              calendar.isDate(completedAt, inSameDayAs: referenceDate) else {
                            return nil
                        }
                        return (record.taskID, completedAt)
                    },
                    uniquingKeysWith: max
                )
                let visibleTasks = allTasks.filter { task in
                    guard task.isArchived else { return true }
                    guard task.recurrence.kind == .once,
                          let completedAt = autoArchivedCompletedAtByTaskID[task.id] else {
                        return false
                    }
                    return task.updatedAt <= completedAt
                }
                let deduplicatedVisibleTasks = TaskDedupSupport.deduplicatedTasks(visibleTasks)

                let taskProjections = deduplicatedVisibleTasks.map(TaskProjection.init)
                let executionProjections = safeExecutions.map(TaskExecutionRecordProjection.init)
                let subtaskProjections = safeSubtasks.map(TaskSubitemProjection.init)
                let taskProjectionsByID = Dictionary(
                    deduplicatedTasks.map { ($0.id, TaskProjection($0)) },
                    uniquingKeysWith: { first, _ in first }
                )
                let scheduleProjectionsByID = Dictionary(
                    allSchedules.map { ($0.id, ScheduleItemProjection($0)) },
                    uniquingKeysWith: { first, _ in first }
                )

                let displayItems = TaskDedupSupport.deduplicatedDisplayItems(
                    TodayTaskProjectionBuilder.build(
                    from: taskProjections,
                    executions: executionProjections,
                    subtasks: subtaskProjections,
                    on: referenceDate
                )
                .compactMap { projection in
                    taskProjectionsByID[projection.taskID].map { task in
                        TasksSnapshotDisplayItem(task: task, projection: projection)
                    }
                },
                    title: { $0.task.title },
                    taskID: { $0.task.id },
                    section: { $0.section },
                    occurrenceDate: { $0.occurrenceDate },
                    sortKey: { item in
                        TaskDisplayDedupSortKey(
                            unskippablePriority: item.task.skipPolicy == .unskippable ? 1 : 0,
                            totalSubtaskCount: item.totalSubtaskCount,
                            completedSubtaskCount: item.completedSubtaskCount,
                            createdAt: item.task.createdAt,
                            stableID: item.task.id.uuidString
                        )
                    }
                )

                let activeTaskIDs = deduplicatedTasks
                    .filter { !$0.isArchived }
                    .sorted { $0.createdAt > $1.createdAt }
                    .map(\.id)
                let archivedTaskIDs = deduplicatedTasks
                    .filter(\.isArchived)
                    .sorted { $0.createdAt > $1.createdAt }
                    .map(\.id)

                let activeScheduleProjections = scheduleProjectionsByID.values
                    .filter { !$0.isArchived }
                let todayScheduleIDs = activeScheduleProjections
                    .filter { $0.shouldAppear(on: referenceDate) }
                    .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
                    .map(\.id)
                let todayScheduleIDSet = Set(todayScheduleIDs)
                let otherScheduleIDs = activeScheduleProjections
                    .filter { !todayScheduleIDSet.contains($0.id) }
                    .sorted { lhs, rhs in
                        if lhs.repeatRule == .once, rhs.repeatRule == .once {
                            return lhs.startTime < rhs.startTime
                        }
                        if lhs.repeatRule == .once { return true }
                        if rhs.repeatRule == .once { return false }
                        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
                    }
                    .map(\.id)
                let archivedScheduleIDs = scheduleProjectionsByID.values
                    .filter(\.isArchived)
                    .sorted { $0.startTime < $1.startTime }
                    .map(\.id)
                #if DEBUG
                let todayPendingSummaries = displayItems
                    .filter { $0.section == .todayPending }
                    .map { item in
                        "\(item.task.title)#\(item.task.id.uuidString.prefix(6))@\(item.occurrenceDate.formatted(.dateTime.month().day()))"
                    }
                    .joined(separator: ",")
                let todayDoneSummaries = displayItems
                    .filter { $0.section == .todayDone }
                    .map { item in
                        "\(item.task.title)#\(item.task.id.uuidString.prefix(6))@\(item.occurrenceDate.formatted(.dateTime.month().day()))"
                    }
                    .joined(separator: ",")
                DebugPerf.mark("TasksView background snapshot end tasks=\(visibleTasks.count) records=\(safeExecutions.count) subtasks=\(safeSubtasks.count) schedules=\(allSchedules.count) todayPending=\(todayPendingSummaries) todayDone=\(todayDoneSummaries)")
                #endif
                return TasksPageSnapshot(
                    displayItems: displayItems,
                    taskProjectionsByID: taskProjectionsByID,
                    scheduleProjectionsByID: scheduleProjectionsByID,
                    activeTaskIDs: activeTaskIDs,
                    archivedTaskIDs: archivedTaskIDs,
                    todayScheduleIDs: todayScheduleIDs,
                    otherScheduleIDs: otherScheduleIDs,
                    archivedScheduleIDs: archivedScheduleIDs
                )
                }
            }.value

            guard !Task.isCancelled else {
                isSnapshotRefreshInFlight = false
                return
            }
            guard canRenderLiveContent else {
                isSnapshotRefreshInFlight = false
                return
            }
            pageSnapshot = refreshedSnapshot
            isSnapshotLoaded = true
            TasksPageSnapshotMemoryCache.store(refreshedSnapshot, at: referenceDate)
            #if DEBUG
            DebugPerf.mark("TasksView snapshot applied items=\(refreshedSnapshot.displayItems.count) empty=\(refreshedSnapshot.isEmpty)")
            #endif
            isSnapshotRefreshInFlight = false
            if needsSnapshotRefreshAfterCurrent {
                needsSnapshotRefreshAfterCurrent = false
                requestSnapshotRefresh(reason: "coalesced", delay: 0.02)
            }
        }
    }

    private func todayTaskRow(_ item: TasksSnapshotDisplayItem, showActions: Bool = true) -> some View {
        taskRow(
            item.task,
            liveTask: taskModelsByID[item.task.id],
            isDone: item.isCompleted,
            showActions: showActions,
            occurrenceDate: item.occurrenceDate,
            occurrenceLabel: item.overdueOriginText,
            totalSubtaskCount: item.totalSubtaskCount,
            completedSubtaskCount: item.completedSubtaskCount
        )
    }

    private func taskRow(
        _ task: TaskProjection,
        liveTask: TaskItem?,
        isDone: Bool,
        showActions: Bool = true,
        allowsArchive: Bool = false,
        occurrenceDate: Date? = nil,
        occurrenceLabel: String? = nil,
        totalSubtaskCount: Int? = nil,
        completedSubtaskCount: Int? = nil
    ) -> some View {
        let hasSubtasks = (totalSubtaskCount ?? 0) > 0

        return HStack(spacing: 10) {
            if showActions {
                if hasSubtasks {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "list.bullet.circle")
                        .font(.title3)
                        .foregroundStyle(isDone ? .green : .secondary)
                } else if let liveTask {
                    Button {
                        toggleCompletion(for: liveTask, occurrenceDate: occurrenceDate ?? .now, isDone: isDone)
                    } label: {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isDone ? .green : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isDone ? .green : .secondary)
                }
            }

            NavigationLink(value: TaskDetailRoute(taskID: task.id, title: task.title)) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .fontWeight(.medium)
                            .strikethrough(isDone)
                            .foregroundStyle(isDone ? .secondary : .primary)

                        HStack(spacing: 3) {
                            Text(task.timingMode == .flexibleDeadline ? "近期计划" : task.recurrenceShortLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if task.timingMode == .flexibleDeadline, let deadline = task.deadline {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                Text("截止 \(deadline.formatted(.dateTime.month().day()))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                Text(RecentPlanSupport.deadlineState(deadline: deadline).statusText)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(recentPlanStatusColor(deadline: deadline))
                            } else if let _ = task.effectiveDateRangeLabel {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                
                                Text(task.effectiveDateRangeLabel!)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if task.timingMode == .scheduled && task.skipPolicy == .unskippable {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }

                            if task.isPaused {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                Label(pauseStatusText(for: task), systemImage: "pause.circle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }

                            if let occurrenceDateText = occurrenceDateMetadataText(
                                occurrenceDate: occurrenceDate,
                                occurrenceLabel: occurrenceLabel,
                                isDone: isDone
                            ) {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    
                                Text(occurrenceDateText)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }

                            if let totalSubtaskCount, totalSubtaskCount > 0,
                               let completedSubtaskCount {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    
                                Text("\(completedSubtaskCount)/\(totalSubtaskCount)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isDone ? .green : .blue)
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                        if !task.note.isEmpty {
                            Text(task.note)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .iOS17SafeSwipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let liveTask {
                if task.timingMode == .scheduled, showActions, !isDone, let occurrenceDate {
                    Button("跳过", systemImage: "forward.end") {
                        skipTask(liveTask, occurrenceDate: occurrenceDate)
                    }
                    .tint(.orange)
                }

                if allowsArchive {
                    if task.recurrence.kind != .once {
                        Button(
                            task.isPaused ? "启用" : "暂停",
                            systemImage: task.isPaused ? "play.fill" : "pause.fill"
                        ) {
                            togglePause(for: liveTask)
                        }
                        .tint(task.isPaused ? .blue : .orange)
                    }

                    Button("归档", systemImage: "archivebox", role: .destructive) {
                        archiveTask(liveTask)
                    }
                }
            }
        }
    }

    private func recentPlanStatusColor(deadline: Date) -> Color {
        switch RecentPlanSupport.deadlineState(deadline: deadline).kind {
        case .overdue:
            return .red
        case .dueToday:
            return .orange
        case .upcoming:
            return RecentPlanSupport.deadlineState(deadline: deadline).dayCount <= 7 ? .orange : .blue
        }
    }

    private func pauseStatusText(for task: TaskProjection) -> String {
        guard let pauseStartedAt = task.pauseStartedAt else { return "" }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return calendar.startOfDay(for: pauseStartedAt) > today ? "明日起暂停" : "已暂停"
    }

    private func togglePause(for task: TaskItem) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        if task.isPaused {
            task.resume(on: today)
        } else {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            task.pause(starting: tomorrow)
        }

        let updatedProjection = TaskProjection(task)
        withAnimation {
            pageSnapshot.taskProjectionsByID[task.id] = updatedProjection
            pageSnapshot.displayItems.removeAll { item in
                item.task.id == task.id && updatedProjection.isOccurrencePaused(item.occurrenceDate)
            }
        }

        do {
            try modelContext.save()
        } catch {
            print("Failed to toggle task pause: \(error)")
        }
        WidgetCenter.shared.reloadAllTimelinesInBackground()
        AppDataChangeCenter.post()
        requestSnapshotRefresh(reason: task.isPaused ? "task paused" : "task resumed", delay: 0.02)
    }

    private func occurrenceDateMetadataText(
        occurrenceDate: Date?,
        occurrenceLabel: String?,
        isDone: Bool
    ) -> String? {
        guard !isDone, let occurrenceDate else { return nil }
        if let occurrenceLabel, !occurrenceLabel.isEmpty {
            return occurrenceLabel
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        if calendar.isDate(occurrenceDate, inSameDayAs: today) {
            return "待办 \(occurrenceDate.formatted(.dateTime.month().day()))"
        }
        if calendar.isDate(occurrenceDate, equalTo: today, toGranularity: .year) {
            return occurrenceDate.formatted(.dateTime.month().day())
        }
        return occurrenceDate.formatted(.dateTime.year().month().day())
    }

    private func archiveTask(_ task: TaskItem) {
        withAnimation {
            task.isArchived = true
            task.updatedAt = .now
            pageSnapshot = TasksPageSnapshot(
                displayItems: pageSnapshot.displayItems.filter { $0.task.id != task.id },
                taskProjectionsByID: pageSnapshot.taskProjectionsByID,
                scheduleProjectionsByID: pageSnapshot.scheduleProjectionsByID,
                activeTaskIDs: pageSnapshot.activeTaskIDs.filter { $0 != task.id },
                archivedTaskIDs: [task.id] + pageSnapshot.archivedTaskIDs.filter { $0 != task.id },
                todayScheduleIDs: pageSnapshot.todayScheduleIDs,
                otherScheduleIDs: pageSnapshot.otherScheduleIDs,
                archivedScheduleIDs: pageSnapshot.archivedScheduleIDs
            )
        }

        try? modelContext.save()
        saveAndReloadWidgetsDeferred()
        AppDataChangeCenter.post()
    }

    private func toggleCompletion(for task: TaskItem, occurrenceDate: Date, isDone: Bool) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        
        let tid = task.id
        
        // 1. 立即乐观更新 UI
        optimisticToggleTask(taskID: tid, occurrenceDate: occurrenceDate, isDone: isDone)
        
        // 2. 主线程同步更新数据库，避免后台 Context 跨线程读写导致瞬时回闪（Flash back）
        do {
            let descriptor = FetchDescriptor<TaskExecutionRecord>(
                predicate: #Predicate<TaskExecutionRecord> { $0.taskID == tid }
            )
            let relevantExecutions = (try? modelContext.fetch(descriptor)) ?? []
            
            if isDone {
                TaskExecutionSupport.reopenTaskCompletion(
                    task: task,
                    occurrenceDate: occurrenceDate,
                    existingExecutions: relevantExecutions,
                    modelContext: modelContext
                )
            } else {
                TaskExecutionSupport.markTaskCompleted(
                    task: task,
                    occurrenceDate: occurrenceDate,
                    existingExecutions: relevantExecutions,
                    modelContext: modelContext
                )
            }
            
            try? modelContext.save()
            saveAndReloadWidgetsDeferred()
            AppDataChangeCenter.post()
        }
    }

    private func skipTask(_ task: TaskItem, occurrenceDate: Date) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)

        let tid = task.id
        optimisticSkipTask(
            taskID: tid,
            occurrenceDate: occurrenceDate,
            shouldArchiveTask: task.recurrence.kind == .once
        )

        let descriptor = FetchDescriptor<TaskExecutionRecord>(
            predicate: #Predicate<TaskExecutionRecord> { $0.taskID == tid }
        )
        let relevantExecutions = (try? modelContext.fetch(descriptor)) ?? []

        TaskExecutionSupport.markTaskSkipped(
            task: task,
            occurrenceDate: occurrenceDate,
            existingExecutions: relevantExecutions,
            modelContext: modelContext
        )

        try? modelContext.save()
        saveAndReloadWidgetsDeferred()
        AppDataChangeCenter.post()
    }

    private func saveAndReloadWidgetsDeferred() {
        deferredSaveTask?.cancel()
        deferredSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            try? modelContext.save()
            WidgetCenter.shared.reloadAllTimelinesInBackground()
        }
    }

    private func optimisticToggleTask(taskID: UUID, occurrenceDate: Date, isDone: Bool) {
        withAnimation {
            if let index = pageSnapshot.displayItems.firstIndex(where: { $0.task.id == taskID && $0.occurrenceDate == occurrenceDate }) {
                let oldItem = pageSnapshot.displayItems[index]
                let nowCompleted = !isDone
                let today = TaskExecutionSupport.day(for: .now)
                
                let newSection: TodayTaskDisplaySection
                if nowCompleted {
                    newSection = .todayDone
                } else {
                    if oldItem.occurrenceDate < today {
                        newSection = .historicalPending
                    } else if Calendar.current.isDate(oldItem.occurrenceDate, inSameDayAs: today) {
                        newSection = .todayPending
                    } else {
                        newSection = .upcomingPending
                    }
                }
                
                let replacement = TasksSnapshotDisplayItem(
                    task: oldItem.task,
                    section: newSection,
                    occurrenceDate: oldItem.occurrenceDate,
                    isCompleted: nowCompleted,
                    pendingOccurrenceCount: oldItem.pendingOccurrenceCount,
                    overdueOriginText: oldItem.overdueOriginText,
                    totalSubtaskCount: oldItem.totalSubtaskCount,
                    completedSubtaskCount: nowCompleted ? oldItem.totalSubtaskCount : 0
                )
                pageSnapshot.displayItems[index] = replacement
            }
        }
    }

    private func optimisticSkipTask(taskID: UUID, occurrenceDate: Date, shouldArchiveTask: Bool) {
        withAnimation {
            pageSnapshot = TasksPageSnapshot(
                displayItems: pageSnapshot.displayItems.filter {
                    !($0.task.id == taskID && $0.occurrenceDate == occurrenceDate)
                },
                taskProjectionsByID: pageSnapshot.taskProjectionsByID,
                scheduleProjectionsByID: pageSnapshot.scheduleProjectionsByID,
                activeTaskIDs: pageSnapshot.activeTaskIDs,
                archivedTaskIDs: shouldArchiveTask
                    ? [taskID] + pageSnapshot.archivedTaskIDs.filter { $0 != taskID }
                    : pageSnapshot.archivedTaskIDs,
                todayScheduleIDs: pageSnapshot.todayScheduleIDs,
                otherScheduleIDs: pageSnapshot.otherScheduleIDs,
                archivedScheduleIDs: pageSnapshot.archivedScheduleIDs
            )
        }
    }

    private func scheduleRowContent(_ schedule: ScheduleItemProjection) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.indigo)
                .frame(width: 4, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.title)
                    .fontWeight(.medium)

                HStack(spacing: 4) {
                    Text(schedule.timeRangeText(on: .now))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.indigo)

                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text(schedule.repeatRuleLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let effectiveDateRangeLabel = schedule.effectiveDateRangeLabel {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        
                        Text(effectiveDateRangeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !schedule.note.isEmpty {
                    Text(schedule.note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func scheduleRow(_ schedule: ScheduleItemProjection) -> some View {
        Group {
            if let liveSchedule = scheduleModelsByID[schedule.id] {
                NavigationLink {
                    AddScheduleView(schedule: liveSchedule)
                } label: {
                    scheduleRowContent(schedule)
                }
            } else {
                scheduleRowContent(schedule)
            }
        }
        .padding(.vertical, 4)
        .iOS17SafeSwipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let liveSchedule = scheduleModelsByID[schedule.id] {
                Button("删除", systemImage: "trash", role: .destructive) {
                    SyncDeletionStore.delete(liveSchedule, in: modelContext)
                    pageSnapshot = TasksPageSnapshot(
                        displayItems: pageSnapshot.displayItems,
                        taskProjectionsByID: pageSnapshot.taskProjectionsByID,
                        scheduleProjectionsByID: pageSnapshot.scheduleProjectionsByID.filter { $0.key != schedule.id },
                        activeTaskIDs: pageSnapshot.activeTaskIDs,
                        archivedTaskIDs: pageSnapshot.archivedTaskIDs,
                        todayScheduleIDs: pageSnapshot.todayScheduleIDs.filter { $0 != schedule.id },
                        otherScheduleIDs: pageSnapshot.otherScheduleIDs.filter { $0 != schedule.id },
                        archivedScheduleIDs: pageSnapshot.archivedScheduleIDs.filter { $0 != schedule.id }
                    )
                    saveAndReloadWidgetsDeferred()
                }

                Button("归档", systemImage: "archivebox") {
                    withAnimation {
                        liveSchedule.isArchived = true
                        pageSnapshot = TasksPageSnapshot(
                            displayItems: pageSnapshot.displayItems,
                            taskProjectionsByID: pageSnapshot.taskProjectionsByID,
                            scheduleProjectionsByID: pageSnapshot.scheduleProjectionsByID,
                            activeTaskIDs: pageSnapshot.activeTaskIDs,
                            archivedTaskIDs: pageSnapshot.archivedTaskIDs,
                            todayScheduleIDs: pageSnapshot.todayScheduleIDs.filter { $0 != schedule.id },
                            otherScheduleIDs: pageSnapshot.otherScheduleIDs.filter { $0 != schedule.id },
                            archivedScheduleIDs: [schedule.id] + pageSnapshot.archivedScheduleIDs.filter { $0 != schedule.id }
                        )
                    }
                    saveAndReloadWidgetsDeferred()
                }
                .tint(.orange)
            }
        }
    }

    private func archivedScheduleRow(_ schedule: ScheduleItemProjection) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.secondary.opacity(0.3))
                .frame(width: 4, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.title)
                    .fontWeight(.medium)
                    .strikethrough()
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(schedule.repeatRule == .once ? schedule.startTime.formatted(.dateTime.year().month().day()) : schedule.repeatRuleLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if let effectiveDateRangeLabel = schedule.effectiveDateRangeLabel {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            
                        Text(effectiveDateRangeLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .iOS17SafeSwipeActions {
            if let liveSchedule = scheduleModelsByID[schedule.id] {
                Button("恢复", systemImage: "arrow.uturn.backward") {
                    liveSchedule.isArchived = false
                    pageSnapshot = TasksPageSnapshot(
                        displayItems: pageSnapshot.displayItems,
                        taskProjectionsByID: pageSnapshot.taskProjectionsByID,
                        scheduleProjectionsByID: pageSnapshot.scheduleProjectionsByID,
                        activeTaskIDs: pageSnapshot.activeTaskIDs,
                        archivedTaskIDs: pageSnapshot.archivedTaskIDs,
                        todayScheduleIDs: pageSnapshot.todayScheduleIDs,
                        otherScheduleIDs: pageSnapshot.otherScheduleIDs,
                        archivedScheduleIDs: pageSnapshot.archivedScheduleIDs.filter { $0 != schedule.id }
                    )
                    saveAndReloadWidgetsDeferred()
                }
                .tint(.blue)

                Button("彻底删除", systemImage: "trash", role: .destructive) {
                    SyncDeletionStore.delete(liveSchedule, in: modelContext)
                    pageSnapshot = TasksPageSnapshot(
                        displayItems: pageSnapshot.displayItems,
                        taskProjectionsByID: pageSnapshot.taskProjectionsByID,
                        scheduleProjectionsByID: pageSnapshot.scheduleProjectionsByID.filter { $0.key != schedule.id },
                        activeTaskIDs: pageSnapshot.activeTaskIDs,
                        archivedTaskIDs: pageSnapshot.archivedTaskIDs,
                        todayScheduleIDs: pageSnapshot.todayScheduleIDs,
                        otherScheduleIDs: pageSnapshot.otherScheduleIDs,
                        archivedScheduleIDs: pageSnapshot.archivedScheduleIDs.filter { $0 != schedule.id }
                    )
                    saveAndReloadWidgetsDeferred()
                }
            }
        }
    }

    private func deleteTask(_ task: TaskItem) {
        let taskID = task.id
        
        do {
            // 局部精准抓取
            let recordsDesc = FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate<TaskExecutionRecord> { $0.taskID == taskID })
            let relatedExecutionRecords = try modelContext.fetch(recordsDesc)
            let relatedExecutionIDs = Set(relatedExecutionRecords.map(\.id))

            let completionsDesc = FetchDescriptor<TaskCompletion>(predicate: #Predicate<TaskCompletion> { $0.taskID == taskID })
            let relatedCompletions = try modelContext.fetch(completionsDesc)

            let subtaskExDesc = FetchDescriptor<TaskSubitemExecutionRecord>()
            let allSubtaskEx = try modelContext.fetch(subtaskExDesc)
            
            let subtasksDesc = FetchDescriptor<TaskSubitem>(predicate: #Predicate<TaskSubitem> { $0.parentTaskID == taskID })
            let relatedSubtasks = try modelContext.fetch(subtasksDesc)

            for completion in relatedCompletions {
                SyncDeletionStore.delete(completion, in: modelContext)
            }
            for subtaskExecution in allSubtaskEx where relatedExecutionIDs.contains(subtaskExecution.taskExecutionID) {
                SyncDeletionStore.delete(subtaskExecution, in: modelContext)
            }
            for execution in relatedExecutionRecords {
                SyncDeletionStore.delete(execution, in: modelContext)
            }
            for subtask in relatedSubtasks {
                SyncDeletionStore.delete(subtask, in: modelContext)
            }
            
            SyncDeletionStore.delete(task, in: modelContext)
            pageSnapshot = TasksPageSnapshot(
                displayItems: pageSnapshot.displayItems.filter { $0.task.id != taskID },
                taskProjectionsByID: pageSnapshot.taskProjectionsByID.filter { $0.key != taskID },
                scheduleProjectionsByID: pageSnapshot.scheduleProjectionsByID,
                activeTaskIDs: pageSnapshot.activeTaskIDs.filter { $0 != taskID },
                archivedTaskIDs: pageSnapshot.archivedTaskIDs.filter { $0 != taskID },
                todayScheduleIDs: pageSnapshot.todayScheduleIDs,
                otherScheduleIDs: pageSnapshot.otherScheduleIDs,
                archivedScheduleIDs: pageSnapshot.archivedScheduleIDs
            )
            saveAndReloadWidgetsDeferred()
        } catch {
            print("Failed to delete task: \(error)")
        }
    }

    private struct DeferredTaskDetailView: View {
        @Environment(\.scenePhase) private var scenePhase

        let route: TaskDetailRoute

        @State private var loadTask: Task<Void, Never>?
        @State private var isReady = false

        private var canLoad: Bool {
            scenePhase == .active && UIApplication.shared.applicationState == .active
        }

        var body: some View {
            Group {
                if isReady {
                    TaskDetailView(taskID: route.taskID, initialTitle: route.title)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在打开 \(route.title)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle(route.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                #if DEBUG
                DebugPerf.mark("DeferredTaskDetailView onAppear title=\(route.title)")
                #endif
                loadTaskAfterNavigationSettles()
            }
            .onChange(of: scenePhase) { _, newPhase in
                #if DEBUG
                DebugPerf.mark("DeferredTaskDetailView scenePhase=\(newPhase) title=\(route.title)")
                #endif
                if newPhase == .active {
                    loadTaskAfterNavigationSettles()
                } else {
                    loadTask?.cancel()
                }
            }
            .onDisappear {
                #if DEBUG
                DebugPerf.mark("DeferredTaskDetailView onDisappear title=\(route.title)")
                #endif
                loadTask?.cancel()
            }
        }

        private func loadTaskAfterNavigationSettles() {
            #if DEBUG
            DebugPerf.mark("DeferredTaskDetailView load requested title=\(route.title)")
            #endif
            loadTask?.cancel()
            guard !isReady else { return }
            guard canLoad else { return }

            loadTask = Task { @MainActor in
                #if DEBUG
                DebugPerf.mark("DeferredTaskDetailView load task started title=\(route.title)")
                #endif
                await Task.yield()
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                guard canLoad else { return }
                isReady = true
            }
        }
    }
}
