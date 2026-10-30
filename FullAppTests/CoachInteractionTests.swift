import XCTest
import SwiftData
import CoachCore
@testable import CoachLab

private actor CoachInteractionTransport: CoachCore.ChatTransport {
    var calls = 0
    let itemID: UUID
    let date: String
    let beforeFirstCompletion: (@MainActor @Sendable () throws -> Void)?
    init(itemID: UUID, date: String, beforeFirstCompletion: (@MainActor @Sendable () throws -> Void)? = nil) {
        self.itemID = itemID; self.date = date; self.beforeFirstCompletion = beforeFirstCompletion
    }
    func complete(messages: [CoachCore.ChatMessage], model: String, apiKey: String) async throws -> CoachCore.ChatReply {
        calls += 1
        if calls == 3, let beforeFirstCompletion { try await beforeFirstCompletion() }
        switch calls % 3 {
        case 1:
            return .init(message: .init(role: "assistant", calls: [.init(name: "query_history", arguments: "{}"), .init(name: "query_plans", arguments: "{}")]))
        case 2:
            let args = CoachCore.PlanArguments(date: date, title: "复习安排", itemIDs: [itemID], rationale: "已到期，依据真实记录安排。")
            return .init(message: .init(role: "assistant", calls: [.init(name: "upsert_plan", arguments: try CoachCore.Codec.text(args))]))
        default: return .init(message: .init(role: "assistant", content: "安排已保存。"))
        }
    }
}

@MainActor private final class ReviewFeedbackTestTarget {
    weak var coach: AICoachCoordinator?
}

