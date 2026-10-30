import SwiftUI
import SwiftData

struct BatchReviewEntryState: Identifiable {
    let item: ReviewItem
    var result: DictationResult
    var id: PersistentIdentifier { item.persistentModelID }
}

private struct SessionReviewSummary: Identifiable {
    let id = UUID()
    let content: String
    let result: ReviewResult
    let detail: String
}

struct BatchReviewGradingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettingsStore.self) private var settings

    let items: [ReviewItem]
    var onReturnFromCompletion: (() -> Void)? = nil
    /// 判卷提交成功（保存落盘）后回调，用于清理听写进度等收尾工作。
    var onSubmittedSuccessfully: (() -> Void)? = nil

    @State private var entryStates: [BatchReviewEntryState] = []
    @State private var isSubmitted = false
    @State private var reviewedSummaries: [SessionReviewSummary] = []
    @State private var reviewSessionID = UUID()
    @State private var accuracyBonusAmount = 0
    @State private var saveErrorMessage: String?
    @State private var skippedSyncedCount = 0
    @State private var isSubmitting = false
    
    private let scheduler = ReviewScheduler()

    init(
        items: [ReviewItem],
        onReturnFromCompletion: (() -> Void)? = nil,
        onSubmittedSuccessfully: (() -> Void)? = nil
    ) {
        self.items = items
        self.onReturnFromCompletion = onReturnFromCompletion
        self.onSubmittedSuccessfully = onSubmittedSuccessfully
    }

    private var allMarked: Bool {
        !entryStates.isEmpty && entryStates.allSatisfy { $0.result != .pending }
    }
    var body: some View {
        Group {
            if isSubmitted {
                completionView
            } else {
                gradingView
            }
        }
        .navigationTitle(isSubmitted ? "复习结果" : "统一判卷")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isSubmitted {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("便捷操作", systemImage: "ellipsis.circle") {
                        Button("全部标记为正确", systemImage: "checkmark.circle.fill") {
                            markAll(as: .correct)
                        }
                    }
                }
            }
        }
        .onAppear {
            if entryStates.isEmpty {
                entryStates = items.map { BatchReviewEntryState(item: $0, result: .pending) }
            }
        }
        .alert("提交失败", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {
                saveErrorMessage = nil
            }
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private var gradingView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    reviewStat(title: "总条数", value: "\(entryStates.count)", tint: .blue)
                    reviewStat(title: "未判定", value: "\(entryStates.filter { $0.result == .pending }.count)", tint: allMarked ? .green : .orange)
                    reviewStat(title: "已判定", value: "\(entryStates.filter { $0.result != .pending }.count)", tint: .mint)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                VStack(spacing: 10) {
                    ForEach(entryStates.indices, id: \.self) { index in
                        let state = $entryStates[index]
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.blue)
                                    .frame(width: 20, height: 20)
                                    .background(Color.blue.opacity(0.1), in: Circle())

                                TypeBadge(type: state.wrappedValue.item.type)
                                
                                Spacer()
                                
                                Text(resultText(for: state.wrappedValue.result))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(statusColor(for: state.wrappedValue.result))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(statusColor(for: state.wrappedValue.result).opacity(0.1), in: Capsule())
                            }

                            let gradingLayout = state.wrappedValue.item.type.isRecitation
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                : AnyLayout(HStackLayout(spacing: 12))
                            gradingLayout {
                                Text(state.wrappedValue.item.content)
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                                HStack(spacing: 8) {
                                    Button {
                                        state.wrappedValue.result = (state.wrappedValue.result == .correct) ? .pending : .correct
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: state.wrappedValue.result == .correct ? "checkmark.circle.fill" : "checkmark.circle")
                                            Text(state.wrappedValue.item.type.isRecitation ? "背出来了" : "正确")
                                        }
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(state.wrappedValue.result == .correct ? .white : .green)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(state.wrappedValue.result == .correct ? Color.green : Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        state.wrappedValue.result = (state.wrappedValue.result == .wrong) ? .pending : .wrong
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: state.wrappedValue.result == .wrong ? "xmark.circle.fill" : "xmark.circle")
                                            Text(state.wrappedValue.item.type.isRecitation ? "没背出来" : "错误")
                                        }
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(state.wrappedValue.result == .wrong ? .white : .red)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(state.wrappedValue.result == .wrong ? Color.red : Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .frame(width: state.wrappedValue.item.type.isRecitation ? nil : 160)
                            }

                            if !state.wrappedValue.item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(state.wrappedValue.item.prompt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(.thinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .strokeBorder(.secondary.opacity(0.1), lineWidth: 1)
                                )
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 16) {
                if !allMarked {
                    Text("还有未判定的项目")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                Button {
                    submitResults()
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isSubmitting ? "正在提交..." : "提交复习结果")
                    }
                }
                .buttonStyle(ResultButtonStyle(color: allMarked ? .blue : .gray))
                .disabled(!allMarked || isSubmitting)
            }
            .padding(20)
            .background(.thinMaterial)
        }
    }

    private func reviewStat(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private func resultText(for result: DictationResult) -> String {
        switch result {
        case .pending:
            return "未判定"
        case .correct:
            return "正确"
        case .wrong:
            return "错误"
        }
    }

    private func statusColor(for result: DictationResult) -> Color {
        switch result {
        case .pending:
            return .secondary
        case .correct:
            return .green
        case .wrong:
            return .red
        }
    }

    private var completionView: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700
            
            let totalCount = reviewedSummaries.count
            let correctCount = reviewedSummaries.filter { $0.result == .correct }.count
            let wrongCount = totalCount - correctCount
            
            let accuracyText: String = {
                guard totalCount > 0 else { return "--" }
                let accuracy = Int((Double(correctCount) / Double(totalCount) * 100).rounded())
                return "\(accuracy)%"
            }()
            
            let summaryText: String = {
                if totalCount == 0, skippedSyncedCount > 0 {
                    return "这些题的进度已经更新，当前无需重复复习。"
                }
                if wrongCount == 0 {
                    return "这次复习全部答对，系统已经自动安排到下一次复习日期。"
                }
                return "这次一共完成 \(totalCount) 题，其中答错 \(wrongCount) 题。答错的内容会安排到之后的日期，今天不会重复出现。"
            }()

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

                        if skippedSyncedCount > 0, totalCount > 0 {
                            Text("另有 \(skippedSyncedCount) 题的进度已更新，本次无需重复复习。")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
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
                        StatGridCard(icon: "checkmark.seal", title: "完成", value: "\(totalCount)", tint: .blue)
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

                    if !reviewedSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("判定详情")
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

                    Button("返回首页") {
                        dismiss()
                        DispatchQueue.main.async {
                            onReturnFromCompletion?()
                        }
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                }
                .padding(isWide ? 32 : 20)
            }
            .navigationBarBackButtonHidden(true)
        }
    }

    private func markAll(as result: DictationResult) {
        for index in entryStates.indices {
            entryStates[index].result = result
        }
    }

    private func submitResults() {
        guard !isSubmitting else { return }
        isSubmitting = true

        var summaries: [SessionReviewSummary] = []
        var submittedRecordIDs: [UUID] = []
        let now = Date()
        let submittedStates = entryStates.filter { $0.result != .pending }
        let eligibleStates: [BatchReviewEntryState]

        do {
            _ = try ReviewScheduler.reconcileStandardReviewProgress(in: modelContext)
            let eligibleIDs = try DailyReviewPlanner.eligibleIDs(in: modelContext, dailyLimit: settings.dailyLimit, now: now)
            var seen = Set<String>()
            eligibleStates = submittedStates.filter { state in
                // ReviewItem is the source of truth for whether work is still due. A
                // matching record can arrive first or survive an interrupted save; it
                // must not make a due answer disappear from this submission.
                ReviewScheduler.isDue(state.item.nextReviewAt, on: now)
                    && eligibleIDs.contains(state.item.id)
                    && seen.insert(ReviewContentIdentity.key(for: state.item)).inserted
            }
        } catch {
            saveErrorMessage = "提交前同步校验失败，请稍后再试一次。\(error.localizedDescription)"
            isSubmitting = false
            return
        }

        skippedSyncedCount = submittedStates.count - eligibleStates.count
        let totalCount = eligibleStates.count
        let correctCount = eligibleStates.filter { $0.result == .correct }.count
        let earnedAccuracyBonusAmount = PointLedgerService.accuracyBonusAmount(
            correctCount: correctCount,
            totalCount: totalCount
        )
        
        for state in eligibleStates {
            let reviewResult: ReviewResult = state.result == .correct ? .correct : .wrong

            let oldTrack = state.item.reviewTrack
            let oldFollowUpStep = state.item.resolvedDictationFollowUpStep
            let output = scheduler.handle(item: state.item, result: reviewResult, now: now)
            let detail = state.item.reviewTransitionDetail(
                result: reviewResult,
                oldStage: output.record.oldStage,
                oldTrack: oldTrack,
                oldFollowUpStep: oldFollowUpStep
            )
            output.record.note = ReviewRecord.storedConfirmedDetailText(detail)
            let persistedRecord = ReviewScheduler.upsertReviewRecord(
                output.record,
                in: modelContext
            ).record
            submittedRecordIDs.append(persistedRecord.id)
            PointLedgerService.awardReviewRecord(persistedRecord, in: modelContext)

            summaries.append(
                SessionReviewSummary(
                    content: state.item.content,
                    result: reviewResult,
                    detail: detail
                )
            )
        }

        if totalCount > 0 {
            PointLedgerService.awardReviewAccuracyBonus(
                sessionID: reviewSessionID,
                correctCount: correctCount,
                totalCount: totalCount,
                in: modelContext
            )
        }
        
        do {
            try modelContext.save()
            AppDataChangeCenter.post()
            // 提交成功后才清理听写进度；若进入判卷但未提交就退出，进度保留可继续。
            onSubmittedSuccessfully?()
        } catch {
            // 保存失败时整体 rollback：撤销本次提交推进的阶段、新增/更新的复习记录和积分。
            // 判卷结果保存在 entryStates（值类型）中，rollback 不影响；
            // 重试时重新计算，阶段只推进一级，记录和积分不会重复。
            modelContext.rollback()
            saveErrorMessage = "这次复习结果没有保存成功，请再试一次。\(error.localizedDescription)"
            isSubmitting = false
            return
        }

        self.reviewedSummaries = summaries
        if !submittedRecordIDs.isEmpty {
            AICoachSignals.post("review", id: reviewSessionID, itemIDs: eligibleStates.map { $0.item.id }, recordIDs: submittedRecordIDs)
        }
        self.accuracyBonusAmount = earnedAccuracyBonusAmount
        
        withAnimation {
            isSubmitted = true
        }
    }
}
