import SwiftUI
import WidgetKit
import QuartzCore
import Foundation

#if DEBUG
enum DebugPerf {
    private static let defaultsKey = "DebugPerf.recentEvents.v1"
    private static let maxStoredEvents = 160
    private static let lock = NSLock()
    private static var memoryEntries: [String] = []

    private final class WatchdogState {
        private let lock = NSLock()
        private var didRunMainCallback = false

        func markMainCallbackDidRun() {
            lock.lock()
            didRunMainCallback = true
            lock.unlock()
        }

        func hasMainCallbackRun() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return didRunMainCallback
        }
    }

    static func mark(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        let timestamp = String(format: "%.3f", CACurrentMediaTime())
        let thread = Thread.isMainThread ? "main" : "background"
        let entry = "[DEBUG-PERF] \(timestamp) [\(thread)] \(message) @\(file):\(line)"
        NSLog("%@", entry)
        appendToMemory(entry)
    }

    static func replayPreviousRunTrace() {
        lock.lock()
        let entries = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        _ = UserDefaults.standard.synchronize()
        lock.unlock()

        guard !entries.isEmpty else { return }
        NSLog("[DEBUG-PERF] PREVIOUS RUN TRACE BEGIN count=%d", entries.count)
        entries.suffix(80).forEach { entry in
            NSLog("[DEBUG-PERF-PREV] %@", entry)
        }
        NSLog("[DEBUG-PERF] PREVIOUS RUN TRACE END")
    }

    static func recentEvents(limit: Int = 40) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let entries = memoryEntries
        guard limit > 0 else { return entries }
        return Array(entries.suffix(limit))
    }

    static func flushRecentEvents() {
        lock.lock()
        let entries = memoryEntries
        lock.unlock()
        persistSnapshot(entries)
    }

    static func clearRecentEvents() {
        lock.lock()
        defer { lock.unlock() }

        memoryEntries.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        _ = UserDefaults.standard.synchronize()
    }

    static func watchMainThread(_ label: String, threshold: TimeInterval = 0.8) {
        let startedAt = CACurrentMediaTime()
        let token = UUID()
        let state = WatchdogState()

        mark("WATCHDOG start \(label) token=\(token.uuidString)")

        DispatchQueue.main.asyncAfter(deadline: .now() + threshold) {
            state.markMainCallbackDidRun()
            let elapsed = CACurrentMediaTime() - startedAt
            mark("WATCHDOG main callback reached \(label) elapsed=\(String(format: "%.3fs", elapsed)) token=\(token.uuidString)")
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + threshold + 0.2) {
            if !state.hasMainCallbackRun() {
                let elapsed = CACurrentMediaTime() - startedAt
                mark("WATCHDOG POSSIBLE MAIN THREAD STALL \(label) elapsed=\(String(format: "%.3fs", elapsed)) token=\(token.uuidString)")
            }
        }
    }

    private static func appendToMemory(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }

        memoryEntries.append(entry)
        if memoryEntries.count > maxStoredEvents {
            memoryEntries.removeFirst(memoryEntries.count - maxStoredEvents)
        }
    }

    private static func persistSnapshot(_ entries: [String]) {
        let trimmedEntries: [String]
        if entries.count > maxStoredEvents {
            trimmedEntries = Array(entries.suffix(maxStoredEvents))
        } else {
            trimmedEntries = entries
        }

        UserDefaults.standard.set(trimmedEntries, forKey: defaultsKey)
        _ = UserDefaults.standard.synchronize()
    }
}
#endif

