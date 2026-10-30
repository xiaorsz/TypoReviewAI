import XCTest
import SwiftData
@testable import CoachLab

final class Grade5ChineseDictationPlanImporterTests: XCTestCase {
    func testPlanHasThirtyConsecutiveDaysStartingJuly15() {
        let plan = Grade5ChineseDictationPlanImporter.plan

        XCTAssertEqual(plan.count, 30)
        XCTAssertEqual(plan.map(\.dayNumber), Array(1...30))
        XCTAssertEqual(Set(plan.map(\.id)).count, 30)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: plan.first!.scheduledDate),
            DateComponents(year: 2026, month: 7, day: 15)
        )
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: plan.last!.scheduledDate),
            DateComponents(year: 2026, month: 8, day: 13)
        )
    }

    func testPlanContainsExpectedEntryCounts() {
        let plan = Grade5ChineseDictationPlanImporter.plan
        let entries = plan.flatMap(\.entries)

        XCTAssertEqual(entries.count, 323)
        XCTAssertEqual(entries.filter { $0.isWritingSupplement }.count, 91)
        XCTAssertEqual(entries.filter { !$0.isWritingSupplement }.count, 232)
        XCTAssertTrue(plan.allSatisfy { (10...11).contains($0.entries.count) })
        XCTAssertTrue(entries.allSatisfy { !$0.content.isEmpty && !$0.content.contains("★") })
    }

    func testKnownFirstAndLastEntriesStayStable() {
        let plan = Grade5ChineseDictationPlanImporter.plan

        XCTAssertEqual(plan.first?.entries.first?.content, "精巧")
        XCTAssertEqual(plan.last?.entries.last?.content, "某年")
        XCTAssertEqual(plan.first?.title, "五上语文听写 第01天｜第1课《白鹭》")
        XCTAssertEqual(plan.last?.title, "五上语文听写 第30天｜第26课《忆读书》")
    }

    @MainActor
    func testImportIsIdempotentAndDoesNotDuplicatePlanRows() throws {
        let schema = Schema([
            DictationSession.self,
            DictationEntry.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let first = try Grade5ChineseDictationPlanImporter.importPlan(in: context)
        XCTAssertEqual(first.insertedSessions, 30)
        XCTAssertEqual(first.refreshedSessions, 0)
        XCTAssertEqual(first.insertedEntries, 323)

        let second = try Grade5ChineseDictationPlanImporter.importPlan(in: context)
        XCTAssertEqual(second.insertedSessions, 0)
        XCTAssertEqual(second.refreshedSessions, 30)
        XCTAssertEqual(second.insertedEntries, 323)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DictationSession>()), 30)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DictationEntry>()), 323)
    }
}
