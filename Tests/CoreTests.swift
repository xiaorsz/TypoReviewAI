import XCTest
@testable import CoachCore

actor ScriptedTransport: ChatTransport {
    var replies: [ChatReply]
    var count = 0
    init(_ messages: [ChatMessage]) { replies = messages.map { ChatReply(message: $0, totalTokens: 20) } }
    func complete(messages: [ChatMessage], model: String, apiKey: String) async throws -> ChatReply {
        count += 1
        guard !replies.isEmpty else { throw LabError.invalid("模拟网络中断") }
        return replies.removeFirst()
    }
}

actor WaitingTransport: ChatTransport {
    var count = 0
    func complete(messages: [ChatMessage], model: String, apiKey: String) async throws -> ChatReply {
        count += 1
        try await Task.sleep(nanoseconds: 100_000_000)
        return ChatReply(message: ChatMessage(role: "assistant", calls: [ToolCall(name: "query_history", arguments: "{}")]))
    }
}

@MainActor final class CoreTests: XCTestCase {
    let now = Codec.date("2026-10-29")!.addingTimeInterval(3600)

    func store() throws -> LabStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coach-tests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try LabStore(fileURL: directory.appendingPathComponent("lab.json"))
    }
    func state() -> LabState {
        var s = LabState()
        s.configuration.isEnabled = true
        let item = ReviewItem(type: "词语", content: "辨别", prompt: "biàn bié", now: now)
        s.items = [item]
        return s
    }
    func fixture(_ state: LabState, version: Int = 5) throws -> Data {
        try Codec.encoder().encode(JSONValue.object([
            "version": .number(Double(version)), "exportedAt": .string("2026-10-28T08:30:00.125Z"),
            "appVersion": .string("1.0"), "settings": .object([
                "childName": .string("小禾"), "dailyLimit": .number(12), "aiSummaryEnabled": .bool(true),
                "serverToken": .string("DO-NOT-IMPORT"), "aiSummaryModelRawValue": .string("old-model")
            ]),
            "reviewItems": try .value(state.items), "reviewRecords": try .value(state.records),
            "dictationSessions": try .value(state.sessions), "dictationEntries": try .value(state.entries),
            "taskItems": .array([.object(["title": .string("忽略的任务")])]), "mediaAssets": .array([])
        ]))
    }
    func reads(_ executor: CoachToolExecutor) throws {
        _ = try executor.execute(ToolCall(name: "query_history", arguments: "{}"))
        _ = try executor.execute(ToolCall(name: "query_plans", arguments: "{}"))
    }
    func plan(_ s: LabState, date: String = "2026-10-29", ids: [UUID]? = nil) throws -> ToolCall {
        ToolCall(name: "upsert_plan", arguments: try Codec.text(PlanArguments(date: date, title: "字词巩固",
            itemIDs: ids ?? [s.items[0].id], rationale: "根据到期记录练习辨别，先读准再独立书写。")))
    }

    func testImportsVersionsOneThroughFiveWithFractionalDatesAndWhitelistedSettings() async throws {
        for version in 1...5 {
            let source = state()
            let preview = try BackupImporter.preview(fixture(source, version: version), now: now)
            XCTAssertEqual(preview.state.items, source.items)
            XCTAssertEqual(preview.state.configuration.childName, "小禾")
            XCTAssertEqual(preview.state.configuration.dailyLimit, 12)
            XCTAssertEqual(preview.state.configuration.model, "deepseek-flash")
            XCTAssertFalse(preview.state.configuration.isEnabled)
            XCTAssertEqual(preview.exportedAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.125, accuracy: 0.001)
            XCTAssertTrue(preview.state.logs.isEmpty)
            XCTAssertTrue(preview.state.pendingFeedbackSessionIDs.isEmpty)
            XCTAssertFalse(try Codec.text(preview.state).contains("DO-NOT-IMPORT"))
        }
    }

    func testLegacySessionWithoutProgressAndValidAssociations() async throws {
        var source = state()
        let session = DictationSession(title: "旧听写", type: "词语", date: now, now: now)
        source.sessions = [session]
        source.entries = [DictationEntry(sessionID: session.id, item: source.items[0], order: 0, now: now)]
        var json = try JSONSerialization.jsonObject(with: fixture(source)) as! [String: Any]
        var sessions = json["dictationSessions"] as! [[String: Any]]
        sessions[0].removeValue(forKey: "currentEntryIndex"); json["dictationSessions"] = sessions
        let result = try BackupImporter.preview(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(result.state.sessions.first?.id, session.id)
        XCTAssertEqual(result.state.sessions.first?.currentEntryIndex, 0)
        XCTAssertEqual(result.state.entries.first?.itemID, source.items.first?.id)
    }

    func testUnsupportedContentIsSkippedAlongWithItsHistory() async throws {
        var source = state()
        let unsupported = ReviewItem(type: "暂不支持类型", content: "A long sentence.", now: now)
        source.items.append(unsupported)
        source.records.append(ReviewRecord(itemID: unsupported.id, correct: true, oldStage: 0, newStage: 1, now: now))
        let result = try BackupImporter.preview(fixture(source))
        XCTAssertEqual(result.state.items.count, 1); XCTAssertTrue(result.state.records.isEmpty)
        XCTAssertEqual(result.skippedItems, 1)
    }

    func testInvalidVersionDuplicateIDsAndDamagedFilesAreRejected() async throws {
        var source = state()
        XCTAssertThrowsError(try BackupImporter.preview(fixture(source, version: 6)))
        XCTAssertThrowsError(try BackupImporter.preview(Data("{broken".utf8)))
        source.items.append(source.items[0])
        XCTAssertThrowsError(try BackupImporter.preview(fixture(source)))
    }

    func testOrphanRecordsAndEntriesAreSkippedWithoutBlockingValidData() async throws {
        var source = state()
        let session = DictationSession(title: "有效听写", type: "词语", date: now, now: now)
        source.sessions = [session]
        let validRecord = ReviewRecord(itemID: source.items[0].id, correct: false, oldStage: 0, newStage: 1, now: now)
        source.records = [validRecord, ReviewRecord(itemID: UUID(), correct: true, oldStage: 0, newStage: 2, now: now)]
        let validEntry = DictationEntry(sessionID: session.id, item: source.items[0], order: 0, now: now)
        source.entries = [validEntry, DictationEntry(sessionID: UUID(), item: source.items[0], order: 0, now: now)]

        let result = try BackupImporter.preview(fixture(source))
        XCTAssertEqual(result.state.items, source.items)
        XCTAssertEqual(result.state.records, [validRecord])
        XCTAssertEqual(result.state.sessions, [session])
        XCTAssertEqual(result.state.entries, [validEntry])
        XCTAssertEqual(result.orphanReviewRecords, 1)
        XCTAssertEqual(result.orphanDictationEntries, 1)
        XCTAssertEqual(result.skippedReviewRecords, 1)
        XCTAssertEqual(result.skippedDictationEntries, 1)
        XCTAssertTrue(result.summary.contains("缺少对应题目：1 条复习记录"))
        XCTAssertTrue(result.summary.contains("缺少对应计划：1 条听写条目"))
        XCTAssertTrue(result.state.pendingFeedbackSessionIDs.isEmpty)
    }

    func testSkippedUnsupportedHistoryIsNotMisreportedAsOrphaned() async throws {
        var source = state()
        let unsupported = ReviewItem(type: "暂不支持类型", content: "A long sentence.", now: now)
        source.items.append(unsupported)
        source.records = [
            ReviewRecord(itemID: unsupported.id, correct: true, oldStage: 0, newStage: 1, now: now),
            ReviewRecord(itemID: UUID(), correct: false, oldStage: 1, newStage: 1, now: now)
        ]
        let unsupportedSession = DictationSession(title: "背诵", type: "暂不支持类型", date: now, now: now)
        source.sessions = [unsupportedSession]
        source.entries = [DictationEntry(sessionID: unsupportedSession.id, item: unsupported, order: 0, now: now)]
        let result = try BackupImporter.preview(fixture(source))
        XCTAssertEqual(result.skippedItems, 1)
        XCTAssertEqual(result.skippedSessions, 1)
        XCTAssertEqual(result.skippedReviewRecords, 2)
        XCTAssertEqual(result.skippedDictationEntries, 1)
        XCTAssertEqual(result.orphanReviewRecords, 1)
        XCTAssertEqual(result.orphanDictationEntries, 0)
        XCTAssertTrue(result.state.records.isEmpty)
        XCTAssertTrue(result.state.entries.isEmpty)
    }

    func testOrphanImportOnlyReplacesOnCommitAndNeverReconstructsMissingParents() async throws {
        let store = try store(); try store.commit(state())
        let originalState = store.state
        let originalDisk = try Data(contentsOf: store.fileURL)
        var source = LabState()
        source.records = [ReviewRecord(itemID: UUID(), correct: false, oldStage: 0, newStage: 1, now: now)]
        source.entries = [DictationEntry(sessionID: UUID(), item: originalState.items[0], order: 0, now: now)]
        let backupURL = store.fileURL.deletingLastPathComponent().appendingPathComponent("source-backup.json")
        let backupBytes = try fixture(source)
        try backupBytes.write(to: backupURL)
        let preview = try BackupImporter.preview(Data(contentsOf: backupURL))
        XCTAssertEqual(store.state, originalState)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalDisk)
        XCTAssertTrue(preview.state.items.isEmpty)
        XCTAssertTrue(preview.state.sessions.isEmpty)
        XCTAssertEqual(preview.orphanReviewRecords, 1)
        XCTAssertEqual(preview.orphanDictationEntries, 1)
        try store.replace(with: preview)
        XCTAssertTrue(store.state.records.isEmpty)
        XCTAssertTrue(store.state.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: backupURL), backupBytes)
    }

    func testOrphanToleranceDoesNotWeakenInvalidResultValidation() async throws {
        var source = state()
        var record = ReviewRecord(itemID: source.items[0].id, correct: false, oldStage: 0, newStage: 1, now: now)
        record.resultRawValue = "unknown"
        source.records = [record, ReviewRecord(itemID: UUID(), correct: false, oldStage: 0, newStage: 1, now: now)]
        XCTAssertThrowsError(try BackupImporter.preview(fixture(source)))
    }

    func testImportPreviewDoesNotMutateStoreAndRepeatedReplacementDoesNotDuplicate() async throws {
        let store = try store(); let original = state(); try store.commit(original)
        let originalBytes = try Data(contentsOf: store.fileURL)
        var other = state(); other.items[0].content = "温暖"
        let bytes = try fixture(other)
        let parsed = try BackupImporter.preview(bytes)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalBytes)
        try store.replace(with: parsed); try store.replace(with: parsed)
        XCTAssertEqual(store.state.items.count, 1)
        XCTAssertEqual(store.state.items[0].content, "温暖")
        XCTAssertFalse(store.state.configuration.isEnabled)
        XCTAssertEqual(bytes, try fixture(other))
        XCTAssertThrowsError(try BackupImporter.preview(Data("bad".utf8)))
        XCTAssertEqual(store.state.items[0].content, "温暖")
    }

    func testFailedAtomicWritePreservesObservableState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coach-block-\(UUID())")
        try Data("file instead of directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LabStore(fileURL: root.appendingPathComponent("lab.json"))
        let before = store.state
        XCTAssertThrowsError(try store.commit(state()))
        XCTAssertEqual(store.state, before)
    }

    func testGradingIsIdempotentAcrossRestartAndPreservesPendingFeedback() async throws {
        let store = try store(); try store.commit(state())
        let sessionID = try store.createManualPractice(itemID: store.state.items[0].id, now: now)
        try store.begin(sessionID, now: now)
        let entryID = store.entries(for: sessionID)[0].id
        try store.mark(entryID, correct: false, now: now)
        XCTAssertTrue(try store.submit(sessionID, now: now))
        XCTAssertFalse(try store.submit(sessionID, now: now))
        let reloaded = try LabStore(fileURL: store.fileURL)
        XCTAssertEqual(reloaded.state.records.count, 1)
        XCTAssertEqual(reloaded.state.items[0].stage, 1)
        XCTAssertEqual(reloaded.state.pendingFeedbackSessionIDs, [sessionID])
        XCTAssertFalse(try reloaded.submit(sessionID, now: now))
        XCTAssertThrowsError(try reloaded.mark(entryID, correct: true))
    }

    func testUnfinishedGradingDoesNotAdvanceProgressAndHistoricalImportCreatesNoEvents() async throws {
        let store = try store(); try store.commit(state())
        let id = try store.createManualPractice(itemID: store.state.items[0].id, now: now)
        try store.begin(id, now: now)
        XCTAssertThrowsError(try store.submit(id, now: now))
        XCTAssertEqual(store.state.items[0].stage, 0)
        try store.mark(store.entries(for: id)[0].id, correct: true)
        _ = try store.submit(id, now: now)
        let imported = try BackupImporter.preview(fixture(store.state))
        XCTAssertNotNil(imported.state.sessions[0].reviewedAt)
        XCTAssertEqual(imported.state.records.count, 1)
        XCTAssertTrue(imported.state.pendingFeedbackSessionIDs.isEmpty)
    }

    func testSchedulerMatchesOriginalStandardAndFollowUpTransitions() async throws {
        var item = state().items[0]
        _ = ReviewScheduler.apply(correct: true, to: &item, now: now)
        XCTAssertEqual(item.stage, 2)
        XCTAssertEqual(Codec.day(item.nextReviewAt), "2026-10-31")
        _ = ReviewScheduler.apply(correct: false, to: &item, now: now)
        XCTAssertEqual(item.stage, 1)
        XCTAssertEqual(Codec.day(item.nextReviewAt), "2026-10-30")
        item.reviewTrackRawValue = "dictationFollowUp"; item.dictationFollowUpStep = 1
        _ = ReviewScheduler.apply(correct: true, to: &item, now: now)
        XCTAssertEqual(item.dictationFollowUpStep, 2)
        XCTAssertEqual(Codec.day(item.nextReviewAt), "2026-11-02")
        _ = ReviewScheduler.apply(correct: false, to: &item, now: now)
        XCTAssertTrue(item.isPriority); XCTAssertEqual(item.reviewTrackRawValue, "standard")
    }

    func testToolsRequireReadsAndRejectUnknownIDsWrongSubjectAndOverLimit() async throws {
        let store = try store(); var s = state()
        s.items.append(ReviewItem(type: "单词", content: "apple", now: now)); s.configuration.dailyLimit = 1
        try store.commit(s)
        let executor = CoachToolExecutor(store: store, feedback: false, now: now)
        XCTAssertThrowsError(try executor.execute(plan(s)))
        try reads(executor)
        XCTAssertThrowsError(try executor.execute(plan(s, ids: [UUID()])))
        XCTAssertThrowsError(try executor.execute(plan(s, ids: [s.items[1].id])))
        XCTAssertThrowsError(try executor.execute(plan(s, ids: [s.items[0].id, s.items[1].id])))
        XCTAssertTrue(store.state.sessions.isEmpty)
        _ = try executor.execute(plan(s))
        XCTAssertEqual(store.state.plans.count, 1)
        XCTAssertEqual(store.state.entries[0].itemID, s.items[0].id)
    }

    func testUpsertReusesSlotAndCannotTouchStartedCancelledOrManualSessions() async throws {
        let store = try store(); let s = state(); try store.commit(s)
        let executor = CoachToolExecutor(store: store, feedback: false, now: now); try reads(executor)
        _ = try executor.execute(plan(s)); let id = store.state.sessions[0].id
        _ = try executor.execute(plan(s))
        XCTAssertEqual(store.state.sessions.count, 1); XCTAssertEqual(store.state.sessions[0].id, id)
        try store.begin(id, now: now)
        let before = store.state
        XCTAssertThrowsError(try executor.execute(plan(s))); XCTAssertEqual(store.state, before)

        try store.commit(s)
        _ = try executor.execute(plan(s)); try store.cancel(store.state.sessions[0].id, now: now)
        XCTAssertThrowsError(try executor.execute(plan(s)))

        try store.commit(s)
        let manual = try store.createManualPractice(itemID: s.items[0].id, now: now)
        XCTAssertThrowsError(try executor.execute(plan(s)))
        XCTAssertEqual(store.state.sessions.first?.id, manual)
        XCTAssertTrue(store.state.plans.isEmpty)
    }

    func testDuplicateContentAndSameDayExistingEntriesAreRejected() async throws {
        let store = try store(); var s = state()
        s.items.append(ReviewItem(type: "词语", content: " 辨别 ", now: now))
        try store.commit(s)
        let executor = CoachToolExecutor(store: store, feedback: false, now: now); try reads(executor)
        XCTAssertThrowsError(try executor.execute(plan(s, ids: s.items.map(\.id))))
        _ = try store.createManualPractice(itemID: s.items[0].id, now: now)
        XCTAssertThrowsError(try executor.execute(plan(s, ids: [s.items[1].id])))
    }

    func testFeedbackDateAndPauseBoundaries() async throws {
        let store = try store(); let s = state(); try store.commit(s)
        let executor = CoachToolExecutor(store: store, feedback: true, now: now); try reads(executor)
        XCTAssertThrowsError(try executor.execute(plan(s)))
        XCTAssertThrowsError(try executor.execute(plan(s, date: "2026-11-06")))
        XCTAssertThrowsError(try executor.execute(plan(s, date: "2026-02-30")))
        _ = try executor.execute(plan(s, date: "2026-10-30"))
        var config = store.state.configuration; config.isEnabled = false; try store.configure(config)
        XCTAssertThrowsError(try executor.execute(plan(s, date: "2026-10-31")))
    }

    func testActualAgentLoopQueriesWritesAndReturnsActualPlanWithIdempotency() async throws {
        let store = try store(); let s = state(); try store.commit(s)
        let transport = ScriptedTransport([
            ChatMessage(role: "assistant", calls: [ToolCall(name: "query_history", arguments: "{}"), ToolCall(name: "query_plans", arguments: "{}")]),
            ChatMessage(role: "assistant", calls: [try plan(s)]),
            ChatMessage(role: "assistant", content: "已安排今天的字词巩固。")
        ])
        let agent = CoachAgent(store: store, transport: transport)
        await agent.run(apiKey: "test-key-never-sent", now: now)
        XCTAssertNil(agent.lastError); XCTAssertFalse(agent.isRunning)
        XCTAssertEqual(store.state.plans.count, 1)
        XCTAssertTrue(store.state.logs.contains { $0.kind == "完成" })
        await agent.run(apiKey: "test-key-never-sent", now: now)
        let count = await transport.count
        XCTAssertEqual(count, 3); XCTAssertEqual(store.state.sessions.count, 1)
        XCTAssertFalse(try Codec.text(store.state).contains("test-key"))
    }

    func testAgentUsesNewResultsToCreateTomorrowPlanAndConsumesFeedbackOnce() async throws {
        let store = try store(); let s = state(); try store.commit(s)
        let id = try store.createManualPractice(itemID: s.items[0].id, now: now)
        try store.begin(id, now: now); try store.mark(store.entries(for: id)[0].id, correct: false, now: now)
        _ = try store.submit(id, now: now)
        let transport = ScriptedTransport([
            ChatMessage(role: "assistant", calls: [ToolCall(name: "query_history", arguments: "{}"), ToolCall(name: "query_plans", arguments: "{}")]),
            ChatMessage(role: "assistant", calls: [try plan(s, date: "2026-10-30")]),
            ChatMessage(role: "assistant", content: "已保存明天的补练。")
        ])
        let agent = CoachAgent(store: store, transport: transport)
        await agent.run(apiKey: "test", now: now)
        XCTAssertNil(agent.lastError)
        XCTAssertTrue(store.state.pendingFeedbackSessionIDs.isEmpty)
        XCTAssertEqual(Codec.day(store.state.sessions.last!.scheduledDate), "2026-10-30")
        XCTAssertTrue(store.state.completedTriggers.contains("feedback:\(id.uuidString)"))
    }

    func testNetworkFailureAfterWriteRetainsPlanAndAllowsSafeRetry() async throws {
        let store = try store(); let s = state(); try store.commit(s)
        let transport = ScriptedTransport([
            ChatMessage(role: "assistant", calls: [ToolCall(name: "query_history", arguments: "{}"), ToolCall(name: "query_plans", arguments: "{}")]),
            ChatMessage(role: "assistant", calls: [try plan(s)])
        ])
        let agent = CoachAgent(store: store, transport: transport)
        await agent.run(apiKey: "test", now: now)
        XCTAssertNotNil(agent.lastError); XCTAssertEqual(store.state.sessions.count, 1)
        XCTAssertTrue(store.state.completedTriggers.isEmpty)
        XCTAssertEqual(try LabStore(fileURL: store.fileURL).state.sessions.count, 1)
        let retry = CoachAgent(store: store, transport: ScriptedTransport([
            ChatMessage(role: "assistant", calls: [ToolCall(name: "query_history", arguments: "{}"), ToolCall(name: "query_plans", arguments: "{}")]),
            ChatMessage(role: "assistant", content: "已有计划可用。")
        ]))
        await retry.run(apiKey: "test", now: now)
        XCTAssertNil(retry.lastError); XCTAssertEqual(store.state.sessions.count, 1)
    }

    func testAgentEnforcesFourRoundLimitAndRejectsFalseSuccess() async throws {
        let store = try store(); try store.commit(state())
        let transport = ScriptedTransport((0..<6).map { _ in ChatMessage(role: "assistant", calls: [ToolCall(name: "query_history", arguments: "{}")]) })
        let agent = CoachAgent(store: store, transport: transport)
        await agent.run(apiKey: "test", now: now)
        let count = await transport.count
        XCTAssertEqual(count, 4); XCTAssertTrue(agent.lastError?.contains("四轮") == true)
        let liar = CoachAgent(store: store, transport: ScriptedTransport([ChatMessage(role: "assistant", content: "全部安排好了")]))
        await liar.run(apiKey: "test", now: now)
        XCTAssertTrue(liar.lastError?.contains("未保存") == true)
        XCTAssertTrue(store.state.sessions.isEmpty)
    }

    func testPauseDuringNetworkWaitPreventsAllFurtherWrites() async throws {
        let store = try store(); try store.commit(state())
        let agent = CoachAgent(store: store, transport: WaitingTransport())
        let task = Task { await agent.run(apiKey: "test", now: now) }
        try await Task.sleep(nanoseconds: 20_000_000)
        agent.cancel()
        var config = store.state.configuration; config.isEnabled = false; try store.configure(config)
        await task.value
        XCTAssertTrue(store.state.sessions.isEmpty)
        XCTAssertTrue(store.state.completedTriggers.isEmpty)
        XCTAssertFalse(agent.isRunning)
    }

    func testRapidStartOnlySchedulesOneRequestAndCancellationReleasesIt() async throws {
        let store = try store(); try store.commit(state())
        let transport = WaitingTransport()
        let agent = CoachAgent(store: store, transport: transport)
        agent.start(apiKey: "test"); agent.start(apiKey: "test"); agent.start(apiKey: "test")
        try await Task.sleep(nanoseconds: 20_000_000)
        let count = await transport.count
        XCTAssertEqual(count, 1)
        agent.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(agent.isRunning)
        XCTAssertTrue(store.state.sessions.isEmpty)
    }

    func testReplacingDatasetWhileAIWaitsRejectsOldResponse() async throws {
        let store = try store(); try store.commit(state())
        let agent = CoachAgent(store: store, transport: WaitingTransport())
        let task = Task { await agent.run(apiKey: "test", now: now) }
        try await Task.sleep(nanoseconds: 20_000_000)
        try store.reset()
        let newID = store.state.datasetID
        await task.value
        XCTAssertEqual(store.state.datasetID, newID)
        XCTAssertTrue(store.state.logs.isEmpty)
        XCTAssertTrue(store.state.plans.isEmpty)
    }

    func testDailyCapAppliesAcrossSubjectsAndDraftGradesSurviveRestart() async throws {
        let store = try store(); var s = state(); s.configuration.dailyLimit = 1
        let english = ReviewItem(type: "单词", content: "apple", now: now)
        s.items.append(english); try store.commit(s)
        let chineseTools = CoachToolExecutor(store: store, feedback: false, now: now); try reads(chineseTools)
        _ = try chineseTools.execute(plan(s))
        var config = store.state.configuration; config.subject = .english; try store.configure(config)
        let englishTools = CoachToolExecutor(store: store, feedback: false, now: now); try reads(englishTools)
        XCTAssertThrowsError(try englishTools.execute(plan(s, ids: [english.id])))
        let id = store.state.sessions[0].id
        try store.begin(id, now: now)
        try store.mark(store.entries(for: id)[0].id, correct: false, now: now)
        try store.advance(id, to: 1, now: now)
        let reloaded = try LabStore(fileURL: store.fileURL)
        XCTAssertEqual(reloaded.entries(for: id)[0].resultRawValue, "错误")
        XCTAssertEqual(reloaded.state.sessions[0].currentEntryIndex, 1)
        XCTAssertTrue(reloaded.state.records.isEmpty)
        XCTAssertNotNil(reloaded.state.sessions[0].startedAt)
    }
}
