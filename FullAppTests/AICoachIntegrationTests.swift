import XCTest
import SwiftData
import CoachCore
@testable import CoachLab

@MainActor final class AICoachIntegrationTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private func environment() throws -> (ModelContainer, ModelContext, AppSettingsStore, AICoachCoordinator) {
        let schema = Schema([CoachLab.ReviewItem.self, CoachLab.ReviewRecord.self,
            CoachLab.DictationSession.self, CoachLab.DictationEntry.self, ReviewDailyPlan.self, AppSettings.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        containers.append(container)
        let context = container.mainContext
        let settings = AppSettingsStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("full-integration-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let coach = AICoachCoordinator(fileURL: directory.appendingPathComponent("lab.json"))
        return (container, context, settings, coach)
    }
    func testExperimentCannotResolveProductionSync() {
        XCTAssertNil(ServerAPIConfiguration.serverURL)
        XCTAssertNil(ServerAPIConfiguration.current)
    }
    func testIntentionalLocalStorageDoesNotShowCloudFailure() {
        let status = SyncStatusStore()
        status.configure(cloudKitEnabled: false, serverSyncEnabled: false)
        XCTAssertFalse(status.isUsingLocalFallback)
        XCTAssertEqual(status.syncNoticeKind, .ready)
        XCTAssertEqual(status.storageModeTitle, "独立本机存储")
    }
    func testDailyQuoteIsAvailableWithoutServerAccess() throws {
        let today = Date()
        let first = try XCTUnwrap(DailyQuote.local(for: today))
        XCTAssertEqual(first, DailyQuote.local(for: today))
        XCTAssertEqual(first.dayKey, DailyQuoteCache.shanghaiDayKey(for: today))
        XCTAssertFalse(first.text.isEmpty)
        let tomorrow = try XCTUnwrap(DailyQuote.local(for: Calendar.current.date(byAdding: .day, value: 1, to: today)!))
        XCTAssertNotEqual(first.id, tomorrow.id)
    }
    func testLiveSnapshotPreservesIDsAndIncludesRecitation() throws {
        let (_, context, settings, coach) = try environment()
        let item = CoachLab.ReviewItem(type: .englishSentence, content: "How are you?", prompt: "你好吗？")
        context.insert(item); try context.save()
        coach.bootstrap(context: context, settings: settings)
        XCTAssertNil(coach.error)
        XCTAssertEqual(coach.store?.state.items.first?.id, item.id)
        XCTAssertEqual(coach.store?.state.items.first?.typeRawValue, "英语背诵")
    }
    func testAIReviewSelectionReplacesDailyPlanAndNeverCreatesDictationInput() throws {
        let (_, context, settings, coach) = try environment()
        let item = CoachLab.ReviewItem(type: .phrase, content: "辨别", prompt: "biàn bié")
        context.insert(item); try context.save()
        coach.bootstrap(context: context, settings: settings)
        let store = try XCTUnwrap(coach.store)
        var config = store.state.configuration; config.isEnabled = true
        try store.configure(config)
        let tools = CoachCore.CoachToolExecutor(store: store, feedback: false, reviewsOnly: true)
        _ = try tools.execute(CoachCore.ToolCall(name: "query_history", arguments: "{}"))
        _ = try tools.execute(CoachCore.ToolCall(name: "query_plans", arguments: "{}"))
        let arguments = CoachCore.PlanArguments(date: CoachCore.Codec.day(.now), title: "AI 字词巩固", itemIDs: [item.id], rationale: "根据已记录的词语安排练习。")
        _ = try tools.execute(CoachCore.ToolCall(name: "upsert_plan", arguments: try CoachCore.Codec.text(arguments)))
        try coach.flushPlans(context: context)
        let plans = try context.fetch(FetchDescriptor<ReviewDailyPlan>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.itemIDs, [item.id])
        XCTAssertEqual(plans.first?.isCoachSelection, true)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.DictationSession>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CoachLab.DictationEntry>()), 0)
        try DailyReviewPlanner.lockToday(in: context)
        let first = try XCTUnwrap(plans.first)
        let rationale = first.coachRationale
        var pending = store.state
        pending.plans[0].rationale = "不应覆盖已开始的清单"
        pending.plans[0].updatedAt = Date().addingTimeInterval(60)
        try store.commit(pending); try coach.flushPlans(context: context)
        XCTAssertEqual(first.coachRationale, rationale)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewDailyPlan>()), 1)
    }

    func testBackupRefreshDoesNotQueueHistoricalFeedback() throws {
        let (_, context, settings, coach) = try environment()
        let item = CoachLab.ReviewItem(type: .phrase, content: "认真", prompt: "做事不马虎")
        let session = CoachLab.DictationSession(title: "历史听写", type: .phrase, reviewedAt: .now)
        context.insert(item); context.insert(session); try context.save()
        coach.bootstrap(context: context, settings: settings)
        coach.refresh(context: context, settings: settings)
        XCTAssertTrue(coach.store?.state.pendingFeedbackSessionIDs.isEmpty == true)
        XCTAssertNotNil(coach.store?.state.sessions.first?.reviewedAt)
    }
}