// MARK: - WidgetCenter Background Reload
// On iOS 17, WidgetCenter.shared.reloadAllTimelines() blocks the main thread
// for 1–3 seconds due to synchronous XPC. Always call via background task.
extension WidgetCenter {
    func reloadAllTimelinesInBackground() {
        Task.detached(priority: .background) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

extension View {
    @ViewBuilder
    func iOS17SafeSwipeActions<Actions: View>(
        edge: HorizontalEdge = .trailing,
        allowsFullSwipe: Bool = true,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        if #available(iOS 18.0, *) {
            swipeActions(edge: edge, allowsFullSwipe: allowsFullSwipe, content: actions)
        } else {
            self
        }
    }
}

extension ReviewItem {
    var stageBadgeText: String {
        if reviewTrack == .dictationFollowUp {
            guard dictationFollowUpStep > 0 else {
                return "听写跟进"
            }
            switch resolvedDictationFollowUpStep {
            case 1:
                return "第3天"
            case 2:
                return "第7天"
            default:
                return "听写跟进"
            }
        }

        if isDictationPass {
            return "听写跟进"
        }

        return stage.reviewStageDisplayText
    }

    var stageBadgeColor: Color {
        if reviewTrack == .dictationFollowUp {
            return resolvedDictationFollowUpStep == 2 ? .teal : .blue
        }

        if isDictationPass {
            return .blue
        }

        return stage.stageColor
    }

    var trackingSummaryText: String {
        if reviewTrack == .dictationFollowUp {
            guard dictationFollowUpStep > 0 else {
                return "听写通过后的跟进复习"
            }
            switch resolvedDictationFollowUpStep {
            case 1:
                return "听写通过后，第3天复习"
            case 2:
                return "听写通过后，第7天复习"
            default:
                return "听写通过后的跟进复习"
            }
        }

        if isDictationPass {
            return "听写通过后的跟进复习"
        }

        return stage.reviewStageDisplayText
    }

    func reviewTransitionDetail(
        result: ReviewResult,
        oldStage: Int,
        oldTrack: ReviewTrack,
        oldFollowUpStep: Int
    ) -> String {
        if oldTrack == .dictationFollowUp || reviewTrack == .dictationFollowUp {
            let oldLabel = Self.followUpLabel(for: oldTrack, step: oldFollowUpStep)
            let newLabel = Self.followUpLabel(for: reviewTrack, step: resolvedDictationFollowUpStep)

            if result == .correct {
                if oldTrack == .dictationFollowUp,
                   reviewTrack == .standard,
                   stage >= ReviewScheduler.completionStage,
                   nextReviewAt == .distantFuture {
                    return "已完成听写跟进，当前标记为已掌握"
                }
                if oldTrack == .dictationFollowUp,
                   reviewTrack == .standard,
                   stage >= ReviewScheduler.dictationFollowUpCompleteStage {
                    return "已完成听写跟进，已进入\(stage.reviewStageDisplayText)"
                }
                if !oldLabel.isEmpty && !newLabel.isEmpty {
                    return "已从\(oldLabel)进入\(newLabel)"
                }
                if !newLabel.isEmpty {
                    return "已安排到\(newLabel)"
                }
                return "已完成本轮听写跟进"
            }

            return "本次判错，已从第二天开始进入错题复习"
        }

        if result == .correct {
            if stage >= ReviewScheduler.completionStage && nextReviewAt == .distantFuture {
                return "已完成所有复习，当前标记为已掌握"
            }
            if oldStage == 0 && stage >= 2 {
                return "已通过首次复习，下一次会跳过明天再出现"
            }
            return "已从\(oldStage.reviewStageDisplayText)进入\(stage.reviewStageDisplayText)"
        }
        return "本次判错，已调整到\(stage.reviewStageDisplayText)"
    }

    private static func followUpLabel(for track: ReviewTrack, step: Int) -> String {
        guard track == .dictationFollowUp else { return "" }
        switch step {
        case 1:
            return "第3天复习"
        case 2:
            return "第7天复习"
        default:
            return "听写跟进"
        }
    }
}

extension ReviewRecord {
    var resultDisplayText: String {
        switch result {
        case .correct:
            return "正确"
        case .wrong:
            return "错误"
        }
    }

    var resultIconName: String {
        switch result {
        case .correct:
            return "checkmark.circle.fill"
        case .wrong:
            return "xmark.circle.fill"
        }
    }

    var resultColor: Color {
        switch result {
        case .correct:
            return .green
        case .wrong:
            return .red
        }
    }

