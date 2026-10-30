import XCTest
import SwiftData
@testable import CoachLab

@MainActor final class SettingsPerformanceTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private func environment() throws -> (AppSettingsStore, ModelContext) {
        let schema = Schema([AppSettings.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        containers.append(container)
        return (AppSettingsStore(), container.mainContext)
    }

    func testValueSnapshotKeepsEveryFieldWithoutDatabaseModelRoundTrip() throws {
        let (settings, _) = try environment()
        settings.childName = "设置测试"
        settings.dailyLimit = 25
        settings.remindHour = 17; settings.remindMinute = 42
        settings.reviewInteractionStyle = .batch
        settings.aiSummaryEnabled = true; settings.aiSummaryModelRawValue = "deepseek-v4-pro"
        settings.boardAutoplayEnabled = false
        settings.boardAutoplaySkipWeekends = false; settings.boardAutoplaySkipChinaHolidays = false
        settings.boardAutoplayStartHour = 6; settings.boardAutoplayStartMinute = 20
        settings.boardAutoplayEndHour = 7; settings.boardAutoplayEndMinute = 50
        settings.boardAutoplayDurationMinutes = 90
        let snapshot = settings.snapshot
        XCTAssertEqual(snapshot, AppSettingsSnapshot(settings.modelRepresentation, updatedAt: snapshot.updatedAt))
        XCTAssertEqual(snapshot.childName, "设置测试")
        XCTAssertEqual(snapshot.dailyLimit, 25)
        XCTAssertEqual(snapshot.boardAutoplayDurationMinutes, 90)
    }

    func testReadingEditsRemainFreshAfterRepeatedDisplayReads() throws {
        let (settings, context) = try environment()
        settings.bootstrap(using: context)
        // Reproduce a legacy backup: the time range has scalar fields but no
        // serialized slot IDs. Initialize before editing, as the live app does.
        settings.boardAutoplaySlotsRawValue = ""
        settings.boardAutoplayStartHour = 7; settings.boardAutoplayStartMinute = 0
        settings.boardAutoplayEndHour = 7; settings.boardAutoplayEndMinute = 30
        settings.boardAutoplayDurationMinutes = 30
        let initial = settings.boardAutoplayTimeSummary
        for _ in 0..<20 { _ = settings.boardAutoplaySlots; _ = settings.boardAutoplayRuleSummary }
        let slot = try XCTUnwrap(settings.boardAutoplaySlots.first)
        settings.updateBoardAutoplaySlot(id: slot.id) { $0.startHour = 13; $0.startMinute = 37; $0.durationMinutes = 45 }
        XCTAssertNotEqual(settings.boardAutoplayTimeSummary, initial)
        XCTAssertEqual(settings.boardAutoplaySlots.first?.startHour, 13)
        XCTAssertEqual(settings.boardAutoplaySlots.first?.durationMinutes, 45)
        settings.persist(using: context)
        let model = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(model.boardAutoplaySlots, settings.boardAutoplaySlots)
        XCTAssertEqual(model.boardAutoplayStartHour, 13)
    }

    func testChangingOrdinarySettingsAndRestoringDoesNotUseStaleRepresentation() throws {
        let (settings, context) = try environment()
        let saved = settings.snapshot
        _ = settings.modelRepresentation
        settings.childName = "新名字"; settings.dailyLimit = 30
        XCTAssertEqual(settings.modelRepresentation.childName, "新名字")
        XCTAssertEqual(settings.snapshot.dailyLimit, 30)
        settings.restore(from: saved, using: context)
        XCTAssertEqual(settings.modelRepresentation.childName, saved.childName)
        XCTAssertEqual(settings.snapshot.dailyLimit, saved.dailyLimit)
    }

    func testScrollingReadWorkDoesNotCreatePersistentSettingsRows() throws {
        let (settings, context) = try environment()
        for _ in 0..<500 {
            _ = settings.snapshot
            _ = settings.boardAutoplayTimeSummary
            _ = settings.boardManualPlaybackOptionSummary
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testLegacyReadingRowRetainsIdentityAndExistingCustomIDsArePreserved() throws {
        let (_, _) = try environment()
        let first = AppSettings(), second = AppSettings()
        first.boardAutoplaySlotsRawValue = ""; second.boardAutoplaySlotsRawValue = ""
        let originalID = try XCTUnwrap(first.boardAutoplaySlots.first?.id)
        for _ in 0..<100 { XCTAssertEqual(first.boardAutoplaySlots.first?.id, originalID) }
        XCTAssertEqual(second.boardAutoplaySlots.first?.id, originalID)
        let custom = BoardAutoplaySlot(startHour: 9, startMinute: 5, durationMinutes: 60)
        first.boardAutoplaySlots = [custom]
        XCTAssertEqual(first.boardAutoplaySlots.first?.id, custom.id)
        first.updateBoardAutoplaySlot(id: custom.id) { $0.startHour = 10 }
        XCTAssertEqual(first.boardAutoplaySlots.first?.id, custom.id)
        XCTAssertEqual(first.boardAutoplaySlots.first?.startHour, 10)
    }

    func testCompareRenderPreparationWithFormerModelAllocationPath() throws {
        let (settings, _) = try environment()
        let snapshot = settings.snapshot
        var baseline = 0, optimized = 0
        let start = ContinuousClock.now
        for _ in 0..<500 {
            let model = snapshot.makeModel()
            baseline += model.boardAutoplaySlots.count
            baseline += model.boardAutoplayTimeSummary.count
        }
        let middle = ContinuousClock.now
        for _ in 0..<500 {
            optimized += settings.boardAutoplaySlots.count
            optimized += settings.boardAutoplayTimeSummary.count
        }
        let end = ContinuousClock.now
        XCTAssertEqual(optimized, baseline)
        print("Settings render preparation, 500 iterations: former=\(start.duration(to: middle)), cached=\(middle.duration(to: end))")
    }
}
