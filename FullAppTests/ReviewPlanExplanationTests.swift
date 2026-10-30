import XCTest
@testable import CoachLab

final class ReviewPlanExplanationTests: XCTestCase {
    func testOldPagingFailureIsFlaggedWithoutInventingAnAlternativeReasonOrTips() {
        let raw = "本次判定的7个错题 ID不在已查询题库分页中，无法补练。改为其他题。提示：注意ou。"
        let value = ReviewPlanExplanation(raw)
        XCTAssertTrue(value.needsRecheck)
        XCTAssertTrue(value.reason.contains("依据不完整"))
        XCTAssertFalse(value.summary.contains("分页"))
        XCTAssertFalse(value.reason.contains("其他题"))
        XCTAssertTrue(value.tips.isEmpty)
        XCTAssertTrue(raw.contains("分页")) // Presentation leaves persisted text untouched.
    }
    func testRealReasonAndEnglishSpellingHintsRemainSeparateAndUnchanged() {
        let value = ReviewPlanExplanation("优先安排明天到期、连续错误较多的内容。提示：moustache注意ou；direction注意-tion；Portugal注意大写与u。")
        XCTAssertFalse(value.needsRecheck)
        XCTAssertEqual(value.reason, "优先安排明天到期、连续错误较多的内容。")
        XCTAssertEqual(value.tips, ["moustache注意ou", "direction注意-tion", "Portugal注意大写与u。"])
    }
    func testEnglishPunctuationAndTechnicalSubstringWithinWordsAreNotRewritten() {
        let value = ReviewPlanExplanation("复习 direction、pyramid 和 Chemist's。")
        XCTAssertFalse(value.needsRecheck)
        XCTAssertEqual(value.summary, "复习 direction、pyramid 和 Chemist's。")
    }
    func testMissingReasonDoesNotClaimModelAnalysis() {
        let value = ReviewPlanExplanation(" \n")
        XCTAssertTrue(value.summary.contains("暂未提供"))
        XCTAssertTrue(value.tips.isEmpty)
    }
}
