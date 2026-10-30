import Foundation

// 首页使用的值类型投影与学习状态，独立于页面生命周期。
enum HomeLearningStatusTone: Equatable {
    case completed
    case pending
    case notRequired
}

struct HomeLearningStatus: Equatable {
    let tone: HomeLearningStatusTone
    let text: String
    let detail: String
}

enum HomeLearningStatusSupport {
    static func task(
        pendingCount: Int,
        historicalPendingCount: Int,
        completedTodayCount: Int
    ) -> HomeLearningStatus {
        if pendingCount > 0 {
            let detail = historicalPendingCount > 0
                ? "待\(pendingCount)项 · 历\(historicalPendingCount)"
                : "待\(pendingCount)项"
            return HomeLearningStatus(tone: .pending, text: "未完成", detail: detail)
        }
        if completedTodayCount > 0 {
            return HomeLearningStatus(
                tone: .completed,
                text: "已完成",
                detail: "完成\(completedTodayCount)项"
            )
        }
        return HomeLearningStatus(tone: .notRequired, text: "无任务", detail: "今日无需")
    }

    static func review(pendingCount: Int, plannedCount: Int) -> HomeLearningStatus {
        if pendingCount > 0 {
            return HomeLearningStatus(tone: .pending, text: "未完成", detail: "待\(pendingCount)项")
        }
        if plannedCount > 0 {
            return HomeLearningStatus(
                tone: .completed,
                text: "已完成",
                detail: "完成\(plannedCount)项"
            )
        }
        return HomeLearningStatus(tone: .notRequired, text: "无复习", detail: "今日无需")
    }

    static func dictation(
        pendingSessionCount: Int,
        pendingEntryCount: Int,
        hasAwaitingReview: Bool,
        completedToday: Bool,
        reviewedEntryCount: Int
    ) -> HomeLearningStatus {
        if pendingSessionCount > 0 {
            if hasAwaitingReview {
                return HomeLearningStatus(
                    tone: .pending,
                    text: "待批改",
                    detail: pendingSessionCount > 1 ? "待\(pendingSessionCount)组" : "听写已提交"
                )
            }
            return HomeLearningStatus(
                tone: .pending,
                text: "未完成",
                detail: pendingEntryCount > 0 ? "待\(pendingEntryCount)条" : "待\(pendingSessionCount)组"
            )
        }
        if completedToday {
            return HomeLearningStatus(
                tone: .completed,
                text: "已完成",
                detail: reviewedEntryCount > 0 ? "批改\(reviewedEntryCount)条" : "已批改"
            )
        }
        return HomeLearningStatus(tone: .notRequired, text: "无听写", detail: "今日无需")
    }

    static func calculation(completed: Bool, submittedRoundCount: Int) -> HomeLearningStatus {
        if completed {
            return HomeLearningStatus(
                tone: .completed,
                text: "已完成",
                detail: submittedRoundCount > 0 ? "共\(submittedRoundCount)轮" : "全部正确"
            )
        }
        return HomeLearningStatus(
            tone: .pending,
            text: "未完成",
            detail: submittedRoundCount > 0 ? "第\(submittedRoundCount + 1)轮补练" : "首轮5题"
        )
    }
}

struct HomeReviewItemProjection: Identifiable, Hashable {
    let id: UUID
    let type: ReviewItemType
    let content: String
    let prompt: String
    let stage: Int
    let createdAt: Date
    let nextReviewAt: Date
    let consecutiveWrongCount: Int

    init(_ item: ReviewItem) {
        id = item.id
        type = item.type
        content = item.content
        prompt = item.prompt
        stage = item.stage
        createdAt = item.createdAt
        nextReviewAt = item.nextReviewAt
        consecutiveWrongCount = item.consecutiveWrongCount
    }

    var isMastered: Bool {
        ReviewScheduler.isMastered(stage: stage, consecutiveWrongCount: consecutiveWrongCount)
            && nextReviewAt == .distantFuture
    }

    var contentIdentityKey: String {
        ReviewContentIdentity.key(type: type, content: content)
    }
}

