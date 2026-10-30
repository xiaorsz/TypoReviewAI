import XCTest
import UIKit
@testable import CoachLab

@MainActor
final class AutoDictationTests: XCTestCase {
    private final class Playback: DictationPlayback {
        var calls: [(String, (Bool) -> Void)] = []
        func play(content: String, type: ReviewItemType, prompt: String, completion: @escaping (Bool) -> Void) {
            calls.append((content, completion))
        }
        func stop() {}
        func finish(_ index: Int? = nil, success: Bool = true) {
            calls[index ?? calls.count - 1].1(success)
        }
    }

    private func fixture(last: Bool = false) -> (AutoDictationController, Playback, UserDefaults) {
        let playback = Playback()
        let defaults = UserDefaults(suiteName: "AutoDictationTests.\(UUID())")!
        let controller = AutoDictationController(playback: playback, defaults: defaults, runsTimer: false)
        controller.select(content: "apple", type: .englishWord, prompt: "苹果", isLast: last, speak: false)
        addTeardownBlock { @MainActor in
            controller.shutdown()
            defaults.removeObject(forKey: "autoDictation.writingInterval")
        }
        return (controller, playback, defaults)
    }

    private func finishBothReadings(_ controller: AutoDictationController, _ playback: Playback) {
        playback.finish()
        controller.advanceWaitingSecond()
        controller.advanceWaitingSecond()
        playback.finish()
    }

    func testTwoCompleteReadingsBeforeThreeSecondCountdownAndSingleAdvance() {
        let (controller, playback, _) = fixture()
        var advances = 0
        controller.onAdvance = { advances += 1 }
        controller.setEnabled(true)
        XCTAssertEqual(controller.phase, .speaking(1))
        controller.advanceWaitingSecond()
        XCTAssertEqual(controller.phase, .speaking(1))
        playback.finish()
        XCTAssertEqual(controller.phase, .repeatGap(2))
        controller.advanceWaitingSecond()
        XCTAssertEqual(playback.calls.count, 1)
        controller.advanceWaitingSecond()
        XCTAssertEqual(controller.phase, .speaking(2))
        playback.finish()
        XCTAssertEqual(controller.phase, .writing(3))
        controller.advanceWaitingSecond()
        controller.advanceWaitingSecond()
        XCTAssertEqual(advances, 0)
        controller.advanceWaitingSecond()
        controller.advanceWaitingSecond()
        XCTAssertEqual(advances, 1)
        controller.select(content: "下一条", type: .phrase, prompt: "", isLast: true)
        XCTAssertEqual(controller.phase, .speaking(1))
        XCTAssertEqual(playback.calls.last?.0, "下一条")
    }

    func testReplayAndRapidSelectionIgnoreOldCompletions() {
        let (controller, playback, _) = fixture()
        controller.setEnabled(true)
        controller.replay()
        playback.finish(0)
        XCTAssertEqual(controller.phase, .speaking(1))
        controller.select(content: "新内容", type: .phrase, prompt: "", isLast: false)
        playback.finish(1)
        XCTAssertEqual(controller.phase, .speaking(1))
        playback.finish(2)
        XCTAssertEqual(controller.phase, .repeatGap(2))
        playback.finish(2)
        XCTAssertEqual(controller.phase, .repeatGap(2))
    }

    func testPauseDuringSpeechAndPausedNavigationRemainPaused() {
        let (controller, playback, _) = fixture()
        controller.setEnabled(true)
        controller.pause()
        playback.finish(0)
        XCTAssertEqual(controller.phase, .paused)
        controller.select(content: "上一条", type: .phrase, prompt: "", isLast: false)
        playback.finish()
        controller.advanceWaitingSecond()
        XCTAssertEqual(controller.phase, .paused)
        controller.start()
        XCTAssertEqual(controller.phase, .speaking(1))
    }

    func testPauseDuringCountdownRestartsBothReadings() {
        let (controller, playback, _) = fixture()
        controller.setEnabled(true)
        finishBothReadings(controller, playback)
        controller.pause()
        controller.advanceWaitingSecond()
        XCTAssertEqual(controller.phase, .paused)
        controller.start()
        XCTAssertEqual(controller.phase, .speaking(1))
    }

    func testIntervalChangesResetWritingTimeAndPersist() {
        let (controller, playback, defaults) = fixture()
        XCTAssertEqual(controller.interval, 3)
        controller.setEnabled(true)
        finishBothReadings(controller, playback)
        controller.advanceWaitingSecond()
        controller.setInterval(8)
        XCTAssertEqual(controller.phase, .writing(8))
        let other = AutoDictationController(playback: Playback(), defaults: defaults, runsTimer: false)
        XCTAssertEqual(other.interval, 8)
        controller.setInterval(30)
        XCTAssertEqual(controller.interval, 8)
    }

