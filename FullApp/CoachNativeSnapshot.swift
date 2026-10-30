import Foundation
import SwiftData
import CoachCore

/// Materialized values may cross executors; SwiftData model instances never do.
/// These mappings intentionally avoid JSON and preserve fractional timestamps.
struct CoachNativeSnapshot: Sendable {
    let items: [CoachCore.ReviewItem]
    let records: [CoachCore.ReviewRecord]
    let sessions: [CoachCore.DictationSession]
    let entries: [CoachCore.DictationEntry]
    let startedDays: [String: Date]

    /// Call from a background task. The context is created and used entirely on
    /// the caller's executor, under the same gate as destructive backup restore.
    nonisolated static func load(from container: ModelContainer) throws -> CoachNativeSnapshot {
        try PersistentStoreAccessGate.withAccess {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try read(from: context)
        }
    }

    /// Synchronous compatibility entry point for the app's main context/tests.
    /// Background callers must use the container overload, not pass this context.
    @MainActor static func load(from context: ModelContext) throws -> CoachNativeSnapshot {
        try PersistentStoreAccessGate.withAccess {
            try read(from: context)
        }
    }

    nonisolated private static func read(from context: ModelContext) throws -> CoachNativeSnapshot {
        let items = try context.fetch(FetchDescriptor<ReviewItem>()).map { native in
            var item = CoachCore.ReviewItem(id: native.id, type: native.typeRawValue,
                content: native.content, prompt: native.prompt, now: native.createdAt)
            item.note = native.note
            item.source = native.source
            item.stage = native.stage
            item.nextReviewAt = native.nextReviewAt
            item.lastReviewedAt = native.lastReviewedAt
            item.consecutiveCorrectCount = native.consecutiveCorrectCount
            item.consecutiveWrongCount = native.consecutiveWrongCount
            item.isPriority = native.isPriority
            item.reviewTrackRawValue = native.reviewTrackRawValue
            item.dictationFollowUpStep = native.dictationFollowUpStep
            item.isDictationPassRaw = native.isDictationPassRaw
            item.createdAt = native.createdAt
            item.updatedAt = native.updatedAt
            return item
        }
        let records = try context.fetch(FetchDescriptor<ReviewRecord>()).map { native in
            var record = CoachCore.ReviewRecord(id: native.id, itemID: native.itemID,
                correct: native.resultRawValue == ReviewResult.correct.rawValue,
                oldStage: native.oldStage, newStage: native.newStage, now: native.reviewedAt)
            record.resultRawValue = native.resultRawValue
            record.modeRawValue = native.modeRawValue
            record.note = native.note
            // The native record does not store a dictation session link.
            record.sessionID = nil
            return record
        }
        let sessions = try context.fetch(FetchDescriptor<DictationSession>()).map { native in
            var session = CoachCore.DictationSession(id: native.id, title: native.title,
                type: native.typeRawValue, date: native.scheduledDate, now: native.createdAt)
            session.updatedAt = native.updatedAt
            session.finishedAt = native.finishedAt
            session.reviewedAt = native.reviewedAt
            session.currentEntryIndex = native.currentEntryIndex
            // These properties belong to coach metadata, not the native table.
            session.startedAt = nil
            session.cancelledAt = nil
            session.practiceMode = nil
            session.gradingStyle = nil
            return session
        }
        let entries = try context.fetch(FetchDescriptor<DictationEntry>()).map { native in
            // Core's initializer accepts a value item, while the native entry
            // stores content rather than an item relation. No link is inferred.
            let content = CoachCore.ReviewItem(id: native.id, type: native.typeRawValue,
                content: native.content, prompt: native.prompt, now: native.createdAt)
            var entry = CoachCore.DictationEntry(sessionID: native.sessionID,
                item: content, order: native.sortOrder, now: native.createdAt)
            entry.id = native.id
            entry.note = native.note
            entry.source = native.source
            entry.resultRawValue = native.resultRawValue
            entry.updatedAt = native.updatedAt
            entry.itemID = nil
            entry.submittedRecordID = nil
            entry.beforeReviewItem = nil
            return entry
        }
        var startedDays: [String: Date] = [:]
        for plan in try context.fetch(FetchDescriptor<ReviewDailyPlan>()) {
            guard let startedAt = plan.startedAt, !plan.dayKey.isEmpty else { continue }
            startedDays[plan.dayKey] = min(startedDays[plan.dayKey] ?? startedAt, startedAt)
        }
        return CoachNativeSnapshot(items: items, records: records, sessions: sessions,
            entries: entries, startedDays: startedDays)
    }
}
