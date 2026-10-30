import SwiftUI
import AVFoundation

struct BatchReviewSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentIndex = 0
    @State private var navigateToReview = false
    @State private var isContentRevealed = false
    @StateObject private var speaker = AutoDictationController()

    let items: [ReviewItem]

    /// 批量复习的进度只与「这一批题目的有序 ID 列表」绑定：
    /// 列表变化（复习完成、新增到期内容）后旧进度自动失效，从头开始。
    private struct StoredProgress: Codable {
        let itemIDs: [UUID]
        let index: Int
    }

    private static let progressDefaultsKey = "batchReviewSession.progress.v1"

    init(items: [ReviewItem]) {
        self.items = items
        let restoredIndex = Self.restoreProgress(matching: items)
        _currentIndex = State(initialValue: restoredIndex)
    }

    private static func restoreProgress(matching items: [ReviewItem]) -> Int {
        guard !items.isEmpty,
              let data = UserDefaults.standard.data(forKey: progressDefaultsKey),
              let progress = try? JSONDecoder().decode(StoredProgress.self, from: data),
              progress.itemIDs == items.map(\.id) else {
            return 0
        }
        return min(max(progress.index, 0), items.count - 1)
    }

    private func persistProgress() {
        let progress = StoredProgress(itemIDs: items.map(\.id), index: currentIndex)
        if let data = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(data, forKey: Self.progressDefaultsKey)
        }
    }

    /// 只有在判卷提交成功后才清除进度（由 BatchReviewGradingView 回调触发）。
    /// 进入判卷但未提交就退出时进度保留，重新进入本页可以继续上次的位置。
    private static func clearProgress() {
        UserDefaults.standard.removeObject(forKey: progressDefaultsKey)
    }

    private var currentItem: ReviewItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    private var progress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(currentIndex) / Double(items.count)
    }

    private var completionProgress: Double {
        Double(currentIndex + 1) / Double(max(items.count, 1))
    }

    private var cardContentTransition: AnyTransition {
        .opacity.combined(with: .offset(x: 12))
    }

    var body: some View {
        Group {
            if let item = currentItem {
                GeometryReader { proxy in
                    let isWide = proxy.size.width >= 700

                            ScrollView(showsIndicators: false) {
                                VStack(spacing: 22) {
                                    progressHeader
                                    if !item.type.isRecitation {
                                        AutoDictationControls(controller: speaker)
                                    }
                                    stageOverviewCard(for: item)
                                    sessionCard(for: item, isWide: isWide)
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
            } else {
                ReviewEmptyStateView()
            }
        }
        .navigationTitle("复习听写")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToReview) {
            BatchReviewGradingView(
                items: items,
                onReturnFromCompletion: {
                    dismiss()
                },
                onSubmittedSuccessfully: {
                    Self.clearProgress()
                }
            )
        }
        .onAppear {
            speaker.onAdvance = {
                guard currentIndex < items.count - 1 else { return }
                currentIndex += 1
            }
            selectCurrentEntry(speak: false)
        }
        .onChange(of: currentIndex) {
            isContentRevealed = false
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
        }
    }


    private func selectCurrentEntry(speak: Bool = true) {
        guard let entry = currentItem else { return }
        if entry.type.isRecitation {
            speaker.setEnabled(false)
        }
        speaker.select(content: entry.content, type: entry.type, prompt: entry.prompt,
                       isLast: currentIndex == items.count - 1, speak: speak && !entry.type.isRecitation)
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("复习进行中")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("第 \(currentIndex + 1) / \(items.count) 题")
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

            ProgressView(value: Double(currentIndex + 1), total: Double(max(items.count, 1)))
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

    private func sessionCard(for item: ReviewItem, isWide: Bool) -> some View {
        ZStack {
            VStack(alignment: .leading, spacing: 20) {
                cardHeader(for: item, isWide: isWide)

                speakButton(for: item)

                HStack(alignment: .top) {
                    helperFooter(for: item)
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
                    VStack(alignment: .leading, spacing: 6) {
                        Divider()
                            .padding(.vertical, 8)
                        Text(item.type.isRecitation ? "背诵原文" : "听写内容")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(item.content)
                            .font(.system(isWide ? .title : .title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.blue)
                        if let phonetic = phoneticText(for: item) {
                            Text(phonetic)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .id(item.id)
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
        .animation(.easeInOut(duration: 0.22), value: item.id)
    }

    private func stageOverviewCard(for item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("复习阶段")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(item.stageBadgeText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(item.stageBadgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(item.stageBadgeColor.opacity(0.12), in: Capsule())
            }

            StageTimelineView(
                steps: item.stageTimelineSteps,
                accentColor: item.stageBadgeColor
            )
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func cardHeader(for item: ReviewItem, isWide: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                TypeBadge(type: item.type)

                if item.type.isEnglish {
                    let translation = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !translation.isEmpty {
                        Text(translation)
                            .font(.system(isWide ? .title : .title3, design: .rounded, weight: .bold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let phonetic = phoneticText(for: item) {
                        Text(phonetic)
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

    private func speakButton(for item: ReviewItem) -> some View {
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

    private func phoneticText(for item: ReviewItem) -> String? {
        guard item.type == .englishWord,
              let gloss = EnglishGlossService.shared.lookup(text: item.content),
              !gloss.displayPhonetic.isEmpty else {
            return nil
        }
        return gloss.displayPhonetic
    }

    private func helperFooter(for item: ReviewItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(helperText(for: item))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bottomActionBar(isWide: Bool) -> some View {
        HStack(spacing: 12) {
            Button("上一条") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentIndex = max(currentIndex - 1, 0)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(Color(uiColor: currentIndex == 0 ? .systemBackground : .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(currentIndex == 0 ? Color.secondary : Color.blue)
            .disabled(currentIndex == 0)

            if currentIndex < items.count - 1 {
                Button("下一条") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentIndex += 1
                    }
                }
                .buttonStyle(ResultButtonStyle(color: .blue))
            } else {
                Button("进入统一判卷") {
                    // 注意：这里不清除进度。若进入判卷后未提交就退出，
                    // 重新进入本页应能从最后一题继续；进度在判卷提交成功后清除。
                    speaker.shutdown()
                    navigateToReview = true
                }
                .buttonStyle(ResultButtonStyle(color: .green))
            }
        }
        .padding(.horizontal, isWide ? 32 : 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
    }

    private func helperText(for item: ReviewItem) -> String {
        if item.type.isRecitation {
            return "先试着背诵，需要时可显示文字重读。背出来算对，没背出来算错。"
        }
        if item.reviewTrack == .dictationFollowUp {
            switch item.resolvedDictationFollowUpStep {
            case 1:
                return "这是听写通过后的第3天复习。今天没做，明天仍会停留在这一步。"
            case 2:
                return "这是听写通过后的第7天复习。今天没做，明天仍会停留在这一步。"
            default:
                return "这是听写通过后的跟进复习。"
            }
        }

        if item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "会直接播放要写的内容，孩子整轮写完后，家长再进入「复习听写」。"
        }
        return "如果不看文字，也可以直接点击朗读来做听写。"
    }
}
