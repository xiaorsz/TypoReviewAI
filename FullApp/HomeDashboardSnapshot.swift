import SwiftUI

// 首页展示快照及统计计算；仅消费值类型，不访问数据库或页面状态。
struct HomeDashboardSnapshot {
    let childName: String
    let dueItems: [HomeReviewItemProjection]
    let allDueCount: Int
    let hasReachedDailyReviewLimit: Bool
    let dailyReviewPlanItemIDs: [UUID]
    let reviewPlanSource: String
    let reviewPlanRationale: String
    let masteredReviewCount: Int
    let todayCompletedCount: Int
    let todayWrongCount: Int
    let todayCorrectCount: Int
    let todayAccuracyText: String
    let todayDictationReviewedEntryCount: Int
    let dictationCompletedToday: Bool
    let hasDictationAwaitingReview: Bool
    let pendingDictationCount: Int
    let pendingDictationSessionCount: Int
    let latestDictationSession: HomeDictationSessionProjection?
    let latestDictationEntryCount: Int
    let dictationEntriesBySessionID: [UUID: [HomeDictationEntryProjection]]
    let todaySchedules: [HomeScheduleProjection]
    let todayPendingTasks: [HomeTaskDisplayItem]
    let historicalPendingTasks: [HomeTaskDisplayItem]
    let historicalPendingTaskCount: Int
    let todayCompletedTasks: [HomeTaskDisplayItem]
    let todayCompletedTaskCount: Int
    let totalPendingTaskCount: Int
    let recentPlans: [RecentPlanProjection]
    let calendarWeeks: [HomeCalendarWeekSummary]
    let activeTaskCount: Int
    let pointBalance: Int
    let pointsEarnedToday: Int
    let currentPointStreak: Int
    let wrongReviewSamples: [String]
    let heroSubtitle: String
    let heroGradientColors: [Color]

    var dueItemIDs: [UUID] {
        var seenIDs = Set<UUID>()
        return dueItems.compactMap { item in
            seenIDs.insert(item.id).inserted ? item.id : nil
        }
    }

    func dictationEntries(for session: HomeDictationSessionProjection) -> [HomeDictationEntryProjection] {
        dictationEntriesBySessionID[session.id] ?? []
    }

    static func make(
        childName: String,
        dailyLimit: Int,
        dailyPlanItemIDs: [UUID]?,
        reviewItems: [HomeReviewItemProjection],
        reviewRecords: [HomeReviewRecordProjection],
        dictationSessions: [HomeDictationSessionProjection],
        dictationEntries: [HomeDictationEntryProjection],
        schedules: [HomeScheduleProjection],
        taskItems: [HomeTaskDisplayItem],
        calendarTasks: [HomeCalendarTaskProjection],
        taskExecutions: [TaskExecutionRecordProjection],
        taskSubtasks: [TaskSubitemProjection],
        recentPlans: [RecentPlanProjection],
        activeTaskCount: Int,
        pointBalance: Int,
        pointsEarnedToday: Int,
        currentPointStreak: Int,
        referenceDate: Date = .now,
        isCoachSelection: Bool = false,
        reviewPlanRationale: String = "",
        reviewPlanStarted: Bool = false
    ) -> HomeDashboardSnapshot {
        let name = childName.isEmpty ? "小朋友" : childName
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: referenceDate)
        let reviewRecords = HomeReviewRecordProjection.canonicalRecords(reviewRecords)

        let canonicalReviewItems = canonicalItems(from: reviewItems)
        let todayRecs = reviewRecords.filter { calendar.isDate($0.reviewedAt, inSameDayAs: referenceDate) }
        let selection = DailyReviewPlanner.select(
            items: reviewItems, records: reviewRecords, sessions: dictationSessions, entries: dictationEntries,
            existingIDs: dailyPlanItemIDs ?? [], fixedSelection: isCoachSelection || reviewPlanStarted,
            dailyLimit: dailyLimit, on: referenceDate, calendar: calendar
        )
        let plannedItemIDs = selection.itemIDs
        let cappedDueContent = selection.pending
        let allDue = selection.allDueCount
        let hasReachedDailyReviewLimit = selection.completedCount >= max(dailyLimit, 0) && allDue > 0
        let masteredReviewCount = canonicalReviewItems.filter(\.isMastered).count

