import Foundation
import SwiftData

struct TaskPauseInterval: Codable, Hashable, Sendable {
    let startDate: Date
    let endDate: Date
}

enum TaskPauseSupport {
    static func decodeIntervals(from json: String?) -> [TaskPauseInterval] {
        guard let json,
              let data = json.data(using: .utf8),
              let intervals = try? JSONDecoder().decode([TaskPauseInterval].self, from: data) else {
            return []
        }
        return intervals
    }

    static func encodeIntervals(_ intervals: [TaskPauseInterval]) -> String? {
        guard !intervals.isEmpty,
              let data = try? JSONEncoder().encode(intervals) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func isDatePaused(
        _ date: Date,
        completedIntervals: [TaskPauseInterval],
        currentPauseStartDate: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        let day = calendar.startOfDay(for: date)

        if let currentPauseStartDate,
           day >= calendar.startOfDay(for: currentPauseStartDate) {
            return true
        }

        return completedIntervals.contains { interval in
            let start = calendar.startOfDay(for: interval.startDate)
            let end = calendar.startOfDay(for: interval.endDate)
            return day >= start && day < end
        }
    }
}

@Model
final class TaskItem {
    var id: UUID = UUID()
    var title: String = ""
    var note: String = ""
    var recurrenceJSON: String?
    var skipPolicyRawValue: String?
    var timingModeRawValue: String?
    var startDate: Date = Date()
    var endDate: Date?
    var deadline: Date?
    var pauseIntervalsJSON: String?
    var pauseStartedAt: Date?
    var isArchived: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        recurrence: TaskRecurrence = .once,
        skipPolicy: TaskSkipPolicy = .skippable,
        timingMode: TaskTimingMode = .scheduled,
        startDate: Date = .now,
        endDate: Date? = nil,
        deadline: Date? = nil,
        pauseIntervalsJSON: String? = nil,
        pauseStartedAt: Date? = nil,
        isArchived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.recurrenceJSON = recurrence.toJSON()
        self.skipPolicyRawValue = skipPolicy.rawValue
        self.timingModeRawValue = timingMode.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.deadline = deadline
        self.pauseIntervalsJSON = pauseIntervalsJSON
        self.pauseStartedAt = pauseStartedAt
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var recurrence: TaskRecurrence {
        get {
            guard let json = recurrenceJSON else { return .once }
            return TaskRecurrence.fromJSON(json)
        }
        set { recurrenceJSON = newValue.toJSON() }
    }

    var skipPolicy: TaskSkipPolicy {
        get {
            guard let raw = skipPolicyRawValue else { return .skippable }
            return TaskSkipPolicy(rawValue: raw) ?? .skippable
        }
        set { skipPolicyRawValue = newValue.rawValue }
    }

    var timingMode: TaskTimingMode {
        get {
            guard let raw = timingModeRawValue else { return .scheduled }
            return TaskTimingMode(rawValue: raw) ?? .scheduled
        }
        set { timingModeRawValue = newValue.rawValue }
    }

    var isFlexibleDeadlinePlan: Bool {
        timingMode == .flexibleDeadline
    }

    var pauseIntervals: [TaskPauseInterval] {
        get { TaskPauseSupport.decodeIntervals(from: pauseIntervalsJSON) }
        set { pauseIntervalsJSON = TaskPauseSupport.encodeIntervals(newValue) }
    }

    var isPaused: Bool {
        recurrence.kind != .once && pauseStartedAt != nil
    }

    func pause(starting date: Date) {
        guard recurrence.kind != .once, pauseStartedAt == nil else { return }
        pauseStartedAt = Calendar.current.startOfDay(for: date)
        updatedAt = .now
    }

    func resume(on date: Date) {
        guard let pauseStartedAt else { return }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: pauseStartedAt)
        let end = calendar.startOfDay(for: date)
        if end > start {
            pauseIntervals.append(TaskPauseInterval(startDate: start, endDate: end))
        }
        self.pauseStartedAt = nil
        updatedAt = .now
    }

    func isOccurrencePaused(_ date: Date) -> Bool {
        guard recurrence.kind != .once else { return false }
        return TaskPauseSupport.isDatePaused(
            date,
            completedIntervals: pauseIntervals,
            currentPauseStartDate: pauseStartedAt
        )
    }

    func originText(for pendingDate: Date, relativeTo date: Date) -> String {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)

        if calendar.isDate(pendingDate, equalTo: targetDay, toGranularity: .year) {
            return "原定 \(pendingDate.formatted(.dateTime.month().day()))"
        }
        return "原定 \(pendingDate.formatted(.dateTime.year().month().day()))"
    }

    func scheduledOccurrenceDates(upTo date: Date) -> [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let unclampedTarget = calendar.startOfDay(for: date)
        let target = min(unclampedTarget, self.effectiveEndDay ?? unclampedTarget)

        guard target >= start else { return [] }

        let scheduledDates: [Date]
        switch recurrence.kind {
        case .once:
            return [start]

        case .daily:
            let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
            scheduledDates = (0...days).compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: start)
            }

        case .weekly:
            var weeklyDates: [Date] = []
            var checkDate = start
            while checkDate <= target {
                let weekday = calendar.component(.weekday, from: checkDate)
                if recurrence.weekdays.contains(weekday) {
                    weeklyDates.append(checkDate)
                }
                guard let nextDate = calendar.date(byAdding: .day, value: 1, to: checkDate) else {
                    break
                }
                checkDate = nextDate
            }
            scheduledDates = weeklyDates
        }

        return scheduledDates.filter { !isOccurrencePaused($0) }
    }

    // MARK: - Display Helpers

    var recurrenceLabel: String {
        switch recurrence.kind {
        case .once:
            return "单次"
        case .daily:
            return "每天"
        case .weekly:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let days = recurrence.weekdays.sorted().compactMap { wd -> String? in
                guard wd >= 1, wd <= 7 else { return nil }
                return "周\(names[wd - 1])"
            }
            return "每周 \(days.joined(separator: "、"))"
        }
    }

    var effectiveDateRangeLabel: String? {
        guard recurrence.kind != .once, let effectiveEndDay else { return nil }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: startDate)
        if calendar.isDate(startDay, equalTo: effectiveEndDay, toGranularity: .year) {
            return "\(startDay.formatted(.dateTime.month().day())) - \(effectiveEndDay.formatted(.dateTime.month().day()))"
        }
        return "\(startDay.formatted(.dateTime.year().month().day())) - \(effectiveEndDay.formatted(.dateTime.year().month().day()))"
    }

    var recurrenceShortLabel: String {
        switch recurrence.kind {
        case .once:
            return "单次"
        case .daily:
            return "每天"
        case .weekly:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let days = recurrence.weekdays.sorted().compactMap { wd -> String? in
                guard wd >= 1, wd <= 7 else { return nil }
                return names[wd - 1]
            }
            return "周" + days.joined(separator: "、")
        }
    }

    func originShortText(for pendingDate: Date) -> String {
        return pendingDate.formatted(.dateTime.month().day())
    }

    var effectiveEndDay: Date? {
        guard let endDate else { return nil }
        return Calendar.current.startOfDay(for: endDate)
    }
}
