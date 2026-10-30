import Foundation
import SwiftData

enum HomeDashboardDataLoader {
    static func load(
        from container: ModelContainer,
        referenceDate: Date
    ) -> HomeDashboardSourceSnapshot {
        PersistentStoreAccessGate.withAccess {
            let context = ModelContext(container)
            let calendar = Calendar.current
            let todayPlanKey = ReviewDailyPlan.dayKey(for: referenceDate, calendar: calendar)
            let weekInterval = calendar.dateInterval(of: .weekOfYear, for: referenceDate)
            let weekStart = weekInterval?.start ?? calendar.startOfDay(for: referenceDate)
            let weekEnd = weekInterval?.end
                ?? calendar.date(byAdding: .day, value: 7, to: weekStart)
                ?? referenceDate

            var source = HomeDashboardSourceSnapshot.empty
            try? context.transaction {
            let reviewItems = ((try? context.fetch(FetchDescriptor<ReviewItem>())) ?? [])
                .map(HomeReviewItemProjection.init)
            let weeklyReviewRecords = ReviewScheduler.canonicalReviewRecords(
                (try? context.fetch(
                    FetchDescriptor<ReviewRecord>(
                        predicate: #Predicate<ReviewRecord> {
                            $0.reviewedAt >= weekStart && $0.reviewedAt < weekEnd
                        }
                    )
                )) ?? []
            )
            let reviewRecords = weeklyReviewRecords
                .map(HomeReviewRecordProjection.init)
            let reviewDailyPlans = ((try? context.fetch(
                FetchDescriptor<ReviewDailyPlan>(
                    predicate: #Predicate<ReviewDailyPlan> { $0.dayKey == todayPlanKey }
                )
            )) ?? []).map(HomeReviewDailyPlanProjection.init)
            let dictationSessionModels = (try? context.fetch(FetchDescriptor<DictationSession>())) ?? []
            let dictationSessions = dictationSessionModels.map(HomeDictationSessionProjection.init)
            let dictationEntries = ((try? context.fetch(FetchDescriptor<DictationEntry>())) ?? [])
                .map(HomeDictationEntryProjection.init)
            let schedules = ((try? context.fetch(
                FetchDescriptor<ScheduleItem>(predicate: #Predicate<ScheduleItem> { !$0.isArchived })
            )) ?? []).map(HomeScheduleProjection.init)
            let tasks = ((try? context.fetch(FetchDescriptor<TaskItem>())) ?? [])
                .map(HomeTaskModelProjection.init)
            let taskExecutions = ((try? context.fetch(FetchDescriptor<TaskExecutionRecord>())) ?? [])
                .map(TaskExecutionRecordProjection.init)
            let taskSubtasks = ((try? context.fetch(
                FetchDescriptor<TaskSubitem>(predicate: #Predicate<TaskSubitem> { !$0.isArchived })
            )) ?? []).map(TaskSubitemProjection.init)
            let pointSummary = (try? loadPointSummary(from: context, referenceDate: referenceDate))
                ?? (balance: 0, earnedToday: 0)
            var rewardStateDescriptor = FetchDescriptor<PointRewardState>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            rewardStateDescriptor.fetchLimit = 1
            let rewardState = try? context.fetch(rewardStateDescriptor).first
            let currentPointStreak: Int
            if let rewardState, let lastActiveDay = rewardState.lastActiveDay {
                let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDate)
                let isCurrent = calendar.isDate(lastActiveDay, inSameDayAs: referenceDate)
                    || yesterday.map { calendar.isDate(lastActiveDay, inSameDayAs: $0) } == true
                currentPointStreak = isCurrent ? rewardState.currentStreak : 0
            } else {
                currentPointStreak = 0
            }

            source = HomeDashboardSourceSnapshot(
                reviewItems: reviewItems,
                reviewRecords: reviewRecords,
                reviewDailyPlans: reviewDailyPlans,
                dictationSessions: dictationSessions,
                dictationEntries: dictationEntries,
                schedules: schedules,
                tasks: tasks,
                taskExecutions: taskExecutions,
                taskSubtasks: taskSubtasks,
                pointBalance: pointSummary.balance,
                pointsEarnedToday: pointSummary.earnedToday,
                currentPointStreak: currentPointStreak
            )
            }
            return source
        }
    }

    static func loadPointSummary(
        from context: ModelContext,
        referenceDate: Date
    ) throws -> (balance: Int, earnedToday: Int) {
        // Keep value fields, not every SwiftData object and its duplicate group.
        // Batched enumeration bounds the number of materialized ledger models.
        var canonical: [String: (id: UUID, createdAt: Date, amount: Int)] = [:]
        var descriptor = FetchDescriptor<PointLedgerEntry>()
        descriptor.propertiesToFetch = [\.id, \.createdAt, \.amount, \.idempotencyKey]
        try context.enumerate(descriptor, batchSize: 256) { entry in
            let id = entry.id
            let createdAt = entry.createdAt
            let amount = entry.amount
            let idempotencyKey = entry.idempotencyKey
            let key = idempotencyKey.isEmpty ? "legacy-\(id.uuidString)" : idempotencyKey
            if let existing = canonical[key],
               existing.createdAt < createdAt
                || (existing.createdAt == createdAt && existing.id.uuidString <= id.uuidString) {
                return
            }
            canonical[key] = (id, createdAt, amount)
        }
        var balance = 0
        var earnedToday = 0
        let calendar = Calendar.current
        for entry in canonical.values {
            balance += entry.amount
            if entry.amount > 0, calendar.isDate(entry.createdAt, inSameDayAs: referenceDate) {
                earnedToday += entry.amount
            }
        }
        return (balance, earnedToday)
    }

}
