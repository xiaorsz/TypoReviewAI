import SwiftUI
import AVFoundation
import SwiftData

struct DictationSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    @State private var currentIndex = 0
    @State private var navigateToReview = false
    @State private var isContentRevealed = false
    @State private var hasAutoSpokenInitialEntry = false
    @State private var isFinishing = false
    @State private var saveErrorMessage: String?
    @State private var didPersistProgress = false
    @StateObject private var speaker = AutoDictationController()

    let session: DictationSession
    let entries: [DictationEntry]

    init(session: DictationSession, entries: [DictationEntry]) {
        self.session = session
        self.entries = entries
        // 恢复上次听写进度；已完成/已判定的会话始终从头开始。
        let restoredIndex: Int
        if session.isFinished || session.isReviewed || entries.isEmpty {
            restoredIndex = 0
        } else {
            restoredIndex = min(max(session.currentEntryIndex, 0), entries.count - 1)
        }
        _currentIndex = State(initialValue: restoredIndex)
        _isContentRevealed = State(initialValue: session.type.isRecitation)
    }

    private var currentEntry: DictationEntry? {
        guard entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    private var completionProgress: Double {
        Double(currentIndex + 1) / Double(max(entries.count, 1))
    }

    private var cardContentTransition: AnyTransition {
        .opacity.combined(with: .offset(x: 12))
    }

    var body: some View {
        Group {
            if let currentEntry {
                GeometryReader { proxy in
                    let isWide = proxy.size.width >= 700

                            ScrollView(showsIndicators: false) {
                                VStack(spacing: 22) {
                                    progressHeader
                                    if !session.type.isRecitation {
                                        AutoDictationControls(controller: speaker)
                                    }
                                    sessionCard(for: currentEntry, isWide: isWide)
                                }
                                .frame(maxWidth: isWide ? 860 : .infinity)
                                .padding(.horizontal, isWide ? 32 : 20)
                                .padding(.top, 20)
                                .padding(.bottom, 140)
                            }
                    .safeAreaInset(edge: .bottom) {
                        bottomActionBar(isWide: isWide)
                    }
                }
            }
        }
        .navigationTitle(session.type.isRecitation ? "今日背诵" : "今日听写")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToReview) {
            DictationReviewView(
                session: session,
                entries: entries,
                onReturnToList: {
                    dismiss()
                }
            )
        }
        .onAppear {
            AICoachSignals.post("started", id: session.id)
            speaker.onAdvance = {
                guard currentIndex < entries.count - 1 else { return }
                currentIndex += 1
            }
            selectCurrentEntry(speak: !hasAutoSpokenInitialEntry)
            hasAutoSpokenInitialEntry = true
        }
        .onChange(of: currentIndex) {
            isContentRevealed = session.type.isRecitation
            persistProgress()
            selectCurrentEntry()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { speaker.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .began {
                speaker.pause()
            }
        }
        .onDisappear {
            speaker.shutdown()
            persistProgress()
            // 本次访问只要保存过进度就广播一次，刷新入口列表的「继续第 X/N 条」。
            // 不依附于退出时这次保存是否发生——逐题保存可能已把进度落盘。
            if didPersistProgress {
                AppDataChangeCenter.post()
            }
        }
        .alert("听写进度保存失败", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }


    private func selectCurrentEntry(speak: Bool = true) {
        guard let entry = currentEntry else { return }
        speaker.select(content: entry.content, type: entry.type, prompt: entry.prompt,
                       isLast: currentIndex == entries.count - 1, speak: speak && !entry.type.isRecitation)
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.type.isRecitation ? "今日背诵" : "今日听写")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("第 \(currentIndex + 1) / \(entries.count) 条")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                }

                Spacer()

                Text("\(Int((completionProgress * 100).rounded()))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            }

            ProgressView(value: Double(currentIndex + 1), total: Double(max(entries.count, 1)))
                .tint(.blue)
                .scaleEffect(x: 1, y: 1.6, anchor: .center)
                .animation(.easeInOut(duration: 0.3), value: currentIndex)

            if currentIndex > 0 {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentIndex = 0
                        }
                    } label: {
                        Label("重新开始", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func sessionCard(for entry: DictationEntry, isWide: Bool) -> some View {
        ZStack {
            VStack(alignment: .leading, spacing: 20) {
                cardHeader(for: entry, isWide: isWide)

                speakButton(for: entry)

                HStack(alignment: .top) {
                    helperFooter
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isContentRevealed.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isContentRevealed ? "eye.slash.fill" : "eye.fill")
                            Text(isContentRevealed ? "隐藏文字" : "显示文字")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.blue.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if isContentRevealed {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                            .padding(.vertical, 8)
                        Text(entry.type.isRecitation ? "背诵原文" : "听写内容")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(entry.content)
                            .font(.system(isWide ? .title : .title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.blue)
                        if let phonetic = phoneticText(for: entry) {
                            Text(phonetic)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .id(entry.id)
            .transition(.asymmetric(insertion: cardContentTransition, removal: .opacity))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isWide ? 32 : 24)
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .strokeBorder(.secondary.opacity(0.2), lineWidth: 1)
                )
        )
        .shadow(color: .blue.opacity(0.08), radius: 24, y: 10)
        .animation(.easeInOut(duration: 0.22), value: entry.id)
    }

    private func cardHeader(for entry: DictationEntry, isWide: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TypeBadge(type: entry.type)

                    Text(session.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.prompt)
                        .font(.system(isWide ? .title : .title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let phonetic = phoneticText(for: entry) {
                    Text(phonetic)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Image(systemName: "waveform.badge.mic")
                .font(.system(size: isWide ? 24 : 20, weight: .medium))
                .foregroundStyle(.blue.opacity(0.45))
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func speakButton(for entry: DictationEntry) -> some View {
        Button {
            speaker.replay()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: speaker.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                    .font(.title3.weight(.bold))
                Text(speaker.isSpeaking ? "正在朗读" : "点击朗读")
                    .font(.system(.title2, design: .rounded, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
        }
        .buttonStyle(ResultButtonStyle(color: speaker.isSpeaking ? .teal : .blue))
    }

    private func phoneticText(for entry: DictationEntry) -> String? {
        guard entry.type == .englishWord,
              let gloss = EnglishGlossService.shared.lookup(text: entry.content),
              !gloss.displayPhonetic.isEmpty else {
            return nil
        }
        return gloss.displayPhonetic
    }

    private var helperFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(session.type.isRecitation
                 ? "先看着读几遍，再隐藏文字试着背。最后按背诵情况判对错。"
                 : "孩子先把整轮内容都写完，最后再统一批量判定。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bottomActionBar(isWide: Bool) -> some View {
        HStack(spacing: 12) {
            Button("上一条") {
                currentIndex = max(currentIndex - 1, 0)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(Color(uiColor: currentIndex == 0 ? .systemBackground : .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(currentIndex == 0 ? Color.secondary : Color.blue)
            .disabled(currentIndex == 0)

            if currentIndex < entries.count - 1 {
                Button("下一条") {
                    currentIndex += 1
                }
                .buttonStyle(ResultButtonStyle(color: .blue))
            } else {
                Button(isFinishing ? "正在保存…" : (session.type.isRecitation ? "完成背诵并判定" : "完成听写并进入判卷")) {
                    finishSession()
                }
                .buttonStyle(ResultButtonStyle(color: .green))
                .disabled(isFinishing)
            }
        }
        .padding(.horizontal, isWide ? 32 : 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
    }

    private func finishSession() {
        guard !isFinishing else { return }
        speaker.pause()
        isFinishing = true

        let now = Date()
        session.finishedAt = now
        session.updatedAt = now
        session.currentEntryIndex = 0

        do {
            try PersistentStoreAccessGate.withAccess {
                try modelContext.save()
            }
            isFinishing = false
            AppDataChangeCenter.post()
            navigateToReview = true
        } catch {
            isFinishing = false
            saveErrorMessage = "本次听写尚未标记为完成，请保持 App 在前台后重试。\(error.localizedDescription)"
        }
    }

    /// 把当前题号写回会话，退出后再次进入可以从这里继续。
    /// 逐题切换时静默落盘；退出页面时由 onDisappear 统一广播一次变更，
    /// 避免每条题都触发首页/列表快照重载。
    private func persistProgress() {
        guard !session.isFinished, !session.isReviewed else { return }
        guard session.currentEntryIndex != currentIndex else { return }

        let previousIndex = session.currentEntryIndex
        let previousUpdatedAt = session.updatedAt
        session.currentEntryIndex = currentIndex
        session.updatedAt = .now

        do {
            try PersistentStoreAccessGate.withAccess {
                try modelContext.save()
            }
            didPersistProgress = true
        } catch {
            // 保存失败必须恢复内存字段：否则 currentEntryIndex 已与 currentIndex 相等，
            // 之后（如退出页面时）再调用会被上面的 guard 提前拦住，
            // 未落盘的进度永远失去重试机会。
            session.currentEntryIndex = previousIndex
            session.updatedAt = previousUpdatedAt
            saveErrorMessage = "听写进度没有保存成功，仍可继续听写。\(error.localizedDescription)"
        }
    }
}
