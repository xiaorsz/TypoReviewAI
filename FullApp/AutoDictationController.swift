import SwiftUI
import AVFoundation

@MainActor
protocol DictationPlayback: AnyObject {
    func play(content: String, type: ReviewItemType, prompt: String, completion: @escaping (Bool) -> Void)
    func stop()
}

/// Utterance identity keeps callbacks from cancelled batches out of the current batch.
@MainActor
final class DictationPlaybackDriver: NSObject, DictationPlayback, @preconcurrency AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending = Set<ObjectIdentifier>()
    private var completion: ((Bool) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(content: String, type: ReviewItemType, prompt: String, completion: @escaping (Bool) -> Void) {
        stop()
        let utterances = SpeechUtteranceBuilder.utterances(content: content, type: type, prompt: prompt)
        guard !utterances.isEmpty else { completion(false); return }
        self.completion = completion
        pending = Set(utterances.map(ObjectIdentifier.init))
        SpeechAudioSession.activate()
        utterances.forEach { synthesizer.speak($0) }
    }

    func stop() {
        pending.removeAll()
        completion = nil
        synthesizer.stopSpeaking(at: .immediate)
        SpeechAudioSession.deactivate()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard pending.remove(ObjectIdentifier(utterance)) != nil, pending.isEmpty else { return }
        let callback = completion
        completion = nil
        SpeechAudioSession.deactivate()
        callback?(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard pending.contains(ObjectIdentifier(utterance)) else { return }
        let callback = completion
        stop()
        callback?(false)
    }
}

@MainActor
final class AutoDictationController: ObservableObject {
    enum Phase: Equatable {
        case idle, speaking(Int), repeatGap(Int), writing(Int), advancing, paused, finished
    }

    static let intervals = [2, 3, 5, 8, 10]
    private static let intervalKey = "autoDictation.writingInterval"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isEnabled = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var interval: Int
    var onAdvance: (() -> Void)?

    private let playback: DictationPlayback
    private let defaults: UserDefaults
    private let runsTimer: Bool
    private var timer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var content: (String, ReviewItemType, String)?
    private var isLast = false
    private var previousIdleTimer: Bool?

    init(playback: DictationPlayback? = nil, defaults: UserDefaults = .standard, runsTimer: Bool = true) {
        self.playback = playback ?? DictationPlaybackDriver()
        self.defaults = defaults
        self.runsTimer = runsTimer
        let saved = defaults.integer(forKey: Self.intervalKey)
        interval = Self.intervals.contains(saved) ? saved : 3
    }

    var isRunning: Bool {
        switch phase {
        case .speaking, .repeatGap, .writing, .advancing: return isEnabled
        default: return false
        }
    }

    var status: String {
        if let errorMessage { return errorMessage }
        switch phase {
        case .idle: return "每条读两遍，读完后等待 \(interval) 秒"
        case .speaking(let number): return "正在读第 \(number)/2 遍"
        case .repeatGap: return "稍等，准备再读一遍"
        case .writing(let seconds): return isLast ? "还有 \(seconds) 秒结束听写" : "还有 \(seconds) 秒进入下一条"
        case .advancing: return "正在进入下一条"
        case .paused: return "已暂停，继续时会重新朗读当前条"
        case .finished: return "听写结束，可以判卷"
        }
    }

    func select(content: String, type: ReviewItemType, prompt: String, isLast: Bool, speak: Bool = true) {
        let continueAutomatically = isRunning
        cancelPlayback()
        self.content = (content, type, prompt)
        self.isLast = isLast
        errorMessage = nil
        if continueAutomatically { start() }
        else {
            phase = isEnabled ? .paused : .idle
            if speak { play(number: nil) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled { start() }
        else { cancelPlayback(); phase = .idle; restoreIdleTimer() }
    }

    func start() {
        guard isEnabled, content != nil else { return }
        cancelPlayback()
        errorMessage = nil
        if previousIdleTimer == nil {
            previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = true
        play(number: 1)
    }

    func replay() {
        errorMessage = nil
        if isRunning { start() }
        else { cancelPlayback(); play(number: nil) }
    }

    func pause() {
        cancelPlayback()
        if isEnabled { phase = .paused }
        restoreIdleTimer()
    }

    func shutdown() {
        setEnabled(false)
        onAdvance = nil
    }

    func setInterval(_ value: Int) {
        guard Self.intervals.contains(value) else { return }
        interval = value
        defaults.set(value, forKey: Self.intervalKey)
        if case .writing = phase {
            phase = .writing(value)
            scheduleTick()
        }
    }

    private func cancelPlayback() {
        generation = UUID()
        timer?.cancel()
        timer = nil
        watchdog?.cancel()
        watchdog = nil
        playback.stop()
        isSpeaking = false
    }

    private func play(number: Int?) {
        guard let content else { return }
        let token = UUID()
        generation = token
        isSpeaking = true
        if let number { phase = .speaking(number) }
        // A missing speech completion must never silently advance to the next item.
        if runsTimer {
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(180)) } catch { return }
                guard let self, self.generation == token else { return }
                self.pause()
                self.errorMessage = "朗读未完成，请重试"
            }
        }
        playback.play(content: content.0, type: content.1, prompt: content.2) { [weak self] success in
            guard let self, self.generation == token else { return }
            self.generation = UUID()
            self.watchdog?.cancel()
            self.isSpeaking = false
            guard success else {
                self.pause()
                self.errorMessage = "朗读未完成，请重试"
                return
            }
            guard let number, self.isEnabled else { return }
            self.phase = number == 1 ? .repeatGap(2) : .writing(self.interval)
            self.scheduleTick()
        }
    }

    private func scheduleTick() {
        timer?.cancel()
        guard runsTimer else { return }
        let token = generation
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.generation == token else { return }
            self.advanceWaitingSecond()
        }
    }

    /// Also serves as a deterministic clock seam for lifecycle/race tests.
    func advanceWaitingSecond() {
        switch phase {
        case .repeatGap(let seconds):
            if seconds > 1 { phase = .repeatGap(seconds - 1); scheduleTick() }
            else { play(number: 2) }
        case .writing(let seconds):
            if seconds > 1 { phase = .writing(seconds - 1); scheduleTick() }
            else if isLast {
                phase = .finished
                restoreIdleTimer()
            } else {
                // Wait for the view's index change to select and play the new item.
                timer?.cancel()
                phase = .advancing
                onAdvance?()
            }
        default: break
        }
    }

    private func restoreIdleTimer() {
        if let previousIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
            self.previousIdleTimer = nil
        }
    }
}

struct AutoDictationControls: View {
    @ObservedObject var controller: AutoDictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("自动听写", isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) }))
            if controller.isEnabled {
                HStack {
                    Text("书写等待")
                    Spacer()
                    Picker("书写等待", selection: Binding(get: { controller.interval }, set: { controller.setInterval($0) })) {
                        ForEach(AutoDictationController.intervals, id: \.self) { seconds in
                            Text("\(seconds) 秒").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text(controller.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.phase != .finished {
                        Button(controller.isRunning ? "暂停" : "继续") {
                            if controller.isRunning { controller.pause() }
                            else { controller.start() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}