    func testLastItemEndsWithoutAdvancingAndRestoresScreenSetting() {
        let (controller, playback, _) = fixture(last: true)
        let original = UIApplication.shared.isIdleTimerDisabled
        var advances = 0
        controller.onAdvance = { advances += 1 }
        controller.setEnabled(true)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        finishBothReadings(controller, playback)
        for _ in 0..<4 { controller.advanceWaitingSecond() }
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertEqual(advances, 0)
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, original)
    }

    func testFailurePausesAndShutdownInvalidatesCallbacks() {
        let (controller, playback, _) = fixture()
        controller.setEnabled(true)
        playback.finish(success: false)
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertNotNil(controller.errorMessage)
        controller.start()
        XCTAssertNil(controller.errorMessage)
        controller.shutdown()
        playback.finish()
        controller.advanceWaitingSecond()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isEnabled)
    }

    func testEmptySessionDoesNotStartPlayback() {
        let playback = Playback()
        let controller = AutoDictationController(playback: playback, runsTimer: false)
        controller.setEnabled(true)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(playback.calls.isEmpty)
        controller.shutdown()
    }
}


@MainActor
final class EnglishRecitationTests: XCTestCase {
    func testRecitationSurvivesSessionEntryAndReviewBackupRoundTrip() throws {
        let session = DictationSession(title: "Unit 3 句子", type: .englishSentence, currentEntryIndex: 1)
        let entry = DictationEntry(
            sessionID: session.id, sortOrder: 0, type: .englishSentence,
            content: "What would you like to eat?", prompt: "你想吃什么？", result: .correct
        )
        let item = ReviewItem(type: entry.type, content: entry.content, prompt: entry.prompt)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let restoredSession = try decoder.decode(
            DictationSessionSnapshot.self, from: encoder.encode(DictationSessionSnapshot(session))
        ).makeModel()
        let restoredEntry = try decoder.decode(
            DictationEntrySnapshot.self, from: encoder.encode(DictationEntrySnapshot(entry))
        ).makeModel()
        let restoredItem = try decoder.decode(
            ReviewItemSnapshot.self, from: encoder.encode(ReviewItemSnapshot(item))
        ).makeModel()

        XCTAssertEqual(restoredSession.type, .englishSentence)
        XCTAssertEqual(restoredSession.currentEntryIndex, 1)
        XCTAssertEqual(restoredEntry.type, .englishSentence)
        XCTAssertEqual(restoredEntry.result, .correct)
        XCTAssertEqual(restoredItem.type, .englishSentence)
        XCTAssertEqual(restoredItem.content, entry.content)
        XCTAssertFalse(ReviewContentIdentity.isSameContent(
            restoredItem, type: .englishWord, content: entry.content
        ))
    }

    func testRecitationUsesExistingFollowUpAndFailureSchedule() {
        let scheduler = ReviewScheduler()
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let item = ReviewItem(
            type: .englishSentence, content: "I'd like a sandwich.", prompt: "我想要一个三明治。",
            stage: 1, nextReviewAt: now, reviewTrack: .dictationFollowUp,
            dictationFollowUpStep: 1, isDictationPass: true
        )

        let correct = scheduler.handle(item: item, result: .correct, now: now)
        XCTAssertEqual(correct.record.result, .correct)
        XCTAssertEqual(item.dictationFollowUpStep, 2)
        XCTAssertEqual(item.nextReviewAt, scheduler.dayStart(after: 4, from: now))

        let nextDate = item.nextReviewAt
        let wrong = scheduler.handle(item: item, result: .wrong, now: nextDate)
        XCTAssertEqual(wrong.record.result, .wrong)
        XCTAssertEqual(item.reviewTrack, .standard)
        XCTAssertEqual(item.nextReviewAt, scheduler.nextDayStart(from: nextDate))
        XCTAssertEqual(item.type, .englishSentence)
    }

    func testRecitationReadsEnglishSentenceWithoutReadingTranslationAsAnswer() {
        let utterances = SpeechUtteranceBuilder.utterances(
            content: "I'd like a sandwich.", type: .englishSentence, prompt: "我想要一个三明治。"
        )
        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances.first?.speechString, "I'd like a sandwich.")
        XCTAssertTrue(utterances.first?.voice?.language.hasPrefix("en") == true)
    }
}
