import Foundation
import SwiftData

// 负责加载首页数据、构建展示快照并保存每日复习计划。
// 页面保留取消、刷新合并和状态发布，数据库访问仍受同一访问锁保护。
enum HomeDashboardSnapshotLoader {
    static func load(
        from container: ModelContainer,
        childName: String,
        dailyLimit: Int,
        referenceDate: Date
    ) -> HomeDashboardSnapshot {
        PersistentStoreAccessGate.withAccess {
            let calendar = Calendar.current

            // SwiftData models can be invalidated by a concurrent delete or CloudKit merge.
            // Materialize every model into an immutable value while the read transaction is active,
            // then perform the relatively expensive dashboard calculations using values only.
            let source = HomeDashboardDataLoader.load(
                from: container,
                referenceDate: referenceDate
            )
            let backgroundContext = ModelContext(container)

            let autoArchivedCompletedAtByTaskID = Dictionary(
                source.taskExecutions.compactMap { record -> (UUID, Date)? in
                    guard record.status == .completed,
                          let completedAt = record.completedAt,
                          calendar.isDate(completedAt, inSameDayAs: referenceDate) else {
                        return nil
                    }
                    return (record.taskID, completedAt)
                },
                uniquingKeysWith: max
            )
            let visibleTaskModels = source.tasks.filter { task in
                guard task.isArchived else { return true }
                guard task.task.recurrence.kind == .once,
                      let completedAt = autoArchivedCompletedAtByTaskID[task.task.id] else {
                    return false
                }
                return task.updatedAt <= completedAt
            }
            let deduplicatedTaskModels = deduplicatedHomeTasks(source.tasks)
            let deduplicatedVisibleTaskModels = deduplicatedHomeTasks(visibleTaskModels)
            let activeTaskModels = deduplicatedTaskModels.filter {
                !$0.isArchived && $0.task.timingMode == .scheduled
            }

            let taskProjections = deduplicatedVisibleTaskModels.map(\.task)
            let taskExecutionProjections = source.taskExecutions
            let taskSubitemProjections = source.taskSubtasks
            let taskProjectionResults = TodayTaskProjectionBuilder.build(
                from: taskProjections,
                executions: taskExecutionProjections,
                subtasks: taskSubitemProjections,
                on: referenceDate
            )
            let tasksByID = Dictionary(
                taskProjections.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let taskDisplayItems = TaskDedupSupport.deduplicatedDisplayItems(
                taskProjectionResults.compactMap { result -> HomeTaskDisplayItem? in
                    guard let task = tasksByID[result.taskID] else { return nil }
                    return HomeTaskDisplayItem(task: task, projection: result)
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
            let recentPlans = RecentPlanSupport.visibleProjections(
                from: deduplicatedTaskModels.map(\.task),
                executions: taskExecutionProjections,
                subtasks: taskSubitemProjections,
                on: referenceDate,
                includeCompletedToday: true,
                calendar: calendar
            )

            #if DEBUG
            let todayPendingSummaries = taskDisplayItems
                .filter { $0.section == .todayPending }
                .map { "\($0.task.title)#\($0.task.id.uuidString.prefix(6))@\($0.occurrenceDate.formatted(.dateTime.month().day()))" }
                .joined(separator: ",")
            let todayDoneSummaries = taskDisplayItems
                .filter { $0.section == .todayDone }
                .map { "\($0.task.title)#\($0.task.id.uuidString.prefix(6))@\($0.occurrenceDate.formatted(.dateTime.month().day()))" }
                .joined(separator: ",")
            DebugPerf.mark("HomeView background snapshot fetch end reviews=\(source.reviewItems.count) records=\(source.reviewRecords.count) sessions=\(source.dictationSessions.count) entries=\(source.dictationEntries.count) schedules=\(source.schedules.count) tasks=\(deduplicatedVisibleTaskModels.count) todayPending=\(todayPendingSummaries) todayDone=\(todayDoneSummaries)")
            #endif

            let todayPlanKey = ReviewDailyPlan.dayKey(for: referenceDate, calendar: calendar)
            let existingDailyPlan = source.reviewDailyPlans
                .filter { $0.dayKey == todayPlanKey }
                .min(by: HomeReviewDailyPlanProjection.precedes)
            let snapshot = HomeDashboardSnapshot.make(
                childName: childName,
                dailyLimit: dailyLimit,
                dailyPlanItemIDs: existingDailyPlan?.itemIDs,
                reviewItems: source.reviewItems,
                reviewRecords: source.reviewRecords,
                dictationSessions: source.dictationSessions,
                dictationEntries: source.dictationEntries,
                schedules: source.schedules,
                taskItems: taskDisplayItems,
                calendarTasks: deduplicatedTaskModels.map(HomeCalendarTaskProjection.init),
                taskExecutions: taskExecutionProjections,
                taskSubtasks: taskSubitemProjections,
                recentPlans: recentPlans,
                activeTaskCount: activeTaskModels.count,
                pointBalance: source.pointBalance,
                pointsEarnedToday: source.pointsEarnedToday,
                currentPointStreak: source.currentPointStreak,
                referenceDate: referenceDate,
                isCoachSelection: existingDailyPlan?.isCoachSelection ?? false,
                reviewPlanRationale: existingDailyPlan?.coachRationale ?? "",
                reviewPlanStarted: existingDailyPlan?.startedAt != nil
            )

            if let existingDailyPlan,
               existingDailyPlan.itemIDs != snapshot.dailyReviewPlanItemIDs {
                let planID = existingDailyPlan.id
                let descriptor = FetchDescriptor<ReviewDailyPlan>(
                    predicate: #Predicate<ReviewDailyPlan> { $0.id == planID }
                )
                if let storedPlan = try? backgroundContext.fetch(descriptor).first,
                   storedPlan.itemIDs == existingDailyPlan.itemIDs,
                   storedPlan.coachRationale == existingDailyPlan.coachRationale,
                   storedPlan.startedAt == existingDailyPlan.startedAt {
                    storedPlan.itemIDs = snapshot.dailyReviewPlanItemIDs
                    try? backgroundContext.save()
                }
            } else if existingDailyPlan == nil, !snapshot.dailyReviewPlanItemIDs.isEmpty {
                backgroundContext.insert(
                    ReviewDailyPlan(
                        dayKey: todayPlanKey,
                        itemIDs: snapshot.dailyReviewPlanItemIDs,
                        createdAt: referenceDate,
                        updatedAt: referenceDate
                    )
                )
                try? backgroundContext.save()
            }

            return snapshot
        }
    }

    private static func deduplicatedHomeTasks(_ tasks: [HomeTaskModelProjection]) -> [HomeTaskModelProjection] {
        var preferredTaskByKey: [String: HomeTaskModelProjection] = [:]
        var keyOrder: [String] = []

        for task in tasks {
            let normalizedTitle = task.task.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            let key = normalizedTitle.isEmpty
                ? "id:\(task.task.id.uuidString.lowercased())"
                : "title:\(normalizedTitle)"
            let sortKey = TaskModelDedupSortKey(
                archivedPriority: task.isArchived ? 0 : 1,
                updatedAt: task.updatedAt,
                createdAt: task.task.createdAt,
                stableID: task.task.id.uuidString
            )

            if let current = preferredTaskByKey[key] {
                let currentSortKey = TaskModelDedupSortKey(
                    archivedPriority: current.isArchived ? 0 : 1,
                    updatedAt: current.updatedAt,
                    createdAt: current.task.createdAt,
                    stableID: current.task.id.uuidString
                )
                if currentSortKey < sortKey {
                    preferredTaskByKey[key] = task
                }
            } else {
                preferredTaskByKey[key] = task
                keyOrder.append(key)
            }
        }

        return keyOrder.compactMap { preferredTaskByKey[$0] }
    }

}
