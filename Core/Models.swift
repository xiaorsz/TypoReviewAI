import Foundation

public enum Subject: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinese, english, all
    public var id: String { rawValue }
    public var title: String { self == .all ? "全部科目" : (self == .chinese ? "语文字词" : "英语单词") }
    public func contains(_ type: String) -> Bool {
        if self == .all { return Self.supports(type) }
        return self == .chinese ? ["汉字", "词语"].contains(type) : type == "单词"
    }
    public static func supports(_ type: String) -> Bool { ContentType(rawValue: type) != nil }
}

public enum ContentType: String, Codable, CaseIterable, Identifiable, Sendable {
    case character = "汉字", phrase = "词语", word = "单词", recitation = "英语背诵"
    public var id: String { rawValue }
    public var title: String { self == .recitation ? "英语背诵" : rawValue }
    public var isEnglish: Bool { self == .word || self == .recitation }
}

public enum GradingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case sequential = "逐题判定", batch = "统一判卷"
    public var id: String { rawValue }
}

public struct PracticePreferences: Codable, Equatable, Sendable {
    public var gradingStyle: GradingStyle = .batch
    public var writingInterval = 5
    public var repeatCount = 2
    public var speechRate = 0.42
    public var readEnglishMeaning = false
    public var reviewDailyLimit = 15
    public var reminderEnabled = false
    public var reminderHour = 20
    public var reminderMinute = 0
    public init() {}
}

public struct ParsedLearningLine: Equatable, Sendable {
    public var content: String
    public var prompt: String
    public var source: String
    public init(content: String, prompt: String = "", source: String = "") {
        self.content = content; self.prompt = prompt; self.source = source
    }
    public var serialized: String { [content, prompt, source].joined(separator: " | ") }
    /// Adapted from the original ParsedDictationEntry, with explicit invalid-line errors.
    public static func parse(_ text: String) throws -> [Self] {
        var rows: [Self] = []
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count <= 3, let content = parts.first, !content.isEmpty,
                  content.count <= 2000, parts.dropFirst().allSatisfy({ $0.count <= 2000 }) else {
                throw LabError.invalid("第 \(index + 1) 行格式不正确，请使用：内容 | 提示 | 来源。")
            }
            rows.append(Self(content: content, prompt: parts.count > 1 ? parts[1] : "", source: parts.count > 2 ? parts[2] : ""))
        }
        guard !rows.isEmpty, rows.count <= 500 else { throw LabError.invalid("请录入 1–500 条有效内容。") }
        return rows
    }
}

public enum Codec {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let box = try decoder.singleValueContainer()
            let text = try box.decode(String.self)
            guard let date = fractional.date(from: text) ?? standard.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: box, debugDescription: "无效日期：\(text)")
            }
            return date
        }
        return decoder
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    public static func text<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func date(_ day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, day.count == 10,
              let result = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Self.day(result, calendar: calendar) == day else { return nil }
        return result
    }
}

public struct ReviewItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var typeRawValue: String
    public var content: String
    public var prompt: String
    public var note: String
    public var source: String
    public var stage: Int
    public var nextReviewAt: Date
    public var lastReviewedAt: Date?
    public var consecutiveCorrectCount: Int
    public var consecutiveWrongCount: Int
    public var isPriority: Bool
    public var reviewTrackRawValue: String?
    public var dictationFollowUpStep: Int?
    public var isDictationPassRaw: Bool?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), type: String, content: String, prompt: String = "", now: Date = .now) {
        self.id = id; typeRawValue = type; self.content = content; self.prompt = prompt
        note = ""; source = ""; stage = 0; nextReviewAt = now; lastReviewedAt = nil
        consecutiveCorrectCount = 0; consecutiveWrongCount = 0; isPriority = false
        reviewTrackRawValue = "standard"; dictationFollowUpStep = 0; isDictationPassRaw = false
        createdAt = now; updatedAt = now
    }
    public var identity: String { "\(typeRawValue)|\(Self.normalized(content))" }
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

public struct ReviewRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var itemID: UUID
    public var reviewedAt: Date
    public var resultRawValue: String
    public var modeRawValue: String
    public var oldStage: Int
    public var newStage: Int
    public var note: String
    public var sessionID: UUID?

    public init(id: UUID = UUID(), itemID: UUID, correct: Bool, oldStage: Int, newStage: Int, now: Date) {
        self.id = id; self.itemID = itemID; reviewedAt = now
        resultRawValue = correct ? "correct" : "wrong"; modeRawValue = "dictation"
        self.oldStage = oldStage; self.newStage = newStage; note = ""
    }
}

