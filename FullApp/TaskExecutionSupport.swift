import Foundation
import SwiftData

enum TodayTaskDisplaySection: Sendable {
    case todayPending
    case historicalPending
    case upcomingPending
    case todayDone
}

struct TaskProjection: Sendable {
    let id: UUID
    let title: String
    let note: String
    let createdAt: Date
    let startDate: Date
    let endDate: Date?
    let recurrence: TaskRecurrence
    let skipPolicy: TaskSkipPolicy
    let timingMode: TaskTimingMode
    let deadline: Date?
    let isArchived: Bool
    let updatedAt: Date
    let pauseIntervals: [TaskPauseInterval]
    let pauseStartedAt: Date?

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        note = task.note
        createdAt = task.createdAt
        startDate = task.startDate
        endDate = task.endDate
        recurrence = task.recurrence
        skipPolicy = task.skipPolicy
        timingMode = task.timingMode
        deadline = task.deadline
        isArchived = task.isArchived
        updatedAt = task.updatedAt
        pauseIntervals = task.pauseIntervals
        pauseStartedAt = task.pauseStartedAt
    }

    init(
        id: UUID,
        title: String,
        note: String = "",
        createdAt: Date = .now,
        startDate: Date = .now,
        endDate: Date? = nil,
        recurrence: TaskRecurrence = .once,
        skipPolicy: TaskSkipPolicy = .skippable,
        timingMode: TaskTimingMode = .scheduled,
        deadline: Date? = nil,
        isArchived: Bool = false,
        updatedAt: Date = .now,
        pauseIntervals: [TaskPauseInterval] = [],
        pauseStartedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.createdAt = createdAt
        self.startDate = startDate
        self.endDate = endDate
        self.recurrence = recurrence
        self.skipPolicy = skipPolicy
        self.timingMode = timingMode
        self.deadline = deadline
        self.isArchived = isArchived
        self.updatedAt = updatedAt
        self.pauseIntervals = pauseIntervals
        self.pauseStartedAt = pauseStartedAt
    }

    // 后台上下文安全的构造器
    init?(id: UUID, context: ModelContext) {
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate<TaskItem> { $0.id == id })
        guard let task = (try? context.fetch(descriptor))?.first else { return nil }
        self.id = task.id
        self.title = task.title
        self.note = task.note
        self.createdAt = task.createdAt
        self.startDate = task.startDate
        self.endDate = task.endDate
        self.recurrence = task.recurrence
        self.skipPolicy = task.skipPolicy
        self.timingMode = task.timingMode
        self.deadline = task.deadline
        self.isArchived = task.isArchived
        self.updatedAt = task.updatedAt
        self.pauseIntervals = task.pauseIntervals
        self.pauseStartedAt = task.pauseStartedAt
    }

    var isPaused: Bool {
        recurrence.kind != .once && pauseStartedAt != nil
    }

    func isOccurrencePaused(_ date: Date) -> Bool {
        guard recurrence.kind != .once else { return false }
        return TaskPauseSupport.isDatePaused(
            date,
            completedIntervals: pauseIntervals,
            currentPauseStartDate: pauseStartedAt
        )
    }

    func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        guard timingMode == .scheduled else { return false }
        let day = calendar.startOfDay(for: date)
        let start = calendar.startOfDay(for: startDate)
        guard day >= start else { return false }

        if let endDate, day > calendar.startOfDay(for: endDate) {
            return false
        }

        let matchesRecurrence: Bool
        switch recurrence.kind {
        case .once:
            matchesRecurrence = calendar.isDate(day, inSameDayAs: start)
        case .daily:
            matchesRecurrence = true
        case .weekly:
            matchesRecurrence = recurrence.weekdays.contains(calendar.component(.weekday, from: day))
        }

        guard matchesRecurrence else { return false }
        guard recurrence.kind != .once else { return true }
        return !TaskPauseSupport.isDatePaused(
            day,
            completedIntervals: pauseIntervals,
            currentPauseStartDate: pauseStartedAt,
            calendar: calendar
        )
    }

    func originText(for pendingDate: Date, relativeTo date: Date) -> String {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)

        if calendar.isDate(pendingDate, equalTo: targetDay, toGranularity: .year) {
            return "原定 \(pendingDate.formatted(.dateTime.month().day()))"
        }
        return "原定 \(pendingDate.formatted(.dateTime.year().month().day()))"
    }

    func scheduledOccurrenceDates(upTo date: Date) -> [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let unclampedTarget = calendar.startOfDay(for: date)
        let target = min(unclampedTarget, effectiveEndDay ?? unclampedTarget)

        guard target >= start else { return [] }

        let scheduledDates: [Date]
        switch recurrence.kind {
        case .once:
            return [start]

        case .daily:
            let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
            scheduledDates = (0...days).compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: start)
            }

        case .weekly:
            var weeklyDates: [Date] = []
            var checkDate = start
            while checkDate <= target {
                let weekday = calendar.component(.weekday, from: checkDate)
                if recurrence.weekdays.contains(weekday) {
                    weeklyDates.append(checkDate)
                }
                guard let nextDate = calendar.date(byAdding: .day, value: 1, to: checkDate) else {
                    break
                }
                checkDate = nextDate
            }
            scheduledDates = weeklyDates
        }

        return scheduledDates.filter { !isOccurrencePaused($0) }
    }

    private var effectiveEndDay: Date? {
        guard let endDate else { return nil }
        return Calendar.current.startOfDay(for: endDate)
    }

    var effectiveDateRangeLabel: String? {
        guard recurrence.kind != .once, let effectiveEndDay else { return nil }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: startDate)
        if calendar.isDate(startDay, equalTo: effectiveEndDay, toGranularity: .year) {
            return "\(startDay.formatted(.dateTime.month().day())) - \(effectiveEndDay.formatted(.dateTime.month().day()))"
        }
        return "\(startDay.formatted(.dateTime.year().month().day())) - \(effectiveEndDay.formatted(.dateTime.year().month().day()))"
    }

    var recurrenceLabel: String {
        switch recurrence.kind {
        case .once:
            return "单次"
        case .daily:
            return "每天"
        case .weekly:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let days = recurrence.weekdays.sorted().compactMap { wd -> String? in
                guard wd >= 1, wd <= 7 else { return nil }
                return "周\(names[wd - 1])"
            }
            return "每周 \(days.joined(separator: "、"))"
        }
    }

    var recurrenceShortLabel: String {
        switch recurrence.kind {
        case .once:
            return "单次"
        case .daily:
            return "每天"
        case .weekly:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let days = recurrence.weekdays.sorted().compactMap { wd -> String? in
                guard wd >= 1, wd <= 7 else { return nil }
                return names[wd - 1]
            }
            return "周" + days.joined(separator: "、")
        }
    }

    func originShortText(for pendingDate: Date) -> String {
        pendingDate.formatted(.dateTime.month().day())
    }
}

enum RecentPlanDeadlineKind: Sendable {
    case upcoming
    case dueToday
    case overdue
}

struct RecentPlanDeadlineState: Sendable {
    let kind: RecentPlanDeadlineKind
    let dayCount: Int

    var statusText: String {
        switch kind {
        case .upcoming:
            return "还剩 \(dayCount) 天"
        case .dueToday:
            return "今天截止"
        case .overdue:
            return "已逾期 \(dayCount) 天"
        }
    }

    var isVoiceReminderEligible: Bool {
        switch kind {
        case .overdue, .dueToday:
            return true
        case .upcoming:
            return dayCount <= 7
        }
    }

