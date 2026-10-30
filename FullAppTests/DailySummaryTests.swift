import XCTest
@testable import CoachLab

final class DailySummaryTests: XCTestCase {
    private func input(review: Int = 0, dictation: Int = 0, tasks: Int = 0) -> DailySummaryInput {
        DailySummaryInput(
            date: "2026-10-29", locale: "zh-Hans", tone: "parent_encouraging", childName: "小禾",
            metrics: .init(
                reviewCompleted: review, reviewCorrect: review, reviewWrong: 0,
                reviewAccuracyText: review > 0 ? "100%" : "--", dictationReviewedEntries: dictation,
                tasksCompleted: tasks, tasksPending: 2, pointsEarnedToday: 3, currentStreak: 1
            ),
            highlights: .init(completedTaskTitles: tasks > 0 ? ["整理书包"] : [], wrongReviewSamples: [])
        )
    }

    func testTaskActivityAndLocalSummaryRemainAvailable() {
        let value = input(tasks: 1)
        XCTAssertTrue(value.hasActivity)
        let result = value.localFallbackResult()
        XCTAssertTrue(result.message.contains("任务有推进"))
        XCTAssertTrue(result.highlights.contains("任务完成 1 项"))
        XCTAssertFalse(result.displayText.contains("计算"))
    }

    func testReviewAndDictationKeepTheirSummaryAndEmptyState() {
        let review = input(review: 2).localFallbackResult()
        XCTAssertTrue(review.message.contains("复习正确率 100%"))
        XCTAssertTrue(review.highlights.contains("完成 2 次复习"))
        let dictation = input(dictation: 4).localFallbackResult()
        XCTAssertTrue(dictation.message.contains("听写判定"))
        XCTAssertTrue(dictation.highlights.contains("听写判定 4 条"))
        XCTAssertFalse(input().hasActivity)
        XCTAssertTrue(input().localFallbackResult().message.contains("复习、听写或任务"))
    }

    func testRequestFactsKeepTasksButContainNoCalculationMetrics() throws {
        let data = try JSONEncoder().encode(input(review: 1, dictation: 2, tasks: 3))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try XCTUnwrap(root["metrics"] as? [String: Any])
        XCTAssertEqual(metrics["tasksCompleted"] as? Int, 3)
        XCTAssertEqual(metrics["tasksPending"] as? Int, 2)
        XCTAssertEqual(metrics["dictationReviewedEntries"] as? Int, 2)
        XCTAssertFalse(metrics.keys.contains { $0.hasPrefix("calculation") })
        XCTAssertEqual(try JSONDecoder().decode(DailySummaryInput.self, from: data), input(review: 1, dictation: 2, tasks: 3))
    }

    func testOldSummaryCacheIsIgnoredAndNewCacheStillWorks() throws {
        let hash = UUID().uuidString
        let model = "test-only-model"
        let oldKey = "dailySummaryAI.cache.v2.\(model).\(hash)"
        let newKey = "dailySummaryAI.cache.v3.learning-and-tasks.\(model).\(hash)"
        defer {
            UserDefaults.standard.removeObject(forKey: oldKey)
            UserDefaults.standard.removeObject(forKey: newKey)
        }
        struct CachedEntry: Encodable { let result: DailySummaryResult; let createdAt: Date }
        let oldResult = DailySummaryResult(title: "旧小结", message: "旧计算小结", highlights: [], tomorrowFocus: "")
        UserDefaults.standard.set(try JSONEncoder().encode(CachedEntry(result: oldResult, createdAt: .now)), forKey: oldKey)
        XCTAssertNil(DailySummaryCache.load(inputHash: hash, model: model))
        let current = input(tasks: 1).localFallbackResult()
        DailySummaryCache.save(current, inputHash: hash, model: model)
        XCTAssertEqual(DailySummaryCache.load(inputHash: hash, model: model), current)
    }
}
