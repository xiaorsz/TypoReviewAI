import Foundation
import SwiftData

enum ReviewTrack: String, Codable {
    case standard
    case dictationFollowUp
}

@Model
final class ReviewItem {
    var id: UUID = UUID()
    var typeRawValue: String = ReviewItemType.chineseCharacter.rawValue
    var content: String = ""
    var prompt: String = ""
    var note: String = ""
    var source: String = ""
    var stage: Int = 0
    var nextReviewAt: Date = Date()
    var lastReviewedAt: Date?
    var consecutiveCorrectCount: Int = 0
    var consecutiveWrongCount: Int = 0
    var isPriority: Bool = false
    var reviewTrackRawValue: String = ReviewTrack.standard.rawValue
    var dictationFollowUpStep: Int = 0
    var isDictationPassRaw: Bool?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        type: ReviewItemType,
        content: String,
        prompt: String,
        note: String = "",
        source: String = "",
        stage: Int = 0,
        nextReviewAt: Date = .now,
        lastReviewedAt: Date? = nil,
        consecutiveCorrectCount: Int = 0,
        consecutiveWrongCount: Int = 0,
        isPriority: Bool = false,
        reviewTrack: ReviewTrack = .standard,
        dictationFollowUpStep: Int = 0,
        isDictationPass: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.typeRawValue = type.rawValue
        self.content = content
        self.prompt = prompt
        self.note = note
        self.source = source
        self.stage = stage
        self.nextReviewAt = nextReviewAt
        self.lastReviewedAt = lastReviewedAt
        self.consecutiveCorrectCount = consecutiveCorrectCount
        self.consecutiveWrongCount = consecutiveWrongCount
        self.isPriority = isPriority
        self.reviewTrackRawValue = reviewTrack.rawValue
        self.dictationFollowUpStep = dictationFollowUpStep
        self.isDictationPassRaw = isDictationPass
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var type: ReviewItemType {
        get { ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter }
        set { typeRawValue = newValue.rawValue }
    }

    var isDictationPass: Bool {
        get { isDictationPassRaw ?? false }
        set { isDictationPassRaw = newValue }
    }

    var reviewTrack: ReviewTrack {
        get {
            if let track = ReviewTrack(rawValue: reviewTrackRawValue) {
                if track == .standard, isDictationPass, dictationFollowUpStep == 0 {
                    return .dictationFollowUp
                }
                return track
            }
            return isDictationPass ? .dictationFollowUp : .standard
        }
        set { reviewTrackRawValue = newValue.rawValue }
    }

    var resolvedDictationFollowUpStep: Int {
        if reviewTrack == .dictationFollowUp {
            if (1...2).contains(dictationFollowUpStep) {
                return dictationFollowUpStep
            }
            return 1
        }

        if isDictationPass {
            return stage >= 5 ? 2 : 1
        }

        return 0
    }

    var isDictationFollowUp: Bool {
        reviewTrack == .dictationFollowUp || isDictationPass
    }
}

enum ReviewContentIdentity {
    static func displayContent(_ content: String) -> String {
        content
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func normalizedContent(_ content: String, type: ReviewItemType) -> String {
        displayContent(content).lowercased()
    }

    static func key(type: ReviewItemType, content: String) -> String {
        "\(type.rawValue)|\(normalizedContent(content, type: type))"
    }

    static func key(for item: ReviewItem) -> String {
        key(type: item.type, content: item.content)
    }

    static func isSameContent(_ item: ReviewItem, type: ReviewItemType, content: String) -> Bool {
        key(for: item) == key(type: type, content: content)
    }

    static func preferredReviewItem(from items: [ReviewItem]) -> ReviewItem? {
        items.max { lhs, rhs in
            isPreferred(rhs, over: lhs)
        }
    }

    static func canonicalReviewItems(from items: [ReviewItem]) -> [ReviewItem] {
        var canonicalByKey: [String: ReviewItem] = [:]

        for item in items {
            let itemKey = key(for: item)
            guard !itemKey.hasSuffix("|") else { continue }

            if let current = canonicalByKey[itemKey] {
                if isPreferred(item, over: current) {
                    canonicalByKey[itemKey] = item
                }
            } else {
                canonicalByKey[itemKey] = item
            }
        }

        return Array(canonicalByKey.values)
    }

    static func isPreferred(_ candidate: ReviewItem, over current: ReviewItem) -> Bool {
        let candidateFinished = candidate.nextReviewAt == .distantFuture
        let currentFinished = current.nextReviewAt == .distantFuture
        if candidateFinished != currentFinished {
            return candidateFinished
        }
        if candidate.stage != current.stage {
            return candidate.stage > current.stage
        }
        if candidate.consecutiveWrongCount != current.consecutiveWrongCount {
            return candidate.consecutiveWrongCount < current.consecutiveWrongCount
        }
        if candidate.nextReviewAt != current.nextReviewAt {
            return candidate.nextReviewAt > current.nextReviewAt
        }

        let candidateReviewedAt = candidate.lastReviewedAt ?? .distantPast
        let currentReviewedAt = current.lastReviewedAt ?? .distantPast
        if candidateReviewedAt != currentReviewedAt {
            return candidateReviewedAt > currentReviewedAt
        }
        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }
        return candidate.createdAt < current.createdAt
    }
}
