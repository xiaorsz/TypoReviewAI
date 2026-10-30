import Foundation
import CryptoKit
import SwiftData

struct ReviewScheduler {
    struct StoredReviewRecordState {
        let record: ReviewRecord
        let itemID: UUID
        let reviewedAt: Date
        let resultRawValue: String
        let modeRawValue: String
        let oldStage: Int
        let newStage: Int
        let note: String

        fileprivate init(record: ReviewRecord) {
            self.record = record
            itemID = record.itemID
            reviewedAt = record.reviewedAt
            resultRawValue = record.resultRawValue
            modeRawValue = record.modeRawValue
            oldStage = record.oldStage
            newStage = record.newStage
            note = record.note
        }

        func restore() {
            record.itemID = itemID
            record.reviewedAt = reviewedAt
            record.resultRawValue = resultRawValue
            record.modeRawValue = modeRawValue
            record.oldStage = oldStage
            record.newStage = newStage
            record.note = note
        }
    }

    struct ReviewRecordUpsertResult {
        let record: ReviewRecord
        let previousStates: [StoredReviewRecordState]

        var reusedExistingRecord: Bool {
            !previousStates.isEmpty
        }
    }

    static let intervals: [Int] = [
        0,
        1,
        2,
        4,
        7,
        15,
        30
    ]
    static let dictationFollowUpCompleteStage = 6
    static let completionStage = 7

