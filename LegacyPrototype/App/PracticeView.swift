import SwiftUI
import AVFoundation
import CoachCore

@MainActor final class DictationSpeech: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var pending = Set<ObjectIdentifier>()
    private var completion: (() -> Void)?
    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ entry: DictationEntry, completion: @escaping () -> Void) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        self.completion = completion; isSpeaking = true
        for index in 0..<2 {
            let utterance = AVSpeechUtterance(string: entry.content)
            utterance.voice = AVSpeechSynthesisVoice(language: entry.typeRawValue == "单词" ? "en-US" : "zh-CN")
            utterance.rate = 0.42; utterance.postUtteranceDelay = index == 0 ? 0.8 : 0
            pending.insert(ObjectIdentifier(utterance)); synthesizer.speak(utterance)
        }
    }
    func stop() {
        completion = nil; pending.removeAll(); synthesizer.stopSpeaking(at: .immediate); isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard pending.remove(ObjectIdentifier(utterance)) != nil, pending.isEmpty else { return }
        isSpeaking = false
        let callback = completion; completion = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        callback?()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard pending.contains(ObjectIdentifier(utterance)) else { return }; stop()
    }
}

struct PracticeView: View {
    @Environment(LabStore.self) private var store
    @Environment(CoachAgent.self) private var agent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let sessionID: UUID
    @StateObject private var speech = DictationSpeech()
    @State private var showGrading = false
    @State private var auto = false
    @State private var remaining = 0
    @State private var countdown: Task<Void, Never>?
    @State private var error: String?
    private var session: DictationSession? { store.state.sessions.first { $0.id == sessionID } }
    private var entries: [DictationEntry] { store.entries(for: sessionID) }
    private var index: Int { session?.currentEntryIndex ?? 0 }
    var body: some View {
        Group {
            if session?.reviewedAt != nil { resultView }
            else if showGrading || index >= entries.count { gradingView }
            else { dictationView }
        }
        .navigationTitle(session?.title ?? "听写练习").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后继续") { stop(); dismiss() } } }
        .onDisappear { stop() }
        .onChange(of: phase) { _, phase in if phase != .active { stop() } }
        .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(error ?? "") }
    }
    private var dictationView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("第 \(index + 1) / \(entries.count) 题").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ProgressView(value: Double(index), total: Double(max(1, entries.count)))
                Image(systemName: speech.isSpeaking ? "waveform" : "pencil.and.outline").font(.system(size: 62)).foregroundStyle(.indigo).frame(height: 110)
                Text(speech.isSpeaking ? "认真听，写在纸上" : remaining > 0 ? "留 \(remaining) 秒，慢慢写" : "准备好纸笔了吗？")
                    .font(.title2.bold())
                Text("每题朗读两遍。练完后由家长对照答案判定。") .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { stop(); readCurrent() } label: { Label("朗读／重读这一题", systemImage: "speaker.wave.2.fill").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.borderedProminent)
                Button(auto ? "暂停自动听写" : "自动听写（每题留 5 秒书写）") {
                    if auto { stop() } else { auto = true; readCurrent() }
                }.buttonStyle(.bordered)
                Button(index + 1 == entries.count ? "写好了，进入家长判定" : "写好了，下一题") { stop(); advance() }
                    .padding(.top, 12)
                Button("直接进入家长判定") { stop(); showGrading = true }.font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemGroupedBackground))
    }
    private var gradingView: some View {
        List {
            Section { Text("请家长对照纸上书写，逐项确认对错。选择会保存，稍后可以继续。") .font(.subheadline).foregroundStyle(.secondary) }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.content).font(.title3.bold())
                    if !entry.prompt.isEmpty { Text(entry.prompt).font(.subheadline).foregroundStyle(.secondary) }
                    HStack {
                        gradeButton(entry, correct: true)
                        gradeButton(entry, correct: false)
                    }
                }.padding(.vertical, 8)
            }
            Section {
                Button("提交判定并调整后续练习") {
                    stop()
                    do {
                        _ = try store.submit(sessionID)
                        if store.state.configuration.isEnabled { agent.start(apiKey: (try? LabKeychain.load()) ?? "") }
                    } catch { self.error = error.localizedDescription }
                }.disabled(entries.isEmpty || entries.contains { $0.resultRawValue == "未判定" })
            }
        }
    }
    private func gradeButton(_ entry: DictationEntry, correct: Bool) -> some View {
        let text = correct ? "正确" : "错误"
        let selected = entry.resultRawValue == text
        return Button {
            do { try store.mark(entry.id, correct: correct) } catch { self.error = error.localizedDescription }
        } label: {
            Label(text, systemImage: correct ? "checkmark.circle" : "xmark.circle")
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(10)
                .background(selected ? (correct ? LabStyle.teal : .orange).opacity(0.15) : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(selected ? (correct ? LabStyle.teal : .orange) : .secondary)
        }.buttonStyle(.plain)
    }
    private var resultView: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(LabStyle.teal)
                Text("认真练过，就有收获").font(.title2.bold())
                Text("共 \(entries.count) 题 · 正确 \(entries.filter { $0.resultRawValue == "正确" }.count) 题") .foregroundStyle(.secondary)
                Panel {
                    Label("后续练习", systemImage: "sparkles").font(.headline)
                    if agent.isRunning { ProgressView(agent.status) }
                    else {
                        Text(agent.status.isEmpty ? "本次判定已保存。" : agent.status).font(.subheadline)
                        if let error = agent.lastError { Text(error).font(.subheadline).foregroundStyle(.orange) }
                    }
                    let plans = store.state.plans.filter { plan in store.state.sessions.contains { $0.id == plan.sessionID && $0.scheduledDate > Calendar.current.startOfDay(for: .now) && $0.cancelledAt == nil } }
                    ForEach(plans) { plan in
                        if let next = store.state.sessions.first(where: { $0.id == plan.sessionID }) {
                            Text("\(next.scheduledDate.formatted(date: .abbreviated, time: .omitted)) · \(next.title)").font(.subheadline.bold())
                            Text(plan.rationale).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if store.state.pendingFeedbackSessionIDs.contains(sessionID) {
                        Button("重试后续安排") { agent.start(apiKey: (try? LabKeychain.load()) ?? "") }
                            .disabled(agent.isRunning || !store.state.configuration.isEnabled)
                    }
                    if !store.state.configuration.isEnabled { Text("教练当前未启用，基础复习进度已记录。") .font(.caption).foregroundStyle(.secondary) }
                }
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            }.padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemGroupedBackground))
    }
    private func readCurrent() {
        guard entries.indices.contains(index) else { return }
        countdown?.cancel(); remaining = 0
        speech.speak(entries[index]) {
            guard auto else { return }
            countdown = Task { @MainActor in
                for second in (1...5).reversed() {
                    if Task.isCancelled { return }; remaining = second
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
                guard !Task.isCancelled, auto else { return }
                remaining = 0; advance()
                if index < entries.count && auto { readCurrent() }
            }
        }
    }
    private func advance() {
        do { try store.advance(sessionID, to: min(index + 1, entries.count)) }
        catch { stop(); self.error = error.localizedDescription }
    }
    private func stop() { auto = false; countdown?.cancel(); countdown = nil; remaining = 0; speech.stop() }
}
