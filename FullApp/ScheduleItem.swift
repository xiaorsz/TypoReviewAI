import Foundation
import SwiftData

@Model
final class ScheduleItem {
    var id: UUID = UUID()
    var title: String = ""
    var note: String = ""
    var startTime: Date = Date()
    var endTime: Date = Date()
    var repeatRuleRawValue: String = "单次"
    var weekdaysJSON: String = "[]"
    var effectiveStartDate: Date = Date()
    var effectiveEndDate: Date?
    var isArchived: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        startTime: Date,
        endTime: Date,
        repeatRule: ScheduleRepeatRule = .once,
        weekdays: [Int] = [],
        effectiveStartDate: Date? = nil,
        effectiveEndDate: Date? = nil,
        isArchived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.startTime = startTime
        self.endTime = endTime
        self.repeatRuleRawValue = repeatRule.rawValue
        self.weekdaysJSON = (try? String(data: JSONEncoder().encode(weekdays), encoding: .utf8)) ?? "[]"
        self.effectiveStartDate = effectiveStartDate ?? Calendar.current.startOfDay(for: startTime)
        self.effectiveEndDate = effectiveEndDate
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Computed Properties

    var repeatRule: ScheduleRepeatRule {
        get { ScheduleRepeatRule(rawValue: repeatRuleRawValue) ?? .once }
        set { repeatRuleRawValue = newValue.rawValue }
    }

    var weekdays: [Int] {
        get {
            guard let data = weekdaysJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([Int].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            weekdaysJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    // MARK: - Today Logic

    /// Whether this schedule should appear on a given date.
    func shouldAppear(on date: Date) -> Bool {
        guard !isArchived else { return false }

        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)
        let startDay = calendar.startOfDay(for: startTime)
        let effectiveStartDay = calendar.startOfDay(for: effectiveStartDate)
        let effectiveEndDay = effectiveEndDate.map { calendar.startOfDay(for: $0) }

        switch repeatRule {
        case .once:
            return calendar.isDate(targetDay, inSameDayAs: startDay)
        case .daily:
            guard targetDay >= effectiveStartDay else { return false }
            if let effectiveEndDay, targetDay > effectiveEndDay { return false }
            return true
        case .weekly:
            guard targetDay >= effectiveStartDay else { return false }
            if let effectiveEndDay, targetDay > effectiveEndDay { return false }
            let weekday = calendar.component(.weekday, from: date)
            return weekdays.contains(weekday)
        }
    }

    /// The display time range string for a given date (e.g., "09:00 - 10:30").
    func timeRangeText(on date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        // For repeating schedules, use the time components from the original
        // but apply them to the target date
        let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)

        let displayStart = calendar.date(bySettingHour: startComponents.hour ?? 0,
                                          minute: startComponents.minute ?? 0,
                                          second: 0, of: date) ?? startTime
        let displayEnd = calendar.date(bySettingHour: endComponents.hour ?? 0,
                                        minute: endComponents.minute ?? 0,
                                        second: 0, of: date) ?? endTime

        return "\(formatter.string(from: displayStart)) - \(formatter.string(from: displayEnd))"
    }

    func hasEnded(on date: Date, reference: Date = .now) -> Bool {
        reference > endDateTime(on: date)
    }

    /// Sort key: start time's hour and minute for ordering within a day.
    var startTimeMinutes: Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: startTime)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    // MARK: - Display Helpers

    var repeatRuleLabel: String {
        switch repeatRule {
        case .once:
            return "单次"
        case .daily:
            return "每天"
        case .weekly:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let days = weekdays.sorted().compactMap { wd -> String? in
                guard wd >= 1, wd <= 7 else { return nil }
                return "周\(names[wd - 1])"
            }
            return "每周 \(days.joined(separator: "、"))"
        }
    }

    var effectiveDateRangeLabel: String? {
        guard repeatRule != .once, let effectiveEndDate else { return nil }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: effectiveStartDate)
        let endDay = calendar.startOfDay(for: effectiveEndDate)
        if calendar.isDate(startDay, equalTo: endDay, toGranularity: .year) {
            return "\(startDay.formatted(.dateTime.month().day())) - \(endDay.formatted(.dateTime.month().day()))"
        }
        return "\(startDay.formatted(.dateTime.year().month().day())) - \(endDay.formatted(.dateTime.year().month().day()))"
    }

    private func endDateTime(on date: Date) -> Date {
        guard repeatRule != .once else { return endTime }

        let calendar = Calendar.current
        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)
        return calendar.date(
            bySettingHour: endComponents.hour ?? 0,
            minute: endComponents.minute ?? 0,
            second: 0,
            of: date
        ) ?? endTime
    }
}

struct ScheduleDisplayIdentity: Hashable {
    let normalizedTitle: String
    let normalizedNote: String
    let startTimeMinutes: Int
    let endTimeMinutes: Int
    let repeatRuleRawValue: String
    let weekdays: [Int]
    let effectiveStartDay: Date
    let effectiveEndDay: Date?

    init(
        title: String,
        note: String,
        startTime: Date,
        endTime: Date,
        repeatRule: ScheduleRepeatRule,
        weekdays: [Int],
        effectiveStartDate: Date,
        effectiveEndDate: Date?,
        calendar: Calendar = .current
    ) {
        normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        startTimeMinutes = (startComponents.hour ?? 0) * 60 + (startComponents.minute ?? 0)

        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)
        endTimeMinutes = (endComponents.hour ?? 0) * 60 + (endComponents.minute ?? 0)
        repeatRuleRawValue = repeatRule.rawValue
        self.weekdays = weekdays.sorted()
        effectiveStartDay = calendar.startOfDay(for: effectiveStartDate)
        effectiveEndDay = effectiveEndDate.map { calendar.startOfDay(for: $0) }
    }
}

enum ScheduleDedupSupport {
    static func deduplicated<Item>(
        _ items: [Item],
        identity: (Item) -> ScheduleDisplayIdentity
    ) -> [Item] {
        var seen = Set<ScheduleDisplayIdentity>()
        return items.filter { seen.insert(identity($0)).inserted }
    }
}