        let tCompleted = todayRecs.count
        let tWrong = todayRecs.filter { $0.result == .wrong }.count
        let tCorrect = todayRecs.filter { $0.result == .correct }.count
        let tAccuracy = tCompleted > 0 ? "\(Int((Double(tCorrect) / Double(tCompleted) * 100).rounded()))%" : "--"
        let reviewContentByID = Dictionary(
            reviewItems.map { ($0.id, $0.content) },
            uniquingKeysWith: { first, _ in first }
        )
        let wrongSamples = Array(
            todayRecs
                .filter { $0.result == .wrong }
                .compactMap { reviewContentByID[$0.itemID] }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(5)
        )
        let calendarWeeks = buildCalendarWeeks(
            tasks: calendarTasks,
            taskExecutions: taskExecutions,
            taskSubtasks: taskSubtasks,
            reviewRecords: reviewRecords,
            dictationSessions: dictationSessions,
            dictationEntries: dictationEntries,
            referenceDate: referenceDate,
            calendar: calendar
        )

        let pendingSessions = dictationSessions.filter {
            !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart
        }
        let pendingDictationSessionCount = pendingSessions.count
        let latestDS: HomeDictationSessionProjection? = {
            if let firstPending = pendingSessions.sorted(by: { $0.scheduledDate < $1.scheduledDate }).first {
                return firstPending
            }
            return dictationSessions.filter {
                calendar.startOfDay(for: $0.scheduledDate) <= todayStart
            }.min(by: { $0.scheduledDate > $1.scheduledDate })
        }()

        let entriesBySessionID = Dictionary(grouping: dictationEntries, by: \.sessionID)
            .mapValues { entries in entries.sorted { $0.sortOrder < $1.sortOrder } }
        let pendingSessionIDs = Set(pendingSessions.map(\.id))
        let latestSessionID = latestDS?.id
        let todayReviewedSessionIDs = Set(
            dictationSessions.compactMap { session -> UUID? in
                guard let reviewedAt = session.reviewedAt,
                      calendar.isDate(reviewedAt, inSameDayAs: referenceDate) else {
                    return nil
                }
                return session.id
            }
        )
        let dictationCompletedToday = !todayReviewedSessionIDs.isEmpty
        let hasDictationAwaitingReview = pendingSessions.contains(where: \.isFinished)
        var pendingDictationEntryCount = 0
        var latestDictationEntryCount = 0
        var todayDictationReviewedEntryCount = 0

        for entry in dictationEntries {
            if pendingSessionIDs.contains(entry.sessionID) {
                pendingDictationEntryCount += 1
            }
            if entry.sessionID == latestSessionID {
                latestDictationEntryCount += 1
            }
            if todayReviewedSessionIDs.contains(entry.sessionID), entry.result != .pending {
                todayDictationReviewedEntryCount += 1
            }
        }

