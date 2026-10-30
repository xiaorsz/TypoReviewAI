import XCTest
import SwiftData
import CoachCore
@testable import CoachLab

private actor UnavailableCoach: CoachCore.ChatTransport {
    func complete(messages: [CoachCore.ChatMessage], model: String, apiKey: String) async throws -> CoachCore.ChatReply {
        throw URLError(.notConnectedToInternet)
    }
}

private actor PlanningCoach: CoachCore.ChatTransport {
    private var messages: [CoachCore.ChatMessage]
    init(_ messages: [CoachCore.ChatMessage]) { self.messages = messages }
    func complete(messages: [CoachCore.ChatMessage], model: String, apiKey: String) async throws -> CoachCore.ChatReply {
        guard !self.messages.isEmpty else { throw URLError(.badServerResponse) }
        return CoachCore.ChatReply(message: self.messages.removeFirst())
    }
}

@MainActor final class DailyReviewPlannerTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let now = CoachCore.Codec.date("2026-10-29")!.addingTimeInterval(3600 * 12)

    private func environment(transport: any CoachCore.ChatTransport = UnavailableCoach()) throws -> (ModelContext, AppSettingsStore, AICoachCoordinator) {
        let schema = Schema([CoachLab.ReviewItem.self, CoachLab.ReviewRecord.self, ReviewDailyPlan.self,
            CoachLab.DictationSession.self, CoachLab.DictationEntry.self, AppSettings.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        containers.append(container)
        let settings = AppSettingsStore(); settings.dailyLimit = 3
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let coach = AICoachCoordinator(fileURL: directory.appendingPathComponent("lab.json"), transport: transport)
        return (container.mainContext, settings, coach)
    }
    private func item(_ content: String, days: Int = 0, type: ReviewItemType = .phrase) -> CoachLab.ReviewItem {
        CoachLab.ReviewItem(type: type, content: content, prompt: "", nextReviewAt: Calendar.current.date(byAdding: .day, value: days, to: now)!)
    }
    private func select(_ items: [CoachLab.ReviewItem], records: [CoachLab.ReviewRecord] = [], sessions: [CoachLab.DictationSession] = [], entries: [CoachLab.DictationEntry] = [], existing: [UUID] = [], fixed: Bool = false, limit: Int = 3) -> DailyReviewPlanner.Selection {
        DailyReviewPlanner.select(items: items.map(HomeReviewItemProjection.init), records: records.map(HomeReviewRecordProjection.init),
            sessions: sessions.map(HomeDictationSessionProjection.init), entries: entries.map(HomeDictationEntryProjection.init),
            existingIDs: existing, fixedSelection: fixed, dailyLimit: limit, on: now)
    }
    func testRuleFallbackKeepsDueOrderAndNeverIncludesFuture() {
        let oldest = item("积压", days: -3), due = item("到期"), future = item("未来", days: 1)
        let selection = select([future, due, oldest], limit: 1)
        XCTAssertEqual(selection.pending.map(\.id), [oldest.id])
        XCTAssertEqual(selection.allDueCount, 2)
    }
    func testAIOrderReplacesRuleOrderAndDoesNotRefillWhenAIChoosesLess() {
        let backlog = item("积压", days: -5), selected = item("易错"), other = item("其他")
        let selection = select([backlog, other, selected], existing: [selected.id], fixed: true)
        XCTAssertEqual(selection.pending.map(\.id), [selected.id])
        XCTAssertEqual(selection.allDueCount, 3)
    }
    func testCompletedReviewsOccupyQuotaAndCannotReturnEvenWhenStillDue() {
        let done = item("已做"), next = item("未做"), third = item("积压", days: -2)
        let record = CoachLab.ReviewRecord(itemID: done.id, reviewedAt: now, result: .wrong, mode: .scheduled, oldStage: 1, newStage: 0)
        let selection = select([done, next, third], records: [record], existing: [done.id, next.id, third.id], fixed: true, limit: 2)
        XCTAssertEqual(selection.itemIDs.count, 2)
        XCTAssertEqual(selection.pending.map(\.id), [next.id])
        XCTAssertEqual(selection.completedCount, 1)
    }
    func testDictationAnswersExcludeSameDayContentWithoutConsumingReviewQuota() {
        let dictated = item("HELLO", type: .englishWord), a = item("甲"), b = item("乙")
        let session = CoachLab.DictationSession(title: "新内容录入", type: .englishWord, scheduledDate: now, reviewedAt: now)
        let entry = CoachLab.DictationEntry(sessionID: session.id, sortOrder: 0, type: .englishWord, content: " hello ", result: .wrong)
        let selection = select([dictated, a, b], sessions: [session], entries: [entry], limit: 2)
        XCTAssertEqual(Set(selection.pending.map(\.id)), [a.id, b.id])
        XCTAssertEqual(selection.completedCount, 0)
        // No ReviewRecord is required: newly entered dictation content has none.
    }
    func testUnreviewedDictationInputDoesNotReserveOrModifyDailyReviews() {
        let a = item("待录入")
        let session = CoachLab.DictationSession(title: "手工计划", type: .phrase, scheduledDate: now)
        let entry = CoachLab.DictationEntry(sessionID: session.id, sortOrder: 0, type: .phrase, content: a.content)
        XCTAssertEqual(select([a], sessions: [session], entries: [entry]).pending.map(\.id), [a.id])
    }
    func testDuplicateContentWithDifferentIDsUsesOneReviewSlot() {
        let a = item("Hello", type: .englishWord), alias = item(" hello ", type: .englishWord), other = item("其他")
        let record = CoachLab.ReviewRecord(itemID: alias.id, reviewedAt: now, result: .correct, mode: .scheduled, oldStage: 0, newStage: 1)
        let selection = select([a, alias, other], records: [record], limit: 2)
        XCTAssertEqual(selection.pending.map(\.id), [other.id])
        XCTAssertEqual(selection.completedCount, 1)
    }
    func testNativeApplySharesOneQuotaAcrossSubjectsAndPreservesListeningInput() throws {
        let (context, _, _) = try environment()
        let a = item("中文"), b = item("English", type: .englishWord), done = item("已复习")
        for value in [a, b, done] { context.insert(value) }
        context.insert(CoachLab.ReviewRecord(itemID: done.id, reviewedAt: now, result: .correct, mode: .scheduled, oldStage: 0, newStage: 1))
        let manual = CoachLab.DictationSession(title: "录入不变", type: .phrase, scheduledDate: now)
        context.insert(manual); try context.save()
        try DailyReviewPlanner.apply(itemIDs: [a.id], subject: .chinese, rationale: "中文易错优先", date: now, dailyLimit: 2, in: context)
        let plan = try XCTUnwrap(context.fetch(FetchDescriptor<ReviewDailyPlan>()).first)
        XCTAssertEqual(plan.itemIDs, [done.id, a.id])
        XCTAssertEqual(manual.title, "录入不变")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.DictationSession>()), 1)
        let board = BoardLearningSupport.pendingReviewItems(items: [a,b,done], records: try context.fetch(FetchDescriptor<CoachLab.ReviewRecord>()), dailyPlans: [plan], dailyLimit: 2, on: now)
        XCTAssertEqual(board.map(\.id), [a.id])
    }
    func testAIResponseRevalidatesAnswersArrivingDuringNetworkRequest() throws {
        let (context, _, _) = try environment()
        let done = item("刚刚已完成"), pending = item("未完成")
        context.insert(done); context.insert(pending)
        context.insert(CoachLab.ReviewRecord(itemID: done.id, reviewedAt: now, result: .correct, mode: .scheduled, oldStage: 0, newStage: 1))
        try context.save()
        try DailyReviewPlanner.apply(itemIDs: [done.id, pending.id], subject: .all, rationale: "返回时重新校验", date: now, dailyLimit: 1, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReviewDailyPlan>()).first?.itemIDs, [done.id])
    }
    func testSingleSubjectAILeavesRoomForOtherSubjectsBeyondOriginalQuotaCutoff() throws {
        let (context, _, _) = try environment()
        let older = item("旧积压", days: -5), selected = item("中文选题", days: -4)
        let english = item("hello", type: .englishWord)
        for value in [older, selected, english] { context.insert(value) }
        try context.save()
        try DailyReviewPlanner.apply(itemIDs: [selected.id], subject: .chinese,
            rationale: "单科由 AI 排序，其余科目按规则补入。", date: now, dailyLimit: 2, in: context)
        let plan = try XCTUnwrap(context.fetch(FetchDescriptor<ReviewDailyPlan>()).first)
        XCTAssertEqual(plan.itemIDs, [selected.id, english.id])
        XCTAssertFalse(plan.itemIDs.contains(older.id))
    }
    func testOtherSubjectFillStillCountsCompletedReviewsAndExcludesDictatedContent() throws {
        let (context, _, _) = try environment()
        let done = item("已完成"), older = item("中文积压", days: -5), selected = item("中文选题", days: -4)
        let dictated = item("hello", type: .englishWord), english = item("world", type: .englishWord)
        for value in [done, older, selected, dictated, english] { context.insert(value) }
        context.insert(CoachLab.ReviewRecord(itemID: done.id, reviewedAt: now, result: .correct,
            mode: .scheduled, oldStage: 0, newStage: 1))
        let session = CoachLab.DictationSession(title: "新录入", type: .englishWord, scheduledDate: now, reviewedAt: now)
        context.insert(session)
        context.insert(CoachLab.DictationEntry(sessionID: session.id, sortOrder: 0,
            type: .englishWord, content: dictated.content, result: .correct))
        try context.save()
        try DailyReviewPlanner.apply(itemIDs: [selected.id], subject: .chinese,
            rationale: "总题量包括已完成复习。", date: now, dailyLimit: 3, in: context)
        let plan = try XCTUnwrap(context.fetch(FetchDescriptor<ReviewDailyPlan>()).first)
        XCTAssertEqual(plan.itemIDs, [done.id, selected.id, english.id])
    }
    func testStartedPlanRejectsLateAIResponse() throws {
        let (context, _, _) = try environment()
        let a = item("原安排"), b = item("晚到结果")
        context.insert(a); context.insert(b)
        let plan = ReviewDailyPlan(dayKey: ReviewDailyPlan.dayKey(for: now), itemIDs: [a.id])
        context.insert(plan); try context.save()
        try DailyReviewPlanner.lockToday(in: context, now: now)
        try DailyReviewPlanner.apply(itemIDs: [b.id], subject: .all, rationale: "不能覆盖", date: now, dailyLimit: 3, in: context)
        XCTAssertEqual(plan.itemIDs, [a.id])
        XCTAssertFalse(plan.isCoachSelection)
    }
    func testMissingKeyAndNetworkFailureLeaveRuleFallbackExecutable() async throws {
        let (context, settings, coach) = try environment()
        let a = item("离线复习", days: -1)
        context.insert(a); try context.save(); coach.bootstrap(context: context, settings: settings)
        var config = try XCTUnwrap(coach.store).state.configuration; config.isEnabled = true
        try coach.store?.configure(config)
        coach.run(context: context, settings: settings, apiKey: "", now: now)
        await coach.waitForPendingRun()
        XCTAssertTrue(coach.error?.contains("原规则") == true)
        coach.run(context: context, settings: settings, apiKey: "fake-test-key", now: now)
        await coach.waitForPendingRun()
        XCTAssertNotNil(coach.agent?.lastError)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 0)
        XCTAssertEqual(select([a]).pending.map(\.id), [a.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.DictationSession>()), 0)
    }
    func testRepeatedWriteAndNewCoordinatorRetainOneSavedPlan() throws {
        let (context, settings, coach) = try environment()
        let a = item("重启后保留")
        context.insert(a); try context.save()
        for _ in 0..<2 { try DailyReviewPlanner.apply(itemIDs: [a.id], subject: .all, rationale: "重复返回", date: now, dailyLimit: 3, in: context) }
        coach.bootstrap(context: context, settings: settings)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReviewDailyPlan>()).first?.itemIDs, [a.id])
    }

    func testModelToolLoopWritesTodayAndAdjustsTomorrowAfterReviewWithoutCreatingInput() async throws {
        let a = item("AI 闭环", days: -1)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        func replies(on date: Date) throws -> [CoachCore.ChatMessage] {
            let args = CoachCore.PlanArguments(date: CoachCore.Codec.day(date), title: "每日复习", itemIDs: [a.id], rationale: "依据实际到期及错误记录。")
            return [
                .init(role: "assistant", calls: [.init(name: "query_history", arguments: "{}"), .init(name: "query_plans", arguments: "{}")]),
                .init(role: "assistant", calls: [.init(name: "upsert_plan", arguments: try CoachCore.Codec.text(args))]),
                .init(role: "assistant", content: "复习安排已保存。")
            ]
        }
        let transport = try PlanningCoach(replies(on: now) + replies(on: tomorrow))
        let (context, settings, coach) = try environment(transport: transport)
        context.insert(a); try context.save()
        coach.bootstrap(context: context, settings: settings)
        var config = try XCTUnwrap(coach.store).state.configuration
        config.isEnabled = true; config.subject = .all
        try coach.store?.configure(config)
        coach.run(context: context, settings: settings, apiKey: "test-only", now: now)
        await coach.waitForPendingRun()
        XCTAssertNil(coach.error)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReviewDailyPlan>()).first?.itemIDs, [a.id])
        coach.run(context: context, settings: settings, apiKey: "test-only", now: now)
        await coach.waitForPendingRun()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 1)

        try DailyReviewPlanner.lockToday(in: context, now: now)
        let result = ReviewScheduler().handle(item: a, result: .wrong, now: now)
        context.insert(result.record); try context.save()
        coach.refresh(context: context, settings: settings)
        let store = try XCTUnwrap(coach.store)
        var state = store.state
        var feedback = CoachCore.DictationSession(title: "新判定", type: "词语", date: now, now: now)
        feedback.practiceMode = "feedback"; feedback.reviewedAt = now
        var entry = CoachCore.DictationEntry(sessionID: feedback.id, item: try XCTUnwrap(state.items.first), order: 0, now: now)
        entry.resultRawValue = "错误"
        state.sessions.append(feedback); state.entries.append(entry); state.pendingFeedbackSessionIDs.append(feedback.id)
        try store.commit(state)
        coach.run(context: context, settings: settings, apiKey: "test-only", now: now)
        await coach.waitForPendingRun()
        XCTAssertNil(coach.error)
        let plans = try context.fetch(FetchDescriptor<ReviewDailyPlan>())
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans.first { $0.dayKey == CoachCore.Codec.day(tomorrow) }?.itemIDs, [a.id])
        XCTAssertNotNil(plans.first { $0.dayKey == CoachCore.Codec.day(now) }?.startedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.DictationSession>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.DictationEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.ReviewRecord>()), 1)
        XCTAssertEqual(a.stage, result.record.newStage)
    }

    func testSubmissionRecheckBlocksAnswersAndQuotaConsumedAfterPageOpened() throws {
        let (context, _, _) = try environment()
        let first = item("先完成"), second = item("已打开的页面")
        context.insert(first); context.insert(second)
        let plan = ReviewDailyPlan(dayKey: ReviewDailyPlan.dayKey(for: now), itemIDs: [first.id, second.id])
        context.insert(plan); try context.save()
        XCTAssertEqual(try DailyReviewPlanner.eligibleIDs(in: context, dailyLimit: 1, now: now), [first.id])
        context.insert(CoachLab.ReviewRecord(itemID: first.id, reviewedAt: now, result: .correct, mode: .scheduled, oldStage: 0, newStage: 1))
        try context.save()
        XCTAssertTrue(try DailyReviewPlanner.eligibleIDs(in: context, dailyLimit: 1, now: now).isEmpty)
    }
}
