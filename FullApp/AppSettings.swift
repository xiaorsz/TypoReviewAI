import Foundation
import SwiftData

struct BoardAutoplaySlot: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var startHour: Int
    var startMinute: Int
    var durationMinutes: Int
    var isEnabled: Bool = true

    init(
        id: UUID = UUID(),
        startHour: Int,
        startMinute: Int,
        durationMinutes: Int,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.startHour = min(max(startHour, 0), 23)
        self.startMinute = min(max(startMinute, 0), 59)
        self.durationMinutes = max(5, durationMinutes)
        self.isEnabled = isEnabled
    }

    var startTimeText: String {
        String(format: "%02d:%02d", startHour, startMinute)
    }
}

enum BoardManualPlaybackOption: String, CaseIterable, Identifiable {
    case unlimited
    case minutes15 = "15m"
    case minutes30 = "30m"
    case minutes45 = "45m"
    case minutes60 = "60m"
    case untilPlaylistEnds = "until_playlist_ends"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlimited:
            return "不限"
        case .minutes15:
            return "15 分钟"
        case .minutes30:
            return "30 分钟"
        case .minutes45:
            return "45 分钟"
        case .minutes60:
            return "1 小时"
        case .untilPlaylistEnds:
            return "直到列表播完"
        }
    }

    var durationMinutes: Int? {
        switch self {
        case .unlimited, .untilPlaylistEnds:
            return nil
        case .minutes15:
            return 15
        case .minutes30:
            return 30
        case .minutes45:
            return 45
        case .minutes60:
            return 60
        }
    }

    var statusText: String {
        switch self {
        case .unlimited:
            return "手动循环播放中"
        case .minutes15, .minutes30, .minutes45, .minutes60, .untilPlaylistEnds:
            return "手动播放中"
        }
    }
}

@Model
final class AppSettings {
    static let syncSingletonID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let defaultChildName = ""
    static let defaultDailyLimit = 15
    static let defaultRemindHour = 19
    static let defaultRemindMinute = 30
    static let defaultReviewInteractionStyle: ReviewInteractionStyle = .oneByOne
    static let defaultBoardAutoplayEnabled = true
    static let defaultBoardAutoplayStartHour = 7
    static let defaultBoardAutoplayStartMinute = 0
    static let defaultBoardAutoplayEndHour = 7
    static let defaultBoardAutoplayEndMinute = 30
    static let defaultBoardAutoplayDurationMinutes = 30
    static let defaultBoardAutoplaySlotsRawValue = ""
    static let defaultBoardManualPlaybackOption = BoardManualPlaybackOption.untilPlaylistEnds.rawValue
    static let defaultBoardAutoplaySkipWeekends = true
    static let defaultBoardAutoplaySkipChinaHolidays = true
    static let defaultAISummaryEnabled = false
    static let defaultAISummaryModelRawValue = "deepseek-v4-flash"
    static let supportedChinaHolidayYearsSummary = ChinaHolidayCalendar.supportedYearsSummary
    static let legacyReviewInteractionStyleKey = "reviewInteractionStyle"

    var id: UUID = AppSettings.syncSingletonID
    var childName: String = AppSettings.defaultChildName
    var dailyLimit: Int = AppSettings.defaultDailyLimit
    var remindHour: Int = AppSettings.defaultRemindHour
    var remindMinute: Int = AppSettings.defaultRemindMinute
    var reviewInteractionStyleRawValue: String = AppSettings.defaultReviewInteractionStyle.rawValue
    var boardAutoplayEnabled: Bool = AppSettings.defaultBoardAutoplayEnabled
    var boardAutoplayStartHour: Int = AppSettings.defaultBoardAutoplayStartHour
    var boardAutoplayStartMinute: Int = AppSettings.defaultBoardAutoplayStartMinute
    var boardAutoplayEndHour: Int = AppSettings.defaultBoardAutoplayEndHour
    var boardAutoplayEndMinute: Int = AppSettings.defaultBoardAutoplayEndMinute
    var boardAutoplayDurationMinutes: Int = AppSettings.defaultBoardAutoplayDurationMinutes
    var boardAutoplaySlotsRawValue: String = AppSettings.defaultBoardAutoplaySlotsRawValue
    var boardManualPlaybackOptionRawValue: String = AppSettings.defaultBoardManualPlaybackOption
    var boardAutoplaySkipWeekends: Bool = AppSettings.defaultBoardAutoplaySkipWeekends
    var boardAutoplaySkipChinaHolidays: Bool = AppSettings.defaultBoardAutoplaySkipChinaHolidays
    var aiSummaryEnabled: Bool = AppSettings.defaultAISummaryEnabled
    var aiSummaryModelRawValue: String = AppSettings.defaultAISummaryModelRawValue

