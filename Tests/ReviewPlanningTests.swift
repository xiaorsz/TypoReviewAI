import XCTest
@testable import CoachCore

@MainActor final class ReviewPlanningTests: XCTestCase {
    private let now = Codec.date("2026-10-29")!.addingTimeInterval(3600 * 12)
    private func environment(limit: Int = 3) throws -> LabStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try LabStore(fileURL: directory.appendingPathComponent("lab.json"))
        var state = LabState(); state.configuration.isEnabled = true
        state.configuration.dailyLimit = limit; state.configuration.subject = .all
        state.items = [ReviewItem(type: "词语", content: "甲", now: now), ReviewItem(type: "单词", content: "hello", now: now), ReviewItem(type: "英语背诵", content: "Good morning.", now: now)]
        try store.commit(state); return store
    }
    private func executor(_ store: LabStore, feedback: Bool = false) throws -> CoachToolExecutor {
        let tools = CoachToolExecutor(store: store, feedback: feedback, now: now, reviewsOnly: true)
        _ = try tools.execute(ToolCall(name: "query_history", arguments: "{}"))
        _ = try tools.execute(ToolCall(name: "query_plans", arguments: "{}"))
        return tools
    }
    private func call(ids: [UUID], date: String = "2026-10-29") throws -> ToolCall {
        ToolCall(name: "upsert_plan", arguments: try Codec.text(PlanArguments(date: date, title: "每日复习", itemIDs: ids, rationale: "已到期，按真实错误记录排序。")))
    }
    func testFeedbackProcessedAfterMidnightDoesNotBecomeNextDayDictation() throws {
        let store = try environment()
        var state = store.state
        let item = state.items[0]
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        state.items[0].nextReviewAt = tomorrow
        var record = ReviewRecord(itemID: item.id, correct: false, oldStage: 1, newStage: 0, now: now)
        record.modeRawValue = "scheduled"
        var feedback = DictationSession(title: "午夜后处理学情", type: "词语", date: tomorrow, now: tomorrow)
        feedback.practiceMode = "feedback"; feedback.reviewedAt = tomorrow
        var entry = DictationEntry(sessionID: feedback.id, item: item, order: 0, now: tomorrow)
        entry.resultRawValue = "错误"
        state.records = [record]; state.sessions = [feedback]; state.entries = [entry]
        try store.commit(state)
        let tools = try executor(store, feedback: true)
        _ = try tools.execute(call(ids: [item.id], date: Codec.day(tomorrow)))
        XCTAssertEqual(store.state.plans.first?.itemIDs, [item.id])
        // An actual dictation judged on that day still excludes the content.
        var updated = store.state
        updated.sessions[0].practiceMode = nil
        try store.commit(updated)
        XCTAssertThrowsError(try executor(store, feedback: true).execute(call(ids: [item.id], date: Codec.day(tomorrow))))
    }

    func testOneQuotaIncludesCompletedReviewsAcrossAllSubjects() throws {
        let store = try environment(limit: 2)
        var state = store.state
        state.records = [ReviewRecord(itemID: state.items[0].id, correct: true, oldStage: 0, newStage: 1, now: now)]
        state.records[0].modeRawValue = "scheduled"
        try store.commit(state)
        let tools = try executor(store)
        XCTAssertThrowsError(try tools.execute(call(ids: Array(state.items.dropFirst().map(\.id)))))
        _ = try tools.execute(call(ids: [state.items[1].id]))
        XCTAssertEqual(store.state.plans.first?.itemIDs, [state.items[1].id])
        XCTAssertEqual(store.state.sessions.first?.practiceMode, "coachReview")
    }
    func testCompletedAndDictatedContentCannotBeRescheduledToday() throws {
        let store = try environment()
        var state = store.state
        state.records = [ReviewRecord(itemID: state.items[0].id, correct: false, oldStage: 1, newStage: 0, now: now)]
        var input = DictationSession(title: "独立听写", type: "单词", date: now, now: now)
        input.reviewedAt = now
        var entry = DictationEntry(sessionID: input.id, item: state.items[1], order: 0, now: now)
        entry.resultRawValue = "错误"
        state.sessions = [input]; state.entries = [entry]; try store.commit(state)
        let tools = try executor(store)
        XCTAssertThrowsError(try tools.execute(call(ids: [state.items[0].id])))
        XCTAssertThrowsError(try tools.execute(call(ids: [state.items[1].id])))
        XCTAssertTrue(store.state.plans.isEmpty)
        XCTAssertEqual(store.state.sessions, [input])
    }
    func testFutureDueDatesAreEnforcedAndFeedbackStartsTomorrow() throws {
        let store = try environment()
        var state = store.state
        state.items[0].nextReviewAt = Calendar.current.date(byAdding: .day, value: 3, to: now)!
        try store.commit(state)
        let tools = try executor(store, feedback: true)
        XCTAssertThrowsError(try tools.execute(call(ids: [state.items[0].id])))
        XCTAssertThrowsError(try tools.execute(call(ids: [state.items[0].id], date: "2026-10-30")))
        _ = try tools.execute(call(ids: [state.items[0].id], date: "2026-11-01"))
        XCTAssertEqual(store.state.items[0].stage, 0)
        XCTAssertEqual(store.state.items[0].nextReviewAt, state.items[0].nextReviewAt)
    }
    func testPendingInputIsIndependentAndDoesNotBlockDueReview() throws {
        let store = try environment()
        var state = store.state
        let input = DictationSession(title: "家长录入", type: "词语", date: now, now: now)
        let entry = DictationEntry(sessionID: input.id, item: state.items[0], order: 0, now: now)
        state.sessions = [input]; state.entries = [entry]; try store.commit(state)
        _ = try executor(store).execute(call(ids: [state.items[0].id]))
        XCTAssertEqual(store.state.sessions.first { $0.id == input.id }, input)
        XCTAssertEqual(store.state.entries.first { $0.id == entry.id }, entry)
        XCTAssertEqual(store.state.plans.count, 1)
    }
    func testNetworkFailureCannotClaimReviewSelectionSaved() async throws {
        let store = try environment()
        let transport = ScriptedTransport([])
        let agent = CoachAgent(store: store, transport: transport, reviewsOnly: true)
        await agent.run(apiKey: "test-only-key", now: now)
        XCTAssertNotNil(agent.lastError)
        XCTAssertTrue(store.state.plans.isEmpty)
        XCTAssertTrue(store.state.completedTriggers.isEmpty)
    }

    func testDailyCheckCompletesWithoutModelWhenOnlyFutureOrMasteredItemsExist() async throws {
        let store = try environment()
        var state = store.state
        state.items[0].nextReviewAt = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        state.items[1].nextReviewAt = .distantFuture
        state.items[2].nextReviewAt = Calendar.current.date(byAdding: .day, value: 8, to: now)!
        try store.commit(state)
        let transport = ScriptedTransport([])
        let agent = CoachAgent(store: store, transport: transport, reviewsOnly: true)

        await agent.run(apiKey: "test-only-key", now: now)
        await agent.run(apiKey: "test-only-key", now: now)
        let calls = await transport.count
        XCTAssertEqual(calls, 0)
        XCTAssertNil(agent.lastError)
        XCTAssertTrue(store.state.plans.isEmpty)
        XCTAssertEqual(store.state.completedTriggers, ["daily:2026-10-29:all:reviews:3"])
    }

    func testNoOpFeedbackDefersConsumptionUntilNativeCompletion() async throws {
        let store = try environment()
        var state = store.state
        state.items[0].nextReviewAt = .distantFuture
        state.items[1].nextReviewAt = Calendar.current.date(byAdding: .day, value: 8, to: now)!
        state.items[2].nextReviewAt = .distantFuture
        var feedback = DictationSession(title: "已掌握的复习", type: "词语", date: now, now: now)
        feedback.practiceMode = "feedback"; feedback.reviewedAt = now
        var entry = DictationEntry(sessionID: feedback.id, item: state.items[0], order: 0, now: now)
        entry.resultRawValue = "正确"
        state.sessions = [feedback]; state.entries = [entry]; state.pendingFeedbackSessionIDs = [feedback.id]
        try store.commit(state)
        let transport = ScriptedTransport([])
        let agent = CoachAgent(store: store, transport: transport, reviewsOnly: true)

        await agent.run(apiKey: "test-only-key", now: now, deferTriggerCompletion: true)
        let calls = await transport.count
        let trigger = "feedback:\(feedback.id.uuidString)"
        XCTAssertEqual(calls, 0)
        XCTAssertNil(agent.lastError)
        XCTAssertEqual(agent.completionTrigger, trigger)
        XCTAssertEqual(store.state.pendingFeedbackSessionIDs, [feedback.id])
        XCTAssertTrue(store.state.completedTriggers.isEmpty)
        XCTAssertTrue(store.state.plans.isEmpty)

        try store.finishTrigger(try XCTUnwrap(agent.completionTrigger))
        XCTAssertTrue(store.state.pendingFeedbackSessionIDs.isEmpty)
        XCTAssertEqual(store.state.completedTriggers, [trigger])
    }

    func testDailyNoOpCountsCompletedReviewsOutsideAuthorizedSubject() async throws {
        let store = try environment(limit: 1)
        var state = store.state
        state.configuration.subject = .chinese
        var completed = ReviewRecord(itemID: state.items[1].id, correct: true, oldStage: 0, newStage: 1, now: now)
        completed.modeRawValue = "scheduled"
        state.records = [completed]
        try store.commit(state)
        let transport = ScriptedTransport([])
        let agent = CoachAgent(store: store, transport: transport, reviewsOnly: true)

        await agent.run(apiKey: "test-only-key", now: now)
        let calls = await transport.count
        XCTAssertEqual(calls, 0)
        XCTAssertNil(agent.lastError)
        XCTAssertTrue(store.state.completedTriggers.contains("daily:2026-10-29:chinese:reviews:1"))
        XCTAssertTrue(store.state.plans.isEmpty)
    }

    func testModelCannotDeclareNoOpWhileFeedbackStillHasEligibleItems() async throws {
        let store = try environment()
        var state = store.state
        state.items[0].nextReviewAt = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        state.items[1].nextReviewAt = .distantFuture
        state.items[2].nextReviewAt = .distantFuture
        var feedback = DictationSession(title: "仍需复习", type: "词语", date: now, now: now)
        feedback.practiceMode = "feedback"; feedback.reviewedAt = now
        var entry = DictationEntry(sessionID: feedback.id, item: state.items[0], order: 0, now: now)
        entry.resultRawValue = "错误"
        state.sessions = [feedback]; state.entries = [entry]; state.pendingFeedbackSessionIDs = [feedback.id]
        try store.commit(state)
        let transport = ScriptedTransport([ChatMessage(role: "assistant", content: "没有需要安排的内容。")])
        let agent = CoachAgent(store: store, transport: transport, reviewsOnly: true)

        await agent.run(apiKey: "test-only-key", now: now, deferTriggerCompletion: true)
        let calls = await transport.count
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(agent.lastError?.contains("未保存") == true)
        XCTAssertNil(agent.completionTrigger)
        XCTAssertEqual(store.state.pendingFeedbackSessionIDs, [feedback.id])
        XCTAssertTrue(store.state.completedTriggers.isEmpty)
    }

    func testQueryPlansRedactsOtherSubjectsButIncludesAnonymousGlobalQuota() throws {
        let store = try environment(limit: 3)
        var state = store.state
        state.configuration.subject = .chinese
        let authorized = DictationSession(title: "语文计划", type: "词语", date: now, now: now)
        let privateSession = DictationSession(title: "PRIVATE_ENGLISH_TITLE", type: "单词", date: now, now: now)
        let mixed = DictationSession(title: "PRIVATE_MIXED_TITLE", type: "词语", date: now, now: now)
        state.items[1].content = "PRIVATE_ENGLISH_CONTENT"
        state.items[1].prompt = "PRIVATE_ENGLISH_PROMPT"
        state.sessions = [authorized, privateSession, mixed]
        state.entries = [
            DictationEntry(sessionID: authorized.id, item: state.items[0], order: 0, now: now),
            DictationEntry(sessionID: privateSession.id, item: state.items[1], order: 0, now: now),
            DictationEntry(sessionID: mixed.id, item: state.items[0], order: 0, now: now),
            DictationEntry(sessionID: mixed.id, item: state.items[1], order: 1, now: now)
        ]
        var completed = ReviewRecord(itemID: state.items[1].id, correct: true, oldStage: 0, newStage: 1, now: now)
        completed.modeRawValue = "scheduled"; state.records = [completed]
        try store.commit(state)

        let tools = CoachToolExecutor(store: store, feedback: false, now: now, reviewsOnly: true)
        let output = try tools.execute(ToolCall(name: "query_plans", arguments: "{}"))
        XCTAssertFalse(output.contains("PRIVATE_"))
        XCTAssertFalse(output.contains(state.items[1].id.uuidString))
        XCTAssertFalse(output.contains(privateSession.id.uuidString))
        XCTAssertTrue(output.contains("语文计划"))
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)),
              let plansValue = root["plans"], case .array(let plans) = plansValue,
              let quotaValue = root["review_quota"], case .array(let quota) = quotaValue,
              let todayValue = quota.first, case .object(let today) = todayValue else {
            return XCTFail("Missing authorized plans or anonymous quota")
        }
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(quota.count, 8)
        XCTAssertEqual(today["completed_reviews"], .number(1))
        XCTAssertEqual(today["remaining_reviews"], .number(2))
    }
}