struct HomeReviewRecordProjection {
    let id: UUID
    let itemID: UUID
    let reviewedAt: Date
    let result: ReviewResult
    let mode: ReviewMode
    let oldStage: Int
    let newStage: Int

    init(_ record: ReviewRecord) {
        id = record.id
        itemID = record.itemID
        reviewedAt = record.reviewedAt
        result = record.result
        mode = record.mode
        oldStage = record.oldStage
        newStage = record.newStage
    }

    static func canonicalRecords(_ records: [HomeReviewRecordProjection]) -> [HomeReviewRecordProjection] {
        Dictionary(grouping: records, by: \.itemID).values
            .flatMap { itemRecords -> [HomeReviewRecordProjection] in
                let ordered = itemRecords.sorted {
                    if $0.reviewedAt != $1.reviewedAt {
                        return $0.reviewedAt < $1.reviewedAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
                var seenCycleIDs = Set<UUID>()
                var resolvedStage: Int?
                var result: [HomeReviewRecordProjection] = []

                for record in ordered {
                    guard seenCycleIDs.insert(record.id).inserted else { continue }
                    if let resolvedStage,
                       record.result == .correct,
                       record.oldStage < resolvedStage,
                       record.newStage <= resolvedStage {
                        continue
                    }
                    result.append(record)
                    resolvedStage = record.newStage
                }
                return result
            }
    }
}

struct HomeReviewDailyPlanProjection: Sendable {
    let id: UUID
    let dayKey: String
    let itemIDs: [UUID]
    let createdAt: Date
    let isCoachSelection: Bool
    let coachRationale: String
    let updatedAt: Date
    let startedAt: Date?

    init(_ plan: ReviewDailyPlan) {
        id = plan.id
        dayKey = plan.dayKey
        itemIDs = plan.itemIDs
        createdAt = plan.createdAt
        isCoachSelection = plan.isCoachSelection
        coachRationale = plan.coachRationale
        updatedAt = plan.updatedAt
        startedAt = plan.startedAt
    }
    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if (lhs.startedAt != nil) != (rhs.startedAt != nil) { return lhs.startedAt != nil }
        if lhs.isCoachSelection != rhs.isCoachSelection { return lhs.isCoachSelection }
        if lhs.isCoachSelection && lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

}

struct HomeDictationSessionProjection: Identifiable, Hashable {
    let id: UUID
    let title: String
    let type: ReviewItemType
    let createdAt: Date
    let scheduledDate: Date
    let finishedAt: Date?
    let reviewedAt: Date?
    let currentEntryIndex: Int

    init(_ session: DictationSession) {
        id = session.id
        title = session.title
        type = session.type
        createdAt = session.createdAt
        scheduledDate = session.scheduledDate
        finishedAt = session.finishedAt
        reviewedAt = session.reviewedAt
        currentEntryIndex = session.currentEntryIndex
    }

    var isFinished: Bool { finishedAt != nil }
    var isReviewed: Bool { reviewedAt != nil }
}

struct HomeDictationEntryProjection: Identifiable, Hashable {
    let id: UUID
    let sessionID: UUID
    let sortOrder: Int
    let type: ReviewItemType
    let content: String
    let prompt: String
    let result: DictationResult

    init(_ entry: DictationEntry) {
        id = entry.id
        sessionID = entry.sessionID
        sortOrder = entry.sortOrder
        type = entry.type
        content = entry.content
        prompt = entry.prompt
        result = entry.result
    }
}

struct HomeScheduleProjection: Identifiable, Hashable {
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

    func hasEnded(on date: Date, reference: Date = .now) -> Bool {
        reference > endDateTime(on: date)
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
            let days = weekdays.sorted().compactMap { wd -> String? in
                guard wd >= 1, wd <= 7 else { return nil }
                return "周\(names[wd - 1])"
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

    private func endDateTime(on date: Date) -> Date {
        guard repeatRule != .once else { return endTime }

        let endComponents = Calendar.current.dateComponents([.hour, .minute], from: endTime)
        return Calendar.current.date(
            bySettingHour: endComponents.hour ?? 0,
            minute: endComponents.minute ?? 0,
            second: 0,
            of: date
        ) ?? endTime
    }
}

struct HomeTaskDisplayItem: Identifiable {
    let task: TaskProjection
    let section: TodayTaskDisplaySection
    let occurrenceDate: Date
    let isCompleted: Bool
    let pendingOccurrenceCount: Int
    let historicalPendingCount: Int
    let totalPendingOccurrenceCount: Int
    let overdueOriginText: String?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int

    init(task: TaskProjection, projection: TodayTaskProjectionResult) {
        self.task = task
        section = projection.section
        occurrenceDate = projection.occurrenceDate
        isCompleted = projection.isCompleted
        pendingOccurrenceCount = projection.pendingOccurrenceCount
        historicalPendingCount = projection.historicalPendingCount
        totalPendingOccurrenceCount = projection.totalPendingOccurrenceCount
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
        historicalPendingCount: Int,
        totalPendingOccurrenceCount: Int,
        overdueOriginText: String?,
        totalSubtaskCount: Int,
        completedSubtaskCount: Int
    ) {
        self.task = task
        self.section = section
        self.occurrenceDate = occurrenceDate
        self.isCompleted = isCompleted
        self.pendingOccurrenceCount = pendingOccurrenceCount
        self.historicalPendingCount = historicalPendingCount
        self.totalPendingOccurrenceCount = totalPendingOccurrenceCount
        self.overdueOriginText = overdueOriginText
        self.totalSubtaskCount = totalSubtaskCount
        self.completedSubtaskCount = completedSubtaskCount
    }

    var id: String {
        "\(task.id.uuidString)-\(occurrenceDate.timeIntervalSince1970)"
    }

    var hasSubtasks: Bool { totalSubtaskCount > 0 }

    var simpleProgressText: String? {
        guard hasSubtasks else { return nil }
        return "\(completedSubtaskCount)/\(totalSubtaskCount)"
    }
}

struct HomeCalendarTaskProjection: Sendable {
    let task: TaskProjection
    let isArchived: Bool

    init(_ task: HomeTaskModelProjection) {
        self.task = task.task
        self.isArchived = task.isArchived
    }
}

struct HomeTaskModelProjection: Sendable {
    let task: TaskProjection
    let isArchived: Bool
    let updatedAt: Date

    init(_ task: TaskItem) {
        self.task = TaskProjection(task)
        isArchived = task.isArchived
        updatedAt = task.updatedAt
    }
}

struct HomeDashboardSourceSnapshot {
    let reviewItems: [HomeReviewItemProjection]
    let reviewRecords: [HomeReviewRecordProjection]
    let reviewDailyPlans: [HomeReviewDailyPlanProjection]
    let dictationSessions: [HomeDictationSessionProjection]
    let dictationEntries: [HomeDictationEntryProjection]
    let schedules: [HomeScheduleProjection]
    let tasks: [HomeTaskModelProjection]
    let taskExecutions: [TaskExecutionRecordProjection]
    let taskSubtasks: [TaskSubitemProjection]
    let pointBalance: Int
    let pointsEarnedToday: Int
    let currentPointStreak: Int

    static let empty = HomeDashboardSourceSnapshot(
        reviewItems: [],
        reviewRecords: [],
        reviewDailyPlans: [],
        dictationSessions: [],
        dictationEntries: [],
        schedules: [],
        tasks: [],
        taskExecutions: [],
        taskSubtasks: [],
        pointBalance: 0,
        pointsEarnedToday: 0,
        currentPointStreak: 0
    )
}

struct HomeCalendarWeekSummary: Identifiable, Hashable {
    let title: String
    let days: [HomeCalendarDaySummary]

    var id: String { title }
}

struct HomeCalendarDaySummary: Identifiable, Hashable {
    let date: Date
    let taskCompletedCount: Int
    let taskTotalCount: Int
    let reviewCompletedCount: Int
    let dictationReviewedCount: Int
    let isToday: Bool

    var id: TimeInterval { date.timeIntervalSinceReferenceDate }
    var hasIncompleteTasks: Bool { taskCompletedCount < taskTotalCount }
    var hasTasks: Bool { taskTotalCount > 0 }
    var hasActivity: Bool {
        hasTasks || reviewCompletedCount > 0 || dictationReviewedCount > 0
    }
}

