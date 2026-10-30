import Foundation

/// Value-type adaptation of the original ReviewScheduler.handle logic. No shared stores or imports.
public enum ReviewScheduler {
    private static let intervals = [0, 1, 2, 4, 7, 15, 30]
    public static func apply(correct: Bool, to item: inout ReviewItem, now: Date, calendar: Calendar = .current) -> ReviewRecord {
        let oldStage = item.stage
        func after(_ days: Int) -> Date {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: now)!)
        }
        if item.reviewTrackRawValue == "dictationFollowUp" || item.isDictationPassRaw == true {
            let step = item.dictationFollowUpStep.flatMap { (1...2).contains($0) ? $0 : nil } ?? (item.stage >= 5 ? 2 : 1)
            if correct {
                item.consecutiveCorrectCount += 1; item.consecutiveWrongCount = 0; item.isPriority = false
                if step == 1 {
                    item.reviewTrackRawValue = "dictationFollowUp"; item.dictationFollowUpStep = 2
                    item.isDictationPassRaw = true; item.stage = max(item.stage, 2); item.nextReviewAt = after(4)
                } else {
                    item.stage = max(item.stage, 6); item.reviewTrackRawValue = "standard"
                    item.dictationFollowUpStep = 0; item.isDictationPassRaw = false
                    item.nextReviewAt = after(intervals[min(item.stage, 6)])
                }
            } else {
                item.reviewTrackRawValue = "standard"; item.dictationFollowUpStep = 0; item.isDictationPassRaw = false
                item.consecutiveCorrectCount = 0; item.consecutiveWrongCount += 1
                item.stage = 1; item.nextReviewAt = after(1); item.isPriority = true
            }
        } else if correct {
            item.consecutiveCorrectCount += 1; item.consecutiveWrongCount = 0; item.isPriority = false
            item.stage = item.stage <= 0 ? 2 : min(7, item.stage + 1)
            item.nextReviewAt = item.stage >= 7 ? .distantFuture : after(intervals[item.stage])
        } else {
            item.consecutiveCorrectCount = 0; item.consecutiveWrongCount += 1
            item.stage = max(1, item.stage - 1); item.nextReviewAt = after(intervals[min(item.stage, 6)])
            item.isPriority = item.consecutiveWrongCount >= 2
        }
        item.lastReviewedAt = now; item.updatedAt = now
        return ReviewRecord(itemID: item.id, correct: correct, oldStage: oldStage, newStage: item.stage, now: now)
    }
}
