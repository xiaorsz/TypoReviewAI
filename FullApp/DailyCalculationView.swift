import SwiftUI
import SwiftData

struct DailyCalculationHomeCard: View {
    @Query(sort: \CalculationRound.createdAt, order: .reverse)
    private var allRounds: [CalculationRound]

    private var todayRounds: [CalculationRound] {
        CalculationSessionService.todayRounds(from: allRounds)
    }

    private var perfectRound: CalculationRound? {
        todayRounds.first(where: \.isPerfect)
    }

    private var firstRound: CalculationRound? {
        todayRounds.first(where: { $0.roundIndex == 0 })
    }

    private var latestRound: CalculationRound? {
        todayRounds.max(by: { $0.roundIndex < $1.roundIndex })
    }

    private var tint: Color {
        if perfectRound != nil { return .green }
        if latestRound?.isSubmitted == true { return .orange }
        return .indigo
    }

    private var statusText: String {
        if let perfectRound {
            let firstAccuracy = firstRound?.accuracyPercent ?? perfectRound.accuracyPercent
            let rounds = perfectRound.roundIndex + 1
            return "已完成 · 首轮正确率 \(firstAccuracy)% · 共 \(rounds) 轮"
        }
        guard let latestRound else {
            return "今天 5 题，全部答完后统一交卷"
        }
        if latestRound.isSubmitted {
            return "第 \(latestRound.roundIndex + 1) 轮有错，继续 3 题补练"
        }
        let answered = latestRound.answers.filter { answer in
            !answer.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        return answered > 0
            ? "第 \(latestRound.roundIndex + 1) 轮已答 \(answered)/\(latestRound.questions.count) 题"
            : "第 \(latestRound.roundIndex + 1) 轮 · \(latestRound.questions.count) 题待完成"
    }

    var body: some View {
        NavigationLink {
            DailyCalculationView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: perfectRound == nil ? "number.square.fill" : "checkmark.seal.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(.white.opacity(0.2), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text("每日计算")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("每日计算，\(statusText)")
    }
}

struct DailyCalculationView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CalculationRound.createdAt)
    private var allRounds: [CalculationRound]

    @State private var selectedRoundID: UUID?
    @State private var answersByQuestionID: [UUID: CalculationAnswer] = [:]
    @State private var errorMessage: String?
    @FocusState private var focusedQuestionID: UUID?

    private var todayRounds: [CalculationRound] {
        CalculationSessionService.todayRounds(from: allRounds)
    }

    private var currentRound: CalculationRound? {
        if let selectedRoundID,
           let selected = todayRounds.first(where: { $0.id == selectedRoundID }) {
            return selected
        }
        return todayRounds.max(by: { $0.roundIndex < $1.roundIndex })
    }

    private var firstRound: CalculationRound? {
        todayRounds.first(where: { $0.roundIndex == 0 })
    }