    init(
        id: UUID = AppSettings.syncSingletonID,
        childName: String = AppSettings.defaultChildName,
        dailyLimit: Int = AppSettings.defaultDailyLimit,
        remindHour: Int = AppSettings.defaultRemindHour,
        remindMinute: Int = AppSettings.defaultRemindMinute,
        reviewInteractionStyle: ReviewInteractionStyle = AppSettings.defaultReviewInteractionStyle,
        boardAutoplayEnabled: Bool = AppSettings.defaultBoardAutoplayEnabled,
        boardAutoplayStartHour: Int = AppSettings.defaultBoardAutoplayStartHour,
        boardAutoplayStartMinute: Int = AppSettings.defaultBoardAutoplayStartMinute,
        boardAutoplayEndHour: Int = AppSettings.defaultBoardAutoplayEndHour,
        boardAutoplayEndMinute: Int = AppSettings.defaultBoardAutoplayEndMinute,
        boardAutoplayDurationMinutes: Int = AppSettings.defaultBoardAutoplayDurationMinutes,
        boardAutoplaySlots: [BoardAutoplaySlot]? = nil,
        boardManualPlaybackOption: BoardManualPlaybackOption = .untilPlaylistEnds,
        boardAutoplaySkipWeekends: Bool = AppSettings.defaultBoardAutoplaySkipWeekends,
        boardAutoplaySkipChinaHolidays: Bool = AppSettings.defaultBoardAutoplaySkipChinaHolidays,
        aiSummaryEnabled: Bool = AppSettings.defaultAISummaryEnabled,
        aiSummaryModelRawValue: String = AppSettings.defaultAISummaryModelRawValue
    ) {
        self.id = id
        self.childName = childName
        self.dailyLimit = dailyLimit
        self.remindHour = remindHour
        self.remindMinute = remindMinute
        self.reviewInteractionStyleRawValue = reviewInteractionStyle.rawValue
        self.boardAutoplayEnabled = boardAutoplayEnabled
        self.boardAutoplayStartHour = boardAutoplayStartHour
        self.boardAutoplayStartMinute = boardAutoplayStartMinute
        self.boardAutoplayEndHour = boardAutoplayEndHour
        self.boardAutoplayEndMinute = boardAutoplayEndMinute
        self.boardAutoplayDurationMinutes = boardAutoplayDurationMinutes
        self.boardAutoplaySlotsRawValue = Self.encodeBoardAutoplaySlots(boardAutoplaySlots ?? [])
        self.boardManualPlaybackOptionRawValue = boardManualPlaybackOption.rawValue
        self.boardAutoplaySkipWeekends = boardAutoplaySkipWeekends
        self.boardAutoplaySkipChinaHolidays = boardAutoplaySkipChinaHolidays
        self.aiSummaryEnabled = aiSummaryEnabled
        self.aiSummaryModelRawValue = aiSummaryModelRawValue
    }

    static func ensureSingleton(in modelContext: ModelContext) throws -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        let allSettings = try modelContext.fetch(descriptor)

        guard let canonical = chooseCanonical(from: allSettings) else {
            let settings = AppSettings()
            modelContext.insert(settings)
            try modelContext.save()
            return settings
        }

        for duplicate in allSettings where duplicate.persistentModelID != canonical.persistentModelID {
            modelContext.delete(duplicate)
        }

        canonical.migrateLegacyReviewInteractionStyleIfNeeded()
        canonical.migrateLegacyBoardAutoplayDurationIfNeeded()
        canonical.migrateLegacyBoardAutoplaySlotsIfNeeded()
        canonical.id = syncSingletonID

        if modelContext.hasChanges {
            try modelContext.save()
        }

