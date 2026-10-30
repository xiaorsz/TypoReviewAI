import Foundation

enum AppSection: Hashable {
    case review
    case library
    case tasks
    case settings
}

enum ReviewMode: String, Codable, CaseIterable {
    case scheduled
    case retry
    case dictation
}

enum ReviewResult: String, Codable, CaseIterable {
    case correct
    case wrong
}

enum ReviewItemType: String, Codable, CaseIterable, Identifiable {
    case chineseCharacter = "汉字"
    case phrase = "词语"
    case englishWord = "单词"
    case englishSentence = "英语背诵"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chineseCharacter: return "汉字"
        case .phrase: return "词句"
        case .englishWord: return "英语"
        case .englishSentence: return "背诵"
        }
    }

    var isRecitation: Bool { self == .englishSentence }

    var isEnglish: Bool { self == .englishWord || isRecitation }
}

enum DictationResult: String, Codable, CaseIterable, Identifiable {
    case pending = "未判定"
    case correct = "正确"
    case wrong = "错误"

    var id: String { rawValue }
}

enum TaskCategory: String, Codable, CaseIterable, Identifiable {
    case reviewSupport = "复习配套"
    case dailyTodo = "今日待办"

    var id: String { rawValue }
}

enum ReviewInteractionStyle: String, Codable, CaseIterable, Identifiable {
    case oneByOne = "逐题判卷"
    case batch = "统一判卷"

    var id: String { rawValue }
}

enum TaskSkipPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case skippable = "可跳过"
    case unskippable = "不可跳过"

    var id: String { rawValue }
}

enum TaskTimingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case scheduled
    case flexibleDeadline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scheduled:
            return "普通任务"
        case .flexibleDeadline:
            return "近期计划"
        }
    }
}

enum ScheduleRepeatRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case once = "单次"
    case daily = "每天"
    case weekly = "每周"

    var id: String { rawValue }
}

/// Recurrence rule encoded as JSON string for SwiftData storage.
struct TaskRecurrence: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case once = "单次"
        case daily = "每天"
        case weekly = "每周"

        var id: String { rawValue }
    }

    var kind: Kind
    /// Only used when kind == .weekly; 1=Sunday, 2=Monday, ... 7=Saturday (Calendar.component .weekday)
    var weekdays: [Int]

    static let once = TaskRecurrence(kind: .once, weekdays: [])
    static let daily = TaskRecurrence(kind: .daily, weekdays: [])

    static func weekly(_ weekdays: [Int]) -> TaskRecurrence {
        TaskRecurrence(kind: .weekly, weekdays: weekdays)
    }

    func toJSON() -> String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}"
    }

    static func fromJSON(_ json: String) -> TaskRecurrence {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(TaskRecurrence.self, from: data) else {
            return .once
        }
        return decoded
    }
}
