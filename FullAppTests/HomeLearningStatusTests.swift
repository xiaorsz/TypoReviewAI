import XCTest
import SwiftUI
@testable import CoachLab

final class HomeLearningStatusTests: XCTestCase {
    func testTaskStatusIncludesHistoricalPendingWork() {
        let status = HomeLearningStatusSupport.task(
            pendingCount: 3,
            historicalPendingCount: 2,
            completedTodayCount: 0
        )

        XCTAssertEqual(status.tone, .pending)
        XCTAssertEqual(status.text, "未完成")
        XCTAssertEqual(status.detail, "待3项 · 历2")
    }

    func testTaskStatusDistinguishesCompletedFromNotRequired() {
        let notRequired = HomeLearningStatusSupport.task(
            pendingCount: 0,
            historicalPendingCount: 0,
            completedTodayCount: 0
        )

        XCTAssertEqual(
            HomeLearningStatusSupport.task(
                pendingCount: 0,
                historicalPendingCount: 0,
                completedTodayCount: 2
            ).tone,
            .completed
        )
        XCTAssertEqual(
            notRequired,
            HomeLearningStatus(tone: .notRequired, text: "无任务", detail: "今日无需")
        )
    }

    func testReviewStatusUsesDailyPlanAsCompletionEvidence() {
        XCTAssertEqual(
            HomeLearningStatusSupport.review(pendingCount: 0, plannedCount: 5),
            HomeLearningStatus(tone: .completed, text: "已完成", detail: "完成5项")
        )
        XCTAssertEqual(
            HomeLearningStatusSupport.review(pendingCount: 0, plannedCount: 0),
            HomeLearningStatus(tone: .notRequired, text: "无复习", detail: "今日无需")
        )
    }

    func testSubmittedDictationRemainsPendingUntilReviewed() {
        let awaitingReview = HomeLearningStatusSupport.dictation(
            pendingSessionCount: 1,
            pendingEntryCount: 8,
            hasAwaitingReview: true,
            completedToday: false,
            reviewedEntryCount: 0
        )
        let reviewed = HomeLearningStatusSupport.dictation(
            pendingSessionCount: 0,
            pendingEntryCount: 0,
            hasAwaitingReview: false,
            completedToday: true,
            reviewedEntryCount: 8
        )

        XCTAssertEqual(awaitingReview.tone, .pending)
        XCTAssertEqual(awaitingReview.text, "待批改")
        XCTAssertEqual(reviewed.tone, .completed)
        XCTAssertEqual(reviewed.text, "已完成")

        XCTAssertEqual(
            HomeLearningStatusSupport.dictation(
                pendingSessionCount: 0,
                pendingEntryCount: 0,
                hasAwaitingReview: false,
                completedToday: false,
                reviewedEntryCount: 0
            ),
            HomeLearningStatus(tone: .notRequired, text: "无听写", detail: "今日无需")
        )
    }

    func testCalculationIsOnlyCompleteAfterPerfectRound() {
        let retrying = HomeLearningStatusSupport.calculation(
            completed: false,
            submittedRoundCount: 1
        )
        let completed = HomeLearningStatusSupport.calculation(
            completed: true,
            submittedRoundCount: 2
        )

        XCTAssertEqual(retrying.tone, .pending)
        XCTAssertEqual(retrying.detail, "第2轮补练")
        XCTAssertEqual(completed.tone, .completed)
        XCTAssertEqual(completed.detail, "共2轮")
    }
}

@MainActor
final class HomeReviewEmptyContentTests: XCTestCase {
    func testEmptyHomeReviewRendersContentForBothModes() {
        for style in [ReviewInteractionStyle.batch, .oneByOne] {
            let host = UIHostingController(rootView: HomeReviewSessionContent(items: [], style: style))
            let size = host.sizeThatFits(in: CGSize(width: 390, height: 844))
            XCTAssertGreaterThan(size.height, 100, "空题目应显示提示，不能返回空白视图")
        }
    }

    func testBatchReviewWithNoItemsDoesNotRenderBlankPage() {
        let host = UIHostingController(rootView: BatchReviewSessionView(items: []))
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 844))
        XCTAssertGreaterThan(size.height, 100, "其他入口传入空数组也应显示提示")
    }
}