    var modeDisplayText: String? {
        switch mode {
        case .scheduled:
            return nil
        case .retry:
            return "重试"
        case .dictation:
            return "听写"
        }
    }

    var stageTransitionText: String {
        if let cachedDetailText {
            switch cachedDetailText {
            case "已从第3天复习进入第7天复习":
                return "第3天复习 -> 第7天复习"
            case "已完成听写跟进，当前标记为已掌握",
                 "已完成本轮听写跟进":
                return "第7天复习 -> 已掌握"
            case "已完成听写跟进，已进入阶段 6",
                 "已完成听写跟进，已进入30天巩固":
                return "第7天复习 -> 30天巩固"
            case "已完成听写跟进，已进入阶段 7":
                return "第7天复习 -> 已掌握"
            case "已完成所有复习，当前标记为已掌握":
                return "阶段 \(ReviewScheduler.completionStage) -> 已掌握"
            case "本次判错，已从第二天开始进入错题复习":
                return "听写跟进 -> 阶段 1"
            default:
                break
            }
        }

        let oldLabel = Self.stageTransitionLabel(for: oldStage)
        let newLabel = Self.stageTransitionLabel(for: newStage)
        return "\(oldLabel) -> \(newLabel)"
    }

    var displayDetailText: String {
        if let cachedDetailText {
            if cachedDetailText == "已完成听写跟进，已进入阶段 6" {
                return "已完成听写跟进，已进入30天巩固"
            }
            return cachedDetailText
        }

        if result == .correct {
            if oldStage == 0 && newStage >= 2 {
                return "已通过首次复习，系统已更新下一次安排"
            }
            return "已完成本次复习，系统已更新后续安排"
        }

        return "本次判错，系统已重新安排后续复习"
    }

    var condensedDisplayDetailText: String? {
        let detail = displayDetailText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return nil }

        switch detail {
        case "已通过首次复习，系统已更新下一次安排",
             "已完成本次复习，系统已更新后续安排",
             "本次判错，系统已重新安排后续复习":
            return nil
        default:
            return detail
        }
    }

    var userVisibleNoteText: String? {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else { return nil }
        guard !trimmedNote.hasPrefix(Self.detailNotePrefix),
              !trimmedNote.hasPrefix(Self.confirmedDetailNotePrefix) else { return nil }
        return trimmedNote
    }

    static func storedDetailText(_ detail: String) -> String {
        detailNotePrefix + detail
    }

    static func storedConfirmedDetailText(_ detail: String) -> String {
        confirmedDetailNotePrefix + detail
    }

    private var cachedDetailText: String? {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        if trimmedNote.hasPrefix(Self.confirmedDetailNotePrefix) {
            prefix = Self.confirmedDetailNotePrefix
        } else if trimmedNote.hasPrefix(Self.detailNotePrefix) {
            prefix = Self.detailNotePrefix
        } else {
            return nil
        }

        let detail = String(trimmedNote.dropFirst(prefix.count))
        return detail.isEmpty ? nil : detail
    }

    private static func stageTransitionLabel(for stage: Int) -> String {
        stage.reviewStageDisplayText
    }
}

// MARK: - Result Button Style

struct ResultButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding()
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GradingChoiceButtonStyle: ButtonStyle {
    let color: Color
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? color : color.opacity(0.12))
            )
            .foregroundStyle(isSelected ? .white : color)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: - Stat Grid Card

struct StatGridCard: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.15), in: Circle())
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            ZStack {
                Color(uiColor: .secondarySystemGroupedBackground)
                tint.opacity(0.1)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(tint.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: tint.opacity(0.06), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Toast Overlay Modifier

struct ToastOverlay: ViewModifier {
    let message: String
    @Binding var isPresented: Bool
    var duration: Double = 1.2

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(message)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(.ultraThickMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 40)
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isPresented)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                            withAnimation {
                                isPresented = false
                            }
                        }
                    }
                }
            }
    }
}

