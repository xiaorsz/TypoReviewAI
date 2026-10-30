import AVFoundation
import Combine

enum WordLessonSpeechLanguage: Equatable {
    case chinese, english
    static func forItem(type: String) -> Self {
        ReviewItemType(rawValue: type)?.isEnglish == true ? .english : .chinese
    }
    var voiceType: ReviewItemType { self == .english ? .englishSentence : .phrase }
    var rate: Float { self == .english ? 0.42 : 0.36 }
}

@MainActor
protocol WordLessonSpeechEngine: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func continueSpeaking() -> Bool
}

extension AVSpeechSynthesizer: WordLessonSpeechEngine {}

/// One visible segment at a time. Identity checks reject late finish/cancel events.
@MainActor
final class WordLessonSpeech: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    enum Phase: Equatable { case idle, speaking, paused }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeKey: String?
    @Published private(set) var title = ""
    @Published private(set) var error: String?
    private var currentUtterance: AVSpeechUtterance?
    private let engine: any WordLessonSpeechEngine
    private let activate: () -> Void
    private let deactivate: () -> Void
    private let makeUtterance: (String, WordLessonSpeechLanguage) -> AVSpeechUtterance?

    init(engine: (any WordLessonSpeechEngine)? = nil,
         activate: (() -> Void)? = nil,
         deactivate: (() -> Void)? = nil,
         makeUtterance: ((String, WordLessonSpeechLanguage) -> AVSpeechUtterance?)? = nil) {
        self.engine = engine ?? AVSpeechSynthesizer()
        self.activate = activate ?? { SpeechAudioSession.activate() }
        self.deactivate = deactivate ?? { SpeechAudioSession.deactivate() }
        self.makeUtterance = makeUtterance ?? Self.utterance
        super.init(); self.engine.delegate = self
    }

    static func utterance(text: String, language: WordLessonSpeechLanguage) -> AVSpeechUtterance? {
        guard let voice = SpeechVoicePicker.voice(for: language.voiceType) else { return nil }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = language.rate; utterance.pitchMultiplier = 1
        return utterance
    }

    func toggle(key: String, title: String, text: String, language: WordLessonSpeechLanguage) {
        if activeKey == key, phase == .speaking {
            if engine.pauseSpeaking(at: .immediate) { phase = .paused } else { stop() }
            return
        }
        if activeKey == key, phase == .paused {
            if engine.continueSpeaking() { phase = .speaking } else { stop() }
            return
        }
        stop()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let utterance = makeUtterance(text, language) else {
            error = "系统语音暂不可用，请稍后重试。"; return
        }
        currentUtterance = utterance; activeKey = key; self.title = title; phase = .speaking
        activate(); engine.speak(utterance)
    }

    func stop() {
        let hadAudio = currentUtterance != nil
        currentUtterance = nil; activeKey = nil; phase = .idle; title = ""; error = nil
        engine.stopSpeaking(at: .immediate)
        if hadAudio { deactivate() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finish(utterance) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finish(utterance) }
    }
    private func finish(_ utterance: AVSpeechUtterance) {
        guard currentUtterance === utterance else { return }
        currentUtterance = nil; activeKey = nil; phase = .idle; title = ""; deactivate()
    }
}
