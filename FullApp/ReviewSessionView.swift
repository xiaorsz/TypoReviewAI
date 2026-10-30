import SwiftUI
import AVFoundation
import SwiftData

struct ReviewSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettingsStore.self) private var settings

    @State private var sessionItems: [ReviewItem]
    @State private var currentIndex = 0
    @State private var completedCount = 0
    @State private var wrongCount = 0
    @State private var showResultButtons = false
    @State private var isContentRevealed = false
    @State private var reviewedSummaries: [SessionReviewSummary] = []
    @State private var showFeedback = false
    @State private var lastResultCorrect = true
    @State private var undoStack: [UndoEntry] = []
    @State private var reviewSessionID = UUID()
    @State private var accuracyBonusAmount = 0
    @State private var saveErrorMessage: String?
    @State private var syncNoticeMessage: String?
    @State private var learningSessionSummary: LearningSessionSummaryResult?
    @State private var learningSessionSummaryInputHash = ""
    @State private var isLearningSessionSummaryAIResult = false
    @State private var isLoadingLearningSessionSummary = false
    @State private var learningSessionSummaryTask: Task<Void, Never>?
    @StateObject private var speaker = ReviewSpeaker()

    private let scheduler = ReviewScheduler()

    init(items: [ReviewItem]) {
        _sessionItems = State(initialValue: items)
    }

    private var currentItem: ReviewItem? {
        guard sessionItems.indices.contains(currentIndex) else { return nil }
        return sessionItems[currentIndex]
    }

    private var progress: Double {
        guard !sessionItems.isEmpty else { return 0 }
        return Double(currentIndex) / Double(sessionItems.count)
    }

    var body: some View {
        ZStack {
            Group {
                if let item = currentItem {
                    GeometryReader { proxy in
                        let isWide = proxy.size.width >= 700

                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 20) {
                                // Progress bar
                                VStack(spacing: 8) {
                                    ProgressView(value: progress)
                                        .tint(.accentColor)
                                        .animation(.easeInOut(duration: 0.3), value: progress)

                                    Text("第 \(currentIndex + 1) / \(sessionItems.count) 题")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }

                                // Question card
                                VStack(alignment: .leading, spacing: 16) {
                                    HStack {
                                        TypeBadge(type: item.type)
                                        Spacer()
                                        Text(item.stageBadgeText)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(item.stageBadgeColor)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(item.stageBadgeColor.opacity(0.12), in: Capsule())
                                    }

                                    Text(headlineText(for: item))
                                        .font(.system(isWide ? .largeTitle : .title2, design: .rounded, weight: .bold))

                                    if let phonetic = phoneticText(for: item) {
                                        Text(phonetic)
                                            .font(.system(.title3, design: .rounded, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    Button {
                                        speaker.speak(item)
                                    } label: {
                                        Label(speaker.isSpeaking ? "正在朗读" : "点击朗读", systemImage: "speaker.wave.2.fill")
                                            .font(.system(.title2, design: .rounded, weight: .bold))
                                            .frame(maxWidth: .infinity)
                                            .frame(minHeight: 56)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)

                                    HStack(alignment: .top) {
                                        Text(helperText(for: item))
                                            .foregroundStyle(.secondary)
                                            .font(.subheadline)

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
                                            Text("题目答案")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                            Text(item.content)
                                                .font(.system(isWide ? .title : .title2, design: .rounded, weight: .semibold))
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(isWide ? 32 : 24)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28))

                                if showResultButtons {
                                    VStack(spacing: 14) {
                                        answerCard(for: item)

                                        HStack(spacing: 14) {
                                            Button {
                                                submit(.correct, for: item)
                                            } label: {
                                                Label(item.type.isRecitation ? "背出来了" : "正确", systemImage: "checkmark.circle.fill")
                                            }
                                            .buttonStyle(ResultButtonStyle(color: .green))

                                            Button {
                                                submit(.wrong, for: item)
                                            } label: {
                                                Label(item.type.isRecitation ? "没背出来" : "不正确", systemImage: "xmark.circle.fill")
                                            }
                                            .buttonStyle(ResultButtonStyle(color: .red))
                                        }
                                    }
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                                } else {
                                    Button(item.type.isRecitation ? "核对背诵" : "我写好了") {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                            showResultButtons = true
                                        }
                                    }
                                    .buttonStyle(ResultButtonStyle(color: .blue))
                                }

                                Spacer()
                            }
                            .padding(isWide ? 32 : 20)
                        }
                    }
                    .id(currentIndex) // Force view refresh on index change
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                } else {
                    completionView
                }
            }

            // Feedback overlay
            AnswerFeedbackOverlay(isCorrect: lastResultCorrect, isVisible: $showFeedback)
        }
        .navigationTitle("开始复习")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    undoLastAnswer()
                } label: {
                    Label("撤回", systemImage: "arrow.uturn.backward")
                }
                .disabled(undoStack.isEmpty)
            }
        }
        .onAppear {
            if let currentItem {
                speaker.prepare(currentItem)
            }
        }
        .onChange(of: currentIndex) {
            isContentRevealed = false
            if let currentItem {
                speaker.prepare(currentItem)
            } else {
                speaker.stop()
            }
        }
        .onDisappear {
            speaker.stop()
            learningSessionSummaryTask?.cancel()
        }
        .alert("保存失败", isPresented: saveErrorBinding) {
            Button("知道了", role: .cancel) {
                saveErrorMessage = nil
            }
        } message: {
            Text(saveErrorMessage ?? "这次复习记录没有保存成功，请再试一次。")
        }
        .alert("同步提示", isPresented: syncNoticeBinding) {
            Button("知道了", role: .cancel) {
                syncNoticeMessage = nil
            }
        } message: {
            Text(syncNoticeMessage ?? "这题的进度已经更新。")
        }
    }

    private var completionView: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700

            ScrollView {
                VStack(spacing: 20) {
                    // Hero card
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: wrongCount == 0 ? "checkmark.seal.fill" : "arrow.trianglehead.clockwise")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)

                        Text("本轮复习完成")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))

                        Text(summaryText)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 28)
                            .fill(
                                LinearGradient(
                                    colors: [.green.opacity(0.82), .mint.opacity(0.55)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )

                    // Stats grid
                    let columns = isWide
                        ? Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
                        : Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

                    LazyVGrid(columns: columns, spacing: 12) {
                        StatGridCard(icon: "checkmark.seal", title: "完成", value: "\(completedCount)", tint: .blue)
                        StatGridCard(icon: "hand.thumbsup", title: "答对", value: "\(correctCount)", tint: .green)
                        StatGridCard(icon: "hand.thumbsdown", title: "答错", value: "\(wrongCount)", tint: .red)
                        StatGridCard(icon: "percent", title: "正确率", value: accuracyText, tint: .orange)
                    }

                    AccuracyBonusCard(
                        title: "复习正确率奖励",
                        amount: accuracyBonusAmount,
                        accuracyText: accuracyText,
                        tint: .orange
                    )

                    learningSessionSummaryCard

                    if !reviewedSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("本次结果")
                                .font(.headline)

                            ForEach(reviewedSummaries) { summary in
                                HStack(spacing: 12) {
                                    Image(systemName: summary.result == .correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(summary.result == .correct ? .green : .red)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(summary.content)
                                            .fontWeight(.semibold)
                                        Text(summary.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    }

                    if !undoStack.isEmpty {
                        Button {
                            undoLastAnswer()
                        } label: {
                            Label("撤回上一题", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(ResultButtonStyle(color: .gray))
                    }

                    Button("返回首页") {
                        dismiss()
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                }
                .padding(isWide ? 32 : 20)
                .onAppear {
                    refreshLearningSessionSummary(force: false)
                }
            }
        }
    }

    // MARK: - Actions

    private func submit(_ result: ReviewResult, for item: ReviewItem) {
        speaker.stop()

        let now = Date()
        guard prepareForSubmission(item, now: now) else { return }

        // Save undo info before modifying
        let undoEntry = UndoEntry(
            itemIndex: currentIndex,
            oldStage: item.stage,
            oldNextReviewAt: item.nextReviewAt,
            oldLastReviewedAt: item.lastReviewedAt,
            oldConsecutiveCorrectCount: item.consecutiveCorrectCount,
            oldConsecutiveWrongCount: item.consecutiveWrongCount,
            oldIsPriority: item.isPriority,
            oldReviewTrackRawValue: item.reviewTrackRawValue,
            oldDictationFollowUpStep: item.dictationFollowUpStep,
            oldIsDictationPass: item.isDictationPass,
            result: result
        )

        let oldTrack = item.reviewTrack
        let oldFollowUpStep = item.resolvedDictationFollowUpStep
        let output = scheduler.handle(item: item, result: result, now: now)
        let detail = item.reviewTransitionDetail(
            result: result,
            oldStage: output.record.oldStage,
            oldTrack: oldTrack,
            oldFollowUpStep: oldFollowUpStep
        )
        output.record.note = ReviewRecord.storedConfirmedDetailText(detail)
        let upsertResult = ReviewScheduler.upsertReviewRecord(
            output.record,
            in: modelContext
        )
        // 用结算式发放而不是按幂等键拦截的发放：撤回会冲正原积分但保留原记录，
        // 重新作答生成相同记录 ID，若按幂等键拦截就会少 1 分基础积分。
        // settle 检查「是否存在未被冲正的有效奖励」，被冲正的允许重发，有效的仍跳过。
        let pointEntryWasCreated = PointLedgerService.settleReviewRecordReward(
            upsertResult.record,
            in: modelContext
        ) != nil

        let finalCompletedCount = completedCount + 1
        let finalWrongCount = wrongCount + (result == .wrong ? 1 : 0)
        let finalCorrectCount = finalCompletedCount - finalWrongCount
        let willCompleteSession = finalCompletedCount == sessionItems.count
        let earnedAccuracyBonusAmount = willCompleteSession
            ? PointLedgerService.accuracyBonusAmount(correctCount: finalCorrectCount, totalCount: finalCompletedCount)
            : 0

        if willCompleteSession {
            // 用 refresh 而不是 award：撤回最后一题后再次完成时，原奖励虽已被冲正，
            // 但其幂等键仍占着，直接 award 会被 hasEntry 拦截导致奖励丢失。
            // refresh 先冲正以往奖励、再以唯一键重发，净额始终等于本次算出的奖励。
            PointLedgerService.refreshReviewAccuracyBonus(
                sessionID: reviewSessionID,
                correctCount: finalCorrectCount,
                totalCount: finalCompletedCount,
                createdAt: output.record.reviewedAt,
                in: modelContext
            )
        }

        guard persistChanges(
            message: "这题的复习结果没有保存成功，请稍后再试一次。"
        ) else {
            return
        }

        reviewedSummaries.append(
            SessionReviewSummary(
                content: item.content,
                result: result,
                detail: detail
            )
        )

        undoEntry.recordID = upsertResult.record.id
        undoEntry.previousRecordStates = upsertResult.previousStates
        undoEntry.pointEntryWasCreated = pointEntryWasCreated
        undoEntry.wasCompletion = willCompleteSession
        undoStack.append(undoEntry)

        completedCount += 1
        if willCompleteSession {
            AICoachSignals.post("review", id: reviewSessionID, itemIDs: sessionItems.map(\.id), recordIDs: undoStack.compactMap(\.recordID))
        }
        if result == .wrong {
            wrongCount += 1
        }
        if willCompleteSession {
            accuracyBonusAmount = earnedAccuracyBonusAmount
        }

        // Show feedback overlay
        lastResultCorrect = result == .correct
        withAnimation(.easeIn(duration: 0.15)) {
            showFeedback = true
        }

        showResultButtons = false

        // Advance after feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex += 1
            }
        }
    }

    private func undoLastAnswer() {
        guard let entry = undoStack.popLast() else { return }

        currentIndex = entry.itemIndex
        let item = sessionItems[entry.itemIndex]

        // Restore item state
        item.updatedAt = .now
        item.stage = entry.oldStage
        item.nextReviewAt = entry.oldNextReviewAt
        item.lastReviewedAt = entry.oldLastReviewedAt
        item.consecutiveCorrectCount = entry.oldConsecutiveCorrectCount
        item.consecutiveWrongCount = entry.oldConsecutiveWrongCount
        item.isPriority = entry.oldIsPriority
        item.reviewTrackRawValue = entry.oldReviewTrackRawValue
        item.dictationFollowUpStep = entry.oldDictationFollowUpStep
        item.isDictationPass = entry.oldIsDictationPass

        // Delete the record
        if let recordID = entry.recordID {
            if entry.pointEntryWasCreated {
                PointLedgerService.reverseEntries(
                    sourceType: .reviewRecord,
                    sourceID: recordID,
                    in: modelContext
                )
            }

            if entry.previousRecordStates.isEmpty {
                let descriptor = FetchDescriptor<ReviewRecord>(
                    predicate: #Predicate { $0.id == recordID }
                )
                if let records = try? modelContext.fetch(descriptor) {
                    for record in records {
                        SyncDeletionStore.delete(record, in: modelContext)
                    }
                }
            } else {
                entry.previousRecordStates.forEach { $0.restore() }
            }
        }

        // 撤回最后一题时，同时冲正本次复习已发放的正确率奖励，并重置结果页展示的奖励金额。
        if entry.wasCompletion {
            PointLedgerService.reverseEntries(
                sourceType: .reviewAccuracyBonus,
                sourceIDRawValue: reviewSessionID.uuidString,
                in: modelContext
            )
            accuracyBonusAmount = 0
        }

        guard persistChanges(
            message: "撤回操作没有保存成功，请稍后再试一次。"
        ) else {
            return
        }

        if entry.wasCompletion { AICoachSignals.post("reviewUndo", id: reviewSessionID) }

        // Restore counters
        completedCount -= 1
        if entry.result == .wrong {
            wrongCount -= 1
        }

        reviewedSummaries.removeLast()
        showResultButtons = false
    }

    // MARK: - Text Helpers

    private func headlineText(for item: ReviewItem) -> String {
        if item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch item.type {
            case .chineseCharacter:
                return "点击朗读，听写这个汉字"
            case .phrase:
                return "点击朗读，听写这个词句"
            case .englishWord:
                return "点击朗读，听写这个英语"
            case .englishSentence:
                return "试着背出这个英语句子"
            }
        }

        return item.prompt
    }

    private func phoneticText(for item: ReviewItem) -> String? {
        guard item.type == .englishWord,
              let gloss = EnglishGlossService.shared.lookup(text: item.content),
              !gloss.displayPhonetic.isEmpty else {
            return nil
        }
        return gloss.displayPhonetic
    }

    private func helperText(for item: ReviewItem) -> String {
        if item.type.isRecitation {
            return "可以显示文字先读几遍，再隐藏文字背诵。背出来算对，没背出来算错。"
        }
        if item.reviewTrack == .dictationFollowUp {
            switch item.resolvedDictationFollowUpStep {
            case 1:
                return "这是听写通过后的第3天复习。今天没做，明天仍会保持在这一步。"
            case 2:
                return "这是听写通过后的第7天复习。今天没做，明天仍会保持在这一步。"
            default:
                return "这是听写通过后的跟进复习。"
            }
        }

        if item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "会直接播放要写的内容，孩子写完后，再由家长判定。"
        }

        return "如果不看文字，也可以直接点击朗读来做听写。"
    }

    private func answerCard(for item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("标准答案")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(item.content)
                .font(.system(.title, design: .rounded, weight: .bold))

            if let phonetic = phoneticText(for: item) {
                Text(phonetic)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.prompt)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                answerMetaRow(title: "备注", value: item.note)
            }

            if !item.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                answerMetaRow(title: "来源", value: item.source)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func answerMetaRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var correctCount: Int {
        completedCount - wrongCount
    }

    private var accuracyText: String {
        guard completedCount > 0 else { return "--" }
        let accuracy = Int((Double(correctCount) / Double(completedCount) * 100).rounded())
        return "\(accuracy)%"
    }

    private var summaryText: String {
        if wrongCount == 0 {
            return "这次复习全部答对，系统已经自动安排到下一次复习日期。"
        }

        return "这次一共完成 \(completedCount) 题，其中答错 \(wrongCount) 题。答错的内容会安排到之后的日期，今天不会重复出现。"
    }

    private var learningSessionSummaryCard: some View {
        let result = learningSessionSummary ?? makeLearningSessionSummaryInput().localFallbackResult()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: wrongCount == 0 ? "sparkles" : "lightbulb.max.fill")
                    .foregroundStyle(.purple)
                Text(wrongCount == 0 ? "本次小结" : "错项建议")
                    .font(.headline)
                learningSessionSummarySourceBadge

                Spacer()

                if isLoadingLearningSessionSummary {
                    ProgressView()
                        .controlSize(.small)
                }

                if settings.aiSummaryEnabled {
                    Button {
                        refreshLearningSessionSummary(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoadingLearningSessionSummary)
                    .accessibilityLabel("重新生成 AI 错项建议")
                }
            }

            Text(result.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !result.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(result.suggestions.prefix(3).enumerated()), id: \.offset) { _, suggestion in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .padding(.top, 2)
                            Text(suggestion)
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var learningSessionSummarySourceBadge: some View {
        let title = isLoadingLearningSessionSummary
            ? "AI 生成中"
            : (isLearningSessionSummaryAIResult ? "AI 小结" : "本地小结")
        let icon = isLoadingLearningSessionSummary
            ? "sparkles"
            : (isLearningSessionSummaryAIResult ? "checkmark.seal.fill" : "iphone")

        return Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isLearningSessionSummaryAIResult || isLoadingLearningSessionSummary ? .purple : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .accessibilityLabel(title)
    }

    private func makeLearningSessionSummaryInput() -> LearningSessionSummaryInput {
        LearningSessionSummaryInput(
            kind: .review,
            title: "今日复习",
            date: DailySummaryInput.dateKey(),
            childName: settings.childName.isEmpty ? "小朋友" : settings.childName,
            metrics: LearningSessionSummaryInput.Metrics(
                totalCount: completedCount,
                correctCount: correctCount,
                wrongCount: wrongCount,
                accuracyText: accuracyText
            ),
            samples: LearningSessionSummaryInput.Samples(
                wrongItems: reviewedSummaries.filter { $0.result == .wrong }.map(\.content).prefix(8).map { $0 },
                correctItems: reviewedSummaries.filter { $0.result == .correct }.map(\.content).prefix(4).map { $0 }
            )
        )
    }

    private func refreshLearningSessionSummary(force: Bool) {
        let input = makeLearningSessionSummaryInput()
        let inputHash = input.stableHash()
        let model = DeepSeekSummaryModel(rawValue: settings.aiSummaryModelRawValue) ?? .flash
        let fallback = input.localFallbackResult()

        guard settings.aiSummaryEnabled else {
            learningSessionSummaryTask?.cancel()
            learningSessionSummaryInputHash = inputHash
            learningSessionSummary = fallback
            isLearningSessionSummaryAIResult = false
            isLoadingLearningSessionSummary = false
            return
        }

        guard let apiKey = try? DeepSeekAPIKeyStore.loadAPIKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            learningSessionSummaryTask?.cancel()
            learningSessionSummaryInputHash = inputHash
            learningSessionSummary = fallback
            isLearningSessionSummaryAIResult = false
            isLoadingLearningSessionSummary = false
            return
        }

        if !force,
           learningSessionSummaryInputHash == inputHash,
           learningSessionSummary != nil {
            return
        }

        if !force,
           let cached = LearningSessionSummaryCache.load(inputHash: inputHash, model: model.rawValue) {
            learningSessionSummaryTask?.cancel()
            learningSessionSummaryInputHash = inputHash
            learningSessionSummary = cached
            isLearningSessionSummaryAIResult = true
            isLoadingLearningSessionSummary = false
            return
        }

        learningSessionSummaryTask?.cancel()
        learningSessionSummaryInputHash = inputHash
        learningSessionSummary = fallback
        isLearningSessionSummaryAIResult = false
        isLoadingLearningSessionSummary = true

        learningSessionSummaryTask = Task {
            do {
                let result = try await DeepSeekSummaryClient(apiKey: apiKey, model: model.rawValue)
                    .generateLearningSessionSummary(for: input)
                await MainActor.run {
                    LearningSessionSummaryCache.save(result, inputHash: inputHash, model: model.rawValue)
                    learningSessionSummary = result
                    learningSessionSummaryInputHash = inputHash
                    isLearningSessionSummaryAIResult = true
                    isLoadingLearningSessionSummary = false
                }
            } catch {
                await MainActor.run {
                    learningSessionSummary = fallback
                    learningSessionSummaryInputHash = inputHash
                    isLearningSessionSummaryAIResult = false
                    isLoadingLearningSessionSummary = false
                }
            }
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    saveErrorMessage = nil
                }
            }
        )
    }

    private var syncNoticeBinding: Binding<Bool> {
        Binding(
            get: { syncNoticeMessage != nil },
            set: { newValue in
                if !newValue {
                    syncNoticeMessage = nil
                }
            }
        )
    }

    private func prepareForSubmission(_ item: ReviewItem, now: Date) -> Bool {
        do {
            _ = try ReviewScheduler.reconcileStandardReviewProgress(in: modelContext)

            let eligible = try DailyReviewPlanner.eligibleIDs(in: modelContext, dailyLimit: settings.dailyLimit, now: now)
            guard ReviewScheduler.isDue(item.nextReviewAt, on: now), eligible.contains(item.id) else {
                if modelContext.hasChanges {
                    try modelContext.save()
                    AppDataChangeCenter.post()
                }
                syncNoticeMessage = "这题已完成、已听写判定或不在今日剩余题量内，本次不重复复习。"
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentIndex += 1
                }
                return false
            }

            if modelContext.hasChanges {
                try modelContext.save()
                AppDataChangeCenter.post()
            }
            return true
        } catch {
            saveErrorMessage = "提交前同步校验失败，请稍后再试一次。\n\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func persistChanges(message: String) -> Bool {
        do {
            try modelContext.save()
            AppDataChangeCenter.post()
            return true
        } catch {
            saveErrorMessage = "\(message)\n\(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - Supporting Types

private struct SessionReviewSummary: Identifiable {
    let id = UUID()
    let content: String
    let result: ReviewResult
    let detail: String
}

private class UndoEntry {
    let itemIndex: Int
    let oldStage: Int
    let oldNextReviewAt: Date
    let oldLastReviewedAt: Date?
    let oldConsecutiveCorrectCount: Int
    let oldConsecutiveWrongCount: Int
    let oldIsPriority: Bool
    let oldReviewTrackRawValue: String
    let oldDictationFollowUpStep: Int
    let oldIsDictationPass: Bool
    let result: ReviewResult
    var recordID: UUID?
    var previousRecordStates: [ReviewScheduler.StoredReviewRecordState] = []
    var pointEntryWasCreated = false
    var wasCompletion = false

    init(
        itemIndex: Int,
        oldStage: Int,
        oldNextReviewAt: Date,
        oldLastReviewedAt: Date?,
        oldConsecutiveCorrectCount: Int,
        oldConsecutiveWrongCount: Int,
        oldIsPriority: Bool,
        oldReviewTrackRawValue: String,
        oldDictationFollowUpStep: Int,
        oldIsDictationPass: Bool,
        result: ReviewResult
    ) {
        self.itemIndex = itemIndex
        self.oldStage = oldStage
        self.oldNextReviewAt = oldNextReviewAt
        self.oldLastReviewedAt = oldLastReviewedAt
        self.oldConsecutiveCorrectCount = oldConsecutiveCorrectCount
        self.oldConsecutiveWrongCount = oldConsecutiveWrongCount
        self.oldIsPriority = oldIsPriority
        self.oldReviewTrackRawValue = oldReviewTrackRawValue
        self.oldDictationFollowUpStep = oldDictationFollowUpStep
        self.oldIsDictationPass = oldIsDictationPass
        self.result = result
    }
}

// MARK: - Speech

@MainActor
private final class ReviewSpeaker: NSObject, ObservableObject {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var currentItem: ReviewItem?
    private var pendingUtteranceCount = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepare(_ item: ReviewItem) {
        currentItem = item
        stop()
    }

    func speak(_ item: ReviewItem) {
        currentItem = item
        speakCurrentText(for: item)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        SpeechAudioSession.deactivate()
        pendingUtteranceCount = 0
        isSpeaking = false
    }

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

    private func speakCurrentText(for item: ReviewItem) {
        stop()
        let utterances = SpeechUtteranceBuilder.utterances(
            content: item.content,
            type: item.type,
            prompt: item.prompt
        )
        guard !utterances.isEmpty else { return }

        pendingUtteranceCount = utterances.count
        SpeechAudioSession.activate()
        utterances.forEach { synthesizer.speak($0) }
    }
}

extension ReviewSpeaker: @preconcurrency AVSpeechSynthesizerDelegate {}