extension View {
    func toast(_ message: String, isPresented: Binding<Bool>, duration: Double = 1.2) -> some View {
        modifier(ToastOverlay(message: message, isPresented: isPresented, duration: duration))
    }
}

// MARK: - Placeholder Text Editor

struct PlaceholderTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 220

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(uiColor: .secondarySystemBackground))

            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity)
                .frame(minHeight: minHeight)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)

            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Feedback Answer Overlay

struct AnswerFeedbackOverlay: View {
    let isCorrect: Bool
    @Binding var isVisible: Bool

    var body: some View {
        if isVisible {
            ZStack {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(isCorrect ? .green : .red)
                        .symbolEffect(.bounce, value: isVisible)

                    Text(isCorrect ? "答对了！" : "再加油！")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(isCorrect ? .green : .red)
                }
                .transition(.scale.combined(with: .opacity))
            }
            .onAppear {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(isCorrect ? .success : .error)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isVisible = false
                    }
                }
            }
        }
    }
}

// MARK: - Type Badge

struct TypeBadge: View {
    let type: ReviewItemType

    private var badgeColor: Color {
        switch type {
        case .chineseCharacter: return .orange
        case .phrase: return .blue
        case .englishWord: return .purple
        case .englishSentence: return .teal
        }
    }

    var body: some View {
        Text(type.displayName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor, in: Capsule())
    }
}

// MARK: - Stage Timeline

enum StageTimelineStepState {
    case completed
    case current
    case upcoming
}

struct StageTimelineStep: Identifiable {
    let id: String
    let title: String
    let state: StageTimelineStepState
}

struct StageTimelineView: View {
    let steps: [StageTimelineStep]
    let accentColor: Color

    private var currentStepID: String? {
        steps.first(where: { $0.state == .current })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        stageChip(for: step)
                            .id(step.id)

                        if index < steps.count - 1 {
                            connector(after: step)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                scrollCurrentStep(in: proxy, animated: false)
            }
            .onChange(of: currentStepID) {
                scrollCurrentStep(in: proxy, animated: true)
            }
        }
    }

    private func stageChip(for step: StageTimelineStep) -> some View {
        HStack(spacing: 6) {
            Text(step.title)
                .lineLimit(1)

            if step.state == .current {
                Text("当前")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.96), in: Capsule())
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(foregroundColor(for: step.state))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(backgroundColor(for: step.state), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(borderColor(for: step.state), lineWidth: step.state == .current ? 1.25 : 1)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private func connector(after step: StageTimelineStep) -> some View {
        Capsule()
            .fill(step.state == .upcoming ? Color.secondary.opacity(0.18) : accentColor.opacity(0.3))
            .frame(width: 12, height: 2)
    }

    private func foregroundColor(for state: StageTimelineStepState) -> Color {
        switch state {
        case .completed:
            return accentColor
        case .current:
            return .white
        case .upcoming:
            return .secondary
        }
    }

    private func backgroundColor(for state: StageTimelineStepState) -> Color {
        switch state {
        case .completed:
            return accentColor.opacity(0.12)
        case .current:
            return accentColor
        case .upcoming:
            return Color(uiColor: .secondarySystemBackground)
        }
    }

    private func borderColor(for state: StageTimelineStepState) -> Color {
        switch state {
        case .completed:
            return accentColor.opacity(0.24)
        case .current:
            return accentColor.opacity(0.92)
        case .upcoming:
            return .secondary.opacity(0.12)
        }
    }

    private func scrollCurrentStep(in proxy: ScrollViewProxy, animated: Bool) {
        guard let currentStepID else { return }

        DispatchQueue.main.async {
            let action = {
                proxy.scrollTo(currentStepID, anchor: .center)
            }

            if animated {
                withAnimation(.easeInOut(duration: 0.25)) {
                    action()
                }
            } else {
                action()
            }
        }
    }
}

// MARK: - Stage Color Helper

extension Int {
    var reviewStageDisplayText: String {
        self == ReviewScheduler.dictationFollowUpCompleteStage ? "30天巩固" : "阶段 \(self)"
    }

    var stageColor: Color {
        switch self {
        case 0...2: return .red
        case 3...5: return .orange
        default: return .green
        }
    }
}

extension ReviewItem {
    var stageTimelineSteps: [StageTimelineStep] {
        if isDictationFollowUp {
            let currentIndex = max(1, min(resolvedDictationFollowUpStep, 2))
            let titles = ["通过", "D3", "D7"]

            return titles.enumerated().map { index, title in
                StageTimelineStep(
                    id: "dictation-\(index)",
                    title: title,
                    state: timelineState(for: index, currentIndex: currentIndex)
                )
            }
        }

        let currentIndex = max(0, min(stage, ReviewScheduler.intervals.count - 1))

        return (0..<ReviewScheduler.intervals.count).map { index in
            StageTimelineStep(
                id: "stage-\(index)",
                title: "S\(index)",
                state: timelineState(for: index, currentIndex: currentIndex)
            )
        }
    }

    private func timelineState(for index: Int, currentIndex: Int) -> StageTimelineStepState {
        if index < currentIndex {
            return .completed
        }
        if index == currentIndex {
            return .current
        }
        return .upcoming
    }
}

enum ReviewItemTypeInference {
    static func infer(from text: String) -> ReviewItemType? {
        let sample = text
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let content = line
                    .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return content.isEmpty ? nil : content
            }
            .first

        guard let sample else { return nil }

        if sample.containsChineseCharacters {
            return .phrase
        }

        if sample.isLikelyEnglishContent {
            return .englishWord
        }

        return nil
    }
}