@MainActor final class CoachInteractionTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let now = CoachCore.Codec.date("2026-10-29")!.addingTimeInterval(3600)
    private func environment(enabled: Bool = true) throws -> (ModelContext, AppSettingsStore, AICoachCoordinator, CoachInteractionTransport) {
        let schema = Schema([CoachLab.ReviewItem.self, CoachLab.ReviewRecord.self, CoachLab.DictationSession.self,
            CoachLab.DictationEntry.self, ReviewDailyPlan.self, AppSettings.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        containers.append(container)
        let context = container.mainContext
        let item = CoachLab.ReviewItem(type: .phrase, content: "有反馈", prompt: "", nextReviewAt: now)
        context.insert(item); try context.save()
        let transport = CoachInteractionTransport(itemID: item.id, date: CoachCore.Codec.day(now))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let coach = AICoachCoordinator(fileURL: directory.appendingPathComponent("lab.json"), transport: transport)
        let settings = AppSettingsStore(); settings.dailyLimit = 4
        coach.bootstrap(context: context, settings: settings)
        var config = try XCTUnwrap(coach.store).state.configuration
        config.isEnabled = enabled; config.subject = .all
        try coach.store?.configure(config)
        return (context, settings, coach, transport)
    }
    func testDisabledCoachExplainsWhyInsteadOfSilentlyIgnoringClick() throws {
        let (context, settings, coach, _) = try environment(enabled: false)
        coach.run(context: context, settings: settings, apiKey: "", now: now, manual: true)
        XCTAssertTrue(coach.status.contains("授权"))
        XCTAssertFalse(coach.isRunning)
    }
    func testBusyStateIsImmediateAndMissingKeyGivesActionableFeedback() async throws {
        let (context, settings, coach, transport) = try environment()
        coach.run(context: context, settings: settings, apiKey: "", now: now, manual: true)
        XCTAssertTrue(coach.isRunning)
        XCTAssertTrue(coach.status.contains("读取"))
        await coach.waitForPendingRun()
        XCTAssertFalse(coach.isRunning)
        XCTAssertTrue(coach.error?.contains("API Key") == true)
        let calls = await transport.calls
        XCTAssertEqual(calls, 0)
    }
    func testLockedDayReportsReasonAndMakesNoModelRequest() async throws {
        let (context, settings, coach, transport) = try environment()
        let plan = ReviewDailyPlan(dayKey: CoachCore.Codec.day(now), itemIDs: [])
        plan.startedAt = now; context.insert(plan); try context.save()
        coach.run(context: context, settings: settings, apiKey: "test-only", now: now, manual: true)
        await coach.waitForPendingRun()
        XCTAssertTrue(coach.status.contains("已锁定"))
        XCTAssertFalse(coach.isRunning)
        let calls = await transport.calls
        XCTAssertEqual(calls, 0)
    }
    func testManualRecheckActuallyQueriesAgainAndKeepsOneNativePlan() async throws {
        let (context, settings, coach, transport) = try environment()
        for _ in 0..<2 {
            coach.run(context: context, settings: settings, apiKey: "test-only", now: now, manual: true)
            await coach.waitForPendingRun()
            XCTAssertNil(coach.error)
        }
        let calls = await transport.calls
        XCTAssertEqual(calls, 6)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.DictationSession>()), 0)
    }
    func testCancelThenImmediateRetryDoesNotLetOldRunClearNewBusyState() async throws {
        let (context, settings, coach, _) = try environment()
        coach.run(context: context, settings: settings, apiKey: "test-only", now: now, manual: true)
        coach.cancel()
        XCTAssertFalse(coach.isRunning)
        coach.run(context: context, settings: settings, apiKey: "test-only", now: now, manual: true)
        XCTAssertTrue(coach.isRunning)
        await coach.waitForPendingRun()
        XCTAssertNil(coach.error)
        XCTAssertFalse(coach.isRunning)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 1)
    }

    func testFeedbackIsAcknowledgedOnlyAfterNativeWriteAndFailureCanRetryOnLockedDay() async throws {
        let (context, settings, initial, _) = try environment()
        let native = try XCTUnwrap(context.fetch(FetchDescriptor<CoachLab.ReviewItem>()).first)
        let itemID = native.id
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let transport = CoachInteractionTransport(itemID: itemID, date: CoachCore.Codec.day(tomorrow)) {
            // Simulate a deletion arriving after model selection but before the
            // native plan can be saved, so this response cannot be applied.
            for item in try context.fetch(FetchDescriptor<CoachLab.ReviewItem>()) where item.id == itemID {
                context.delete(item)
            }
            try context.save()
        }
        let fileURL = try XCTUnwrap(initial.store).fileURL
        let coach = AICoachCoordinator(fileURL: fileURL, transport: transport)
        coach.bootstrap(context: context, settings: settings)
        let store = try XCTUnwrap(coach.store)
        var state = store.state
        var feedback = CoachCore.DictationSession(title: "新判定", type: "词语", date: now, now: now)
        feedback.practiceMode = "feedback"; feedback.reviewedAt = now
        var entry = CoachCore.DictationEntry(sessionID: feedback.id, item: try XCTUnwrap(state.items.first), order: 0, now: now)
        entry.resultRawValue = "错误"
        state.sessions.append(feedback); state.entries.append(entry); state.pendingFeedbackSessionIDs.append(feedback.id)
        try store.commit(state)
        let today = ReviewDailyPlan(dayKey: CoachCore.Codec.day(now), itemIDs: [itemID])
        today.startedAt = now; context.insert(today); try context.save()
        coach.run(context: context, settings: settings, apiKey: "test-only", now: now, manual: true)
        await coach.waitForPendingRun()
        XCTAssertNotNil(coach.error)
        XCTAssertTrue(store.state.pendingFeedbackSessionIDs.contains(feedback.id))
        XCTAssertFalse(store.state.completedTriggers.contains("feedback:\(feedback.id.uuidString)"))

        let restored = CoachLab.ReviewItem(id: itemID, type: .phrase, content: "有反馈", prompt: "", nextReviewAt: tomorrow)
        context.insert(restored); try context.save()
        coach.run(context: context, settings: settings, apiKey: "test-only", now: now, manual: true)
        await coach.waitForPendingRun()
        XCTAssertNil(coach.error)
        XCTAssertFalse(store.state.pendingFeedbackSessionIDs.contains(feedback.id))
        XCTAssertTrue(store.state.completedTriggers.contains("feedback:\(feedback.id.uuidString)"))
        let plans = try context.fetch(FetchDescriptor<ReviewDailyPlan>())
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans.first { $0.dayKey == CoachCore.Codec.day(tomorrow) }?.itemIDs, [itemID])
        XCTAssertEqual(today.startedAt, now)
    }

    private func reviewSignal(id: UUID, recordIDs: [UUID]) -> Notification {
        Notification(name: AICoachSignals.changed, userInfo: ["action": "review", "id": id, "recordIDs": recordIDs])
    }

    private func undoSignal(id: UUID) -> Notification {
        Notification(name: AICoachSignals.changed, userInfo: ["action": "reviewUndo", "id": id])
    }

    private func addReviewRecord(in context: ModelContext, result: CoachLab.ReviewResult = .wrong, id: UUID = UUID()) throws -> CoachLab.ReviewRecord {
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<CoachLab.ReviewItem>()).first)
        let record = CoachLab.ReviewRecord(id: id, itemID: item.id, reviewedAt: now, result: result, mode: .scheduled, oldStage: 0, newStage: 0)
        item.nextReviewAt = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        context.insert(record); try context.save()
        return record
    }

    func testStableReviewSubmissionIsConsumedOnceAndUndoAllowsCorrectedResult() throws {
        let (context, settings, coach, _) = try environment(enabled: false)
        let store = try XCTUnwrap(coach.store)
        let submissionID = UUID()
        let record = try addReviewRecord(in: context)
        let recordID = record.id
        let signal = reviewSignal(id: submissionID, recordIDs: [recordID])
        coach.receive(signal, context: context, settings: settings)
        coach.receive(signal, context: context, settings: settings)
        XCTAssertEqual(store.state.pendingFeedbackSessionIDs, [submissionID])
        XCTAssertEqual(store.entries(for: submissionID).count, 1)
        XCTAssertEqual(store.entries(for: submissionID).first?.submittedRecordID, recordID)
        XCTAssertEqual(store.entries(for: submissionID).first?.resultRawValue, "错误")

        try store.finishTrigger("feedback:\(submissionID.uuidString)")
        coach.refresh(context: context, settings: settings)
        coach.receive(signal, context: context, settings: settings)
        XCTAssertTrue(store.state.pendingFeedbackSessionIDs.isEmpty)

        context.delete(record); try context.save()
        coach.receive(undoSignal(id: submissionID), context: context, settings: settings)
        XCTAssertFalse(store.state.completedTriggers.contains("feedback:\(submissionID.uuidString)"))
        _ = try addReviewRecord(in: context, result: .correct, id: recordID)
        coach.receive(signal, context: context, settings: settings)
        XCTAssertEqual(store.state.pendingFeedbackSessionIDs, [submissionID])
        XCTAssertEqual(store.entries(for: submissionID).map(\.resultRawValue), ["正确"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.ReviewRecord>()), 1)
    }

    func testMissingSubmittedRecordsDoNotBecomeInventedWrongFeedback() throws {
        let (context, settings, coach, _) = try environment(enabled: false)
        let record = try addReviewRecord(in: context)
        let validID = UUID()
        coach.receive(reviewSignal(id: UUID(), recordIDs: [UUID()]), context: context, settings: settings)
        XCTAssertTrue(coach.store?.state.pendingFeedbackSessionIDs.isEmpty == true)
        coach.receive(reviewSignal(id: validID, recordIDs: [record.id]), context: context, settings: settings)
        XCTAssertEqual(coach.store?.state.pendingFeedbackSessionIDs, [validID])
    }

    func testUndoWhileModelIsReturningCannotFlushOldFeedbackPlans() async throws {
        let (context, settings, original, _) = try environment(enabled: false)
        let record = try addReviewRecord(in: context)
        let submissionID = UUID()
        let target = ReviewFeedbackTestTarget()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let transport = CoachInteractionTransport(itemID: record.itemID, date: CoachCore.Codec.day(tomorrow)) {
            context.delete(record); try context.save()
            target.coach?.receive(Notification(name: AICoachSignals.changed, userInfo: ["action": "reviewUndo", "id": submissionID]), context: context, settings: settings)
        }
        let coach = AICoachCoordinator(fileURL: try XCTUnwrap(original.store).fileURL, transport: transport)
        target.coach = coach
        coach.bootstrap(context: context, settings: settings)
        coach.receive(reviewSignal(id: submissionID, recordIDs: [record.id]), context: context, settings: settings)
        let store = try XCTUnwrap(coach.store)
        var config = store.state.configuration; config.isEnabled = true; try store.configure(config)
        coach.run(context: context, settings: settings, apiKey: "test-only", now: now)
        await coach.waitForPendingRun()
        XCTAssertFalse(coach.isRunning)
        XCTAssertTrue(store.state.plans.isEmpty)
        XCTAssertTrue(store.state.pendingFeedbackSessionIDs.isEmpty)
        XCTAssertFalse(store.state.completedTriggers.contains("feedback:\(submissionID.uuidString)"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 0)
        XCTAssertTrue(coach.status.contains("撤回"))
    }

    func testRecordRemovedWithoutUndoSignalInvalidatesResponseBeforeNativeSave() async throws {
        let (context, settings, original, _) = try environment(enabled: false)
        let record = try addReviewRecord(in: context)
        let submissionID = UUID()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let transport = CoachInteractionTransport(itemID: record.itemID, date: CoachCore.Codec.day(tomorrow)) {
            context.delete(record); try context.save()
        }
        let coach = AICoachCoordinator(fileURL: try XCTUnwrap(original.store).fileURL, transport: transport)
        coach.bootstrap(context: context, settings: settings)
        coach.receive(reviewSignal(id: submissionID, recordIDs: [record.id]), context: context, settings: settings)
        let store = try XCTUnwrap(coach.store)
        var config = store.state.configuration; config.isEnabled = true; try store.configure(config)
        coach.run(context: context, settings: settings, apiKey: "test-only", now: now)
        await coach.waitForPendingRun()
        XCTAssertTrue(coach.error?.contains("判定已撤回或同步更新") == true)
        XCTAssertTrue(store.state.plans.isEmpty)
        XCTAssertTrue(store.state.pendingFeedbackSessionIDs.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 0)
    }

    func testUndoRemovesOnlyUnchangedUnstartedFeedbackPlan() async throws {
        for mutation in ["unchanged", "laterEdit", "started"] {
            let (context, settings, original, _) = try environment(enabled: false)
            let record = try addReviewRecord(in: context)
            let submissionID = UUID()
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
            let transport = CoachInteractionTransport(itemID: record.itemID, date: CoachCore.Codec.day(tomorrow))
            let coach = AICoachCoordinator(fileURL: try XCTUnwrap(original.store).fileURL, transport: transport)
            coach.bootstrap(context: context, settings: settings)
            coach.receive(reviewSignal(id: submissionID, recordIDs: [record.id]), context: context, settings: settings)
            let store = try XCTUnwrap(coach.store)
            var config = store.state.configuration; config.isEnabled = true; try store.configure(config)
            coach.run(context: context, settings: settings, apiKey: "test-only", now: now)
            await coach.waitForPendingRun()
            XCTAssertNil(coach.error)
            let plan = try XCTUnwrap(context.fetch(FetchDescriptor<ReviewDailyPlan>()).first)
            if mutation == "laterEdit" { plan.coachRationale = "另一设备稍后确认的新安排" }
            if mutation == "started" { plan.startedAt = tomorrow }
            try context.save()
            context.delete(record); try context.save()
            coach.receive(undoSignal(id: submissionID), context: context, settings: settings)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), mutation == "unchanged" ? 0 : 1, mutation)
            if mutation == "laterEdit" { XCTAssertEqual(plan.coachRationale, "另一设备稍后确认的新安排") }
            if mutation == "started" { XCTAssertEqual(plan.startedAt, tomorrow) }
            XCTAssertFalse(store.state.pendingFeedbackSessionIDs.contains(submissionID))
        }
    }
}
