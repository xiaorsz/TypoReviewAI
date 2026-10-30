import XCTest
import AVFoundation
@testable import CoachLab

@MainActor private final class LessonSpeechEngineStub: WordLessonSpeechEngine {
    weak var delegate: AVSpeechSynthesizerDelegate?
    var utterances: [AVSpeechUtterance] = []
    var pauses = 0, resumes = 0, stops = 0
    var acceptsPause = true, acceptsResume = true
    func speak(_ utterance: AVSpeechUtterance) { utterances.append(utterance) }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { stops += 1; return true }
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { pauses += 1; return acceptsPause }
    func continueSpeaking() -> Bool { resumes += 1; return acceptsResume }
}

@MainActor final class WordLessonSpeechTests: XCTestCase {
    private func controller(_ engine: LessonSpeechEngineStub) -> WordLessonSpeech {
        WordLessonSpeech(engine: engine, activate: {}, deactivate: {}, makeUtterance: { text, _ in AVSpeechUtterance(string: text) })
    }
    func testUsesChineseAndEnglishVoicesWithoutAppendingDictionaryMeaning() throws {
        XCTAssertEqual(WordLessonSpeechLanguage.forItem(type: "单词"), .english)
        XCTAssertEqual(WordLessonSpeechLanguage.forItem(type: "词语"), .chinese)
        let word = try XCTUnwrap(WordLessonSpeech.utterance(text: "Portugal", language: .english))
        XCTAssertEqual(word.speechString, "Portugal")
        XCTAssertTrue(word.voice?.language.hasPrefix("en") == true)
        let sentence = try XCTUnwrap(WordLessonSpeech.utterance(text: "Portugal is in Europe.", language: .english))
        XCTAssertEqual(sentence.speechString, "Portugal is in Europe.")
        XCTAssertTrue(sentence.voice?.language.hasPrefix("en") == true)
        let translation = try XCTUnwrap(WordLessonSpeech.utterance(text: "葡萄牙在欧洲。", language: .chinese))
        XCTAssertTrue(translation.voice?.language.hasPrefix("zh") == true)
    }
    func testSameButtonPausesAndResumesWithoutQueueingAnotherUtterance() {
        let engine = LessonSpeechEngineStub()
        let player = controller(engine)
        for _ in 0..<3 { player.toggle(key: "example", title: "例句", text: "A complete sentence.", language: .english) }
        XCTAssertEqual(engine.utterances.count, 1)
        XCTAssertEqual(engine.pauses, 1); XCTAssertEqual(engine.resumes, 1)
        XCTAssertEqual(player.phase, .speaking)
        player.stop(); XCTAssertEqual(player.phase, .idle); XCTAssertNil(player.activeKey)
    }
    func testSwitchingContentIgnoresLateCallbacksFromPreviousSegment() async throws {
        let engine = LessonSpeechEngineStub(), player = controller(engine)
        player.toggle(key: "word", title: "单词", text: "Portugal", language: .english)
        let old = try XCTUnwrap(engine.utterances.first)
        player.toggle(key: "example", title: "例句", text: "Portugal is in Europe.", language: .english)
        let current = try XCTUnwrap(engine.utterances.last)
        let sender = AVSpeechSynthesizer()
        player.speechSynthesizer(sender, didCancel: old)
        player.speechSynthesizer(sender, didFinish: old)
        await Task.yield()
        XCTAssertEqual(player.activeKey, "example"); XCTAssertEqual(player.phase, .speaking)
        player.speechSynthesizer(sender, didFinish: current)
        for _ in 0..<20 where player.phase != .idle { await Task.yield() }
        XCTAssertEqual(player.phase, .idle); XCTAssertNil(player.activeKey)
    }
    func testStopReleasesAudioOnceAndCannotBeReactivatedByLateFinish() throws {
        let engine = LessonSpeechEngineStub()
        var activations = 0, deactivations = 0
        let player = WordLessonSpeech(engine: engine, activate: { activations += 1 }, deactivate: { deactivations += 1 },
            makeUtterance: { text, _ in AVSpeechUtterance(string: text) })
        player.toggle(key: "word", title: "词语", text: "辨别", language: .chinese)
        let old = try XCTUnwrap(engine.utterances.first)
        player.stop(); player.stop()
        player.speechSynthesizer(AVSpeechSynthesizer(), didFinish: old)
        XCTAssertEqual(activations, 1); XCTAssertEqual(deactivations, 1)
        XCTAssertEqual(player.phase, .idle); XCTAssertNil(player.activeKey)
    }
    func testEmptyOrUnavailableVoiceDoesNotStartAudio() {
        let engine = LessonSpeechEngineStub()
        var activations = 0
        let player = WordLessonSpeech(engine: engine, activate: { activations += 1 }, deactivate: {}, makeUtterance: { _, _ in nil })
        player.toggle(key: "empty", title: "例句", text: " \n ", language: .chinese)
        XCTAssertNil(player.error)
        player.toggle(key: "word", title: "单词", text: "Portugal", language: .english)
        XCTAssertNotNil(player.error); XCTAssertTrue(engine.utterances.isEmpty)
        XCTAssertEqual(activations, 0); XCTAssertEqual(player.phase, .idle)
    }
    func testRejectedPauseDoesNotLeaveButtonStuckSpeaking() {
        let engine = LessonSpeechEngineStub(); engine.acceptsPause = false
        let player = controller(engine)
        player.toggle(key: "word", title: "单词", text: "Portugal", language: .english)
        player.toggle(key: "word", title: "单词", text: "Portugal", language: .english)
        XCTAssertEqual(player.phase, .idle); XCTAssertNil(player.activeKey)
    }
}
