import XCTest
@testable import CoachCore

private actor FeedbackPagingTransport: ChatTransport {
    let itemID: UUID
    let date: String
    private(set) var calls = 0
    init(itemID: UUID, date: String) { self.itemID = itemID; self.date = date }
    func complete(messages: [ChatMessage], model: String, apiKey: String) async throws -> ChatReply {
        calls += 1
        switch calls {
        case 1:
            return .init(message: .init(role: "assistant", calls: [
                .init(id: "feedback-history", name: "query_history", arguments: "{}"),
                .init(id: "feedback-plans", name: "query_plans", arguments: "{}")
            ]))
        case 2:
            guard let history = messages.first(where: { $0.tool_call_id == "feedback-history" })?.content,
                  history.contains(itemID.uuidString) else { throw LabError.invalid("本次错题被历史分页遗漏。") }
            let args = PlanArguments(date: date, title: "本次错题复习", itemIDs: [itemID], rationale: "依据本次错误，按到期日补练。")
            return .init(message: .init(role: "assistant", calls: [.init(name: "upsert_plan", arguments: try Codec.text(args))]))
        default:
            return .init(message: .init(role: "assistant", content: "已保存本次错题的后续复习。"))
        }
    }
}

@MainActor final class CoachFeedbackPagingTests: XCTestCase {
    private let now = Codec.date("2026-10-29")!.addingTimeInterval(3600 * 12)

    private func environment() throws -> (LabStore, UUID, [ReviewItem], [ReviewItem]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try LabStore(fileURL: directory.appendingPathComponent("lab.json"))
        var state = LabState()
        state.configuration.isEnabled = true; state.configuration.subject = .english; state.configuration.dailyLimit = 15
        let backlog = (0..<180).map { index -> ReviewItem in
            var item = ReviewItem(type: "单词", content: "old-\(index)", now: now)
            item.nextReviewAt = Calendar.current.date(byAdding: .day, value: -5, to: now)!
            item.consecutiveWrongCount = 9
            return item
        }
        let wrong = (0..<7).map { index -> ReviewItem in
            var item = ReviewItem(type: "单词", content: "recent-wrong-\(index)", now: now)
            item.nextReviewAt = Calendar.current.date(byAdding: .day, value: 1, to: now)!
            item.consecutiveWrongCount = 1
            return item
        }
        let correct = (0..<3).map { index -> ReviewItem in
            var item = ReviewItem(type: "单词", content: "recent-correct-\(index)", now: now)
            item.nextReviewAt = Calendar.current.date(byAdding: .day, value: 3, to: now)!
            return item
        }
        var feedback = DictationSession(title: "本次正式复习", type: "单词", date: now, now: now)
        feedback.practiceMode = "feedback"; feedback.reviewedAt = now
        let reviewed = wrong + correct
        state.items = backlog + reviewed
        state.sessions = [feedback]
        state.entries = reviewed.enumerated().map { offset, item in
            var entry = DictationEntry(sessionID: feedback.id, item: item, order: offset, now: now)
            entry.resultRawValue = offset < wrong.count ? "错误" : "正确"
            return entry
        }
        state.records = reviewed.enumerated().map { offset, item in
            var record = ReviewRecord(itemID: item.id, correct: offset >= wrong.count, oldStage: 0, newStage: 0, now: now)
            record.modeRawValue = "scheduled"
            return record
        }
        state.pendingFeedbackSessionIDs = [feedback.id]
        try store.commit(state)
        return (store, feedback.id, wrong, correct)
    }