    func nextDate(for stage: Int, from date: Date = .now) -> Date {
        let safeStage = max(0, min(stage, Self.intervals.count - 1))
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .day, value: Self.intervals[safeStage], to: date) ?? date
        return Self.normalizedReviewDate(target, calendar: calendar)
    }

    func nextDayStart(from date: Date = .now) -> Date {
        dayStart(after: 1, from: date)
    }

    func dayStart(after days: Int, from date: Date = .now) -> Date {
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .day, value: days, to: date) ?? date
        return calendar.startOfDay(for: target)
    }

    static func normalizedReviewDate(_ date: Date, calendar: Calendar = .current) -> Date {
        guard date != .distantFuture else { return date }
        return calendar.startOfDay(for: date)
    }

    static func isDue(_ nextReviewAt: Date, on referenceDate: Date = .now, calendar: Calendar = .current) -> Bool {
        guard nextReviewAt != .distantFuture else { return false }
        return normalizedReviewDate(nextReviewAt, calendar: calendar) <= calendar.startOfDay(for: referenceDate)
    }

    static func isMastered(stage: Int, consecutiveWrongCount: Int) -> Bool {
        stage >= completionStage && consecutiveWrongCount == 0
    }

    /// A stable identifier for one scheduled review cycle. Two devices holding the same
    /// stale item state produce the same identifier, so their submissions can be treated
    /// as one result after CloudKit merges them.
    static func reviewCycleID(
        for item: ReviewItem,
        mode: ReviewMode = .scheduled,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> UUID {
        let scheduledDay = normalizedReviewDate(item.nextReviewAt, calendar: calendar)
        var components = [
            item.id.uuidString.lowercased(),
            mode.rawValue,
            item.reviewTrackRawValue,
            String(item.resolvedDictationFollowUpStep),
            String(item.stage),
            String(Int64(scheduledDay.timeIntervalSince1970.rounded()))
        ]

        // A dictation or explicit retry is a separate learning event. Scheduled reviews
        // intentionally omit the submission day so an overdue cycle keeps the same ID.
        if mode != .scheduled {
            let reviewDay = calendar.startOfDay(for: now)
            components.append(String(Int64(reviewDay.timeIntervalSince1970.rounded())))
        }

        return deterministicUUID(for: components.joined(separator: "|"))
    }

    /// Saves one logical review cycle without allowing an orphaned ReviewRecord to block
    /// an explicit answer. This can happen when CloudKit (or an interrupted local save)
    /// delivers the immutable record before the mutable ReviewItem progress. In that case
    /// the user's current answer updates the existing cycle and the item can move forward.
    static func upsertReviewRecord(
        _ candidate: ReviewRecord,
        in modelContext: ModelContext
    ) -> ReviewRecordUpsertResult {
        let cycleID = candidate.id
        let descriptor = FetchDescriptor<ReviewRecord>(
            predicate: #Predicate { $0.id == cycleID }
        )
        let existingRecords = (try? modelContext.fetch(descriptor)) ?? []

        guard !existingRecords.isEmpty else {
            modelContext.insert(candidate)
            return ReviewRecordUpsertResult(record: candidate, previousStates: [])
        }

        let previousStates = existingRecords.map(StoredReviewRecordState.init)
        for record in existingRecords {
            record.itemID = candidate.itemID
            record.reviewedAt = candidate.reviewedAt
            record.resultRawValue = candidate.resultRawValue
            record.modeRawValue = candidate.modeRawValue
            record.oldStage = candidate.oldStage
            record.newStage = candidate.newStage
            record.note = candidate.note
        }

        return ReviewRecordUpsertResult(
            record: existingRecords[0],
            previousStates: previousStates
        )
    }

    /// Removes duplicate/stale transitions from the logical history without deleting raw
    /// records. Keeping the raw records makes this repair safe and reversible.
    static func canonicalReviewRecords(_ records: [ReviewRecord]) -> [ReviewRecord] {
        ReviewRecord.canonicalRecords(records)
    }

    private static func deterministicUUID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        var bytes = Array(digest.prefix(16))
        // Mark this as an RFC 4122-compatible name-based UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    @discardableResult
    static func normalizeStoredReviewDates(in modelContext: ModelContext, calendar: Calendar = .current) throws -> Int {
        let items = try modelContext.fetch(FetchDescriptor<ReviewItem>())
        var normalizedCount = 0

        for item in items {
            let normalizedDate = normalizedReviewDate(item.nextReviewAt, calendar: calendar)
            guard item.nextReviewAt != normalizedDate else { continue }
            item.nextReviewAt = normalizedDate
            normalizedCount += 1
        }

        return normalizedCount
    }

    @discardableResult
    static func migrateLegacyStageSevenCaps(in modelContext: ModelContext) throws -> Int {
        let records = try modelContext.fetch(FetchDescriptor<ReviewRecord>())
        let items = try modelContext.fetch(FetchDescriptor<ReviewItem>())
        let itemsByID = Dictionary(grouping: items, by: \.id)
            .compactMapValues { ReviewContentIdentity.preferredReviewItem(from: $0) }
        let latestRecordDateByItemID = Dictionary(
            records.map { ($0.itemID, $0.reviewedAt) },
            uniquingKeysWith: max
        )
        var latestMigratedRecordDateByItemID: [UUID: Date] = [:]
        var migratedCount = 0

        for record in records {
            guard record.result == .correct,
                  record.newStage >= completionStage || (
                    record.newStage == dictationFollowUpCompleteStage &&
                    record.note.contains("已完成所有复习")
                  ),
                  !record.note.contains("听写跟进") else {
                continue
            }

            record.newStage = completionStage
            if record.note.hasPrefix("__detail__:") {
                record.note = "__detail__:已完成所有复习，当前标记为已掌握"
            }
            latestMigratedRecordDateByItemID[record.itemID] = max(
                latestMigratedRecordDateByItemID[record.itemID] ?? .distantPast,
                record.reviewedAt
            )
            migratedCount += 1
        }

        for item in items where item.reviewTrack == .standard && item.consecutiveWrongCount == 0 {
            if item.stage >= completionStage {
                if item.nextReviewAt != .distantFuture {
                    item.nextReviewAt = .distantFuture
                    item.updatedAt = .now
                    migratedCount += 1
                }
            } else if item.stage == dictationFollowUpCompleteStage,
                      item.nextReviewAt == .distantFuture {
                item.stage = completionStage
                item.updatedAt = .now
                migratedCount += 1
            }
        }

        for (itemID, migratedRecordDate) in latestMigratedRecordDateByItemID {
            guard latestRecordDateByItemID[itemID] == migratedRecordDate,
                  let item = itemsByID[itemID],
                  item.stage == completionStage,
                  item.consecutiveWrongCount == 0 else {
                continue
            }

            item.stage = completionStage
            item.nextReviewAt = .distantFuture
            item.reviewTrack = .standard
            item.dictationFollowUpStep = 0
            item.isDictationPass = false
            item.updatedAt = .now
            migratedCount += 1
        }

        return migratedCount
    }

    @discardableResult
    static func deduplicateReviewItems(in modelContext: ModelContext) throws -> Int {
        let items = try modelContext.fetch(FetchDescriptor<ReviewItem>())
        let records = try modelContext.fetch(FetchDescriptor<ReviewRecord>())
        let recordsByItemID = Dictionary(grouping: records, by: \.itemID)
        let groupedItems = Dictionary(grouping: items) { item in
            ReviewContentIdentity.key(for: item)
        }
        var changedCount = 0

        for (key, duplicateItems) in groupedItems {
            let normalizedContent = key.components(separatedBy: "|").last ?? ""
            guard !normalizedContent.isEmpty, duplicateItems.count > 1,
                  let canonical = ReviewContentIdentity.preferredReviewItem(from: duplicateItems) else {
                continue
            }

            for duplicate in duplicateItems where duplicate.persistentModelID != canonical.persistentModelID {
                mergeReviewItem(duplicate, into: canonical)

                for record in recordsByItemID[duplicate.id, default: []] {
                    record.itemID = canonical.id
                    changedCount += 1
                }

                modelContext.delete(duplicate)
                changedCount += 1
            }
        }

        return changedCount
    }

    /// Repairs a clear CloudKit ordering gap where a review record has arrived but the
    /// corresponding mutable ReviewItem is still older. Dictation-follow-up items are
    /// excluded because their track transition cannot be reconstructed from ReviewRecord
    /// alone without losing information.
    @discardableResult
    static func reconcileStandardReviewProgress(in modelContext: ModelContext) throws -> Int {
        let items = try modelContext.fetch(FetchDescriptor<ReviewItem>())
        let rawRecords = try modelContext.fetch(FetchDescriptor<ReviewRecord>())
            .filter { $0.mode != .dictation }
        let rawRecordsByID = Dictionary(grouping: rawRecords, by: \.id)
        let rawRecordsByItemID = Dictionary(grouping: rawRecords, by: \.itemID)
        let scheduler = ReviewScheduler()
        var changedCount = 0

        // Repair an interrupted/split sync first. A deterministic cycle record proves
        // that this exact due state was answered, even if the mutable ReviewItem update
        // did not arrive. Replaying that stored answer removes the item from today's list
        // without asking the user to complete it again.
        for item in items where item.reviewTrack == .standard
            && !item.isDictationPass
            && isDue(item.nextReviewAt) {
            let cycleID = reviewCycleID(for: item)
            let exactCycleRecord = rawRecordsByID[cycleID]?.max {
                $0.reviewedAt < $1.reviewedAt
            }
            let storedReviewDate = item.lastReviewedAt ?? .distantPast
            let scheduledDay = normalizedReviewDate(item.nextReviewAt)
            let compatibleRecord = rawRecordsByItemID[item.id]?
                .filter { record in
                    record.mode == .scheduled
                        && record.oldStage == item.stage
                        && reviewSyncSecond(record.reviewedAt) > reviewSyncSecond(storedReviewDate)
                        && record.reviewedAt >= scheduledDay
                }
                .max { $0.reviewedAt < $1.reviewedAt }

            // The semantic fallback covers records whose itemID was repointed while
            // duplicate ReviewItems were merged. Their deterministic record ID still
            // contains the removed item's old ID, so an exact cycle lookup cannot match.
            guard let orphanedRecord = exactCycleRecord ?? compatibleRecord else {
                continue
            }

            orphanedRecord.markAsExplicitlyConfirmedSubmission()
            applyStandardProgress(
                from: orphanedRecord,
                to: item,
                scheduler: scheduler
            )
            changedCount += 1
        }

        let records = canonicalReviewRecords(
            rawRecords
        )
        let latestRecordByItemID = Dictionary(
            records.map { ($0.itemID, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.reviewedAt > current.reviewedAt ? candidate : current
            }
        )
        for item in items where item.reviewTrack == .standard && !item.isDictationPass {
            guard let latestRecord = latestRecordByItemID[item.id] else { continue }

            let storedReviewDate = item.lastReviewedAt ?? .distantPast
            // Uploads use whole-second ISO-8601 dates, but migrated history can
            // retain fractions. Comparing raw Dates repairs the same answer on
            // every server echo and changes updatedAt forever. Compare at wire
            // precision without modifying either stored timestamp.
            let storedSecond = reviewSyncSecond(storedReviewDate)
            let recordSecond = reviewSyncSecond(latestRecord.reviewedAt)
            let recordIsNewer = storedSecond < recordSecond
            let stateDisagreesAtSameReview = storedSecond == recordSecond
                && item.stage != latestRecord.newStage
            let stateComesFromSupersededRecord = storedSecond > recordSecond
                && item.stage == latestRecord.newStage
            guard recordIsNewer || stateDisagreesAtSameReview || stateComesFromSupersededRecord else {
                continue
            }

            applyStandardProgress(from: latestRecord, to: item, scheduler: scheduler)

            changedCount += 1
        }

        return changedCount
    }

    private static func reviewSyncSecond(_ date: Date) -> TimeInterval {
        date.timeIntervalSince1970.rounded(.down)
    }

    private static func applyStandardProgress(
        from record: ReviewRecord,
        to item: ReviewItem,
        scheduler: ReviewScheduler
    ) {
        item.stage = record.newStage
        item.lastReviewedAt = record.reviewedAt
        item.updatedAt = max(.now, record.reviewedAt)

        switch record.result {
        case .correct:
            item.consecutiveCorrectCount = max(item.consecutiveCorrectCount, 1)
            item.consecutiveWrongCount = 0
            item.isPriority = false
            item.nextReviewAt = record.newStage >= completionStage
                ? .distantFuture
                : scheduler.nextDate(for: record.newStage, from: record.reviewedAt)
        case .wrong:
            item.consecutiveCorrectCount = 0
            item.consecutiveWrongCount = max(item.consecutiveWrongCount, 1)
            item.isPriority = item.consecutiveWrongCount >= 2
            item.nextReviewAt = scheduler.nextDate(for: record.newStage, from: record.reviewedAt)
        }
    }

    @discardableResult
    static func deduplicateDailyReviewPlans(in modelContext: ModelContext) throws -> Int {
        let plans = try modelContext.fetch(FetchDescriptor<ReviewDailyPlan>())
        let plansByDay = Dictionary(grouping: plans, by: \.dayKey)
        var deletedCount = 0

        for dailyPlans in plansByDay.values where dailyPlans.count > 1 {
            guard let preferred = ReviewDailyPlan.preferred(from: dailyPlans) else { continue }
            for duplicate in dailyPlans where duplicate.persistentModelID != preferred.persistentModelID {
                modelContext.delete(duplicate)
                deletedCount += 1
            }
        }

        return deletedCount
    }

    private static func mergeReviewItem(_ duplicate: ReviewItem, into canonical: ReviewItem) {
        if canonical.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            canonical.prompt = duplicate.prompt
        }
        if canonical.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            canonical.note = duplicate.note
        }
        if canonical.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            canonical.source = duplicate.source
        }

        canonical.createdAt = min(canonical.createdAt, duplicate.createdAt)
        canonical.updatedAt = max(canonical.updatedAt, duplicate.updatedAt)
        switch (canonical.lastReviewedAt, duplicate.lastReviewedAt) {
        case let (current?, incoming?):
            canonical.lastReviewedAt = max(current, incoming)
        case (nil, let incoming?):
            canonical.lastReviewedAt = incoming
        default:
            break
        }
    }

    func dictationFollowUpDate(for step: Int, from date: Date = .now) -> Date {
        switch step {
        case 1:
            return dayStart(after: 3, from: date)
        default:
            return dayStart(after: 7, from: date)
        }
    }

    func handle(
        item: ReviewItem,
        result: ReviewResult,
        mode: ReviewMode = .scheduled,
        now: Date = .now
    ) -> (item: ReviewItem, record: ReviewRecord) {
        let cycleID = Self.reviewCycleID(for: item, mode: mode, now: now)
        let oldStage = item.stage
        item.lastReviewedAt = now
        item.updatedAt = now

        if item.reviewTrack == .dictationFollowUp || item.isDictationPass {
            let currentStep = item.resolvedDictationFollowUpStep
            if result == .correct {
                item.consecutiveCorrectCount += 1
                item.consecutiveWrongCount = 0
                item.isPriority = false

                if currentStep <= 1 {
                    item.reviewTrack = .dictationFollowUp
                    item.dictationFollowUpStep = 2
                    item.isDictationPass = true
                    item.stage = max(item.stage, 2)
                    item.nextReviewAt = daySevenFollowUpDate(afterCompletingDayThreeAt: now)
                } else {
                    item.stage = max(item.stage, Self.dictationFollowUpCompleteStage)
                    item.reviewTrack = .standard
                    item.dictationFollowUpStep = 0
                    item.isDictationPass = false
                    item.nextReviewAt = nextReviewDateAvoidingSameDay(for: item.stage, from: now)
                }
            } else {
                item.reviewTrack = .standard
                item.dictationFollowUpStep = 0
                item.isDictationPass = false
                item.consecutiveCorrectCount = 0
                item.consecutiveWrongCount += 1
                item.stage = 1
                item.nextReviewAt = nextDayStart(from: now)
                item.isPriority = true
            }
        } else {
            switch result {
            case .correct:
                item.consecutiveCorrectCount += 1
                item.consecutiveWrongCount = 0
                item.stage = nextStageAfterCorrect(from: item.stage)
                item.nextReviewAt = item.stage >= Self.completionStage
                    ? .distantFuture
                    : nextReviewDateAvoidingSameDay(for: item.stage, from: now)
                item.isPriority = false
            case .wrong:
                item.consecutiveCorrectCount = 0
                item.consecutiveWrongCount += 1
                item.stage = max(item.stage - 1, 1)
                item.nextReviewAt = nextReviewDateAvoidingSameDay(for: item.stage, from: now)
                item.isPriority = item.consecutiveWrongCount >= 2
            }
        }

        return (
            item,
            ReviewRecord(
                id: cycleID,
                itemID: item.id,
                reviewedAt: now,
                result: result,
                mode: mode,
                oldStage: oldStage,
                newStage: item.stage
            )
        )
    }

    func isMastered(_ item: ReviewItem) -> Bool {
        Self.isMastered(stage: item.stage, consecutiveWrongCount: item.consecutiveWrongCount)
            && item.nextReviewAt == .distantFuture
    }

    private func nextStageAfterCorrect(from currentStage: Int) -> Int {
        // The first successful formal review should not create another due item
        // on the very next day. Jumping from stage 0 to 2 skips that back-to-back run.
        if currentStage <= 0 {
            return min(2, Self.completionStage)
        }
        return min(currentStage + 1, Self.completionStage)
    }

    private func nextReviewDateAvoidingSameDay(for stage: Int, from date: Date) -> Date {
        let candidate = nextDate(for: stage, from: date)
        let calendar = Calendar.current

        guard calendar.isDate(candidate, inSameDayAs: date) else {
            return candidate
        }

        return nextDayStart(from: date)
    }

    private func daySevenFollowUpDate(afterCompletingDayThreeAt completionDate: Date) -> Date {
        // 第3天复习完成后固定间隔4天。即使补做逾期，也保留完整的巩固间隔。
        dayStart(after: 4, from: completionDate)
    }
}
