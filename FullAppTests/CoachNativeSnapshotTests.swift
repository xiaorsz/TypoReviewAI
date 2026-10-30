import XCTest
import SwiftData
import CoachCore
@testable import CoachLab

@MainActor final class CoachNativeSnapshotTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema([CoachLab.ReviewItem.self, CoachLab.ReviewRecord.self,
            CoachLab.DictationSession.self, CoachLab.DictationEntry.self, ReviewDailyPlan.self])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    func testDirectMappingPreservesRawValuesIDsAndFractionalDates() throws {
        let container = try container()
        let context = container.mainContext
        let created = Date(timeIntervalSince1970: 1_793_295_421.125)
        let updated = created.addingTimeInterval(10.375)
        let item = CoachLab.ReviewItem(type: .phrase, content: " 原内容 ", prompt: "原提示",
            note: "原备注", source: "原来源", stage: 4, nextReviewAt: updated,
            lastReviewedAt: created.addingTimeInterval(3.125), consecutiveCorrectCount: 2,
            consecutiveWrongCount: 3, isPriority: true, reviewTrack: .dictationFollowUp,
            dictationFollowUpStep: 2, createdAt: created, updatedAt: updated)
        item.typeRawValue = "原始类型"
        item.isDictationPassRaw = nil
        let record = CoachLab.ReviewRecord(itemID: item.id, reviewedAt: updated,
            result: .wrong, mode: .retry, oldStage: 4, newStage: 0, note: "__confirmed_detail__:原记录")
        let session = CoachLab.DictationSession(title: "原听写", type: .phrase,
            createdAt: created, updatedAt: updated, scheduledDate: created.addingTimeInterval(0.25),
            finishedAt: updated, reviewedAt: updated.addingTimeInterval(1.125), currentEntryIndex: 3)
        let entry = CoachLab.DictationEntry(sessionID: session.id, sortOrder: 7, type: .phrase,
            content: " 原条目 ", prompt: "条目提示", note: "条目备注", source: "条目来源",
            result: .wrong, createdAt: created, updatedAt: updated)
        context.insert(item); context.insert(record); context.insert(session); context.insert(entry)
        try context.save()

        let snapshot = try CoachNativeSnapshot.load(from: context)
        var expectedItem = CoachCore.ReviewItem(id: item.id, type: item.typeRawValue,
            content: item.content, prompt: item.prompt, now: created)
        expectedItem.note = item.note; expectedItem.source = item.source
        expectedItem.stage = item.stage; expectedItem.nextReviewAt = updated
        expectedItem.lastReviewedAt = item.lastReviewedAt
        expectedItem.consecutiveCorrectCount = 2; expectedItem.consecutiveWrongCount = 3
        expectedItem.isPriority = true; expectedItem.reviewTrackRawValue = "dictationFollowUp"
        expectedItem.dictationFollowUpStep = 2; expectedItem.isDictationPassRaw = nil
        expectedItem.updatedAt = updated
        XCTAssertEqual(snapshot.items, [expectedItem])
        var expectedRecord = CoachCore.ReviewRecord(id: record.id, itemID: item.id,
            correct: false, oldStage: 4, newStage: 0, now: updated)
        expectedRecord.modeRawValue = "retry"; expectedRecord.note = record.note
        XCTAssertEqual(snapshot.records, [expectedRecord])

        let mappedSession = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(mappedSession.id, session.id)
        XCTAssertEqual(mappedSession.typeRawValue, session.typeRawValue)
        XCTAssertEqual(mappedSession.createdAt, created)
        XCTAssertEqual(mappedSession.updatedAt, updated)
        XCTAssertEqual(mappedSession.scheduledDate, session.scheduledDate)
        XCTAssertEqual(mappedSession.finishedAt, session.finishedAt)
        XCTAssertEqual(mappedSession.reviewedAt, session.reviewedAt)
        XCTAssertEqual(mappedSession.currentEntryIndex, 3)
        XCTAssertNil(mappedSession.practiceMode)
        XCTAssertNil(mappedSession.startedAt)

        let mappedEntry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(mappedEntry.id, entry.id)
        XCTAssertEqual(mappedEntry.sessionID, session.id)
        XCTAssertEqual(mappedEntry.sortOrder, 7)
        XCTAssertEqual(mappedEntry.typeRawValue, entry.typeRawValue)
        XCTAssertEqual(mappedEntry.content, entry.content)
        XCTAssertEqual(mappedEntry.prompt, entry.prompt)
        XCTAssertEqual(mappedEntry.note, entry.note)
        XCTAssertEqual(mappedEntry.source, entry.source)
        XCTAssertEqual(mappedEntry.resultRawValue, entry.resultRawValue)
        XCTAssertEqual(mappedEntry.createdAt, created)
        XCTAssertEqual(mappedEntry.updatedAt, updated)
        XCTAssertNil(mappedEntry.itemID)
        XCTAssertNil(mappedEntry.submittedRecordID)
        XCTAssertNil(mappedEntry.beforeReviewItem)
        XCTAssertFalse(context.hasChanges)
    }

    func testContainerLoaderCrossesExecutorAsValuesAndCombinesStartedDays() async throws {
        let container = try container()
        let context = container.mainContext
        let timestamp = Date(timeIntervalSince1970: 1_793_295_421.375)
        let item = CoachLab.ReviewItem(type: .englishWord, content: "hello", prompt: "你好",
            nextReviewAt: timestamp, createdAt: timestamp, updatedAt: timestamp)
        context.insert(item)
        for start in [timestamp, timestamp.addingTimeInterval(30)] {
            let plan = ReviewDailyPlan(dayKey: "2026-10-29", itemIDs: [item.id])
            plan.startedAt = start
            context.insert(plan)
        }
        context.insert(ReviewDailyPlan(dayKey: "2026-10-30", itemIDs: [item.id]))
        try context.save()

        let snapshot = try await Task.detached(priority: .utility) {
            try CoachNativeSnapshot.load(from: container)
        }.value
        XCTAssertEqual(snapshot.items.map(\.id), [item.id])
        XCTAssertEqual(snapshot.items.first?.nextReviewAt, timestamp)
        XCTAssertEqual(snapshot.startedDays, ["2026-10-29": timestamp])
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 3)
    }
}