    private func queriedItems(_ text: String) throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try XCTUnwrap(root["items"] as? [[String: Any]])
    }

    func testFeedbackWrongAndCorrectItemsAppearBeforeLargeOverdueBacklog() throws {
        let (store, feedbackID, wrong, correct) = try environment()
        let regular = CoachToolExecutor(store: store, feedback: false, now: now, reviewsOnly: true)
        let original = try queriedItems(regular.execute(.init(name: "query_history", arguments: "{}")))
        XCTAssertEqual(original.count, 60)
        XCTAssertTrue(Set(original.compactMap { $0["id"] as? String }).isDisjoint(with: Set(wrong.map { $0.id.uuidString })))

        let feedback = CoachToolExecutor(store: store, feedback: true, now: now, reviewsOnly: true, feedbackSessionID: feedbackID)
        let first = try queriedItems(feedback.execute(.init(name: "query_history", arguments: "{}")))
        XCTAssertEqual(first.count, 60)
        XCTAssertEqual(Set(first.prefix(7).compactMap { $0["id"] as? String }), Set(wrong.map { $0.id.uuidString }))
        XCTAssertEqual(Set(first.dropFirst(7).prefix(3).compactMap { $0["id"] as? String }), Set(correct.map { $0.id.uuidString }))
        XCTAssertTrue(first.prefix(10).allSatisfy { $0["is_current_feedback"] as? Bool == true })
        XCTAssertTrue(first.dropFirst(10).allSatisfy { $0["is_current_feedback"] as? Bool == false })
    }

    func testTargetedReadReturnsRealHistoryAndGrantsOnlyReturnedIDs() throws {
        let (store, _, wrong, _) = try environment()
        let tools = CoachToolExecutor(store: store, feedback: true, now: now, reviewsOnly: true)
        _ = try tools.execute(.init(name: "query_history", arguments: "{}"))
        _ = try tools.execute(.init(name: "query_plans", arguments: "{}"))
        func plan(_ id: UUID) throws -> ToolCall {
            .init(name: "upsert_plan", arguments: try Codec.text(PlanArguments(date: "2026-10-30", title: "补练", itemIDs: [id], rationale: "本次判错，明日到期。")))
        }
        XCTAssertThrowsError(try tools.execute(plan(wrong[0].id)))
        let arguments = try Codec.text(["item_ids": [wrong[0].id]])
        let result = try queriedItems(tools.execute(.init(name: "query_history", arguments: arguments)))
        XCTAssertEqual(result.compactMap { $0["id"] as? String }, [wrong[0].id.uuidString])
        XCTAssertEqual(result.first?["next_review"] as? String, "2026-10-30")
        let history = try XCTUnwrap(result.first?["history"] as? [[String: Any]])
        XCTAssertEqual(history.first?["result"] as? String, "wrong")
        _ = try tools.execute(plan(wrong[0].id))
        XCTAssertEqual(store.state.plans.first?.itemIDs, [wrong[0].id])
        XCTAssertThrowsError(try tools.execute(plan(wrong[1].id)))
    }

    func testTargetedReadRejectsUnknownOutOfScopeAndUnboundedQueriesAtomically() throws {
        let (store, _, wrong, _) = try environment()
        var state = store.state
        let chinese = ReviewItem(type: "词语", content: "未授权", now: now)
        state.items.append(chinese); try store.commit(state)
        let tools = CoachToolExecutor(store: store, feedback: true, now: now, reviewsOnly: true)
        for ids in [[], [UUID()], [chinese.id], [wrong[0].id, UUID()], [wrong[0].id, wrong[0].id], Array(state.items.prefix(101).map(\.id))] {
            XCTAssertThrowsError(try tools.execute(.init(name: "query_history", arguments: try Codec.text(["item_ids": ids]))))
        }
        let combined = JSONValue.object(["offset": .number(0), "item_ids": .array([.string(wrong[0].id.uuidString)])])
        XCTAssertThrowsError(try tools.execute(.init(name: "query_history", arguments: try Codec.text(combined))))
        _ = try tools.execute(.init(name: "query_history", arguments: "{}"))
        _ = try tools.execute(.init(name: "query_plans", arguments: "{}"))
        let args = PlanArguments(date: "2026-10-30", title: "补练", itemIDs: [wrong[0].id], rationale: "不能凭失败的混合查询获得权限。")
        XCTAssertThrowsError(try tools.execute(.init(name: "upsert_plan", arguments: try Codec.text(args))))
        XCTAssertTrue(store.state.plans.isEmpty)
    }

    func testFeedbackAgentSchedulesRecentWrongItemInThreeRequestsDespiteLargeHistory() async throws {
        let (store, _, wrong, _) = try environment()
        let transport = FeedbackPagingTransport(itemID: wrong[0].id, date: "2026-10-30")
        let agent = CoachAgent(store: store, transport: transport, reviewsOnly: true)
        await agent.run(apiKey: "test-only-key", now: now)
        XCTAssertNil(agent.lastError)
        XCTAssertTrue(store.state.pendingFeedbackSessionIDs.isEmpty)
        XCTAssertEqual(store.state.plans.first?.itemIDs, [wrong[0].id])
        let calls = await transport.calls
        XCTAssertEqual(calls, 3)
    }
}
