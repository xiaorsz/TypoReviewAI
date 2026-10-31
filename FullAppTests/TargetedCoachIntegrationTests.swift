import XCTest
import SwiftData
import CoachCore
@testable import CoachLab

private actor TargetedTestTransport: ChatTransport {
    var calls = 0
    var capturedMessages: [ChatMessage] = []
    let response: String
    let beforeReply: (@MainActor @Sendable () throws -> Void)?
    init(response: String, beforeReply: (@MainActor @Sendable () throws -> Void)? = nil) {
        self.response = response; self.beforeReply = beforeReply
    }
    func complete(messages: [ChatMessage], model: String, apiKey: String) async throws -> ChatReply {
        calls += 1
        capturedMessages = messages
        if let beforeReply { try await beforeReply() }
        if response == "FAIL" { throw LabError.invalid("测试网络失败") }
        return .init(message: .init(role: "assistant", content: response))
    }
}

private actor NextWordTestTransport: ChatTransport {
    var requestedWords: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    let held: XCTestExpectation
    let failSecond: Bool
    init(held: XCTestExpectation, failSecond: Bool = false) { self.held = held; self.failSecond = failSecond }
    func release() { gate?.resume(); gate = nil }
    func complete(messages: [ChatMessage], model: String, apiKey: String) async throws -> ChatReply {
        let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(messages.last?.content).utf8)) as? [String: Any])
        let word = try XCTUnwrap(facts["content"] as? String)
        requestedWords.append(word)
        let call = requestedWords.count
        if call == 2 {
            await withCheckedContinuation { gate = $0; held.fulfill() }
            if failSecond { throw LabError.invalid("测试预备下一词失败") }
        }
        let lesson = ["meaning": "测试词义", "structure": "", "example": "The word is \(word).",
                      "exampleTranslation": "这个词是 \(word)。", "question": "根据刚才的释义填写完整单词：____", "answer": word]
        let content = String(decoding: try JSONSerialization.data(withJSONObject: lesson), as: UTF8.self)
        return .init(message: .init(role: "assistant", content: content))
    }
}

@MainActor private final class TargetedCancelBox {
    weak var coordinator: TargetedCoachCoordinator?
}

@MainActor final class TargetedCoachIntegrationTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let now = CoachCore.Codec.date("2026-10-30")!.addingTimeInterval(12 * 3600)
    private let response = """
    {"strategy":"先辨析拼写，再联系语境回忆；具体错因还不确定。","exercises":[{"kind":"choice","prompt":"选择正确写法。","answer":"Portugal","choices":["Portugal","Portugla","Protugal"]},{"kind":"cloze","prompt":"Lisbon is the capital of ____.","answer":"Portugal","choices":[]}]}
    """

    private func setup() throws -> (ModelContext, AICoachCoordinator, CoachLab.ReviewItem, URL) {
        let schema = Schema([CoachLab.ReviewItem.self, CoachLab.ReviewRecord.self, CoachLab.DictationSession.self,
            CoachLab.DictationEntry.self, ReviewDailyPlan.self, AppSettings.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        containers.append(container)
        let context = container.mainContext
        let item = CoachLab.ReviewItem(type: .englishWord, content: "Portugal", prompt: "葡萄牙", stage: 2, nextReviewAt: now)
        context.insert(item)
        for days in [-4, -3, -1] {
            context.insert(CoachLab.ReviewRecord(itemID: item.id, reviewedAt: now.addingTimeInterval(Double(days) * 86400 + 0.125),
                result: .wrong, mode: .scheduled, oldStage: 2, newStage: 0))
        }
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let coach = AICoachCoordinator(fileURL: directory.appendingPathComponent("lab.json"))
        coach.bootstrap(context: context, settings: AppSettingsStore())
        var config = try XCTUnwrap(coach.store).state.configuration
        config.subject = .english; config.isEnabled = true
        try coach.store?.configure(config)
        return (context, coach, item, directory.appendingPathComponent("targeted.json"))
    }

    func testLocalClosedLoopUsesLaterNativeRecordsWithoutWritingGradesStagesOrPlans() async throws {
        let (context, coach, item, url) = try setup()
        let targeted = TargetedCoachCoordinator(fileURL: url)
        let dataset = try XCTUnwrap(coach.store).state.datasetID
        await targeted.refresh(context: context, datasetID: dataset, subject: .english, now: now)
        let finding = try XCTUnwrap(targeted.findings.first)
        let beforeIDs = try context.fetch(FetchDescriptor<CoachLab.ReviewRecord>()).map(\.id).sorted { $0.uuidString < $1.uuidString }
        try await targeted.createLocal(findingID: finding.id, observation: .unknown, mistake: "", context: context, now: now)
        let draft = try XCTUnwrap(targeted.state?.interventions.first)
        try await targeted.approve(draft.id, context: context, now: now)
        try await targeted.answer(draft.id, exerciseID: draft.exercises[0].id, response: "", parentJudgment: true,
                            revealed: true, context: context, now: now)
        XCTAssertEqual(item.stage, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CoachLab.ReviewRecord>()).map(\.id).sorted { $0.uuidString < $1.uuidString }, beforeIDs)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 0)
        let completed = try XCTUnwrap(targeted.state?.interventions.first)
        XCTAssertEqual(targeted.report(for: completed, now: now).state, .awaiting)
        let first = CoachLab.ReviewRecord(itemID: item.id, reviewedAt: now.addingTimeInterval(86400), result: .correct, mode: .scheduled, oldStage: 2, newStage: 3)
        let second = CoachLab.ReviewRecord(itemID: item.id, reviewedAt: now.addingTimeInterval(172800), result: .correct, mode: .dictation, oldStage: 3, newStage: 4)
        context.insert(first); context.insert(second); try context.save()
        await targeted.refresh(context: context, datasetID: dataset, subject: .english, now: now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(targeted.report(for: completed, now: now.addingTimeInterval(3 * 86400)).state, .improving)
        context.delete(second); try context.save()
        await targeted.refresh(context: context, datasetID: dataset, subject: .english, now: now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(targeted.report(for: completed, now: now.addingTimeInterval(3 * 86400)).state, .oneCorrect)
    }

    func testAIGenerationIsDeduplicatedAndDraftSurvivesRestartButNotDatasetReplacement() async throws {
        let (context, coach, item, url) = try setup()
        let transport = TargetedTestTransport(response: response)
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: transport)
        let dataset = try XCTUnwrap(coach.store).state.datasetID
        await targeted.refresh(context: context, datasetID: dataset, subject: .english, now: now)
        for _ in 0..<2 {
            await targeted.generate(findingID: item.id, observation: .unknown, mistake: "", context: context, coach: coach, apiKey: "test-only", now: now)
        }
        XCTAssertNil(targeted.error)
        let calls = await transport.calls
        XCTAssertEqual(calls, 1); XCTAssertEqual(targeted.state?.interventions.count, 1)
        XCTAssertNil(targeted.state?.interventions.first?.approvedAt)
        let restarted = TargetedCoachCoordinator(fileURL: url)
        await restarted.refresh(context: context, datasetID: dataset, subject: .english, now: now)
        XCTAssertEqual(restarted.state, targeted.state)
        await restarted.refresh(context: context, datasetID: UUID(), subject: .english, now: now)
        XCTAssertTrue(restarted.state?.interventions.isEmpty == true)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.ReviewRecord>()), 3)
    }

    func testFailurePreservesDataAndOffersExplicitLocalPractice() async throws {
        let (context, coach, item, url) = try setup()
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: TargetedTestTransport(response: "FAIL"))
        await targeted.refresh(context: context, datasetID: try XCTUnwrap(coach.store).state.datasetID, subject: .english, now: now)
        await targeted.generate(findingID: item.id, observation: .unknown, mistake: "", context: context, coach: coach, apiKey: "test-only", now: now)
        XCTAssertNotNil(targeted.error); XCTAssertTrue(targeted.state?.interventions.isEmpty == true)
        try await targeted.createLocal(findingID: item.id, observation: .unknown, mistake: "", context: context, now: now)
        XCTAssertFalse(try XCTUnwrap(targeted.state?.interventions.first).isAIGenerated)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.ReviewRecord>()), 3)
    }

    func testRevokedAuthorizationRejectsLateModelResponse() async throws {
        let (context, coach, item, url) = try setup()
        let transport = TargetedTestTransport(response: response, beforeReply: {
            var config = try XCTUnwrap(coach.store).state.configuration
            config.isEnabled = false; try coach.store?.configure(config)
        })
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: transport)
        await targeted.refresh(context: context, datasetID: try XCTUnwrap(coach.store).state.datasetID, subject: .english, now: now)
        await targeted.generate(findingID: item.id, observation: .unknown, mistake: "", context: context, coach: coach, apiKey: "test-only", now: now)
        XCTAssertTrue(targeted.state?.interventions.isEmpty == true)
        XCTAssertFalse(targeted.isGenerating)
    }

    func testUndoWhileModelRunsRejectsResponseAndExistingDraftCannotBeApprovedAfterUndo() async throws {
        let (context, coach, item, url) = try setup()
        let toDelete = try XCTUnwrap(context.fetch(FetchDescriptor<CoachLab.ReviewRecord>()).first)
        let transport = TargetedTestTransport(response: response, beforeReply: { context.delete(toDelete); try context.save() })
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: transport)
        await targeted.refresh(context: context, datasetID: try XCTUnwrap(coach.store).state.datasetID, subject: .english, now: now)
        await targeted.generate(findingID: item.id, observation: .unknown, mistake: "", context: context, coach: coach, apiKey: "test-only", now: now)
        XCTAssertTrue(targeted.state?.interventions.isEmpty == true)
        XCTAssertTrue(targeted.error?.contains("来源判定已变化") == true)
    }

    func testUndoStopsAnExistingDraftWithoutChangingItsSavedProgress() async throws {
        let (context, coach, item, url) = try setup()
        let targeted = TargetedCoachCoordinator(fileURL: url)
        await targeted.refresh(context: context, datasetID: try XCTUnwrap(coach.store).state.datasetID, subject: .english, now: now)
        try await targeted.createLocal(findingID: item.id, observation: .unknown, mistake: "", context: context, now: now)
        let draft = try XCTUnwrap(targeted.state?.interventions.first)
        let removed = try XCTUnwrap(context.fetch(FetchDescriptor<CoachLab.ReviewRecord>()).first)
        context.delete(removed); try context.save()
        do { try await targeted.approve(draft.id, context: context, now: now); XCTFail("撤销来源后不能开始旧补练") }
        catch { XCTAssertTrue(error.localizedDescription.contains("来源判定")) }
        XCTAssertNil(targeted.state?.interventions.first?.approvedAt)
        XCTAssertEqual(targeted.report(for: draft, now: now).state, .invalidated)
    }

    func testDatasetReplacementWhileModelRunsDropsLateResponse() async throws {
        let (context, coach, item, url) = try setup()
        let replacement = UUID()
        let transport = TargetedTestTransport(response: response, beforeReply: {
            var next = try XCTUnwrap(coach.store).state
            next.datasetID = replacement; try coach.store?.commit(next)
        })
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: transport)
        await targeted.refresh(context: context, datasetID: try XCTUnwrap(coach.store).state.datasetID, subject: .english, now: now)
        await targeted.generate(findingID: item.id, observation: .unknown, mistake: "", context: context, coach: coach, apiKey: "test-only", now: now)
        XCTAssertTrue(targeted.state?.interventions.isEmpty == true)
        await targeted.refresh(context: context, datasetID: replacement, subject: .english, now: now)
        XCTAssertEqual(targeted.state?.datasetID, replacement)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.ReviewRecord>()), 3)
    }

    func testCorruptMetadataIsPreservedAndDoesNotTouchNativeLearningData() async throws {
        let (context, coach, _, url) = try setup()
        let broken = Data("{broken-metadata".utf8)
        try broken.write(to: url)
        let targeted = TargetedCoachCoordinator(fileURL: url)
        await targeted.refresh(context: context, datasetID: try XCTUnwrap(coach.store).state.datasetID, subject: .english, now: now)
        XCTAssertNotNil(targeted.error); XCTAssertNil(targeted.state)
        XCTAssertEqual(try Data(contentsOf: url), broken)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.ReviewRecord>()), 3)
    }

    func testNewErrorDoesNotCreateASecondActivePracticeGroup() async throws {
        let (context, coach, item, url) = try setup()
        let targeted = TargetedCoachCoordinator(fileURL: url)
        let dataset = try XCTUnwrap(coach.store).state.datasetID
        await targeted.refresh(context: context, datasetID: dataset, subject: .english, now: now)
        try await targeted.createLocal(findingID: item.id, observation: .unknown, mistake: "", context: context, now: now)
        let firstID = try XCTUnwrap(targeted.state?.interventions.first?.id)
        context.insert(CoachLab.ReviewRecord(itemID: item.id, reviewedAt: now.addingTimeInterval(60), result: .wrong, mode: .scheduled, oldStage: 2, newStage: 0))
        try context.save()
        await targeted.refresh(context: context, datasetID: dataset, subject: .english, now: now.addingTimeInterval(120))
        let finding = try XCTUnwrap(targeted.findings.first)
        XCTAssertEqual(targeted.existing(for: finding)?.id, firstID)
        do { try await targeted.createLocal(findingID: item.id, observation: .unknown, mistake: "", context: context, now: now); XCTFail("不应重复创建") }
        catch { }
        XCTAssertEqual(targeted.state?.interventions.count, 1)
    }

    func testNewAICycleReceivesPreviousStrategyAndIndependentFailureSeparatelyFromPracticeSuccess() async throws {
        let (context, coach, item, url) = try setup()
        let transport = TargetedTestTransport(response: response)
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: transport)
        let dataset = try XCTUnwrap(coach.store).state.datasetID
        await targeted.refresh(context: context, datasetID: dataset, subject: .english, now: now)
        try await targeted.createLocal(findingID: item.id, observation: .unknown, mistake: "", context: context, now: now)
        let first = try XCTUnwrap(targeted.state?.interventions.first)
        try await targeted.approve(first.id, context: context, now: now)
        try await targeted.answer(first.id, exerciseID: first.exercises[0].id, response: "", parentJudgment: true,
                                  revealed: true, context: context, now: now)
        let independentWrong = CoachLab.ReviewRecord(itemID: item.id, reviewedAt: now.addingTimeInterval(86400),
            result: .wrong, mode: .scheduled, oldStage: 2, newStage: 0)
        context.insert(independentWrong); try context.save()
        let later = now.addingTimeInterval(90000)
        await targeted.refresh(context: context, datasetID: dataset, subject: .english, now: later)
        let previous = try XCTUnwrap(targeted.state?.interventions.first)
        XCTAssertEqual(targeted.report(for: previous, now: later).state, .needsPractice)
        let finding = try XCTUnwrap(targeted.findings.first)
        XCTAssertNil(targeted.existing(for: finding, now: later))
        await targeted.generate(findingID: item.id, observation: .unknown, mistake: "", context: context, coach: coach, apiKey: "test-only", now: later)
        XCTAssertEqual(targeted.state?.interventions.count, 2)
        let messages = await transport.capturedMessages
        let user = try XCTUnwrap(messages.last?.content)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any])
        let history = try XCTUnwrap(object["previous_interventions"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0]["practiceCorrect"] as? Int, 1)
        XCTAssertTrue((history[0]["strategy"] as? String)?.contains("本地基础练法") == true)
        let actual = try XCTUnwrap(history[0]["independentEvidence"] as? [[String: Any]])
        XCTAssertEqual(actual.first?["id"] as? String, independentWrong.id.uuidString)
        XCTAssertEqual(actual.first?["correct"] as? Bool, false)
    }

    func testCancelDuringGenerationPreventsDraftAndAllowsLocalRetry() async throws {
        let (context, coach, item, url) = try setup()
        let box = TargetedCancelBox()
        let transport = TargetedTestTransport(response: response, beforeReply: { box.coordinator?.cancel() })
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: transport)
        box.coordinator = targeted
        await targeted.refresh(context: context, datasetID: try XCTUnwrap(coach.store).state.datasetID, subject: .english, now: now)
        await targeted.generate(findingID: item.id, observation: .unknown, mistake: "", context: context, coach: coach, apiKey: "test-only", now: now)
        XCTAssertFalse(targeted.isGenerating)
        XCTAssertTrue(targeted.state?.interventions.isEmpty == true)
        try await targeted.createLocal(findingID: item.id, observation: .unknown, mistake: "", context: context, now: now)
        XCTAssertEqual(targeted.state?.interventions.count, 1)
        XCTAssertFalse(try XCTUnwrap(targeted.state?.interventions.first).isAIGenerated)
    }
    private var lessonResponse: String {
        """
        {"meaning":"葡萄牙，欧洲的一个国家。","structure":"注意首字母 P 大写。","example":"Portugal is in Europe.","exampleTranslation":"葡萄牙在欧洲。","question":"Lisbon is the capital of ____.","answer":"Portugal"}
        """
    }

    func testFiveThenTwoLessonsCanBeCompletedWithoutParentOrNativeGradeChanges() async throws {
        let (context, coach, item, url) = try setup()
        item.prompt = "葡萄牙"
        for word in ["apple", "banana", "orange", "pear", "grape", "peach"] {
            let added = CoachLab.ReviewItem(type: .englishWord, content: word, prompt: "水果", stage: 2, nextReviewAt: now)
            context.insert(added)
            for days in [-4, -3, -1] {
                context.insert(CoachLab.ReviewRecord(itemID: added.id, reviewedAt: now.addingTimeInterval(Double(days) * 86400),
                    result: .wrong, mode: .scheduled, oldStage: 2, newStage: 0))
            }
        }
        try context.save()
        let targeted = TargetedCoachCoordinator(fileURL: url)
        let firstIDResult = await targeted.startGroup(context: context, coach: coach, now: now)
        let firstID = try XCTUnwrap(firstIDResult)
        XCTAssertEqual(targeted.state?.groups.first?.targets.count, 5)
        let duplicate = await targeted.startGroup(context: context, coach: coach, now: now)
        XCTAssertEqual(duplicate, firstID); XCTAssertEqual(targeted.state?.groups.count, 1)
        var seen = Set<String>()
        for expected in [5, 2] {
            let group = try XCTUnwrap(targeted.state?.groups.last)
            XCTAssertEqual(group.targets.count, expected)
            for target in group.targets {
                XCTAssertTrue(seen.insert(target.identity).inserted)
                await targeted.prepareLesson(groupID: group.id, targetID: target.id, basic: true, context: context, coach: coach, now: now)
                XCTAssertNil(targeted.error)
                let entry = try XCTUnwrap(targeted.state?.interventions.last)
                XCTAssertNotNil(entry.lesson); XCTAssertFalse(entry.isAIGenerated)
                try await targeted.approve(entry.id, context: context, now: now)
                try await targeted.answer(entry.id, exerciseID: entry.exercises[0].id, response: entry.content,
                    parentJudgment: nil, revealed: false, context: context, now: now)
            }
            XCTAssertNil(targeted.activeGroup(subject: .english))
            let next = await targeted.startGroup(context: context, coach: coach, now: now)
            if expected == 5 { XCTAssertNotNil(next) } else { XCTAssertNil(next) }
        }
        XCTAssertEqual(seen.count, 7); XCTAssertEqual(targeted.state?.groups.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.ReviewRecord>()), 21)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 0)
        XCTAssertEqual(item.stage, 2)
    }

    func testPreparedAILessonAndStartedProgressResumeWithoutGeneratingAgain() async throws {
        let (context, coach, _, url) = try setup()
        let response = lessonResponse.replacingOccurrences(of: "\"structure\":", with: "\"soundMemory\":\"先按有把握的读音分段记，再对照字母回忆完整写法。\",\"structure\":")
        let transport = TargetedTestTransport(response: response)
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: transport)
        let idResult = await targeted.startGroup(context: context, coach: coach, now: now)
        let id = try XCTUnwrap(idResult)
        let target = try XCTUnwrap(targeted.state?.groups.first?.targets.first)
        for _ in 0..<2 {
            await targeted.prepareLesson(groupID: id, targetID: target.id, context: context, coach: coach, apiKey: "test-only", now: now)
        }
        let calls = await transport.calls
        XCTAssertEqual(calls, 1); XCTAssertNil(targeted.error)
        let entry = try XCTUnwrap(targeted.state?.interventions.first)
        XCTAssertEqual(entry.lesson?.soundMemory, "先按有把握的读音分段记，再对照字母回忆完整写法。")
        try await targeted.approve(entry.id, context: context, now: now)
        let restarted = TargetedCoachCoordinator(fileURL: url, transport: transport)
        let resumedID = await restarted.startGroup(context: context, coach: coach, now: now)
        XCTAssertEqual(resumedID, id); XCTAssertEqual(restarted.state, targeted.state)
        XCTAssertEqual(restarted.activeGroup(subject: .english)?.firstUnfinished(in: restarted.state!.interventions), 0)
        try await restarted.answer(entry.id, exerciseID: entry.exercises[0].id, response: "portugal",
            parentJudgment: nil, revealed: false, context: context, now: now)
        XCTAssertEqual(restarted.state?.interventions.first?.attempts.first?.correct, false)
        XCTAssertEqual(restarted.report(for: restarted.state!.interventions[0], now: now).state, .awaiting)
    }

    private func setupNextWord(transport: any ChatTransport) async throws -> (ModelContext, AICoachCoordinator, TargetedCoachCoordinator, CoachingStudyGroup) {
        let (context, coach, _, url) = try setup()
        for word in ["apple", "banana", "pear", "grape"] {
            let item = CoachLab.ReviewItem(type: .englishWord, content: word, prompt: "水果", stage: 2, nextReviewAt: now)
            context.insert(item)
            for days in [-4, -3, -1] {
                context.insert(CoachLab.ReviewRecord(itemID: item.id, reviewedAt: now.addingTimeInterval(Double(days) * 86400),
                    result: .wrong, mode: .scheduled, oldStage: 2, newStage: 0))
            }
        }
        try context.save()
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: transport)
        _ = await targeted.startGroup(context: context, coach: coach, now: now)
        let group = try XCTUnwrap(targeted.state?.groups.first)
        await targeted.prepareLesson(groupID: group.id, targetID: group.targets[0].id, context: context, coach: coach, apiKey: "test-only", now: now)
        XCTAssertNil(targeted.error)
        return (context, coach, targeted, group)
    }

    func testOnlyNextWordIsPreparedWhileCurrentAnswerRemainsUsableAndSaved() async throws {
        let held = expectation(description: "下一词请求进行中")
        let transport = NextWordTestTransport(held: held)
        let (context, coach, targeted, group) = try await setupNextWord(transport: transport)
        let task = try XCTUnwrap(targeted.prefetchNextLesson(groupID: group.id, after: group.targets[0].id,
            context: context, coach: coach, apiKey: "test-only", now: now))
        await fulfillment(of: [held], timeout: 3)
        XCTAssertFalse(targeted.isGenerating, "后台预备不能禁用当前词的作答")
        XCTAssertEqual(targeted.prefetchingTargetID, group.targets[1].id)
        let current = try XCTUnwrap(targeted.state?.interventions.first)
        try await targeted.startLesson(current.id, context: context)
        try await targeted.answer(current.id, exerciseID: current.exercises[0].id, response: current.content,
            parentJudgment: nil, revealed: false, context: context, now: now)
        await transport.release(); await task.value
        XCTAssertEqual(targeted.state?.interventions.count, 2)
        XCTAssertEqual(targeted.state?.interventions.first?.attempts.count, 1, "后台返回不能覆盖当前作答")
        XCTAssertNotNil(targeted.state?.groups.first?.targets[1].interventionID)
        XCTAssertNil(targeted.state?.groups.first?.targets[2].interventionID, "不能自动预备再后面的词")
        var requests = await transport.requestedWords
        XCTAssertEqual(requests, Array(group.targets.prefix(2)).map(\.content))
        targeted.prefetchNextLesson(groupID: group.id, after: group.targets[0].id, context: context, coach: coach, apiKey: "test-only", now: now)
        requests = await transport.requestedWords; XCTAssertEqual(requests.count, 2, "已经准备的下一词不重复生成")
        let nextTask = try XCTUnwrap(targeted.prefetchNextLesson(groupID: group.id, after: group.targets[1].id,
            context: context, coach: coach, apiKey: "test-only", now: now))
        await nextTask.value
        requests = await transport.requestedWords
        XCTAssertEqual(requests, Array(group.targets.prefix(3)).map(\.content))
        XCTAssertNil(targeted.state?.groups.first?.targets[3].interventionID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.ReviewRecord>()), 15)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 0)
    }

    func testEnteringNextWordSharesTheInFlightRequest() async throws {
        let held = expectation(description: "下一词请求进行中")
        let transport = NextWordTestTransport(held: held)
        let (context, coach, targeted, group) = try await setupNextWord(transport: transport)
        let task = try XCTUnwrap(targeted.prefetchNextLesson(groupID: group.id, after: group.targets[0].id,
            context: context, coach: coach, apiKey: "test-only", now: now))
        await fulfillment(of: [held], timeout: 3)
        let foreground = Task {
            await targeted.prepareLesson(groupID: group.id, targetID: group.targets[1].id, context: context, coach: coach, apiKey: "test-only", now: now)
        }
        await transport.release(); await foreground.value; await task.value
        let requests = await transport.requestedWords
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(targeted.state?.interventions.count, 2)
        XCTAssertNil(targeted.prefetchingTargetID)
    }

    func testPrefetchFailureIsSpecificToNextWordAndAllowsExplicitRetry() async throws {
        let held = expectation(description: "下一词请求进行中")
        let transport = NextWordTestTransport(held: held, failSecond: true)
        let (context, coach, targeted, group) = try await setupNextWord(transport: transport)
        let task = try XCTUnwrap(targeted.prefetchNextLesson(groupID: group.id, after: group.targets[0].id,
            context: context, coach: coach, apiKey: "test-only", now: now))
        await fulfillment(of: [held], timeout: 3)
        await transport.release(); await task.value
        XCTAssertNil(targeted.error, "下一词失败不应替换当前词或显示成当前词出错")
        XCTAssertNotNil(targeted.lessonPreparationErrors[group.targets[1].id])
        XCTAssertNil(targeted.prefetchNextLesson(groupID: group.id, after: group.targets[0].id,
            context: context, coach: coach, apiKey: "test-only", now: now), "失败后不自动反复请求")
        let current = try XCTUnwrap(targeted.state?.interventions.first)
        try await targeted.startLesson(current.id, context: context)
        await targeted.prepareLesson(groupID: group.id, targetID: group.targets[1].id, context: context, coach: coach, apiKey: "test-only", now: now)
        XCTAssertNil(targeted.lessonPreparationErrors[group.targets[1].id])
        XCTAssertEqual(targeted.state?.interventions.count, 2)
        let requests = await transport.requestedWords; XCTAssertEqual(requests.count, 3)
    }

    func testLatePrefetchIsRejectedAfterCancellationRevocationRestoreOrSourceUndo() async throws {
        for mode in ["cancel", "revoke", "restore", "undo"] {
            let held = expectation(description: "下一词请求进行中：" + mode)
            let transport = NextWordTestTransport(held: held)
            let (context, coach, targeted, group) = try await setupNextWord(transport: transport)
            let task = try XCTUnwrap(targeted.prefetchNextLesson(groupID: group.id, after: group.targets[0].id,
                context: context, coach: coach, apiKey: "test-only", now: now))
            await fulfillment(of: [held], timeout: 3)
            switch mode {
            case "cancel": targeted.cancel()
            case "revoke":
                var config = try XCTUnwrap(coach.store).state.configuration
                config.isEnabled = false; try coach.store?.configure(config)
            case "restore":
                targeted.dataChanged(action: "restore", context: context, datasetID: coach.store!.state.datasetID, subject: .english)
            default:
                let record = try XCTUnwrap(context.fetch(FetchDescriptor<CoachLab.ReviewRecord>()).first { $0.itemID == group.targets[1].id })
                context.delete(record); try context.save()
            }
            await transport.release(); await task.value
            XCTAssertFalse(targeted.state?.interventions.contains { $0.itemID == group.targets[1].id } == true, mode)
            XCTAssertNil(targeted.prefetchingTargetID)
            targeted.cancel()
        }
    }

    func testStudyPresentationResolvesWordAndPageBeforeFirstFrame() throws {
        let items = ["one", "two"].map { CoachCore.ReviewItem(type: "单词", content: $0, now: now) }
        let records = items.flatMap { item in
            [-4, -3, -1].map { days in
                CoachCore.ReviewRecord(itemID: item.id, correct: false, oldStage: 2, newStage: 0,
                                      now: now.addingTimeInterval(Double(days) * 86400))
            }
        }
        let findings = TargetedCoaching.findings(items: items, records: records, subject: .english, now: now)
        var group = CoachingStudyGroup(findings: findings, now: now)
        var entry = try TargetedCoaching.basicLesson(findings[0], meaning: "示例释义", now: now)
        group.targets[0].interventionID = entry.id
        var presentation = WordStudyPresentation(group: group, interventions: [entry])
        XCTAssertEqual(presentation.id, group.id)
        XCTAssertEqual(presentation.index, 0)
        XCTAssertEqual(presentation.page, .lesson, "缓存讲解第一帧直接显示讲解，不经过初始化转圈")

        entry.approve(now: now)
        presentation = WordStudyPresentation(group: group, interventions: [entry])
        XCTAssertEqual(presentation.page, .quiz, "退出重进已开始的词，第一帧就应恢复作答页")
        try entry.answer(exerciseID: entry.exercises[0].id, response: entry.content, parentJudgment: nil, revealed: false, now: now)
        group.usesBasic = true
        presentation = WordStudyPresentation(group: group, interventions: [entry])
        XCTAssertEqual(presentation.index, 1, "续学直接定位后面的词，不能先展示第一词再跳转")
        XCTAssertEqual(presentation.page, .lesson)
        XCTAssertTrue(presentation.usesBasic)
        XCTAssertEqual(WordStudyPresentation.page(for: entry), .result, "切换回已完成词时同步定位结果页")

        group.targets[1].skipped = true
        presentation = WordStudyPresentation(group: group, interventions: [entry])
        XCTAssertEqual(presentation.index, group.targets.count)
        XCTAssertEqual(presentation.page, .lesson)
    }

    func testLessonFailureCanUseExplicitBasicFallbackAndPreservesGroup() async throws {
        let (context, coach, item, url) = try setup(); item.prompt = "葡萄牙"; try context.save()
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: TargetedTestTransport(response: "FAIL"))
        let idResult = await targeted.startGroup(context: context, coach: coach, now: now)
        let id = try XCTUnwrap(idResult)
        let target = try XCTUnwrap(targeted.state?.groups.first?.targets.first)
        await targeted.prepareLesson(groupID: id, targetID: target.id, context: context, coach: coach, apiKey: "test-only", now: now)
        XCTAssertNotNil(targeted.error); XCTAssertTrue(targeted.state?.interventions.isEmpty == true)
        await targeted.prepareLesson(groupID: id, targetID: target.id, basic: true, context: context, coach: coach, now: now)
        XCTAssertNil(targeted.error); XCTAssertEqual(targeted.state?.interventions.first?.isAIGenerated, false)
        XCTAssertNotNil(targeted.state?.groups.first?.targets.first?.interventionID)
    }

    func testLateLessonAfterRevocationOrCancellationIsNotSaved() async throws {
        for revoke in [true, false] {
            let (context, coach, _, url) = try setup()
            let box = TargetedCancelBox()
            let transport = TargetedTestTransport(response: lessonResponse, beforeReply: {
                if revoke {
                    var config = try XCTUnwrap(coach.store).state.configuration
                    config.isEnabled = false; try coach.store?.configure(config)
                } else { box.coordinator?.cancel() }
            })
            let targeted = TargetedCoachCoordinator(fileURL: url, transport: transport); box.coordinator = targeted
            let idResult = await targeted.startGroup(context: context, coach: coach, now: now)
            let id = try XCTUnwrap(idResult)
            let target = try XCTUnwrap(targeted.state?.groups.first?.targets.first)
            await targeted.prepareLesson(groupID: id, targetID: target.id, context: context, coach: coach, apiKey: "test-only", now: now)
            XCTAssertTrue(targeted.state?.interventions.isEmpty == true); XCTAssertFalse(targeted.isGenerating)
            XCTAssertNil(targeted.state?.groups.first?.targets.first?.interventionID)
        }
    }

    func testOldUnfinishedPaperPracticeDoesNotBlockNewScreenLesson() async throws {
        let (context, coach, item, url) = try setup()
        let targeted = TargetedCoachCoordinator(fileURL: url)
        await targeted.refresh(context: context, datasetID: coach.store!.state.datasetID, subject: .english, now: now)
        try await targeted.createLocal(findingID: item.id, observation: .unknown, mistake: "", context: context, now: now)
        let oldID = targeted.state?.interventions.first?.id
        XCTAssertNil(targeted.state?.interventions.first?.lesson)
        let id = await targeted.startGroup(context: context, coach: coach, now: now)
        XCTAssertNotNil(id); XCTAssertEqual(targeted.state?.groups.first?.targets.count, 1)
        XCTAssertEqual(targeted.state?.interventions.first?.id, oldID)
    }

    func testUndoDuringLessonGenerationPreservesGroupWithoutSavingStaleContent() async throws {
        let (context, coach, _, url) = try setup()
        let transport = TargetedTestTransport(response: lessonResponse, beforeReply: {
            let records = try context.fetch(FetchDescriptor<CoachLab.ReviewRecord>())
            context.delete(try XCTUnwrap(records.first)); try context.save()
        })
        let targeted = TargetedCoachCoordinator(fileURL: url, transport: transport)
        let result = await targeted.startGroup(context: context, coach: coach, now: now)
        let id = try XCTUnwrap(result), target = try XCTUnwrap(targeted.state?.groups.first?.targets.first)
        await targeted.prepareLesson(groupID: id, targetID: target.id, context: context, coach: coach, apiKey: "test-only", now: now)
        XCTAssertNotNil(targeted.error); XCTAssertTrue(targeted.state?.interventions.isEmpty == true)
        XCTAssertNil(targeted.state?.groups.first?.targets.first?.interventionID)
        try targeted.skipTarget(groupID: id, targetID: target.id)
        XCTAssertNil(targeted.activeGroup(subject: .english))
    }

    func testBasicModeAndGroupProgressSurviveRestartAndBackupRestoreClearsGroups() async throws {
        let (context, coach, item, url) = try setup(); item.prompt = "葡萄牙"; try context.save()
        let targeted = TargetedCoachCoordinator(fileURL: url)
        let result = await targeted.startGroup(context: context, coach: coach, now: now)
        let id = try XCTUnwrap(result), target = try XCTUnwrap(targeted.state?.groups.first?.targets.first)
        await targeted.prepareLesson(groupID: id, targetID: target.id, basic: true, context: context, coach: coach, now: now)
        XCTAssertEqual(targeted.state?.groups.first?.usesBasic, true)
        let restarted = TargetedCoachCoordinator(fileURL: url)
        await restarted.refresh(context: context, datasetID: coach.store!.state.datasetID, subject: .english, now: now)
        XCTAssertEqual(restarted.state, targeted.state)
        restarted.dataChanged(action: "restore", context: context, datasetID: UUID(), subject: .english)
        XCTAssertTrue(restarted.state?.groups.isEmpty == true)
        XCTAssertTrue(restarted.state?.interventions.isEmpty == true)
        XCTAssertTrue(restarted.recommendations.isEmpty)
        restarted.cancel()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.ReviewRecord>()), 3)
    }

}