private extension String {
    var containsChineseCharacters: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    var isLikelyEnglishContent: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.containsChineseCharacters else { return false }

        let allowedPunctuation = CharacterSet(charactersIn: " -'")
        let allowedScalars = CharacterSet.decimalDigits
            .union(.letters)
            .union(allowedPunctuation)

        guard trimmed.unicodeScalars.allSatisfy({ allowedScalars.contains($0) && $0.isASCII }) else {
            return false
        }

        return trimmed.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) && scalar.isASCII
        }
    }
}

import AVFoundation

@MainActor
final class DictationSpeaker: NSObject, ObservableObject {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var lastUtteranceText = ""
    private var lastType: ReviewItemType = .chineseCharacter
    private var lastPrompt = ""
    private var pendingUtteranceCount = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepare(content: String, type: ReviewItemType, prompt: String = "") {
        lastUtteranceText = content
        lastType = type
        lastPrompt = prompt
        stop()
    }

    func speak(content: String, type: ReviewItemType, prompt: String = "") {
        lastUtteranceText = content
        lastType = type
        lastPrompt = prompt
        speakCurrentText()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        SpeechAudioSession.deactivate()
        pendingUtteranceCount = 0
        isSpeaking = false
    }

    private func speakCurrentText() {
        stop()
        let utterances = SpeechUtteranceBuilder.utterances(
            content: lastUtteranceText,
            type: lastType,
            prompt: lastPrompt
        )
        guard !utterances.isEmpty else { return }

        pendingUtteranceCount = utterances.count
        SpeechAudioSession.activate()
        utterances.forEach { synthesizer.speak($0) }
    }
}

extension DictationSpeaker: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        pendingUtteranceCount = max(pendingUtteranceCount - 1, 0)
        if pendingUtteranceCount == 0 {
            SpeechAudioSession.deactivate()
            isSpeaking = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        pendingUtteranceCount = 0
        SpeechAudioSession.deactivate()
        isSpeaking = false
    }
}

// A failed manual refresh must not silently look like a successful update.
extension View {
    func serverRefreshError(_ message: Binding<String?>) -> some View {
        alert("刷新未完成", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("知道了", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

struct ReviewEmptyStateView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentUnavailableView {
            Label("暂无待复习内容", systemImage: "checkmark.seal")
        } description: {
            Text("今天没有待复习的题目，或题目已在其他设备完成。返回首页可查看最新进度。")
        } actions: {
            Button("返回首页") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