    var urgencyRank: Int {
        switch kind {
        case .overdue:
            return 0
        case .dueToday:
            return 1
        case .upcoming:
            return 2
        }
    }
}

struct RecentPlanProjection: Identifiable, Sendable {
    let task: TaskProjection
    let deadline: Date
    let deadlineState: RecentPlanDeadlineState
    let isCompleted: Bool
    let completedAt: Date?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int

    var id: UUID { task.id }

    var isVoiceReminderEligible: Bool {
        !isCompleted && deadlineState.isVoiceReminderEligible
    }

    var hasSubtasks: Bool {
        totalSubtaskCount > 0
    }
}

enum RecentPlanSupport {
    static func visibilityStart(
        for deadline: Date,
        calendar: Calendar = .current
    ) -> Date {
        let deadlineDay = calendar.startOfDay(for: deadline)
        return calendar.startOfDay(
            for: calendar.date(byAdding: .month, value: -1, to: deadlineDay) ?? deadlineDay
        )
    }

    static func deadlineState(
        deadline: Date,
        on referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> RecentPlanDeadlineState {
        let today = calendar.startOfDay(for: referenceDate)
        let deadlineDay = calendar.startOfDay(for: deadline)
        let difference = calendar.dateComponents([.day], from: today, to: deadlineDay).day ?? 0

        if difference < 0 {
            return RecentPlanDeadlineState(kind: .overdue, dayCount: abs(difference))
        }
        if difference == 0 {
            return RecentPlanDeadlineState(kind: .dueToday, dayCount: 0)
        }
        return RecentPlanDeadlineState(kind: .upcoming, dayCount: difference)
    }

    static func isInHomeVisibilityWindow(
        deadline: Date,
        on referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        calendar.startOfDay(for: referenceDate) >= visibilityStart(for: deadline, calendar: calendar)
    }

    static func allProjections(
        from tasks: [TaskProjection],
        executions: [TaskExecutionRecordProjection],
        subtasks: [TaskSubitemProjection],
        on referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> [RecentPlanProjection] {
        let executionsByTaskID = Dictionary(grouping: executions, by: \.taskID)
        let subtasksByExecutionID = Dictionary(
            grouping: subtasks.filter { !$0.isArchived && $0.taskExecutionID != nil },
            by: { $0.taskExecutionID! }
        )

        return tasks.compactMap { task in
            guard task.timingMode == .flexibleDeadline,
                  let deadline = task.deadline else {
                return nil
            }

            let record = preferredExecution(in: executionsByTaskID[task.id] ?? [])
            let planSubtasks = record.map { subtasksByExecutionID[$0.id] ?? [] } ?? []
            let completedSubtaskCount = planSubtasks.filter { $0.status == .completed }.count
            let isCompleted = planSubtasks.isEmpty
                ? record?.status == .completed
                : completedSubtaskCount == planSubtasks.count

            return RecentPlanProjection(
                task: task,
                deadline: calendar.startOfDay(for: deadline),
                deadlineState: deadlineState(
                    deadline: deadline,
                    on: referenceDate,
                    calendar: calendar
                ),
                isCompleted: isCompleted,
                completedAt: record?.completedAt,
                totalSubtaskCount: planSubtasks.count,
                completedSubtaskCount: completedSubtaskCount
            )
        }
        .sorted(by: sort)
    }

    static func visibleProjections(
        from tasks: [TaskProjection],
        executions: [TaskExecutionRecordProjection],
        subtasks: [TaskSubitemProjection],
        on referenceDate: Date = .now,
        includeCompletedToday: Bool,
        calendar: Calendar = .current
    ) -> [RecentPlanProjection] {
        allProjections(
            from: tasks,
            executions: executions,
            subtasks: subtasks,
            on: referenceDate,
            calendar: calendar
        )
        .filter { plan in
            if plan.isCompleted {
                guard includeCompletedToday, let completedAt = plan.completedAt else { return false }
                return calendar.isDate(completedAt, inSameDayAs: referenceDate)
            }
            guard !plan.task.isArchived else { return false }
            return isInHomeVisibilityWindow(
                deadline: plan.deadline,
                on: referenceDate,
                calendar: calendar
            )
        }
    }

    private static func preferredExecution(
        in records: [TaskExecutionRecordProjection]
    ) -> TaskExecutionRecordProjection? {
        records.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func sort(
        _ lhs: RecentPlanProjection,
        _ rhs: RecentPlanProjection
    ) -> Bool {
        if lhs.isCompleted != rhs.isCompleted {
            return !lhs.isCompleted
        }
        if lhs.deadlineState.urgencyRank != rhs.deadlineState.urgencyRank {
            return lhs.deadlineState.urgencyRank < rhs.deadlineState.urgencyRank
        }
        if lhs.deadline != rhs.deadline {
            return lhs.deadline < rhs.deadline
        }
        return lhs.task.createdAt < rhs.task.createdAt
    }
}

struct TaskSubitemProjection: Identifiable, Sendable {
    let id: UUID
    let parentTaskID: UUID
    let taskExecutionID: UUID?
    let title: String
    let note: String
    let detail: String
    var status: TaskExecutionStatus
    var sortOrder: Int
    let isArchived: Bool
    let createdAt: Date
    let updatedAt: Date

    init(_ subtask: TaskSubitem) {
        id = subtask.id
        parentTaskID = subtask.parentTaskID
        taskExecutionID = subtask.taskExecutionID
        title = subtask.title
        note = subtask.note
        detail = subtask.detail
        status = subtask.status
        sortOrder = subtask.sortOrder
        isArchived = subtask.isArchived
        createdAt = subtask.createdAt
        updatedAt = subtask.updatedAt
    }
}

private struct TaskSubitemDeduplicationKey: Hashable {
    let parentTaskID: UUID
    let taskExecutionID: UUID
    let sortOrder: Int
    let title: String
    let note: String
    let detail: String
    let isArchived: Bool

    init?(_ subtask: TaskSubitem) {
        guard let taskExecutionID = subtask.taskExecutionID else { return nil }
        parentTaskID = subtask.parentTaskID
        self.taskExecutionID = taskExecutionID
        sortOrder = subtask.sortOrder
        title = subtask.title.trimmingCharacters(in: .whitespacesAndNewlines)
        note = subtask.note.trimmingCharacters(in: .whitespacesAndNewlines)
        detail = subtask.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        isArchived = subtask.isArchived
    }

    init?(_ subtask: TaskSubitemProjection) {
        guard let taskExecutionID = subtask.taskExecutionID else { return nil }
        parentTaskID = subtask.parentTaskID
        self.taskExecutionID = taskExecutionID
        sortOrder = subtask.sortOrder
        title = subtask.title.trimmingCharacters(in: .whitespacesAndNewlines)
        note = subtask.note.trimmingCharacters(in: .whitespacesAndNewlines)
        detail = subtask.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        isArchived = subtask.isArchived
    }
}

struct TaskExecutionRecordProjection: Sendable {
    let id: UUID
    let taskID: UUID
    let occurrenceDate: Date
    let detail: String
    let status: TaskExecutionStatus
    let completedAt: Date?
    let updatedAt: Date

    init(_ record: TaskExecutionRecord) {
        id = record.id
        taskID = record.taskID
        occurrenceDate = record.occurrenceDate
        detail = record.detail
        status = record.status
        completedAt = record.completedAt
        updatedAt = record.updatedAt
    }
}

struct TodayTaskProjectionResult: Sendable {
    let taskID: UUID
    let section: TodayTaskDisplaySection
    let occurrenceDate: Date
    let isCompleted: Bool
    let pendingOccurrenceCount: Int
    let historicalPendingCount: Int
    let totalPendingOccurrenceCount: Int
    let overdueOriginText: String?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int
}

struct TodayTaskDisplayItem: Identifiable, Equatable {
    let task: TaskItem
    let section: TodayTaskDisplaySection
    let occurrenceDate: Date
    let isCompleted: Bool
    let pendingOccurrenceCount: Int
    let historicalPendingCount: Int
    let totalPendingOccurrenceCount: Int
    let overdueOriginText: String?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int

    static func == (lhs: TodayTaskDisplayItem, rhs: TodayTaskDisplayItem) -> Bool {
        lhs.task.id == rhs.task.id &&
        lhs.section == rhs.section &&
        lhs.occurrenceDate == rhs.occurrenceDate &&
        lhs.isCompleted == rhs.isCompleted &&
        lhs.pendingOccurrenceCount == rhs.pendingOccurrenceCount &&
        lhs.historicalPendingCount == rhs.historicalPendingCount &&
        lhs.totalPendingOccurrenceCount == rhs.totalPendingOccurrenceCount &&
        lhs.overdueOriginText == rhs.overdueOriginText &&
        lhs.totalSubtaskCount == rhs.totalSubtaskCount &&
        lhs.completedSubtaskCount == rhs.completedSubtaskCount
    }

    var id: String {
        "\(task.id.uuidString)-\(occurrenceDate.timeIntervalSince1970)"
    }

    var hasSubtasks: Bool {
        totalSubtaskCount > 0
    }

    var subtaskProgressText: String? {
        guard hasSubtasks else { return nil }
        return "\(completedSubtaskCount)/\(totalSubtaskCount) 子任务"
    }

    var simpleProgressText: String? {
        guard hasSubtasks else { return nil }
        return "\(completedSubtaskCount)/\(totalSubtaskCount)"
    }
}

struct TodayTaskSectionSnapshot<Item> {
    let todayPendingItems: [Item]
    let historicalPendingItems: [Item]
    let todayDoneItems: [Item]
    let historicalPendingTotalCount: Int
}

struct TaskDisplayDedupSortKey: Comparable, Sendable {
    let unskippablePriority: Int
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int
    let createdAt: Date
    let stableID: String

    static func < (lhs: TaskDisplayDedupSortKey, rhs: TaskDisplayDedupSortKey) -> Bool {
        if lhs.unskippablePriority != rhs.unskippablePriority {
            return lhs.unskippablePriority < rhs.unskippablePriority
        }
        if lhs.totalSubtaskCount != rhs.totalSubtaskCount {
            return lhs.totalSubtaskCount < rhs.totalSubtaskCount
        }
        if lhs.completedSubtaskCount != rhs.completedSubtaskCount {
            return lhs.completedSubtaskCount < rhs.completedSubtaskCount
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.stableID < rhs.stableID
    }
}

struct TaskModelDedupSortKey: Comparable, Sendable {
    let archivedPriority: Int
    let updatedAt: Date
    let createdAt: Date
    let stableID: String

    static func < (lhs: TaskModelDedupSortKey, rhs: TaskModelDedupSortKey) -> Bool {
        if lhs.archivedPriority != rhs.archivedPriority {
            return lhs.archivedPriority < rhs.archivedPriority
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.stableID < rhs.stableID
    }
}

enum TaskDedupSupport {
    static func deduplicatedTasks(_ tasks: [TaskItem]) -> [TaskItem] {
        deduplicate(
            tasks,
            key: { task in
                let normalizedTitle = normalizedTitle(task.title)
                return normalizedTitle.isEmpty ? "id:\(task.id.uuidString.lowercased())" : "title:\(normalizedTitle)"
            },
            sortKey: { task in
                TaskModelDedupSortKey(
                    archivedPriority: task.isArchived ? 0 : 1,
                    updatedAt: task.updatedAt,
                    createdAt: task.createdAt,
                    stableID: task.id.uuidString
                )
            }
        )
    }

    static func deduplicatedDisplayItems<Item>(
        _ items: [Item],
        title: (Item) -> String,
        taskID: (Item) -> UUID,
        section: (Item) -> TodayTaskDisplaySection,
        occurrenceDate: (Item) -> Date,
        sortKey: (Item) -> TaskDisplayDedupSortKey
    ) -> [Item] {
        deduplicate(
            items,
            key: { item in
                let normalized = normalizedTitle(title(item))
                let occurrenceDay = Calendar.current.startOfDay(for: occurrenceDate(item))
                return [
                    normalized.isEmpty
                        ? "id:\(taskID(item).uuidString.lowercased())"
                        : "title:\(normalized)",
                    String(describing: section(item)),
                    String(occurrenceDay.timeIntervalSinceReferenceDate)
                ].joined(separator: "|")
            },
            sortKey: sortKey
        )
    }

    private static func deduplicate<Item, Key: Hashable, SortKey: Comparable>(
        _ items: [Item],
        key: (Item) -> Key,
        sortKey: (Item) -> SortKey
    ) -> [Item] {
        var preferredItemsByKey: [Key: Item] = [:]
        var order: [Key] = []

        for item in items {
            let itemKey = key(item)
            if let existing = preferredItemsByKey[itemKey] {
                if sortKey(existing) < sortKey(item) {
                    preferredItemsByKey[itemKey] = item
                }
            } else {
                preferredItemsByKey[itemKey] = item
                order.append(itemKey)
            }
        }

        return order.compactMap { preferredItemsByKey[$0] }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

enum TodayTaskSectionSnapshotBuilder {
    static func build<Item>(
        from items: [Item],
        taskID: (Item) -> UUID,
        section: (Item) -> TodayTaskDisplaySection,
        collapseTodayDone: Bool = true
    ) -> TodayTaskSectionSnapshot<Item> {
        let todayPendingItems = collapse(items.filter { section($0) == .todayPending }, taskID: taskID)
        let historicalPendingSource = items.filter { section($0) == .historicalPending }
        let historicalPendingItems = collapse(historicalPendingSource, taskID: taskID)
        let todayDoneSource = items.filter { section($0) == .todayDone }
        let todayDoneItems = collapseTodayDone
            ? collapse(todayDoneSource, taskID: taskID)
            : todayDoneSource

        return TodayTaskSectionSnapshot(
            todayPendingItems: todayPendingItems,
            historicalPendingItems: historicalPendingItems,
            todayDoneItems: todayDoneItems,
            historicalPendingTotalCount: historicalPendingSource.count
        )
    }

    private static func collapse<Item>(
        _ items: [Item],
        taskID: (Item) -> UUID
    ) -> [Item] {
        var seenTaskIDs = Set<UUID>()
        return items.filter { item in
            seenTaskIDs.insert(taskID(item)).inserted
        }
    }
}

struct TaskOccurrenceSnapshot: Identifiable, Sendable {
    let taskID: UUID
    let occurrenceDate: Date
    var isCompleted: Bool
    let overdueOriginText: String?
    let executionRecordID: UUID?
    let executionDetail: String
    let hasDetail: Bool
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int

    var id: String {
        "\(taskID.uuidString)-\(occurrenceDate.timeIntervalSince1970)-\(isCompleted)"
    }

    var hasSubtasks: Bool {
        totalSubtaskCount > 0
    }

    var subtaskProgressText: String? {
        guard hasSubtasks else { return nil }
        return "\(completedSubtaskCount)/\(totalSubtaskCount) 子任务"
    }

    var simpleProgressText: String? {
        guard hasSubtasks else { return nil }
        return "\(completedSubtaskCount)/\(totalSubtaskCount)"
    }
}

enum TaskExecutionSupport {
    static func day(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// 修复旧版快速连点或同步冲突产生的重复子任务。
    /// 只合并 UUID 相同，或“同次执行 + 同排序位置 + 内容完全相同”的记录，
    /// 避免误删用户有意创建的同名子任务。
    @discardableResult
    static func deduplicateSubtasks(in modelContext: ModelContext) throws -> Int {
        let allSubtasks = try modelContext.fetch(FetchDescriptor<TaskSubitem>())
        guard allSubtasks.count > 1 else { return 0 }

        var deletedCount = 0
        var idSurvivors: [TaskSubitem] = []
        let groupsByID = Dictionary(grouping: allSubtasks, by: \.id)

        for group in groupsByID.values {
            let winner = group.max(by: subtaskDeduplicationPreference)!
            idSurvivors.append(winner)
            for duplicate in group where duplicate !== winner {
                modelContext.delete(duplicate)
                deletedCount += 1
            }
        }

        let keyedSurvivors = idSurvivors.compactMap { subtask -> (TaskSubitemDeduplicationKey, TaskSubitem)? in
            guard let key = TaskSubitemDeduplicationKey(subtask) else { return nil }
            return (key, subtask)
        }
        let groupsByContent = Dictionary(grouping: keyedSurvivors, by: { $0.0 })

        for group in groupsByContent.values where group.count > 1 {
            let candidates = group.map(\.1)
            let winner = candidates.max(by: subtaskDeduplicationPreference)!
            for duplicate in candidates where duplicate !== winner {
                modelContext.delete(duplicate)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            try modelContext.save()
        }
        return deletedCount
    }

    private static func deduplicatedSubtasks(_ subtasks: [TaskSubitem]) -> [TaskSubitem] {
        let idWinners = Dictionary(grouping: subtasks, by: \.id).values.compactMap {
            $0.max(by: subtaskDeduplicationPreference)
        }
        let unkeyed = idWinners.filter { TaskSubitemDeduplicationKey($0) == nil }
        let keyed = idWinners.compactMap { subtask -> (TaskSubitemDeduplicationKey, TaskSubitem)? in
            guard let key = TaskSubitemDeduplicationKey(subtask) else { return nil }
            return (key, subtask)
        }
        let contentWinners = Dictionary(grouping: keyed, by: { $0.0 }).values.compactMap { group in
            group.map(\.1).max(by: subtaskDeduplicationPreference)
        }
        return (unkeyed + contentWinners).sorted(by: sortSubtasks)
    }

    static func deduplicatedSubtasks(_ subtasks: [TaskSubitemProjection]) -> [TaskSubitemProjection] {
        let idWinners = Dictionary(grouping: subtasks, by: \.id).values.compactMap {
            $0.max(by: subtaskDeduplicationPreference)
        }
        let unkeyed = idWinners.filter { TaskSubitemDeduplicationKey($0) == nil }
        let keyed = idWinners.compactMap { subtask -> (TaskSubitemDeduplicationKey, TaskSubitemProjection)? in
            guard let key = TaskSubitemDeduplicationKey(subtask) else { return nil }
            return (key, subtask)
        }
        let contentWinners = Dictionary(grouping: keyed, by: { $0.0 }).values.compactMap { group in
            group.map(\.1).max(by: subtaskDeduplicationPreference)
        }
        return (unkeyed + contentWinners).sorted(by: sortSubtasks)
    }

    static func legacyTemplateSubtasks(
        for taskID: UUID,
        in subtasks: [TaskSubitem]
    ) -> [TaskSubitem] {
        subtasks
            .filter {
                $0.parentTaskID == taskID &&
                $0.taskExecutionID == nil &&
                !$0.isArchived
            }
            .sorted(by: sortSubtasks)
    }

    static func executionSubtasks(
        for executionRecord: TaskExecutionRecord?,
        in subtasks: [TaskSubitem]
    ) -> [TaskSubitem] {
        guard let executionRecord else { return [] }
        return deduplicatedSubtasks(
            subtasks.filter {
                $0.taskExecutionID == executionRecord.id &&
                !$0.isArchived
            }
        )
    }

    static func executionSubtasks(
        for executionRecord: TaskExecutionRecordProjection?,
        in subtasks: [TaskSubitemProjection]
    ) -> [TaskSubitemProjection] {
        guard let executionRecord else { return [] }
        return deduplicatedSubtasks(
            subtasks.filter {
                $0.taskExecutionID == executionRecord.id &&
                !$0.isArchived
            }
        )
    }

    static func executionRecord(
        for taskID: UUID,
        on occurrenceDate: Date,
        in executions: [TaskExecutionRecord]
    ) -> TaskExecutionRecord? {
        let targetDay = day(for: occurrenceDate)
        let matchingRecords = executions.filter {
            $0.taskID == taskID && Calendar.current.isDate($0.occurrenceDate, inSameDayAs: targetDay)
        }
        return preferredExecutionRecord(in: matchingRecords)
    }

    static func subtaskProgress(
        for executionRecord: TaskExecutionRecord?,
        in subtasks: [TaskSubitem]
    ) -> (completed: Int, total: Int) {
        let executionSubtasks = executionSubtasks(for: executionRecord, in: subtasks)
        let completed = executionSubtasks.filter { $0.status == .completed }.count
        return (completed, executionSubtasks.count)
    }

    static func isOccurrenceCompleted(
        task: TaskItem,
        occurrenceDate: Date,
        executions: [TaskExecutionRecord],
        subtasks: [TaskSubitem],
        subtaskExecutions: [TaskSubitemExecutionRecord] = []
    ) -> Bool {
        let record = executionRecord(for: task.id, on: occurrenceDate, in: executions)
        let occurrenceSubtasks = executionSubtasks(for: record, in: subtasks)

        if occurrenceSubtasks.isEmpty {
            return record?.status == .completed
        }

        return occurrenceSubtasks.allSatisfy { $0.status == .completed }
    }

    static func occurrenceSnapshots(
        for task: TaskItem,
        executions: [TaskExecutionRecord],
        subtasks allSubtasks: [TaskSubitem],
        subtaskExecutions: [TaskSubitemExecutionRecord],
        on date: Date = .now
    ) -> [TaskOccurrenceSnapshot] {
        let today = day(for: date)

        // 优化：使用字典分组，完全避免在循环内访问 SwiftData PersistentModel 导致的 CoreData 锁
        let taskExecutions = executions.filter { $0.taskID == task.id }
        let executionsByDate = Dictionary(grouping: taskExecutions) { day(for: $0.occurrenceDate) }
        
        let validSubtasks = TaskExecutionSupport.deduplicatedSubtasks(
            allSubtasks.filter { $0.parentTaskID == task.id && $0.taskExecutionID != nil && !$0.isArchived }
        )
        let subtasksByExecutionID = Dictionary(grouping: validSubtasks) { $0.taskExecutionID! }

        return task.scheduledOccurrenceDates(upTo: date).compactMap { occurrenceDate in
            let dateKey = day(for: occurrenceDate)
            let record = preferredExecutionRecord(in: executionsByDate[dateKey] ?? [])
            if record?.status == .skipped {
                return nil
            }

            // O(1) 获取子任务，避免 O(M) 次读取数据库对象属性
            let occurrenceSubtasks: [TaskSubitem] = {
                guard let executionID = record?.id else { return [] }
                return (subtasksByExecutionID[executionID] ?? []).sorted(by: sortSubtasks)
            }()
            
            let completed: Bool
            if occurrenceSubtasks.isEmpty {
                completed = record?.status == .completed
            } else {
                completed = occurrenceSubtasks.allSatisfy { $0.status == .completed }
            }

            if !completed &&
                task.skipPolicy == .skippable &&
                occurrenceDate < today &&
                record == nil {
                return nil
            }

            let completedSubtasksCount = occurrenceSubtasks.filter { $0.status == .completed }.count

            let overdueOriginText: String? = {
                guard task.skipPolicy == .unskippable, occurrenceDate < today else { return nil }
                return task.originText(for: occurrenceDate, relativeTo: today)
            }()

            return TaskOccurrenceSnapshot(
                taskID: task.id,
                occurrenceDate: occurrenceDate,
                isCompleted: completed,
                overdueOriginText: completed ? nil : overdueOriginText,
                executionRecordID: record?.id,
                executionDetail: record?.detail ?? "",
                hasDetail: recordHasDetail(record) || occurrenceSubtasks.contains(where: subtaskHasDetail),
                totalSubtaskCount: occurrenceSubtasks.count,
                completedSubtaskCount: completedSubtasksCount
            )
        }
    }

    static func occurrenceSnapshots(
        for task: TaskProjection,
        executions: [TaskExecutionRecordProjection],
        subtasks allSubtasks: [TaskSubitemProjection],
        on date: Date = .now
    ) -> [TaskOccurrenceSnapshot] {
        let today = day(for: date)
        let taskExecutions = executions.filter { $0.taskID == task.id }
        let executionsByDate = Dictionary(grouping: taskExecutions) { day(for: $0.occurrenceDate) }
        let validSubtasks = deduplicatedSubtasks(
            allSubtasks.filter {
                $0.parentTaskID == task.id &&
                $0.taskExecutionID != nil &&
                !$0.isArchived
            }
        )
        let subtasksByExecutionID = Dictionary(grouping: validSubtasks) { $0.taskExecutionID! }

        return task.scheduledOccurrenceDates(upTo: date).compactMap { occurrenceDate in
            let dateKey = day(for: occurrenceDate)
            let record = preferredExecutionRecord(in: executionsByDate[dateKey] ?? [])
            if record?.status == .skipped {
                return nil
            }

            let occurrenceSubtasks: [TaskSubitemProjection] = {
                guard let executionID = record?.id else { return [] }
                return (subtasksByExecutionID[executionID] ?? []).sorted(by: sortSubtasks)
            }()

            let completed: Bool
            if occurrenceSubtasks.isEmpty {
                completed = record?.status == .completed
            } else {
                completed = occurrenceSubtasks.allSatisfy { $0.status == .completed }
            }

            if !completed &&
                task.skipPolicy == .skippable &&
                occurrenceDate < today &&
                record == nil {
                return nil
            }

            let completedSubtasksCount = occurrenceSubtasks.filter { $0.status == .completed }.count
            let overdueOriginText: String? = {
                guard task.skipPolicy == .unskippable, occurrenceDate < today else { return nil }
                return task.originText(for: occurrenceDate, relativeTo: today)
            }()

            return TaskOccurrenceSnapshot(
                taskID: task.id,
                occurrenceDate: occurrenceDate,
                isCompleted: completed,
                overdueOriginText: completed ? nil : overdueOriginText,
                executionRecordID: record?.id,
                executionDetail: record?.detail ?? "",
                hasDetail: recordHasDetail(record) || occurrenceSubtasks.contains(where: subtaskHasDetail),
                totalSubtaskCount: occurrenceSubtasks.count,
                completedSubtaskCount: completedSubtasksCount
            )
        }
    }

    static func buildTodayItems(
        from tasks: [TaskItem],
        executions: [TaskExecutionRecord],
        subtasks: [TaskSubitem],
        subtaskExecutions: [TaskSubitemExecutionRecord],
        on date: Date = .now
    ) -> [TodayTaskDisplayItem] {
        let calendar = Calendar.current
        let today = day(for: date)
        let lookaheadDay = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        
        // --- 核心性能优化：在任务百日大循环之外，一次性将全库的记录按照 taskID 切分好！
        // 从而彻底防止内部每次检查 task.id 而导致读取 CoreData PersistentModel 发生锁耗时（会导致 Watchdog）
        let validSubtasks = deduplicatedSubtasks(subtasks.filter { !$0.isArchived })
        let subtasksByTask = Dictionary(grouping: validSubtasks, by: \.parentTaskID)
        let executionsByTask = Dictionary(grouping: executions, by: \.taskID)

        return tasks
            .filter { $0.timingMode == .scheduled }
            .flatMap { task -> [TodayTaskDisplayItem] in
            let snapshots = occurrenceSnapshots(
                for: task,
                executions: executionsByTask[task.id] ?? [],
                subtasks: subtasksByTask[task.id] ?? [],
                subtaskExecutions: subtaskExecutions,
                on: lookaheadDay
            )
            let historicalPendingCount = snapshots.filter {
                !$0.isCompleted && $0.occurrenceDate < today
            }.count
            let todayPendingCount = snapshots.filter {
                !$0.isCompleted && calendar.isDate($0.occurrenceDate, inSameDayAs: today)
            }.count
            let totalPendingOccurrenceCount = historicalPendingCount + todayPendingCount
            let upcomingPendingCount = snapshots.filter {
                !$0.isCompleted && $0.occurrenceDate > today
            }.count

            return snapshots.compactMap { snapshot -> TodayTaskDisplayItem? in
                let section: TodayTaskDisplaySection
                if snapshot.isCompleted {
                    guard calendar.isDate(snapshot.occurrenceDate, inSameDayAs: today) else { return nil }
                    section = .todayDone
                } else if calendar.isDate(snapshot.occurrenceDate, inSameDayAs: today) {
                    section = .todayPending
                } else if snapshot.occurrenceDate > today {
                    section = .upcomingPending
                } else {
                    section = .historicalPending
                }

                let pendingCount: Int
                switch section {
                case .todayPending:
                    pendingCount = todayPendingCount
                case .historicalPending:
                    pendingCount = historicalPendingCount
                case .upcomingPending:
                    pendingCount = upcomingPendingCount
                case .todayDone:
                    pendingCount = 0
                }

                return TodayTaskDisplayItem(
                    task: task,
                    section: section,
                    occurrenceDate: snapshot.occurrenceDate,
                    isCompleted: snapshot.isCompleted,
                    pendingOccurrenceCount: pendingCount,
                    historicalPendingCount: historicalPendingCount,
                    totalPendingOccurrenceCount: totalPendingOccurrenceCount,
                    overdueOriginText: snapshot.overdueOriginText,
                    totalSubtaskCount: snapshot.totalSubtaskCount,
                    completedSubtaskCount: snapshot.completedSubtaskCount
                )
            }
        }
    }

    static func ensureExecutionRecord(
        for task: TaskItem,
        occurrenceDate: Date,
        existingExecutions: [TaskExecutionRecord],
        modelContext: ModelContext
    ) -> TaskExecutionRecord {
        if let record = executionRecord(for: task.id, on: occurrenceDate, in: existingExecutions) {
            return record
        }

        let record = TaskExecutionRecord(
            taskID: task.id,
            occurrenceDate: day(for: occurrenceDate)
        )
        modelContext.insert(record)
        return record
    }

    static func syncExecutionStatus(
        record: TaskExecutionRecord,
        task: TaskItem,
        subtasks: [TaskSubitem],
        subtaskExecutions: [TaskSubitemExecutionRecord] = [],
        modelContext: ModelContext? = nil
    ) {
        let wasCompleted = record.status == .completed
        if record.status == .skipped {
            record.completedAt = nil
            record.updatedAt = .now
            if task.recurrence.kind == .once {
                task.isArchived = true
            }
            if wasCompleted, let modelContext {
                PointLedgerService.reverseEntries(
                    sourceType: .taskExecution,
                    sourceID: record.id,
                    in: modelContext
                )
            }
            return
        }

        let occurrenceSubtasks = executionSubtasks(for: record, in: subtasks)
        if occurrenceSubtasks.isEmpty {
            if record.status == .completed {
                record.completedAt = record.completedAt ?? .now
            }
        } else if occurrenceSubtasks.allSatisfy({ $0.status == .completed }) {
            record.status = .completed
            record.completedAt = record.completedAt ?? .now
            if task.recurrence.kind == .once {
                task.isArchived = true
            }
        } else {
            record.status = .pending
            record.completedAt = nil
            if task.recurrence.kind == .once {
                task.isArchived = false
            }
        }
        record.updatedAt = .now

        if let modelContext {
            if !wasCompleted && record.status == .completed {
                PointLedgerService.awardTaskExecution(record, taskTitle: task.title, in: modelContext)
            } else if wasCompleted && record.status != .completed {
                PointLedgerService.reverseEntries(
                    sourceType: .taskExecution,
                    sourceID: record.id,
                    in: modelContext
                )
            }
        }
    }

    static func markTaskCompleted(
        task: TaskItem,
        occurrenceDate: Date,
        existingExecutions: [TaskExecutionRecord],
        modelContext: ModelContext
    ) {
        let record = ensureExecutionRecord(
            for: task,
            occurrenceDate: occurrenceDate,
            existingExecutions: existingExecutions,
            modelContext: modelContext
        )
        let wasCompleted = record.status == .completed
        record.status = .completed
        record.completedAt = .now
        record.updatedAt = .now

        if task.recurrence.kind == .once {
            task.isArchived = true
        }

        if !wasCompleted {
            PointLedgerService.awardTaskExecution(record, taskTitle: task.title, in: modelContext)
        }
    }

    static func markTaskSkipped(
        task: TaskItem,
        occurrenceDate: Date,
        existingExecutions: [TaskExecutionRecord],
        modelContext: ModelContext
    ) {
        let record = ensureExecutionRecord(
            for: task,
            occurrenceDate: occurrenceDate,
            existingExecutions: existingExecutions,
            modelContext: modelContext
        )
        let wasCompleted = record.status == .completed
        record.status = .skipped
        record.completedAt = nil
        record.updatedAt = .now

        if task.recurrence.kind == .once {
            task.isArchived = true
        }

        if wasCompleted {
            PointLedgerService.reverseEntries(
                sourceType: .taskExecution,
                sourceID: record.id,
                in: modelContext
            )
        }
    }

    static func reopenTaskCompletion(
        task: TaskItem,
        occurrenceDate: Date,
        existingExecutions: [TaskExecutionRecord],
        modelContext: ModelContext
    ) {
        guard let record = executionRecord(for: task.id, on: occurrenceDate, in: existingExecutions) else {
            return
        }
        let wasCompleted = record.status == .completed

        let isToday = Calendar.current.isDate(occurrenceDate, inSameDayAs: .now)
        if record.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isToday {
            SyncDeletionStore.delete(record, in: modelContext)
        } else {
            record.status = .pending
            record.completedAt = nil
            record.updatedAt = .now
        }

        if task.recurrence.kind == .once {
            task.isArchived = false
        }

        if wasCompleted {
            PointLedgerService.reverseEntries(
                sourceType: .taskExecution,
                sourceID: record.id,
                in: modelContext
            )
        }
    }

    private static func preferredExecutionRecord(
        in records: [TaskExecutionRecord]
    ) -> TaskExecutionRecord? {
        records.max { lhs, rhs in
            executionRecordSortKey(for: lhs) < executionRecordSortKey(for: rhs)
        }
    }

    private static func preferredExecutionRecord(
        in records: [TaskExecutionRecordProjection]
    ) -> TaskExecutionRecordProjection? {
        records.max { lhs, rhs in
            executionRecordSortKey(for: lhs) < executionRecordSortKey(for: rhs)
        }
    }

    private static func executionRecordSortKey(
        for record: TaskExecutionRecord
    ) -> (Int, Date, Date, UUID) {
        (
            executionStatusSortPriority(record.status),
            record.completedAt ?? .distantPast,
            record.updatedAt,
            record.id
        )
    }

    private static func executionRecordSortKey(
        for record: TaskExecutionRecordProjection
    ) -> (Int, Date, Date, UUID) {
        (
            executionStatusSortPriority(record.status),
            record.completedAt ?? .distantPast,
            record.updatedAt,
            record.id
        )
    }

    private static func executionStatusSortPriority(_ status: TaskExecutionStatus) -> Int {
        switch status {
        case .pending:
            return 0
        case .completed:
            return 1
        case .skipped:
            return 2
        }
    }

    static func targetMigrationOccurrenceDate(
        for task: TaskItem,
        executions: [TaskExecutionRecord],
        subtasks: [TaskSubitem],
        referenceDate: Date = .now
    ) -> Date {
        let today = day(for: referenceDate)
        let scheduledUpToToday = task.scheduledOccurrenceDates(upTo: referenceDate)
        if let firstPending = scheduledUpToToday.first(where: {
            !isOccurrenceCompleted(
                task: task,
                occurrenceDate: $0,
                executions: executions,
                subtasks: subtasks
            )
        }) {
            return firstPending
        }

        let calendar = Calendar.current
        if let lookahead = calendar.date(byAdding: .day, value: 7, to: today) {
            if let nextFuture = task.scheduledOccurrenceDates(upTo: lookahead).first(where: { $0 > today }) {
                return nextFuture
            }
        }

        return scheduledUpToToday.last ?? day(for: task.startDate)
    }

    static func migrateLegacySubtasksIfNeeded(in modelContext: ModelContext) {
        let allSubtasks = (try? modelContext.fetch(FetchDescriptor<TaskSubitem>())) ?? []
        let legacySubtasks = allSubtasks.filter { $0.taskExecutionID == nil }
        guard !legacySubtasks.isEmpty else { return }

        let tasks = (try? modelContext.fetch(FetchDescriptor<TaskItem>())) ?? []
        let allExecutions = (try? modelContext.fetch(FetchDescriptor<TaskExecutionRecord>())) ?? []
        let legacyExecutionRecords = (try? modelContext.fetch(FetchDescriptor<TaskSubitemExecutionRecord>())) ?? []

        let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let legacySubtasksByID = Dictionary(legacySubtasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let executionsByTask = Dictionary(grouping: allExecutions, by: \.taskID)

        var allKnownSubtasks = allSubtasks

        for legacyExecution in legacyExecutionRecords {
            guard
                let template = legacySubtasksByID[legacyExecution.subtaskID],
                let task = tasksByID[template.parentTaskID],
                let executionRecord = allExecutions.first(where: { $0.id == legacyExecution.taskExecutionID })
            else {
                continue
            }

            let exists = allKnownSubtasks.contains {
                $0.taskExecutionID == executionRecord.id &&
                $0.title == template.title &&
                $0.sortOrder == template.sortOrder
            }
            guard !exists else { continue }

            let migrated = TaskSubitem(
                parentTaskID: task.id,
                taskExecutionID: executionRecord.id,
                title: template.title,
                note: template.note,
                detail: legacyExecution.detail,
                status: legacyExecution.status,
                sortOrder: template.sortOrder,
                isArchived: false,
                completedAt: legacyExecution.completedAt,
                createdAt: legacyExecution.createdAt,
                updatedAt: legacyExecution.updatedAt
            )
            modelContext.insert(migrated)
            allKnownSubtasks.append(migrated)
        }

        let legacyTemplatesByTask = Dictionary(grouping: legacySubtasks, by: \.parentTaskID)
        var executionPool = allExecutions

        for (taskID, templates) in legacyTemplatesByTask {
            guard let task = tasksByID[taskID] else { continue }

            let targetDate = targetMigrationOccurrenceDate(
                for: task,
                executions: executionsByTask[taskID] ?? executionPool.filter { $0.taskID == taskID },
                subtasks: allKnownSubtasks
            )
            let executionRecord = ensureExecutionRecord(
                for: task,
                occurrenceDate: targetDate,
                existingExecutions: executionPool,
                modelContext: modelContext
            )
            if !executionPool.contains(where: { $0.id == executionRecord.id }) {
                executionPool.append(executionRecord)
            }

            for template in templates {
                let exists = allKnownSubtasks.contains {
                    $0.taskExecutionID == executionRecord.id &&
                    $0.title == template.title &&
                    $0.sortOrder == template.sortOrder
                }
                guard !exists else { continue }

                let migrated = TaskSubitem(
                    parentTaskID: task.id,
                    taskExecutionID: executionRecord.id,
                    title: template.title,
                    note: template.note,
                    detail: template.detail,
                    status: template.status,
                    sortOrder: template.sortOrder,
                    isArchived: false,
                    completedAt: template.completedAt,
                    createdAt: template.createdAt,
                    updatedAt: template.updatedAt
                )
                modelContext.insert(migrated)
                allKnownSubtasks.append(migrated)
            }
        }

        legacyExecutionRecords.forEach(modelContext.delete)
        legacySubtasks.forEach(modelContext.delete)

        if modelContext.hasChanges {
            try? modelContext.save()
        }
    }

    private static func sortSubtasks(_ lhs: TaskSubitem, _ rhs: TaskSubitem) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.sortOrder < rhs.sortOrder
    }

    private static func subtaskDeduplicationPreference(_ lhs: TaskSubitem, _ rhs: TaskSubitem) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func subtaskDeduplicationPreference(
        _ lhs: TaskSubitemProjection,
        _ rhs: TaskSubitemProjection
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func sortSubtasks(_ lhs: TaskSubitemProjection, _ rhs: TaskSubitemProjection) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.sortOrder < rhs.sortOrder
    }

    private static func recordHasDetail(_ record: TaskExecutionRecord?) -> Bool {
        record?.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func recordHasDetail(_ record: TaskExecutionRecordProjection?) -> Bool {
        record?.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func subtaskHasDetail(_ subtask: TaskSubitem) -> Bool {
        !subtask.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !subtask.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func subtaskHasDetail(_ subtask: TaskSubitemProjection) -> Bool {
        !subtask.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !subtask.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum TodayTaskListBuilder {
    static func build(
        from tasks: [TaskItem],
        completions: [TaskCompletion],
        on date: Date = .now
    ) -> [TodayTaskDisplayItem] {
        let migratedExecutions = completions.map { completion in
            TaskExecutionRecord(
                id: completion.id,
                taskID: completion.taskID,
                occurrenceDate: completion.completedDate,
                detail: "",
                status: .completed,
                completedAt: completion.completedAt,
                createdAt: completion.completedAt,
                updatedAt: completion.completedAt
            )
        }
        return build(
            from: tasks,
            executions: migratedExecutions,
            subtasks: [],
            subtaskExecutions: [],
            on: date
        )
    }

    static func build(
        from tasks: [TaskItem],
        executions: [TaskExecutionRecord],
        subtasks: [TaskSubitem],
        subtaskExecutions: [TaskSubitemExecutionRecord],
        on date: Date = .now
    ) -> [TodayTaskDisplayItem] {
        TaskExecutionSupport.buildTodayItems(
            from: tasks,
            executions: executions,
            subtasks: subtasks,
            subtaskExecutions: subtaskExecutions,
            on: date
        )
    }
}

enum TodayTaskProjectionBuilder {
    static func build(
        from tasks: [TaskProjection],
        executions: [TaskExecutionRecordProjection],
        subtasks: [TaskSubitemProjection],
        on date: Date = .now
    ) -> [TodayTaskProjectionResult] {
        let calendar = Calendar.current
        let today = Calendar.current.startOfDay(for: date)
        let lookaheadDay = calendar.date(byAdding: .day, value: 7, to: today) ?? today

        let executionsByTask = Dictionary(grouping: executions, by: \.taskID)
        let subtasksByTask = Dictionary(grouping: subtasks, by: \.parentTaskID)

        return tasks
            .filter { $0.timingMode == .scheduled }
            .flatMap { task -> [TodayTaskProjectionResult] in
            let snapshots = occurrenceSnapshots(
                for: task,
                executions: executionsByTask[task.id] ?? [],
                subtasks: subtasksByTask[task.id] ?? [],
                referenceDay: today,
                upTo: lookaheadDay
            )
            let historicalPendingCount = snapshots.filter {
                !$0.isCompleted && $0.occurrenceDate < today
            }.count
            let todayPendingCount = snapshots.filter {
                !$0.isCompleted && calendar.isDate($0.occurrenceDate, inSameDayAs: today)
            }.count
            let totalPendingOccurrenceCount = historicalPendingCount + todayPendingCount
            let upcomingPendingCount = snapshots.filter {
                !$0.isCompleted && $0.occurrenceDate > today
            }.count

            return snapshots.compactMap { snapshot in
                let section: TodayTaskDisplaySection
                if snapshot.isCompleted {
                    guard calendar.isDate(snapshot.occurrenceDate, inSameDayAs: today) else { return nil }
                    section = .todayDone
                } else if calendar.isDate(snapshot.occurrenceDate, inSameDayAs: today) {
                    section = .todayPending
                } else if snapshot.occurrenceDate > today {
                    section = .upcomingPending
                } else {
                    section = .historicalPending
                }

                let pendingCount: Int
                switch section {
                case .todayPending:
                    pendingCount = todayPendingCount
                case .historicalPending:
                    pendingCount = historicalPendingCount
                case .upcomingPending:
                    pendingCount = upcomingPendingCount
                case .todayDone:
                    pendingCount = 0
                }

                return TodayTaskProjectionResult(
                    taskID: task.id,
                    section: section,
                    occurrenceDate: snapshot.occurrenceDate,
                    isCompleted: snapshot.isCompleted,
                    pendingOccurrenceCount: pendingCount,
                    historicalPendingCount: historicalPendingCount,
                    totalPendingOccurrenceCount: totalPendingOccurrenceCount,
                    overdueOriginText: snapshot.overdueOriginText,
                    totalSubtaskCount: snapshot.totalSubtaskCount,
                    completedSubtaskCount: snapshot.completedSubtaskCount
                )
            }
        }
    }

    static func displayItems(
        from projections: [TodayTaskProjectionResult],
        tasksByID: [UUID: TaskItem]
    ) -> [TodayTaskDisplayItem] {
        projections.compactMap { projection in
            guard let task = tasksByID[projection.taskID] else { return nil }
            return TodayTaskDisplayItem(
                task: task,
                section: projection.section,
                occurrenceDate: projection.occurrenceDate,
                isCompleted: projection.isCompleted,
                pendingOccurrenceCount: projection.pendingOccurrenceCount,
                historicalPendingCount: projection.historicalPendingCount,
                totalPendingOccurrenceCount: projection.totalPendingOccurrenceCount,
                overdueOriginText: projection.overdueOriginText,
                totalSubtaskCount: projection.totalSubtaskCount,
                completedSubtaskCount: projection.completedSubtaskCount
            )
        }
    }

    private static func occurrenceSnapshots(
        for task: TaskProjection,
        executions: [TaskExecutionRecordProjection],
        subtasks: [TaskSubitemProjection],
        referenceDay: Date,
        upTo date: Date
    ) -> [ProjectedTaskOccurrenceSnapshot] {
        let calendar = Calendar.current
        let today = Calendar.current.startOfDay(for: referenceDay)
        let targetDate = Calendar.current.startOfDay(for: date)

        // 优化：使用字典分组，避免 O(N*M) 性能问题和属性读取阻塞
        let taskExecutions = executions.filter { $0.taskID == task.id }
        let executionsByDate = Dictionary(grouping: taskExecutions) { Calendar.current.startOfDay(for: $0.occurrenceDate) }

        let validSubtasks = TaskExecutionSupport.deduplicatedSubtasks(
            subtasks.filter {
                $0.parentTaskID == task.id &&
                $0.taskExecutionID != nil &&
                !$0.isArchived
            }
        )
        let subtasksByExecutionID = Dictionary(grouping: validSubtasks) { $0.taskExecutionID! }

        return task.scheduledOccurrenceDates(upTo: targetDate).compactMap { occurrenceDate in
            let dateKey = Calendar.current.startOfDay(for: occurrenceDate)
            let record = preferredExecutionRecord(in: executionsByDate[dateKey] ?? [])
            if record?.status == .skipped {
                return nil
            }
            
            let occurrenceSubtasks: [TaskSubitemProjection] = {
                guard let executionID = record?.id else { return [] }
                return (subtasksByExecutionID[executionID] ?? []).sorted(by: sortSubtasks)
            }()
            
            let completed: Bool
            if occurrenceSubtasks.isEmpty {
                completed = record?.status == .completed
            } else {
                completed = occurrenceSubtasks.allSatisfy { $0.status == .completed }
            }

            if !completed &&
                task.skipPolicy == .skippable &&
                !calendar.isDate(occurrenceDate, inSameDayAs: today) &&
                record == nil {
                return nil
            }

            let completedSubtasksCount = occurrenceSubtasks.filter { $0.status == .completed }.count

            let overdueOriginText: String? = {
                guard task.skipPolicy == .unskippable, occurrenceDate < today else { return nil }
                return task.originText(for: occurrenceDate, relativeTo: today)
            }()

            return ProjectedTaskOccurrenceSnapshot(
                taskID: task.id,
                createdAt: task.createdAt,
                occurrenceDate: occurrenceDate,
                isCompleted: completed,
                overdueOriginText: completed ? nil : overdueOriginText,
                totalSubtaskCount: occurrenceSubtasks.count,
                completedSubtaskCount: completedSubtasksCount
            )
        }
    }

    private static func executionRecord(
        for taskID: UUID,
        on occurrenceDate: Date,
        in executions: [TaskExecutionRecordProjection]
    ) -> TaskExecutionRecordProjection? {
        let targetDay = Calendar.current.startOfDay(for: occurrenceDate)
        let matchingRecords = executions.filter {
            $0.taskID == taskID && Calendar.current.isDate($0.occurrenceDate, inSameDayAs: targetDay)
        }
        return preferredExecutionRecord(in: matchingRecords)
    }

    private static func preferredExecutionRecord(
        in records: [TaskExecutionRecord]
    ) -> TaskExecutionRecord? {
        records.max { lhs, rhs in
            executionRecordSortKey(for: lhs) < executionRecordSortKey(for: rhs)
        }
    }

    private static func preferredExecutionRecord(
        in records: [TaskExecutionRecordProjection]
    ) -> TaskExecutionRecordProjection? {
        records.max { lhs, rhs in
            executionRecordSortKey(for: lhs) < executionRecordSortKey(for: rhs)
        }
    }

    private static func executionRecordSortKey(
        for record: TaskExecutionRecord
    ) -> (Int, Date, Date, UUID) {
        (
            executionStatusSortPriority(record.status),
            record.completedAt ?? .distantPast,
            record.updatedAt,
            record.id
        )
    }

    private static func executionRecordSortKey(
        for record: TaskExecutionRecordProjection
    ) -> (Int, Date, Date, UUID) {
        (
            executionStatusSortPriority(record.status),
            record.completedAt ?? .distantPast,
            record.updatedAt,
            record.id
        )
    }

    private static func executionStatusSortPriority(_ status: TaskExecutionStatus) -> Int {
        switch status {
        case .pending:
            return 0
        case .completed:
            return 1
        case .skipped:
            return 2
        }
    }

    private static func isOccurrenceCompleted(
        task: TaskProjection,
        occurrenceDate: Date,
        executions: [TaskExecutionRecordProjection],
        subtasks: [TaskSubitemProjection]
    ) -> Bool {
        let record = executionRecord(for: task.id, on: occurrenceDate, in: executions)
        let occurrenceSubtasks = executionSubtasks(for: record, in: subtasks)

        if occurrenceSubtasks.isEmpty {
            return record?.status == .completed
        }

        return occurrenceSubtasks.allSatisfy { $0.status == .completed }
    }

    private static func executionSubtasks(
        for executionRecord: TaskExecutionRecordProjection?,
        in subtasks: [TaskSubitemProjection]
    ) -> [TaskSubitemProjection] {
        guard let executionRecord else { return [] }
        return TaskExecutionSupport.deduplicatedSubtasks(
            subtasks.filter {
                $0.taskExecutionID == executionRecord.id &&
                !$0.isArchived
            }
        )
    }

    private static func subtaskProgress(
        for executionRecord: TaskExecutionRecordProjection?,
        in subtasks: [TaskSubitemProjection]
    ) -> (completed: Int, total: Int) {
        let executionSubtasks = executionSubtasks(for: executionRecord, in: subtasks)
        let completed = executionSubtasks.filter { $0.status == .completed }.count
        return (completed, executionSubtasks.count)
    }

    private static func sortSubtasks(_ lhs: TaskSubitemProjection, _ rhs: TaskSubitemProjection) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.sortOrder < rhs.sortOrder
    }
}

private struct ProjectedTaskOccurrenceSnapshot {
    let taskID: UUID
    let createdAt: Date
    let occurrenceDate: Date
    let isCompleted: Bool
    let overdueOriginText: String?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int
}
