import Foundation
import SwiftData

@Model
final class DictationEntry {
    var id: UUID = UUID()
    var sessionID: UUID = UUID()
    var sortOrder: Int = 0
    var typeRawValue: String = ReviewItemType.chineseCharacter.rawValue
    var content: String = ""
    var prompt: String = ""
    var note: String = ""
    var source: String = ""
    var resultRawValue: String = DictationResult.pending.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        sortOrder: Int,
        type: ReviewItemType,
        content: String,
        prompt: String = "",
        note: String = "",
        source: String = "",
        result: DictationResult = .pending,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sortOrder = sortOrder
        self.typeRawValue = type.rawValue
        self.content = content
        self.prompt = prompt
        self.note = note
        self.source = source
        self.resultRawValue = result.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var type: ReviewItemType {
        get { ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter }
        set { typeRawValue = newValue.rawValue }
    }

    var result: DictationResult {
        get { DictationResult(rawValue: resultRawValue) ?? .pending }
        set { resultRawValue = newValue.rawValue }
    }
}
