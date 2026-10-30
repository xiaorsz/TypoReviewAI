import XCTest
@testable import CoachCore

@MainActor final class CoachResponsivenessTests: XCTestCase {
    private let now = Codec.date("2026-10-29")!.addingTimeInterval(3600)

    private func fileURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coach-responsiveness-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("lab.json")
    }

    private func fixture(count: Int = 1) -> LabState {
        var state = LabState()
        state.configuration.isEnabled = true
        state.configuration.subject = .all
        state.reviewPlannerVersion = 1
        state.items = (0..<count).map { ReviewItem(type: "词语", content: "复习内容\($0)", prompt: "真实题库提示", now: now) }
        state.records = state.items.map { ReviewRecord(itemID: $0.id, correct: false, oldStage: 1, newStage: 0, now: now.addingTimeInterval(-86400)) }
        return state
    }

    private func replies(for itemID: UUID, date: String, rationale: String = "根据真实到期记录安排。") throws -> [ChatMessage] {
        let args = PlanArguments(date: date, title: "每日复习", itemIDs: [itemID], rationale: rationale)
        return [
            ChatMessage(role: "assistant", calls: [ToolCall(name: "query_history", arguments: "{}"), ToolCall(name: "query_plans", arguments: "{}")]),
            ChatMessage(role: "assistant", calls: [ToolCall(name: "upsert_plan", arguments: try Codec.text(args))]),
            ChatMessage(role: "assistant", content: "已保存复习安排。")
        ]
    }

    func testMetadataPersistenceRetainsFullMemorySnapshotButDoesNotRewriteLearningHistory() throws {
        let url = fileURL()
        let store = try LabStore(fileURL: url, persistsLearningSnapshot: false)
        var state = fixture(count: 500)
        let item = state.items[0]
        let manual = DictationSession(title: "独立听写录入", type: "词语", date: now, now: now)
        var planned = DictationSession(title: "AI 复习", type: "词语", date: now, now: now)
        planned.practiceMode = "coachReview"
        var feedback = DictationSession(title: "本次新判定", type: "词语", date: now, now: now)
        feedback.practiceMode = "feedback"; feedback.reviewedAt = now
        state.sessions = [manual, planned, feedback]
        state.entries = state.sessions.map { DictationEntry(sessionID: $0.id, item: item, order: 0, now: now) }
        state.plans = [CoachPlan(id: UUID(), sessionID: planned.id, itemIDs: [item.id], rationale: "已保存的安排", subject: .all, createdAt: now, updatedAt: now)]
        state.pendingFeedbackSessionIDs = [feedback.id]
        state.completedTriggers = ["daily:2026-10-28:all:reviews:15"]

        try store.commit(state)
        XCTAssertEqual(store.state, state)
        try store.appendLog(runID: UUID(), kind: "检查", message: "元数据写盘不应复制全部题库与历史。")
        XCTAssertEqual(store.state.items, state.items)
        XCTAssertEqual(store.state.records, state.records)
        XCTAssertEqual(store.state.sessions, state.sessions)
        XCTAssertEqual(store.state.entries, state.entries)

        let bytes = try Data(contentsOf: url)
        let durable = try Codec.decoder().decode(LabState.self, from: bytes)
        XCTAssertTrue(durable.items.isEmpty)
        XCTAssertTrue(durable.records.isEmpty)
        XCTAssertEqual(Set(durable.sessions.map(\.id)), [planned.id, feedback.id])
        XCTAssertEqual(Set(durable.entries.map(\.sessionID)), [planned.id, feedback.id])
        XCTAssertEqual(durable.configuration, state.configuration)
        XCTAssertEqual(durable.plans, state.plans)
        XCTAssertEqual(durable.pendingFeedbackSessionIDs, [feedback.id])
        XCTAssertEqual(durable.completedTriggers, state.completedTriggers)
        XCTAssertEqual(durable.logs.last?.message, store.state.logs.last?.message)
        XCTAssertLessThan(bytes.count, try Codec.encoder().encode(store.state).count / 4)

        let reopened = try LabStore(fileURL: url, persistsLearningSnapshot: false)
        XCTAssertEqual(reopened.state.configuration, state.configuration)
        XCTAssertEqual(reopened.state.plans, state.plans)
        XCTAssertEqual(reopened.state.logs.map(\.id), store.state.logs.map(\.id))
        XCTAssertTrue(reopened.state.items.isEmpty)
        XCTAssertTrue(reopened.state.records.isEmpty)
        XCTAssertFalse(reopened.state.sessions.contains { $0.id == manual.id })
    }

    func testDefaultPersistenceStillRestoresLearningData() throws {
        let url = fileURL()
        let store = try LabStore(fileURL: url)
        var state = fixture(count: 3)
        let session = DictationSession(title: "旧原型听写", type: "词语", date: now, now: now)
        state.sessions = [session]
        state.entries = [DictationEntry(sessionID: session.id, item: state.items[0], order: 0, now: now)]
        try store.commit(state)
        let reopened = try LabStore(fileURL: url)
        XCTAssertEqual(reopened.state.items, state.items)
        XCTAssertEqual(reopened.state.records, state.records)
        XCTAssertEqual(reopened.state.sessions, state.sessions)
        XCTAssertEqual(reopened.state.entries, state.entries)
    }

    func testManualDailyRecheckRequestsFreshToolsButReusesTheSamePlan() async throws {
        let store = try LabStore(fileURL: fileURL())
        let state = fixture()
        try store.commit(state)
        let id = state.items[0].id
        let date = Codec.day(now)
        let secondRationale = "家长手动重新检查，仍按同一日期安排。"
        let transport = try ScriptedTransport(replies(for: id, date: date) + replies(for: id, date: date, rationale: secondRationale))
        let agent = CoachAgent(store: store, transport: transport, reviewsOnly: true)

        await agent.run(apiKey: "test-only-key", now: now)
        XCTAssertNil(agent.lastError)
        let firstPlan = try XCTUnwrap(store.state.plans.first)
        let firstCalls = await transport.count
        XCTAssertEqual(firstCalls, 3)
        await agent.run(apiKey: "test-only-key", now: now)
        let automaticCalls = await transport.count
        XCTAssertEqual(automaticCalls, firstCalls)

        await agent.run(apiKey: "test-only-key", now: now, forceDailyRecheck: true)
        let manualCalls = await transport.count
        XCTAssertEqual(manualCalls, 6)
        XCTAssertNil(agent.lastError)
        XCTAssertEqual(store.state.plans.count, 1)
        XCTAssertEqual(store.state.plans.first?.sessionID, firstPlan.sessionID)
        XCTAssertEqual(store.state.plans.first?.rationale, secondRationale)
        XCTAssertEqual(store.state.sessions.count, 1)
        XCTAssertEqual(store.entries(for: firstPlan.sessionID).map(\.itemID), [id])
    }

    func testManualRecheckDoesNotReplayAnAlreadyConsumedFeedbackTrigger() async throws {
        let store = try LabStore(fileURL: fileURL())
        var state = fixture()
        var feedback = DictationSession(title: "新判定", type: "词语", date: now, now: now)
        feedback.practiceMode = "feedback"; feedback.reviewedAt = now
        var entry = DictationEntry(sessionID: feedback.id, item: state.items[0], order: 0, now: now)
        entry.resultRawValue = "错误"
        state.sessions = [feedback]; state.entries = [entry]; state.pendingFeedbackSessionIDs = [feedback.id]
        try store.commit(state)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let transport = try ScriptedTransport(replies(for: state.items[0].id, date: Codec.day(tomorrow)))
        let agent = CoachAgent(store: store, transport: transport, reviewsOnly: true)
        await agent.run(apiKey: "test-only-key", feedbackSessionID: feedback.id, now: now)
        XCTAssertNil(agent.lastError)
        XCTAssertTrue(store.state.pendingFeedbackSessionIDs.isEmpty)
        let firstCalls = await transport.count

        await agent.run(apiKey: "test-only-key", feedbackSessionID: feedback.id, now: now, forceDailyRecheck: true)
        let retryCalls = await transport.count
        XCTAssertEqual(firstCalls, 3)
        XCTAssertEqual(retryCalls, firstCalls)
        XCTAssertEqual(store.state.plans.count, 1)
    }

    func testDecoderRetainsMixedFractionalAndStandardDatePrecision() throws {
        struct Dates: Decodable { let values: [Date] }
        let strings = ["2026-10-29T08:30:00.125Z", "2026-10-29T08:30:00Z", "2026-10-29T16:30:00.875+08:00"]
        let repeated = (0..<100).flatMap { _ in strings }
        let data = try JSONSerialization.data(withJSONObject: ["values": repeated])
        let values = try Codec.decoder().decode(Dates.self, from: data).values
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: strings[1]))
        XCTAssertEqual(values.count, 300)
        for index in stride(from: 0, to: values.count, by: 3) {
            XCTAssertEqual(values[index].timeIntervalSince(base), 0.125, accuracy: 0.0001)
            XCTAssertEqual(values[index + 1], base)
            XCTAssertEqual(values[index + 2].timeIntervalSince(base), 0.875, accuracy: 0.0001)
        }
    }
}