        return canonical
    }

    static func chooseCanonical(from settings: [AppSettings]) -> AppSettings? {
        settings.max { lhs, rhs in
            let lhsScore = lhs.priorityScore
            let rhsScore = rhs.priorityScore

            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }

            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    private var priorityScore: Int {
        var score = 0

        if childName != AppSettings.defaultChildName {
            score += 8
        }

        if dailyLimit != AppSettings.defaultDailyLimit {
            score += 4
        }

        if remindHour != AppSettings.defaultRemindHour || remindMinute != AppSettings.defaultRemindMinute {
            score += 2
        }

        if reviewInteractionStyle != AppSettings.defaultReviewInteractionStyle {
            score += 1
        }

        if boardAutoplayEnabled != AppSettings.defaultBoardAutoplayEnabled {
            score += 1
        }

        if normalizedBoardAutoplaySlots != Self.defaultBoardAutoplaySlots {
            score += 2
        }

        if boardManualPlaybackOptionRawValue != AppSettings.defaultBoardManualPlaybackOption {
            score += 1
        }

        if boardAutoplaySkipWeekends != AppSettings.defaultBoardAutoplaySkipWeekends
            || boardAutoplaySkipChinaHolidays != AppSettings.defaultBoardAutoplaySkipChinaHolidays {
            score += 1
        }

        if aiSummaryEnabled != AppSettings.defaultAISummaryEnabled
            || aiSummaryModelRawValue != AppSettings.defaultAISummaryModelRawValue {
            score += 1
        }

        return score
    }

    var reviewInteractionStyle: ReviewInteractionStyle {
        get { ReviewInteractionStyle(rawValue: reviewInteractionStyleRawValue) ?? AppSettings.defaultReviewInteractionStyle }
        set { reviewInteractionStyleRawValue = newValue.rawValue }
    }

    var boardManualPlaybackOption: BoardManualPlaybackOption {
        get { BoardManualPlaybackOption(rawValue: boardManualPlaybackOptionRawValue) ?? .untilPlaylistEnds }
        set { boardManualPlaybackOptionRawValue = newValue.rawValue }
    }

    var boardAutoplaySlots: [BoardAutoplaySlot] {
        get {
            if boardAutoplaySlotsRawValue.isEmpty {
                return [legacyBoardAutoplaySlot]
            }

            return Self.decodeBoardAutoplaySlots(boardAutoplaySlotsRawValue)
        }
        set {
            let normalized = Self.normalizeBoardAutoplaySlots(newValue)
            boardAutoplaySlotsRawValue = Self.encodeBoardAutoplaySlots(normalized)
            synchronizeLegacyBoardAutoplayFields(with: normalized.first)
        }
    }

    private func migrateLegacyReviewInteractionStyleIfNeeded() {
        guard reviewInteractionStyle == AppSettings.defaultReviewInteractionStyle else { return }
        guard let legacyValue = UserDefaults.standard.string(forKey: AppSettings.legacyReviewInteractionStyleKey) else { return }
        guard let legacyStyle = ReviewInteractionStyle(rawValue: legacyValue) else { return }

        reviewInteractionStyle = legacyStyle
    }

    private func migrateLegacyBoardAutoplayDurationIfNeeded() {
        let legacyDuration = legacyBoardAutoplayDurationMinutes()
        if boardAutoplayDurationMinutes <= 0
            || (boardAutoplayDurationMinutes == AppSettings.defaultBoardAutoplayDurationMinutes
                && legacyDuration != AppSettings.defaultBoardAutoplayDurationMinutes) {
            boardAutoplayDurationMinutes = legacyDuration
        }

        synchronizeLegacyBoardAutoplayEndTime()
    }

    private func migrateLegacyBoardAutoplaySlotsIfNeeded() {
        guard boardAutoplaySlotsRawValue.isEmpty else {
            synchronizeLegacyBoardAutoplayFields(with: normalizedBoardAutoplaySlots.first)
            return
        }

        boardAutoplaySlots = [legacyBoardAutoplaySlot]
    }

    var boardAutoplayTimeSummary: String {
        let summaries = normalizedBoardAutoplaySlots.map { slot in
            let start = formattedTime(hour: slot.startHour, minute: slot.startMinute)
            let end = formattedTime(totalMinutes: slot.startHour * 60 + slot.startMinute + slot.durationMinutes)
            return "\(start) - \(end)"
        }

        switch summaries.count {
        case 0:
            return "未设置时间段"
        case 1:
            return summaries[0]
        case 2:
            return summaries.joined(separator: " · ")
        default:
            return summaries.prefix(2).joined(separator: " · ") + " · +\(summaries.count - 2)"
        }
    }

    var boardAutoplayDurationSummary: String {
        formattedDuration(minutes: normalizedBoardAutoplaySlots.first?.durationMinutes ?? normalizedBoardAutoplayDurationMinutes)
    }

    var boardManualPlaybackOptionSummary: String {
        boardManualPlaybackOption.title
    }

    var boardAutoplayRuleSummary: String {
        var rules: [String] = []
        if boardAutoplaySkipWeekends {
            rules.append("周末不播放")
        }
        if boardAutoplaySkipChinaHolidays {
            rules.append("法定节假日不播放")
        }
        return rules.isEmpty ? "每天都可自动播放" : rules.joined(separator: " · ")
    }

    var hasValidBoardAutoplayWindow: Bool {
        !normalizedBoardAutoplaySlots.isEmpty
    }

    func boardAutoplayWindow(on date: Date) -> (start: Date, end: Date)? {
        currentBoardAutoplayWindow(on: date) ?? nextBoardAutoplayWindow(on: date)
    }

    func boardAutoplayWindows(on date: Date) -> [(start: Date, end: Date)] {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)

        return normalizedBoardAutoplaySlots.compactMap { slot in
            guard let start = calendar.date(
                bySettingHour: slot.startHour,
                minute: slot.startMinute,
                second: 0,
                of: day
            ) else {
                return nil
            }

            guard let end = calendar.date(byAdding: .minute, value: slot.durationMinutes, to: start),
                  end > start else {
                return nil
            }

            return (start, end)
        }
    }

    func currentBoardAutoplayWindow(on date: Date) -> (start: Date, end: Date)? {
        boardAutoplayWindows(on: date).first { window in
            date >= window.start && date < window.end
        }
    }

    func nextBoardAutoplayWindow(on date: Date) -> (start: Date, end: Date)? {
        boardAutoplayWindows(on: date).first { $0.start > date }
    }

    func isBoardAutoplayActive(on date: Date) -> Bool {
        guard boardAutoplayEnabled, isBoardAutoplayAllowed(on: date) else {
            return false
        }

        return currentBoardAutoplayWindow(on: date) != nil
    }

    func isBoardAutoplayAllowed(on date: Date) -> Bool {
        boardAutoplayBlockedReason(on: date) == nil
    }

    func boardAutoplayBlockedReason(on date: Date) -> String? {
        let calendar = Calendar(identifier: .gregorian)

        if boardAutoplaySkipWeekends && calendar.isDateInWeekend(date) {
            return "周末不播放"
        }

        if boardAutoplaySkipChinaHolidays && ChinaHolidayCalendar.isHoliday(date) {
            return "节假日不播放"
        }

        return nil
    }

    func setBoardAutoplayStart(hour: Int, minute: Int) {
        boardAutoplayStartHour = hour
        boardAutoplayStartMinute = minute
        synchronizeLegacyBoardAutoplayEndTime()
        replaceFirstBoardAutoplaySlot(
            startHour: hour,
            startMinute: minute,
            durationMinutes: normalizedBoardAutoplayDurationMinutes
        )
    }

    func setBoardAutoplayDuration(minutes: Int) {
        boardAutoplayDurationMinutes = minutes
        synchronizeLegacyBoardAutoplayEndTime()
        replaceFirstBoardAutoplaySlot(
            startHour: boardAutoplayStartHour,
            startMinute: boardAutoplayStartMinute,
            durationMinutes: max(5, minutes)
        )
    }

    func addBoardAutoplaySlot() {
        var slots = normalizedBoardAutoplaySlots
        let last = slots.last
        slots.append(
            BoardAutoplaySlot(
                startHour: last?.startHour ?? AppSettings.defaultBoardAutoplayStartHour,
                startMinute: last?.startMinute ?? AppSettings.defaultBoardAutoplayStartMinute,
                durationMinutes: last?.durationMinutes ?? AppSettings.defaultBoardAutoplayDurationMinutes
            )
        )
        boardAutoplaySlots = slots
    }

    func updateBoardAutoplaySlot(id: UUID, _ update: (inout BoardAutoplaySlot) -> Void) {
        var slots = normalizedBoardAutoplaySlots
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        update(&slots[index])
        slots[index].durationMinutes = max(5, slots[index].durationMinutes)
        boardAutoplaySlots = slots
    }

    func removeBoardAutoplaySlot(id: UUID) {
        var slots = normalizedBoardAutoplaySlots
        slots.removeAll { $0.id == id }
        boardAutoplaySlots = slots
    }

    func synchronizeLegacyBoardAutoplayEndTime() {
        guard let firstSlot = normalizedBoardAutoplaySlots.first else { return }
        let endMinutes = firstSlot.startHour * 60 + firstSlot.startMinute + firstSlot.durationMinutes
        let normalizedEndMinutes = ((endMinutes % (24 * 60)) + (24 * 60)) % (24 * 60)
        boardAutoplayEndHour = normalizedEndMinutes / 60
        boardAutoplayEndMinute = normalizedEndMinutes % 60
    }

    private var normalizedBoardAutoplayDurationMinutes: Int {
        max(5, boardAutoplayDurationMinutes)
    }

    private var normalizedBoardAutoplaySlots: [BoardAutoplaySlot] {
        Self.normalizeBoardAutoplaySlots(boardAutoplaySlots)
    }

    private func legacyBoardAutoplayDurationMinutes() -> Int {
        var components = DateComponents()
        components.hour = boardAutoplayStartHour
        components.minute = boardAutoplayStartMinute
        guard let start = Calendar.current.date(from: components) else {
            return AppSettings.defaultBoardAutoplayDurationMinutes
        }

        components.hour = boardAutoplayEndHour
        components.minute = boardAutoplayEndMinute
        guard let end = Calendar.current.date(from: components) else {
            return AppSettings.defaultBoardAutoplayDurationMinutes
        }

        let duration = Int(end.timeIntervalSince(start) / 60)
        return duration > 0 ? duration : AppSettings.defaultBoardAutoplayDurationMinutes
    }

    private func formattedTime(hour: Int, minute: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "HH:mm"

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        return formatter.string(from: Calendar.current.date(from: components) ?? .now)
    }

    private func formattedTime(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formattedTime(totalMinutes: Int) -> String {
        let normalized = ((totalMinutes % (24 * 60)) + (24 * 60)) % (24 * 60)
        return formattedTime(hour: normalized / 60, minute: normalized % 60)
    }

    private func formattedDuration(minutes: Int) -> String {
        if minutes % 60 == 0 {
            return "\(minutes / 60) 小时"
        }
        return "\(minutes) 分钟"
    }

    // A legacy single time range is the same logical row on every read/device.
    // A fresh UUID here makes SwiftUI replace its DatePicker while scrolling or
    // editing, and updateBoardAutoplaySlot cannot find the row the user tapped.
    private static let legacyBoardAutoplaySlotID = UUID(uuidString: "A0820F06-FFB5-59DA-A411-72487B75A501")!

    private var legacyBoardAutoplaySlot: BoardAutoplaySlot {
        BoardAutoplaySlot(
            id: Self.legacyBoardAutoplaySlotID,
            startHour: boardAutoplayStartHour,
            startMinute: boardAutoplayStartMinute,
            durationMinutes: legacyBoardAutoplayDurationMinutes()
        )
    }

    private func replaceFirstBoardAutoplaySlot(
        startHour: Int,
        startMinute: Int,
        durationMinutes: Int
    ) {
        var slots = normalizedBoardAutoplaySlots
        if slots.isEmpty {
            slots = [
                BoardAutoplaySlot(
                    startHour: startHour,
                    startMinute: startMinute,
                    durationMinutes: durationMinutes
                )
            ]
        } else {
            slots[0].startHour = min(max(startHour, 0), 23)
            slots[0].startMinute = min(max(startMinute, 0), 59)
            slots[0].durationMinutes = max(5, durationMinutes)
        }
        boardAutoplaySlots = slots
    }

    private func synchronizeLegacyBoardAutoplayFields(with firstSlot: BoardAutoplaySlot?) {
        guard let firstSlot else { return }
        boardAutoplayStartHour = firstSlot.startHour
        boardAutoplayStartMinute = firstSlot.startMinute
        boardAutoplayDurationMinutes = firstSlot.durationMinutes
        synchronizeLegacyBoardAutoplayEndTime()
    }

    private static var defaultBoardAutoplaySlots: [BoardAutoplaySlot] {
        [
            BoardAutoplaySlot(
                id: legacyBoardAutoplaySlotID,
                startHour: defaultBoardAutoplayStartHour,
                startMinute: defaultBoardAutoplayStartMinute,
                durationMinutes: defaultBoardAutoplayDurationMinutes
            )
        ]
    }

    private static func normalizeBoardAutoplaySlots(_ slots: [BoardAutoplaySlot]) -> [BoardAutoplaySlot] {
        slots
            .map {
                BoardAutoplaySlot(
                    id: $0.id,
                    startHour: $0.startHour,
                    startMinute: $0.startMinute,
                    durationMinutes: max(5, $0.durationMinutes),
                    isEnabled: $0.isEnabled
                )
            }
            .filter(\.isEnabled)
            .sorted {
                ($0.startHour, $0.startMinute, $0.durationMinutes, $0.id.uuidString)
                    < ($1.startHour, $1.startMinute, $1.durationMinutes, $1.id.uuidString)
            }
    }

    private static func decodeBoardAutoplaySlots(_ rawValue: String) -> [BoardAutoplaySlot] {
        guard let data = rawValue.data(using: .utf8),
              let slots = try? JSONDecoder().decode([BoardAutoplaySlot].self, from: data) else {
            return []
        }

        return normalizeBoardAutoplaySlots(slots)
    }

    private static func encodeBoardAutoplaySlots(_ slots: [BoardAutoplaySlot]) -> String {
        guard let data = try? JSONEncoder().encode(normalizeBoardAutoplaySlots(slots)),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return string
    }

    private enum ChinaHolidayCalendar {
        static let supportedYearsSummary = "2025、2026"

        private static let calendar = Calendar(identifier: .gregorian)
        private static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        // Official holiday dates from State Council General Office notices:
        // 2025: https://www.gov.cn/zhengce/content/202411/content_6986382.htm
        // 2026: https://www.gov.cn/zhengce/content/202510/content_7034453.htm
        private static let holidayDatesByYear: [Int: Set<String>] = [
            2025: [
                "2025-01-01",
                "2025-01-28", "2025-01-29", "2025-01-30", "2025-01-31",
                "2025-02-01", "2025-02-02", "2025-02-03", "2025-02-04",
                "2025-04-04", "2025-04-05", "2025-04-06",
                "2025-05-01", "2025-05-02", "2025-05-03", "2025-05-04", "2025-05-05",
                "2025-05-31", "2025-06-01", "2025-06-02",
                "2025-10-01", "2025-10-02", "2025-10-03", "2025-10-04",
                "2025-10-05", "2025-10-06", "2025-10-07", "2025-10-08"
            ],
            2026: [
                "2026-01-01", "2026-01-02", "2026-01-03",
                "2026-02-15", "2026-02-16", "2026-02-17", "2026-02-18",
                "2026-02-19", "2026-02-20", "2026-02-21", "2026-02-22", "2026-02-23",
                "2026-04-04", "2026-04-05", "2026-04-06",
                "2026-05-01", "2026-05-02", "2026-05-03", "2026-05-04", "2026-05-05",
                "2026-06-19", "2026-06-20", "2026-06-21",
                "2026-09-25", "2026-09-26", "2026-09-27",
                "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04",
                "2026-10-05", "2026-10-06", "2026-10-07"
            ]
        ]

        static func isHoliday(_ date: Date) -> Bool {
            guard let key = holidayKey(for: date),
                  let year = Int(key.prefix(4)) else {
                return false
            }

            return holidayDatesByYear[year]?.contains(key) ?? false
        }

        private static func holidayKey(for date: Date) -> String? {
            var components = calendar.dateComponents(in: timeZone, from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                return nil
            }

            components.timeZone = timeZone
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
    }
}
