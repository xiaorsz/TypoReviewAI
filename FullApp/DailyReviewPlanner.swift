import Foundation
import SwiftData
import CoachCore

/// One selection policy for the home page, the board and AI writes. Dictation is
/// an independent input flow: its answers exclude same-day reviews, not quota.
enum DailyReviewPlanner {
    struct Selection {
        let itemIDs: [UUID]
        let pending: [HomeReviewItemProjection]
        let allDueCount: Int
        let completedCount: Int
    }

    static func select(
        items: [HomeReviewItemProjection], records: [HomeReviewRecordProjection],
        sessions: [HomeDictationSessionProjection] = [], entries: [HomeDictationEntryProjection] = [],
        existingIDs: [UUID] = [], fixedSelection: Bool = false,
        dailyLimit: Int, on date: Date, calendar: Calendar = .current
    ) -> Selection {
        let canonical = HomeDashboardSnapshot.canonicalItems(from: items)
        let byID = Dictionary(items.map { ($0.id, $0.contentIdentityKey) }, uniquingKeysWith: { first, _ in first })
        let canonicalByKey = Dictionary(canonical.map { ($0.contentIdentityKey, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ id: UUID) -> String { byID[id] ?? "deleted:\(id.uuidString)" }
        let todayRecords = HomeReviewRecordProjection.canonicalRecords(records)
            .filter { calendar.isDate($0.reviewedAt, inSameDayAs: date) }
            .sorted { $0.reviewedAt == $1.reviewedAt ? $0.id.uuidString < $1.id.uuidString : $0.reviewedAt < $1.reviewedAt }
        var completedKeys = Set<String>()
        let completedIDs = todayRecords.filter { $0.mode != .dictation }.compactMap { record -> UUID? in
            guard completedKeys.insert(key(record.itemID)).inserted else { return nil }
            return canonicalByKey[key(record.itemID)]?.id ?? record.itemID
        }
        var dictatedKeys = Set(todayRecords.filter { $0.mode == .dictation }.map { key($0.itemID) })
        let reviewedSessionIDs = Set(sessions.filter {
            $0.reviewedAt.map { calendar.isDate($0, inSameDayAs: date) } == true
        }.map(\.id))
        for entry in entries where reviewedSessionIDs.contains(entry.sessionID) && entry.result != .pending {
            dictatedKeys.insert(ReviewContentIdentity.key(type: entry.type, content: entry.content))
        }
        let due = canonical.filter {
            ReviewScheduler.isDue($0.nextReviewAt, on: date, calendar: calendar)
                && !completedKeys.contains($0.contentIdentityKey) && !dictatedKeys.contains($0.contentIdentityKey)
        }.sorted {
            let lhs = ReviewScheduler.normalizedReviewDate($0.nextReviewAt, calendar: calendar)
            let rhs = ReviewScheduler.normalizedReviewDate($1.nextReviewAt, calendar: calendar)
            if lhs != rhs { return lhs < rhs }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let dueByID = Dictionary(due.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let target = max(max(dailyLimit, 0), completedIDs.count)
        var result = completedIDs
        var seen = Set(result)
        let existing = existingIDs.compactMap { canonicalByKey[key($0)]?.id }
        for id in existing + (fixedSelection ? [] : due.map(\.id)) {
            guard result.count < target else { break }
            if dueByID[id] != nil && seen.insert(id).inserted { result.append(id) }
        }
        return Selection(itemIDs: result, pending: result.compactMap { dueByID[$0] },
            allDueCount: due.count, completedCount: completedIDs.count)
    }

    @MainActor static func apply(
        itemIDs: [UUID], subject: CoachCore.Subject, rationale: String, date: Date,
        dailyLimit: Int, in context: ModelContext
    ) throws {
        try PersistentStoreAccessGate.withAccess {
            let dayKey = ReviewDailyPlan.dayKey(for: date)
            let plans = try context.fetch(FetchDescriptor<ReviewDailyPlan>()).filter { $0.dayKey == dayKey }
            // A second physical cloud row must not bypass a lock from another device.
            guard !plans.contains(where: { $0.startedAt != nil }) else { return }
            let items = try context.fetch(FetchDescriptor<ReviewItem>()).map(HomeReviewItemProjection.init)
            let lookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard itemIDs.allSatisfy({ id in lookup[id].map { subject.contains($0.type.rawValue) } == true }) else {
                throw CoachCore.LabError.invalid("AI 复习计划包含已删除或超出范围的题目。")
            }
            let records = try context.fetch(FetchDescriptor<ReviewRecord>()).map(HomeReviewRecordProjection.init)
            let sessions = try context.fetch(FetchDescriptor<DictationSession>()).map(HomeDictationSessionProjection.init)
            let entries = try context.fetch(FetchDescriptor<DictationEntry>()).map(HomeDictationEntryProjection.init)
            // Unselected subjects retain their original rule order within the same quota.
            // Gather all rule candidates before taking the other subjects. A
            // quota-limited list may contain only this subject's older items,
            // hiding eligible items that should fill the remaining slots.
            let rules = select(items: items, records: records, sessions: sessions, entries: entries,
                dailyLimit: max(dailyLimit, items.count + records.count), on: date)
            let otherIDs = rules.pending.filter { !subject.contains($0.type.rawValue) }.map(\.id)
            let selection = select(items: items, records: records, sessions: sessions, entries: entries,
                existingIDs: itemIDs + otherIDs, fixedSelection: true, dailyLimit: dailyLimit, on: date)
            if selection.pending.isEmpty && selection.completedCount < dailyLimit
                && rules.pending.contains(where: { subject.contains($0.type.rawValue) }) {
                throw CoachCore.LabError.invalid("AI 选题已因新判定失效，继续使用原规则复习。")
            }
            let plan = ReviewDailyPlan.preferred(from: plans) ?? ReviewDailyPlan(dayKey: dayKey, itemIDs: [])
            if plans.isEmpty { context.insert(plan) }
            plan.itemIDs = selection.itemIDs
            plan.coachSubjectRawValue = subject.rawValue
            plan.coachRationale = rationale
            // Persist one canonical row so the board/home use exactly the same order.
            for duplicate in plans where duplicate.persistentModelID != plan.persistentModelID { context.delete(duplicate) }
            try context.save()
        }
    }

    @MainActor static func lockToday(in context: ModelContext, itemIDs: [UUID] = [], now: Date = .now) throws {
        try PersistentStoreAccessGate.withAccess {
            let key = ReviewDailyPlan.dayKey(for: now)
            let plans = try context.fetch(FetchDescriptor<ReviewDailyPlan>()).filter { $0.dayKey == key }
            if plans.isEmpty {
                let plan = ReviewDailyPlan(dayKey: key, itemIDs: itemIDs)
                plan.startedAt = now
                context.insert(plan)
            } else {
                for plan in plans where plan.startedAt == nil {
                    plan.startedAt = now
                    plan.updatedAt = now
                }
            }
            try context.save()
        }
    }

    /// Recheck immediately before submission, including answers merged since the
    /// practice page opened. It uses the same quota and identities as the home page.
    @MainActor static func eligibleIDs(in context: ModelContext, dailyLimit: Int, now: Date = .now) throws -> Set<UUID> {
        let key = ReviewDailyPlan.dayKey(for: now)
        let plans = try context.fetch(FetchDescriptor<ReviewDailyPlan>()).filter { $0.dayKey == key }
        let plan = ReviewDailyPlan.preferred(from: plans)
        let selection = select(
            items: try context.fetch(FetchDescriptor<ReviewItem>()).map(HomeReviewItemProjection.init),
            records: try context.fetch(FetchDescriptor<ReviewRecord>()).map(HomeReviewRecordProjection.init),
            sessions: try context.fetch(FetchDescriptor<DictationSession>()).map(HomeDictationSessionProjection.init),
            entries: try context.fetch(FetchDescriptor<DictationEntry>()).map(HomeDictationEntryProjection.init),
            existingIDs: plan?.itemIDs ?? [], fixedSelection: plan?.isCoachSelection == true || plan?.startedAt != nil,
            dailyLimit: dailyLimit, on: now)
        return Set(selection.pending.map(\.id))
    }
}