        let sortedVisibleSchedules = schedules
            .filter { $0.shouldAppear(on: referenceDate) && !$0.hasEnded(on: referenceDate, reference: referenceDate) }
            .sorted { lhs, rhs in
                if lhs.startTimeMinutes != rhs.startTimeMinutes {
                    return lhs.startTimeMinutes < rhs.startTimeMinutes
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let tSchedules = ScheduleDedupSupport.deduplicated(sortedVisibleSchedules) { schedule in
            ScheduleDisplayIdentity(
                title: schedule.title,
                note: schedule.note,
                startTime: schedule.startTime,
                endTime: schedule.endTime,
                repeatRule: schedule.repeatRule,
                weekdays: schedule.weekdays,
                effectiveStartDate: schedule.effectiveStartDate,
                effectiveEndDate: schedule.effectiveEndDate,
                calendar: calendar
            )
        }

        let todayTaskItems = taskItems.filter { $0.section == .todayPending }
        let historicalTaskItems = taskItems.filter { $0.section == .historicalPending }
            .sorted { lhs, rhs in
                if lhs.occurrenceDate == rhs.occurrenceDate {
                    return lhs.task.createdAt < rhs.task.createdAt
                }
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
        let orderedTaskItems = todayTaskItems + historicalTaskItems + taskItems.filter { $0.section == .todayDone }
        let taskSections = TodayTaskSectionSnapshotBuilder.build(
            from: orderedTaskItems,
            taskID: { $0.task.id },
            section: { $0.section },
            collapseTodayDone: false
        )
        let tPendingTasks = taskSections.todayPendingItems
        let hPendingTasks = taskSections.historicalPendingItems
        let historicalPendingTaskCount = taskSections.historicalPendingTotalCount
        let tCompletedTasks = taskSections.todayDoneItems
        let tCompletedTaskCount = tCompletedTasks.count
        let totPendingTaskCount = todayTaskItems.count + historicalPendingTaskCount

        let tasksDone = totPendingTaskCount == 0 && (tCompletedTaskCount > 0 || activeTaskCount == 0)
        let reviewDone = cappedDueContent.isEmpty
        let dictationDone = latestDS?.isReviewed ?? true

        let hSubtitle: String = {
            if tasksDone && reviewDone && dictationDone { return "表现太棒了！录入新错题或休息一下吧。明天见！" }
            if let session = latestDS, !session.isReviewed {
                if session.isFinished {
                    return "今天听写已完成，快让家长点击「复习听写」吧！"
                }
                if pendingDictationEntryCount > 0 {
                    return "当前共有 \(pendingDictationEntryCount) 条待听写内容，先从「\(session.title)」开始。"
                }
                return "别忘了还有一场「\(session.title)」听写在进行中。"
            }
            if historicalPendingTaskCount > 0 && tPendingTasks.isEmpty {
                return "还有 \(historicalPendingTaskCount) 次历史待办，先清一清积压吧。"
            }
            if totPendingTaskCount > 0 && !cappedDueContent.isEmpty { return "先完成今天的任务，再做错题复习。加油！" }
            if totPendingTaskCount > 0 { return "先把今天的任务完成吧！" }
            if allDue > dailyLimit { return "今天共有 \(allDue) 项到期，推荐先练 \(dailyLimit) 项。" }
            return "孩子在纸上写，家长判定对错，同一题当天只练一次。"
        }()

        let hGradient: [Color] = {
            if tasksDone && reviewDone && dictationDone { return [.green.opacity(0.85), .mint.opacity(0.65)] }
            if totPendingTaskCount > 0 || !cappedDueContent.isEmpty || !(latestDS?.isReviewed ?? true) {
                if totPendingTaskCount > 0 && !cappedDueContent.isEmpty { return [.orange.opacity(0.95), .pink.opacity(0.78)] }
                return [.blue.opacity(0.8), .cyan.opacity(0.6)]
            }
            return [.blue.opacity(0.8), .cyan.opacity(0.6)]
        }()

        return HomeDashboardSnapshot(
            childName: name,
            dueItems: cappedDueContent,
            allDueCount: allDue,
            hasReachedDailyReviewLimit: hasReachedDailyReviewLimit,
            dailyReviewPlanItemIDs: plannedItemIDs,
            reviewPlanSource: isCoachSelection ? "AI 复习安排" : "规则复习安排",
            reviewPlanRationale: isCoachSelection ? reviewPlanRationale : "按原有复习间隔安排到期内容；听写录入独立，当天已判定内容不重复复习。",
            masteredReviewCount: masteredReviewCount,
            todayCompletedCount: tCompleted,
            todayWrongCount: tWrong,
            todayCorrectCount: tCorrect,
            todayAccuracyText: tAccuracy,
            todayDictationReviewedEntryCount: todayDictationReviewedEntryCount,
            dictationCompletedToday: dictationCompletedToday,
            hasDictationAwaitingReview: hasDictationAwaitingReview,
            pendingDictationCount: pendingDictationEntryCount,
            pendingDictationSessionCount: pendingDictationSessionCount,
            latestDictationSession: latestDS,
            latestDictationEntryCount: latestDictationEntryCount,
            dictationEntriesBySessionID: entriesBySessionID,
            todaySchedules: tSchedules,
            todayPendingTasks: tPendingTasks,
            historicalPendingTasks: hPendingTasks,
            historicalPendingTaskCount: historicalPendingTaskCount,
            todayCompletedTasks: tCompletedTasks,
            todayCompletedTaskCount: tCompletedTaskCount,
            totalPendingTaskCount: totPendingTaskCount,
            recentPlans: recentPlans,
            calendarWeeks: calendarWeeks,
            activeTaskCount: activeTaskCount,
            pointBalance: pointBalance,
            pointsEarnedToday: pointsEarnedToday,
            currentPointStreak: currentPointStreak,
            wrongReviewSamples: wrongSamples,
            heroSubtitle: hSubtitle,
            heroGradientColors: hGradient
        )
    }

    static func canonicalItems(from items: [HomeReviewItemProjection]) -> [HomeReviewItemProjection] {
        var canonicalByKey: [String: HomeReviewItemProjection] = [:]

        for item in items {
            guard !ReviewContentIdentity.normalizedContent(item.content, type: item.type).isEmpty else { continue }
            if let current = canonicalByKey[item.contentIdentityKey] {
                if isPreferred(item, over: current) {
                    canonicalByKey[item.contentIdentityKey] = item
                }
            } else {
                canonicalByKey[item.contentIdentityKey] = item
            }
        }

        return Array(canonicalByKey.values)
    }

    private static func isPreferred(_ candidate: HomeReviewItemProjection, over current: HomeReviewItemProjection) -> Bool {
        let candidateFinished = candidate.nextReviewAt == .distantFuture
        let currentFinished = current.nextReviewAt == .distantFuture
        if candidateFinished != currentFinished {
            return candidateFinished
        }
        if candidate.stage != current.stage {
            return candidate.stage > current.stage
        }
        if candidate.consecutiveWrongCount != current.consecutiveWrongCount {
            return candidate.consecutiveWrongCount < current.consecutiveWrongCount
        }
        if candidate.nextReviewAt != current.nextReviewAt {
            return candidate.nextReviewAt > current.nextReviewAt
        }
        if candidate.createdAt != current.createdAt {
            return candidate.createdAt < current.createdAt
        }
        return candidate.id.uuidString < current.id.uuidString
    }

    private static func buildCalendarWeeks(
        tasks: [HomeCalendarTaskProjection],
        taskExecutions: [TaskExecutionRecordProjection],
        taskSubtasks: [TaskSubitemProjection],
        reviewRecords: [HomeReviewRecordProjection],
        dictationSessions: [HomeDictationSessionProjection],
        dictationEntries: [HomeDictationEntryProjection],
        referenceDate: Date,
        calendar: Calendar
    ) -> [HomeCalendarWeekSummary] {
        let today = calendar.startOfDay(for: referenceDate)
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return [
            HomeCalendarWeekSummary(
                title: "本周",
                days: buildCalendarDays(
                    startingAt: currentWeekStart,
                    tasks: tasks,
                    taskExecutions: taskExecutions,
                    taskSubtasks: taskSubtasks,
                    reviewRecords: reviewRecords,
                    dictationSessions: dictationSessions,
                    dictationEntries: dictationEntries,
                    today: today,
                    calendar: calendar
                )
            )
        ]
    }

    private static func buildCalendarDays(
        startingAt weekStart: Date,
        tasks: [HomeCalendarTaskProjection],
        taskExecutions: [TaskExecutionRecordProjection],
        taskSubtasks: [TaskSubitemProjection],
        reviewRecords: [HomeReviewRecordProjection],
        dictationSessions: [HomeDictationSessionProjection],
        dictationEntries: [HomeDictationEntryProjection],
        today: Date,
        calendar: Calendar
    ) -> [HomeCalendarDaySummary] {
        let executionsByTask = Dictionary(grouping: taskExecutions, by: \.taskID)
        let subtasksByExecutionID = Dictionary(
            grouping: taskSubtasks.filter { !$0.isArchived && $0.taskExecutionID != nil },
            by: { $0.taskExecutionID! }
        )

        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            let day = calendar.startOfDay(for: date)
            let taskCounts = taskCompletionCounts(
                on: day,
                tasks: tasks,
                executionsByTask: executionsByTask,
                subtasksByExecutionID: subtasksByExecutionID,
                calendar: calendar
            )
            let reviewCount = reviewRecords.filter {
                calendar.isDate($0.reviewedAt, inSameDayAs: day)
            }.count
            let reviewedSessionIDs = Set(
                dictationSessions.compactMap { session -> UUID? in
                    guard let reviewedAt = session.reviewedAt,
                          calendar.isDate(reviewedAt, inSameDayAs: day) else {
                        return nil
                    }
                    return session.id
                }
            )
            let dictationReviewedCount = dictationEntries.filter {
                reviewedSessionIDs.contains($0.sessionID)
            }.count

            return HomeCalendarDaySummary(
                date: day,
                taskCompletedCount: taskCounts.completed,
                taskTotalCount: taskCounts.total,
                reviewCompletedCount: reviewCount,
                dictationReviewedCount: dictationReviewedCount,
                isToday: calendar.isDate(day, inSameDayAs: today)
            )
        }
    }

    private static func taskCompletionCounts(
        on day: Date,
        tasks: [HomeCalendarTaskProjection],
        executionsByTask: [UUID: [TaskExecutionRecordProjection]],
        subtasksByExecutionID: [UUID: [TaskSubitemProjection]],
        calendar: Calendar
    ) -> (completed: Int, total: Int) {
        var completed = 0
        var total = 0

        for calendarTask in tasks {
            let occurrenceDay = calendar.startOfDay(for: day)
            guard taskOccurs(calendarTask.task, on: occurrenceDay, calendar: calendar) else { continue }

            let execution = preferredExecutionRecord(
                for: calendarTask.task.id,
                on: occurrenceDay,
                in: executionsByTask[calendarTask.task.id] ?? [],
                calendar: calendar
            )
            guard !calendarTask.isArchived || execution != nil else { continue }

            total += 1
            if isTaskCompleted(execution: execution, subtasksByExecutionID: subtasksByExecutionID) {
                completed += 1
            }
        }

        return (completed, total)
    }

    private static func taskOccurs(
        _ task: TaskProjection,
        on day: Date,
        calendar: Calendar
    ) -> Bool {
        task.occurs(on: day, calendar: calendar)
    }

    private static func preferredExecutionRecord(
        for taskID: UUID,
        on day: Date,
        in records: [TaskExecutionRecordProjection],
        calendar: Calendar
    ) -> TaskExecutionRecordProjection? {
        records
            .filter { $0.taskID == taskID && calendar.isDate($0.occurrenceDate, inSameDayAs: day) }
            .max { lhs, rhs in
                executionRecordSortKey(for: lhs) < executionRecordSortKey(for: rhs)
            }
    }

    private static func isTaskCompleted(
        execution: TaskExecutionRecordProjection?,
        subtasksByExecutionID: [UUID: [TaskSubitemProjection]]
    ) -> Bool {
        guard let execution else { return false }
        let subtasks = subtasksByExecutionID[execution.id] ?? []

        if subtasks.isEmpty {
            return execution.status == .completed
        }

        return subtasks.allSatisfy { $0.status == .completed }
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
}