    var body: some View {
        Group {
            if let round = currentRound {
                roundContent(round)
            } else {
                ProgressView("正在准备今天的计算题…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("每日计算")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CalculationHistoryView()
                } label: {
                    Label("计算记录", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .task {
            prepareTodayIfNeeded()
        }
        .onChange(of: currentRound?.id) { _, _ in
            loadAnswersFromCurrentRound()
        }
        .alert("保存失败", isPresented: errorBinding) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "请稍后再试。")
        }
    }

    @ViewBuilder
    private func roundContent(_ round: CalculationRound) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                roundHeader(round)

                if round.isSubmitted {
                    submittedContent(round)
                } else {
                    questionForm(round)
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func roundHeader(_ round: CalculationRound) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    round.roundIndex == 0 ? "今日首轮" : "第 \(round.roundIndex) 次补练",
                    systemImage: round.roundIndex == 0 ? "flag.fill" : "arrow.triangle.2.circlepath"
                )
                .font(.headline)
                .foregroundStyle(.indigo)

                Spacer()

                Text("\(round.questions.count) 题")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(round.roundIndex == 0
                 ? "先认真算完全部题目，再统一交卷。准确比速度更重要。"
                 : "这些是针对上一轮错误类型生成的新题，争取这一轮全部做对。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .calculationCard()
    }

    private func questionForm(_ round: CalculationRound) -> some View {
        VStack(spacing: 14) {
            ForEach(Array(round.questions.enumerated()), id: \.element.id) { index, question in
                questionInputCard(question, number: index + 1, round: round)
            }

            Button {
                submit(round)
            } label: {
                Label("交卷", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(!canSubmit(round))

            if !canSubmit(round) {
                Text("请先填写所有题目的答案")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func questionInputCard(
        _ question: CalculationQuestion,
        number: Int,
        round: CalculationRound
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 25, height: 25)
                    .background(kindColor(question.kind), in: Circle())

                Label(question.kind.rawValue, systemImage: question.kind.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(kindColor(question.kind))

                Spacer()
            }

            Text(question.expression)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .minimumScaleFactor(0.72)

            if question.answerMode == .quotientAndRemainder {
                HStack(spacing: 10) {
                    answerField(
                        title: "商",
                        text: answerValueBinding(questionID: question.id, round: round),
                        questionID: question.id
                    )
                    answerField(
                        title: "余数",
                        text: answerRemainderBinding(questionID: question.id, round: round),
                        questionID: question.id
                    )
                }
            } else {
                answerField(
                    title: "答案",
                    text: answerValueBinding(questionID: question.id, round: round),
                    questionID: question.id
                )
            }
        }
        .calculationCard()
    }

    private func answerField(
        title: String,
        text: Binding<String>,
        questionID: UUID
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("请输入", text: text)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .focused($focusedQuestionID, equals: questionID)
        }
        .frame(maxWidth: .infinity)
    }

    private func submittedContent(_ round: CalculationRound) -> some View {
        VStack(spacing: 16) {
            resultSummary(round)

            let answers = Dictionary(uniqueKeysWithValues: round.answers.map { ($0.questionID, $0) })
            ForEach(Array(round.questions.enumerated()), id: \.element.id) { index, question in
                submittedQuestionCard(
                    question,
                    answer: answers[question.id],
                    number: index + 1
                )
            }

            if round.isPerfect {
                completionCard(round)
            } else {
                Button {
                    createRetry(after: round)
                } label: {
                    Label("再练 3 题", systemImage: "arrow.clockwise.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
    }

    private func resultSummary(_ round: CalculationRound) -> some View {
        HStack(spacing: 14) {
            Image(systemName: round.isPerfect ? "checkmark.seal.fill" : "chart.bar.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(round.isPerfect ? .green : .orange)
                .frame(width: 54, height: 54)
                .background((round.isPerfect ? Color.green : Color.orange).opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(round.isPerfect ? "这一轮全部正确" : "本轮答对 \(round.correctCount)/\(round.questions.count)")
                    .font(.title3.weight(.bold))
                Text("正确率 \(round.accuracyPercent)% · 用时 \(durationText(round.durationSeconds))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .calculationCard()
    }

    private func submittedQuestionCard(
        _ question: CalculationQuestion,
        answer: CalculationAnswer?,
        number: Int
    ) -> some View {
        let isCorrect = answer?.isCorrect == true
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(number). \(question.expression)")
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isCorrect ? .green : .red)
                    .font(.title3)
            }

            Text("你的答案：\(submittedAnswerText(answer, question: question))")
                .font(.subheadline)
                .foregroundStyle(isCorrect ? .green : .red)

            if !isCorrect {
                Divider()
                Text("正确答案：\(question.standardAnswerText)")
                    .font(.subheadline.weight(.semibold))
                Label(question.hint, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .calculationCard(borderColor: isCorrect ? .green : .red)
    }

    private func completionCard(_ round: CalculationRound) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
            Text("今天的计算练习完成了")
                .font(.title3.weight(.bold))
            Text("首轮正确率 \(firstRound?.accuracyPercent ?? round.accuracyPercent)% · 共完成 \(round.roundIndex + 1) 轮")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("获得 +\(CalculationSessionService.completionRewardAmount) 积分")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .calculationCard()
    }

    private func prepareTodayIfNeeded() {
        do {
            let round = try CalculationSessionService.ensureInitialRound(in: modelContext)
            if selectedRoundID == nil {
                selectedRoundID = todayRounds.max(by: { $0.roundIndex < $1.roundIndex })?.id ?? round.id
            }
            loadAnswersFromCurrentRound()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadAnswersFromCurrentRound() {
        guard let round = currentRound else { return }
        let stored = Dictionary(uniqueKeysWithValues: round.answers.map { ($0.questionID, $0) })
        answersByQuestionID = Dictionary(uniqueKeysWithValues: round.questions.map { question in
            (question.id, stored[question.id] ?? CalculationAnswer(questionID: question.id))
        })
    }

    private func canSubmit(_ round: CalculationRound) -> Bool {
        round.questions.allSatisfy { question in
            guard let answer = answersByQuestionID[question.id] else { return false }
            return CalculationAnswerEvaluator.isComplete(answer, for: question)
        }
    }

    private func submit(_ round: CalculationRound) {
        focusedQuestionID = nil
        let answers = round.questions.compactMap { answersByQuestionID[$0.id] }
        do {
            let judged = try CalculationSessionService.submit(
                answers: answers,
                for: round,
                in: modelContext
            )
            answersByQuestionID = Dictionary(uniqueKeysWithValues: judged.map { ($0.questionID, $0) })
            AppDataChangeCenter.post()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createRetry(after round: CalculationRound) {
        do {
            let retry = try CalculationSessionService.createRetryRound(after: round, in: modelContext)
            selectedRoundID = retry.id
            answersByQuestionID = Dictionary(uniqueKeysWithValues: retry.questions.map {
                ($0.id, CalculationAnswer(questionID: $0.id))
            })
            AppDataChangeCenter.post()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func answerValueBinding(questionID: UUID, round: CalculationRound) -> Binding<String> {
        Binding(
            get: { answersByQuestionID[questionID]?.value ?? "" },
            set: { newValue in
                var answer = answersByQuestionID[questionID] ?? CalculationAnswer(questionID: questionID)
                answer.value = newValue
                answer.isCorrect = nil
                answersByQuestionID[questionID] = answer
                persistDraft(round)
            }
        )
    }

    private func answerRemainderBinding(questionID: UUID, round: CalculationRound) -> Binding<String> {
        Binding(
            get: { answersByQuestionID[questionID]?.remainder ?? "" },
            set: { newValue in
                var answer = answersByQuestionID[questionID] ?? CalculationAnswer(questionID: questionID)
                answer.remainder = newValue
                answer.isCorrect = nil
                answersByQuestionID[questionID] = answer
                persistDraft(round)
            }
        )
    }

    private func persistDraft(_ round: CalculationRound) {
        let answers = round.questions.compactMap { answersByQuestionID[$0.id] }
        CalculationSessionService.saveDraft(answers: answers, for: round, in: modelContext)
    }

    private func submittedAnswerText(_ answer: CalculationAnswer?, question: CalculationQuestion) -> String {
        guard let answer else { return "未填写" }
        if question.answerMode == .quotientAndRemainder {
            return "商 \(answer.value)，余数 \(answer.remainder)"
        }
        return answer.value
    }

    private func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remainder = total % 60
        return minutes > 0 ? "\(minutes)分\(remainder)秒" : "\(remainder)秒"
    }

    private func kindColor(_ kind: CalculationKind) -> Color {
        switch kind {
        case .multiplication: return .blue
        case .division: return .teal
        case .mixed: return .purple
        case .numberSense: return .orange
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

struct CalculationHistoryView: View {
    @Query(sort: \CalculationRound.createdAt, order: .reverse)
    private var rounds: [CalculationRound]

    private var completedDays: [(dayKey: String, rounds: [CalculationRound])] {
        Dictionary(grouping: rounds, by: \.dayKey)
            .map { dayKey, values in
                (dayKey, values.sorted { $0.roundIndex < $1.roundIndex })
            }
            .sorted { $0.dayKey > $1.dayKey }
    }

    var body: some View {
        List {
            if completedDays.isEmpty {
                ContentUnavailableView(
                    "还没有计算记录",
                    systemImage: "number.square",
                    description: Text("完成第一次每日计算后，记录会显示在这里。")
                )
            } else {
                ForEach(completedDays, id: \.dayKey) { day in
                    let submitted = day.rounds.filter(\.isSubmitted)
                    let first = day.rounds.first(where: { $0.roundIndex == 0 })
                    let perfect = day.rounds.first(where: \.isPerfect)
                    HStack(spacing: 12) {
                        Image(systemName: perfect == nil ? "circle.dashed" : "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(perfect == nil ? .orange : .green)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.dayKey)
                                .font(.headline)
                            Text(perfect == nil
                                 ? "尚未完成 · 已提交 \(submitted.count) 轮"
                                 : "首轮正确率 \(first?.accuracyPercent ?? 0)% · 共 \((perfect?.roundIndex ?? 0) + 1) 轮")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("计算记录")
    }
}

private struct CalculationCardModifier: ViewModifier {
    var borderColor: Color?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke((borderColor ?? .primary).opacity(borderColor == nil ? 0.05 : 0.22), lineWidth: 1)
            )
    }
}

private extension View {
    func calculationCard(borderColor: Color? = nil) -> some View {
        modifier(CalculationCardModifier(borderColor: borderColor))
    }
}
