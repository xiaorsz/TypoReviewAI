import XCTest
@testable import CoachLab

final class RecentPlanTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testVisibilityStartsOneNaturalMonthBeforeMonthEndDeadline() {
        let deadline = date(2026, 8, 31)

        XCTAssertEqual(
            RecentPlanSupport.visibilityStart(for: deadline, calendar: calendar),
            date(2026, 7, 31)
        )
        XCTAssertFalse(
            RecentPlanSupport.isInHomeVisibilityWindow(
                deadline: deadline,
                on: date(2026, 7, 30),
                calendar: calendar
            )
        )
        XCTAssertTrue(
            RecentPlanSupport.isInHomeVisibilityWindow(
                deadline: deadline,
                on: date(2026, 7, 31),
                calendar: calendar
            )
        )
    }

    func testDeadlineStatesAndVoiceEligibility() {
        let reference = date(2026, 7, 31)
        let eightDays = RecentPlanSupport.deadlineState(
            deadline: date(2026, 8, 8),
            on: reference,
            calendar: calendar
        )
        let sevenDays = RecentPlanSupport.deadlineState(
            deadline: date(2026, 8, 7),
            on: reference,
            calendar: calendar
        )
        let today = RecentPlanSupport.deadlineState(
            deadline: reference,
            on: reference,
            calendar: calendar
        )
        let overdue = RecentPlanSupport.deadlineState(
            deadline: date(2026, 7, 29),
            on: reference,
            calendar: calendar
        )

        XCTAssertEqual(eightDays.statusText, "还剩 8 天")
        XCTAssertFalse(eightDays.isVoiceReminderEligible)
        XCTAssertTrue(sevenDays.isVoiceReminderEligible)
        XCTAssertEqual(today.statusText, "今天截止")
        XCTAssertTrue(today.isVoiceReminderEligible)
        XCTAssertEqual(overdue.statusText, "已逾期 2 天")
        XCTAssertTrue(overdue.isVoiceReminderEligible)
    }

    func testRecentPlanIsExcludedFromRegularTodayTaskProjection() {
        let plan = TaskProjection(
            id: UUID(),
            title: "完成暑假作业",
            startDate: date(2026, 7, 31),
            timingMode: .flexibleDeadline,
            deadline: date(2026, 8, 20)
        )

        let results = TodayTaskProjectionBuilder.build(
            from: [plan],
            executions: [],
            subtasks: [],
            on: date(2026, 7, 31)
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testVisibleProjectionIncludesWindowAndKeepsCompletedPlanOnlyForCompletionDay() {
        let taskID = UUID()
        let executionID = UUID()
        let plan = TaskProjection(
            id: taskID,
            title: "准备开学用品",
            startDate: date(2026, 7, 1),
            timingMode: .flexibleDeadline,
            deadline: date(2026, 8, 20),
            isArchived: true
        )
        let completedAt = date(2026, 7, 31, hour: 10)
        let execution = TaskExecutionRecordProjection(
            TaskExecutionRecord(
                id: executionID,
                taskID: taskID,
                occurrenceDate: date(2026, 7, 1),
                status: .completed,
                completedAt: completedAt,
                createdAt: completedAt,
                updatedAt: completedAt
            )
        )

        let completionDay = RecentPlanSupport.visibleProjections(
            from: [plan],
            executions: [execution],
            subtasks: [],
            on: date(2026, 7, 31),
            includeCompletedToday: true,
            calendar: calendar
        )
        let nextDay = RecentPlanSupport.visibleProjections(
            from: [plan],
            executions: [execution],
            subtasks: [],
            on: date(2026, 8, 1),
            includeCompletedToday: true,
            calendar: calendar
        )

        XCTAssertEqual(completionDay.count, 1)
        XCTAssertTrue(completionDay[0].isCompleted)
        XCTAssertTrue(nextDay.isEmpty)
    }

    func testLegacyTaskSnapshotWithoutRecentPlanFieldsDefaultsToScheduled() throws {
        let task = TaskItem(title: "旧任务")
        let encoded = try JSONEncoder().encode(TaskItemSnapshot(task))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "timingModeRawValue")
        object.removeValue(forKey: "deadline")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TaskItemSnapshot.self, from: legacyData)
        let restored = decoded.makeModel()

        XCTAssertEqual(restored.timingMode, .scheduled)
        XCTAssertNil(restored.deadline)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}