public struct DictationSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var typeRawValue: String
    public var createdAt: Date
    public var updatedAt: Date
    public var scheduledDate: Date
    public var finishedAt: Date?
    public var reviewedAt: Date?
    public var currentEntryIndex: Int
    public var startedAt: Date?
    public var cancelledAt: Date?
    public var practiceMode: String?
    public var gradingStyle: GradingStyle?
    public var isFormalReview: Bool { practiceMode == "scheduled" }

    public init(id: UUID = UUID(), title: String, type: String, date: Date, now: Date = .now) {
        self.id = id; self.title = title; typeRawValue = type; scheduledDate = date
        createdAt = now; updatedAt = now; currentEntryIndex = 0
    }
    enum CodingKeys: String, CodingKey {
        case id, title, typeRawValue, createdAt, updatedAt, scheduledDate, finishedAt, reviewedAt
        case currentEntryIndex, startedAt, cancelledAt, practiceMode, gradingStyle
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        typeRawValue = try c.decode(String.self, forKey: .typeRawValue)
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        scheduledDate = try c.decode(Date.self, forKey: .scheduledDate)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        reviewedAt = try c.decodeIfPresent(Date.self, forKey: .reviewedAt)
        currentEntryIndex = try c.decodeIfPresent(Int.self, forKey: .currentEntryIndex) ?? 0
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        cancelledAt = try c.decodeIfPresent(Date.self, forKey: .cancelledAt)
        practiceMode = try c.decodeIfPresent(String.self, forKey: .practiceMode)
        gradingStyle = try c.decodeIfPresent(GradingStyle.self, forKey: .gradingStyle)
    }
    public var isUntouched: Bool {
        startedAt == nil && currentEntryIndex == 0 && finishedAt == nil && reviewedAt == nil && cancelledAt == nil
    }
}

public struct DictationEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var sortOrder: Int
    public var typeRawValue: String
    public var content: String
    public var prompt: String
    public var note: String
    public var source: String
    public var resultRawValue: String
    public var createdAt: Date
    public var updatedAt: Date
    public var itemID: UUID?
    public var submittedRecordID: UUID?
    public var beforeReviewItem: ReviewItem?

    public init(sessionID: UUID, item: ReviewItem, order: Int, now: Date) {
        id = UUID(); self.sessionID = sessionID; sortOrder = order; typeRawValue = item.typeRawValue
        content = item.content; prompt = item.prompt; note = item.note; source = item.source
        resultRawValue = "未判定"; createdAt = now; updatedAt = now; itemID = item.id
    }
    public var identity: String { "\(typeRawValue)|\(ReviewItem.normalized(content))" }
}

public struct CoachConfiguration: Codable, Equatable, Sendable {
    public var childName = ""
    public var dailyLimit = 15
    public var subject: Subject = .chinese
    public var isEnabled = false
    public var model = "deepseek-flash"
    public init() {}
}

public struct CoachPlan: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var itemIDs: [UUID]
    public var rationale: String
    public var subject: Subject
    public var createdAt: Date
    public var updatedAt: Date
}

public struct CoachLog: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date: Date = .now
    public var runID: UUID
    public var kind: String
    public var message: String
    public init(runID: UUID, kind: String, message: String) {
        self.runID = runID; self.kind = kind; self.message = message
    }
}

public struct LabState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var datasetID = UUID()
    public var configuration = CoachConfiguration()
    public var items: [ReviewItem] = []
    public var records: [ReviewRecord] = []
    public var sessions: [DictationSession] = []
    public var entries: [DictationEntry] = []
    public var plans: [CoachPlan] = []
    public var logs: [CoachLog] = []
    public var completedTriggers: [String] = []
    public var pendingFeedbackSessionIDs: [UUID] = []
    public var reviewPlannerVersion: Int?
    public var importedAt: Date?
    public var sourceExportedAt: Date?
    public var preferences: PracticePreferences?
    public var practicePreferences: PracticePreferences { preferences ?? PracticePreferences() }
    public init() {}
}

public enum LabError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
