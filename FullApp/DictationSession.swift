import Foundation
import SwiftData

@Model
final class DictationSession {
    var id: UUID = UUID()
    var title: String = ""
    var typeRawValue: String = ReviewItemType.chineseCharacter.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var scheduledDate: Date = Date()
    var finishedAt: Date?
    var reviewedAt: Date?
    /// 听写进度：当前进行到的条目下标（0 表示未开始或已完成）。
    var currentEntryIndex: Int = 0

    init(
        id: UUID = UUID(),
        title: String,
        type: ReviewItemType,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        scheduledDate: Date = .now,
        finishedAt: Date? = nil,
        reviewedAt: Date? = nil,
        currentEntryIndex: Int = 0
    ) {
        self.id = id
        self.title = title
        self.typeRawValue = type.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.scheduledDate = scheduledDate
        self.finishedAt = finishedAt
        self.reviewedAt = reviewedAt
        self.currentEntryIndex = currentEntryIndex
    }

    var type: ReviewItemType {
        get { ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter }
        set { typeRawValue = newValue.rawValue }
    }

    var isFinished: Bool {
        finishedAt != nil
    }

    var isReviewed: Bool {
        reviewedAt != nil
    }
}
