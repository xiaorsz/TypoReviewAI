import SwiftUI
import SwiftData
import AVFoundation
import CoachCore

private struct StudyRoute: Identifiable { let id: UUID }

struct TargetedCoachView: View {
    @Environment(TargetedCoachCoordinator.self) private var targeted
    @Environment(AICoachCoordinator.self) private var coach
    @Environment(\.modelContext) private var context
    @State private var route: StudyRoute?
    @State private var showingHistory = false

    private var subject: Subject { coach.store?.state.configuration.subject ?? .all }
    private var active: CoachingStudyGroup? { targeted.activeGroup(subject: subject) }
    private var words: [String] { active?.targets.map(\.content) ?? targeted.recommendations.map { $0.item.content } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("词语小课堂").font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(WordLessonPalette.accent)
                        Text("和词语\n交个朋友")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold)).lineSpacing(3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    WordLessonBook()
                }
                .padding(.top, 12)
                Text("每组推荐 5 个重点词，学完还可以再学 5 个。")
                    .font(.subheadline).foregroundStyle(WordLessonPalette.muted).lineSpacing(4)
                recommendationCard
                Button { showingHistory = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "books.vertical").font(.title3).foregroundStyle(WordLessonPalette.accent)
                            .frame(width: 46, height: 46).background(WordLessonPalette.soft, in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("学习记录").font(.system(.headline, design: .rounded))
                            Text("翻翻学过的词，看看之后的表现").font(.caption).foregroundStyle(WordLessonPalette.muted)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right").font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("学习记录")
                DisclosureGroup("为什么推荐这些词？") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("当前范围：\(subject.title)。从近 30 天至少错 3 次、跨 2 天的记录中推荐；同一天不重复推荐，数量不足时按实际展示。")
                        Text("屏幕输入只说明这次练习的表现，不代表实际书写。之后的正常复习和听写会帮助观察是否有改善。")
                        Text("补练记录仅保存在本实验版当前设备，暂不随 iCloud 或备份同步。")
                    }.font(.caption).lineSpacing(4).padding(.top, 10)
                }
                .font(.subheadline).foregroundStyle(WordLessonPalette.muted).tint(WordLessonPalette.muted)
            }
            .padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(WordLessonPalette.background.ignoresSafeArea())
        .foregroundStyle(WordLessonPalette.ink).tint(WordLessonPalette.accent)
        .navigationTitle("AI 词语讲解").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(WordLessonPalette.background, for: .navigationBar)
        .task { await refresh() }.refreshable { await refresh() }
        .navigationDestination(isPresented: $showingHistory) { WordLearningHistoryView() }
        .fullScreenCover(item: $route) { WordStudyGroupView(groupID: $0.id, onClose: { route = nil }) }
    }

    private var recommendationCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(active == nil ? "这一组，认识它们" : "接着上次的小课堂")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                Spacer(minLength: 8)
                Text(subject.title).font(.caption).foregroundStyle(WordLessonPalette.muted)
            }
            if targeted.isLoading {
                ProgressView("正在找值得再学的词…").tint(WordLessonPalette.accent)
            } else if !words.isEmpty {
                WordLessonFlow {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        WordLessonTag(text: word).rotationEffect(.degrees(index.isMultiple(of: 2) ? -1.5 : 1))
                    }
                }.accessibilityIdentifier("targeted.recommendations")
                if let active {
                    let finished = active.targets.count - (active.targets.filter { target in
                        !target.skipped && !(targeted.state?.interventions.contains { $0.id == target.interventionID && $0.completedAt != nil } ?? false)
                    }.count)
                    Text("已走过 \(finished) / \(active.targets.count) 个词，继续就好。")
                        .font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                } else if words.count < 5 {
                    Text("这次有 \(words.count) 个值得再学的词，慢慢来。")
                        .font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                }
                Button {
                    if let active { route = StudyRoute(id: active.id) } else { start() }
                } label: {
                    WordLessonActionLabel(title: active != nil ? "继续学习" : (targeted.state?.groups.isEmpty == false ? "再学 5 个" : "开始学习"))
                }
                .buttonStyle(WordLessonButtonStyle()).disabled(targeted.isLoading)
                .accessibilityIdentifier("targeted.start")
            } else {
                Image(systemName: "leaf").font(.largeTitle).foregroundStyle(WordLessonPalette.accent)
                Text(targeted.findings.isEmpty ? "暂时没有需要重点学习的反复错词。继续正常听写和复习就好。" : "今天的新词已学完，之后有新的反复错词再来看看。")
                    .font(.body).foregroundStyle(WordLessonPalette.muted).lineSpacing(5)
            }
            if let error = targeted.error { Text(error).font(.subheadline).foregroundStyle(WordLessonPalette.muted) }
        }.modifier(WordLessonSurface())
    }
    private func refresh() async {
        guard let store = coach.store else { return }
        await targeted.refresh(context: context, datasetID: store.state.datasetID, subject: subject)
        #if DEBUG
        targeted.seedRichLessonForUITesting()
        #endif
    }
    private func start() {
        Task { if let id = await targeted.startGroup(context: context, coach: coach) { route = StudyRoute(id: id) } }
    }
}

private struct WordStudyGroupView: View {
    @Environment(TargetedCoachCoordinator.self) private var targeted
    @Environment(AICoachCoordinator.self) private var coach
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speech = WordLessonSpeech()
    let groupID: UUID
    let onClose: () -> Void
    @State private var nextGroupID: UUID?
    private var currentGroupID: UUID { nextGroupID ?? groupID }
    @State private var index = 0
    @State private var initialized = false
    private enum LearningPage { case lesson, quiz, result }
    @State private var page: LearningPage = .lesson
    @State private var returningToWord: UUID?
    @State private var drafts: [UUID: String] = [:]
    @State private var revisitedAnswers: Set<UUID> = []
    @State private var usingBasic = false
    @State private var response = ""
    @State private var localError: String?
    @FocusState private var inputFocused: Bool

    private var group: CoachingStudyGroup? { targeted.state?.groups.first { $0.id == currentGroupID } }
    private var target: CoachingStudyTarget? {
        guard let group, group.targets.indices.contains(index) else { return nil }
        return group.targets[index]
    }
    private var intervention: CoachingIntervention? { targeted.state?.interventions.first { $0.id == target?.interventionID } }
    private var busy: Bool { targeted.isLoading || targeted.isSaving || targeted.isGenerating }
    private var validIntervention: CoachingIntervention? {
        guard let intervention, targeted.report(for: intervention).state != .invalidated else { return nil }
        return intervention
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if initialized, let group {
                        if let target {
                            progress(group)
                            if let intervention {
                                if targeted.report(for: intervention).state == .invalidated {
                                    unavailable("这个词的原题或记录变了，先跳过它吧。")
                                } else if page == .result, let attempt = intervention.attempts.first {
                                    result(intervention, correct: attempt.correct)
                                } else if page == .quiz, let exercise = intervention.exercises.first {
                                    quiz(exercise)
                                } else if let lesson = intervention.lesson {
                                    lessonPage(target, intervention: intervention, lesson: lesson)
                                }
                            } else if targeted.isGenerating {
                                VStack(alignment: .leading, spacing: 22) {
                                    WordLessonBook()
                                    Text("把这个词，讲明白一点。")
                                        .font(.system(.title2, design: .rounded, weight: .bold))
                                    ProgressView("正在准备这个词的讲解…").tint(WordLessonPalette.accent)
                                    Button("停止准备") { targeted.cancel() }.font(.subheadline)
                                }.modifier(WordLessonSurface())
                            } else {
                                unavailable(targeted.error ?? "这一词还没准备好，稍后再试试吧。")
                            }
                            if let localError { Text(localError).font(.subheadline).foregroundStyle(WordLessonPalette.muted) }
                        } else { summary(group) }
                    } else { ProgressView().tint(WordLessonPalette.accent) }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
                .frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
                .disabled(targeted.isLoading || targeted.isSaving)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: index)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(WordLessonPalette.background.ignoresSafeArea())
            .foregroundStyle(WordLessonPalette.ink).tint(WordLessonPalette.accent)
            .safeAreaInset(edge: .bottom) { bottomAction }
            .navigationTitle("词语学习").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(WordLessonPalette.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回", systemImage: "chevron.left") { goBack() }
                        .accessibilityIdentifier("targeted.back").disabled(targeted.isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("稍后继续", systemImage: "xmark") { exitLearning() }
                        .labelStyle(.iconOnly).accessibilityLabel("稍后继续")
                        .accessibilityIdentifier("targeted.close").disabled(targeted.isSaving)
                }
                if target != nil, intervention?.lesson != nil, page == .lesson, intervention?.attempts.isEmpty == true {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("讲解有问题，跳过这个词", systemImage: "forward") { skip() }
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("更多学习操作").disabled(busy)
                    }
                }
            }
            .task {
                guard !initialized, let group else { return }
                index = group.firstUnfinished(in: targeted.state?.interventions ?? []) ?? group.targets.count
                usingBasic = group.usesBasic == true; initialized = true
            }
            .task(id: initialized ? target?.id : nil) {
                guard initialized, let target else { return }
                speech.stop()
                response = drafts[target.id] ?? ""; localError = nil; inputFocused = false
                if returningToWord == target.id { page = .lesson; returningToWord = nil }
                else if intervention?.attempts.isEmpty == false { page = .result }
                else { page = intervention?.approvedAt != nil ? .quiz : .lesson }
                if target.interventionID == nil {
                    await targeted.prepareLesson(groupID: currentGroupID, targetID: target.id, basic: usingBasic, context: context, coach: coach)
                }
            }
            .onChange(of: page) { _, _ in speech.stop() }
            .onChange(of: validIntervention?.id) { _, _ in speech.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { speech.stop() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { _ in speech.stop() }
            .onDisappear { speech.stop(); targeted.cancel() }
        }
    }

    private func progress(_ group: CoachingStudyGroup) -> some View {
        HStack(spacing: 12) {
            Text("第 \(index + 1) / \(group.targets.count) 个词")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .monospacedDigit().foregroundStyle(WordLessonPalette.muted)
                .fixedSize(horizontal: true, vertical: true)
            if page != .quiz, intervention?.lesson != nil {
                WordLessonSpeechStatus(speech: speech)
            } else {
                Spacer(minLength: 0)
                Text(page == .quiz ? "小小挑战" : "词语学习").font(.caption).foregroundStyle(WordLessonPalette.muted)
            }
        }.frame(minHeight: 44)
    }

    private func lessonPage(_ target: CoachingStudyTarget, intervention: CoachingIntervention, lesson: CoachingWordLesson) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(intervention.isAIGenerated ? "AI 讲解" : "题库／词典基础讲解")
                    .font(.caption2).foregroundStyle(WordLessonPalette.muted)
                HStack(spacing: 4) {
                    Text(target.content).font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .minimumScaleFactor(0.7).textSelection(.enabled)
                        .accessibilityIdentifier("targeted.word")
                    WordLessonReadButton(speech: speech, key: intervention.id.uuidString + ".word",
                        title: target.type == "单词" ? "单词" : "词语", text: target.content,
                        language: .forItem(type: target.type), identifier: "targeted.speech.word")
                    Spacer(minLength: 0)
                }
            }
            WordLessonExplanation(meaning: lesson.meaning, structure: lesson.structure, example: lesson.example, translation: lesson.exampleTranslation,
                speech: speech, speechScope: intervention.id.uuidString, speechLanguage: .forItem(type: intervention.type))
        }.modifier(WordLessonSurface())
    }

    private func quiz(_ exercise: CoachingExercise) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "pencil.and.scribble").font(.largeTitle).foregroundStyle(WordLessonPalette.accent).accessibilityHidden(true)
            Text("轮到你啦").font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text(exercise.prompt).font(.title3).lineSpacing(6)
            TextField("输入完整词语", text: $response)
                .font(.system(.title2, design: .rounded, weight: .medium))
                .padding(18).background(WordLessonPalette.soft.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(inputFocused ? WordLessonPalette.accent : WordLessonPalette.line, lineWidth: inputFocused ? 2 : 1))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($inputFocused).submitLabel(.done).accessibilityIdentifier("targeted.answer")
                .onSubmit { if let intervention { submit(intervention) } }
            Text(target?.type == "单词" ? "完整写出单词，也留意一下大小写。" : "想一想，写出刚才认识的那个词。")
                .font(.subheadline).foregroundStyle(WordLessonPalette.muted)
        }.modifier(WordLessonSurface())
    }

    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "cloud").font(.largeTitle).foregroundStyle(WordLessonPalette.muted).accessibilityHidden(true)
            Text("稍等一下，也没关系").font(.system(.title2, design: .rounded, weight: .bold))
            Text(message).font(.subheadline).lineSpacing(4).foregroundStyle(WordLessonPalette.muted)
            if intervention == nil {
                Button { prepare(basic: false) } label: { WordLessonActionLabel(title: "重新准备 AI 讲解", symbol: "arrow.clockwise") }
                    .buttonStyle(WordLessonButtonStyle()).disabled(busy)
                Button("使用基础讲解") { prepare(basic: true) }.font(.headline).accessibilityIdentifier("targeted.basic").disabled(busy)
                NavigationLink("首次 AI 配置") { AICoachView() }.font(.caption)
            }
            Button("先跳过这个词") { skip() }.font(.subheadline).disabled(busy)
        }.modifier(WordLessonSurface())
    }

    @ViewBuilder private var bottomAction: some View {
        if target != nil, let entry = validIntervention {
            VStack(spacing: 0) {
                if entry.attempts.isEmpty {
                    if page == .quiz {
                        Button { submit(entry) } label: { WordLessonActionLabel(title: "提交答案", symbol: "checkmark") }
                            .buttonStyle(WordLessonButtonStyle())
                            .disabled(busy || response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("targeted.submit")
                    } else {
                        Button {
                            Task {
                                do { try await targeted.startLesson(entry.id, context: context); page = .quiz }
                                catch { localError = error.localizedDescription }
                            }
                        } label: { WordLessonActionLabel(title: "去试一试") }
                        .buttonStyle(WordLessonButtonStyle()).disabled(busy).accessibilityIdentifier("targeted.try")
                    }
                } else if page == .lesson {
                    Button { page = .result } label: { WordLessonActionLabel(title: "查看作答结果") }
                        .buttonStyle(WordLessonButtonStyle()).accessibilityIdentifier("targeted.result")
                } else {
                    Button { next() } label: { WordLessonActionLabel(title: index + 1 < (group?.targets.count ?? 0) ? "下一个词" : "查看本组结果") }
                        .buttonStyle(WordLessonButtonStyle()).disabled(busy).accessibilityIdentifier("targeted.next")
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
            .background(WordLessonPalette.background)
        } else if initialized, target == nil, group != nil {
            VStack(spacing: 10) {
                if !targeted.recommendations.isEmpty {
                    Button {
                        Task {
                            if let id = await targeted.startGroup(context: context, coach: coach) {
                                nextGroupID = id; index = 0; page = .lesson; response = ""; localError = nil
                            }
                        }
                    } label: { WordLessonActionLabel(title: "再学 5 个") }
                    .buttonStyle(WordLessonButtonStyle()).disabled(busy).accessibilityIdentifier("targeted.more")
                }
                Button("今天先到这里") { exitLearning() }.font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("完成").accessibilityIdentifier("targeted.finish")
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
            .background(WordLessonPalette.background)
        }
    }

    private func prepare(basic: Bool) {
        guard let target else { return }
        usingBasic = basic
        Task { await targeted.prepareLesson(groupID: currentGroupID, targetID: target.id, basic: basic, context: context, coach: coach) }
    }
    private func skip() {
        speech.stop()
        guard let target else { return }
        do { try targeted.skipTarget(groupID: currentGroupID, targetID: target.id); next() }
        catch { localError = error.localizedDescription }
    }
    private func next() {
        speech.stop()
        if let target { drafts[target.id] = response }
        inputFocused = false; page = .lesson; localError = nil; index += 1
    }
    private func exitLearning() {
        speech.stop()
        inputFocused = false; targeted.cancel(); onClose()
    }
    private func goBack() {
        guard !targeted.isSaving else { return }
        speech.stop()
        inputFocused = false; localError = nil
        if let target { drafts[target.id] = response }
        if page == .quiz {
            if let target { revisitedAnswers.insert(target.id) }
            page = .lesson
        } else if page == .result {
            page = .lesson
        } else if let group, let previous = group.targets.indices.reversed().first(where: { position in
            position < index && !group.targets[position].skipped
                && targeted.state?.interventions.contains(where: { $0.id == group.targets[position].interventionID && $0.lesson != nil }) == true
        }) {
            targeted.cancel()
            returningToWord = group.targets[previous].id; page = .lesson; index = previous
        } else { exitLearning() }
    }
    private func submit(_ intervention: CoachingIntervention) {
        guard !busy, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let exercise = intervention.exercises.first else { return }
        let answer = response
        let revealed = target.map { revisitedAnswers.contains($0.id) } ?? false
        inputFocused = false
        Task {
            do {
                try await targeted.answer(intervention.id, exerciseID: exercise.id, response: answer, parentJudgment: nil, revealed: revealed, context: context)
                localError = nil; page = .result
            } catch { localError = error.localizedDescription }
        }
    }

    private func result(_ intervention: CoachingIntervention, correct: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Image(systemName: correct ? "sparkles" : "leaf").font(.largeTitle).foregroundStyle(WordLessonPalette.accent)
                Spacer()
                Text(correct ? "又前进一小步" : "慢慢记，也可以").font(.caption).foregroundStyle(WordLessonPalette.muted)
            }.accessibilityElement(children: .combine)
            Text(correct ? "答对了！" : "再记一记这个词")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            VStack(alignment: .leading, spacing: 10) {
                Text("正确答案").font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                HStack(spacing: 4) {
                    Text(intervention.content).font(.system(.largeTitle, design: .rounded, weight: .bold))
                    WordLessonReadButton(speech: speech, key: intervention.id.uuidString + ".word",
                        title: intervention.type == "单词" ? "单词" : "词语", text: intervention.content,
                        language: .forItem(type: intervention.type), identifier: "targeted.speech.word")
                    Spacer(minLength: 0)
                }
                if !correct, let attempt = intervention.attempts.first {
                    Text("你刚才写的是：\(attempt.response)").font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(WordLessonPalette.soft, in: RoundedRectangle(cornerRadius: 20))
            if let lesson = intervention.lesson {
                Text(lesson.meaning).font(.title3).lineSpacing(5)
                if !lesson.structure.isEmpty { Text(lesson.structure).font(.body).lineSpacing(5).foregroundStyle(WordLessonPalette.muted) }
            }
        }.modifier(WordLessonSurface())
    }

    private func summary(_ group: CoachingStudyGroup) -> some View {
        let completed = group.targets.compactMap { target in targeted.state?.interventions.first { $0.id == target.interventionID && $0.completedAt != nil } }
        let correct = completed.filter { $0.attempts.first?.correct == true }.count
        return VStack(alignment: .leading, spacing: 28) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("小课堂 · 告一段落").font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                    Text("这一组学完了").font(.system(.largeTitle, design: .rounded, weight: .bold))
                }
                Spacer(minLength: 0)
                WordLessonBook(celebrating: true).scaleEffect(0.8).frame(width: 92)
            }
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(completed.count)").font(.system(size: 64, weight: .bold, design: .rounded)).foregroundStyle(WordLessonPalette.accent)
                    Text("个词，一点点记住").font(.system(.headline, design: .rounded))
                }
                Text("完成 \(completed.count) 个词，本次答对 \(correct) 个。").font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                WordLessonFlow {
                    ForEach(completed) { entry in WordLessonTag(text: entry.content, marked: entry.attempts.first?.correct == true) }
                }
                if group.targets.contains(where: \.skipped) {
                    Text("跳过 \(group.targets.filter(\.skipped).count) 个词。").font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                }
            }.modifier(WordLessonSurface())
            Text("接下来正常听写和复习就好，之后的表现会记录在「学习记录」里。")
                .font(.subheadline).lineSpacing(5).foregroundStyle(WordLessonPalette.muted)
            if targeted.recommendations.isEmpty {
                Text("今天没有更多新词了，休息一下吧。").font(.subheadline).foregroundStyle(WordLessonPalette.muted)
            }
        }
    }
}

private struct WordLearningHistoryView: View {
    @Environment(TargetedCoachCoordinator.self) private var targeted
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("翻翻学过的词").font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("这里记着每次的小进步，也会继续观察之后的听写和复习。")
                    .font(.subheadline).foregroundStyle(WordLessonPalette.muted).lineSpacing(4)
                if targeted.state?.interventions.isEmpty != false {
                    Text("学完词语后，可以在这里查看记录。").foregroundStyle(WordLessonPalette.muted)
                        .modifier(WordLessonSurface())
                }
                LazyVStack(spacing: 12) {
                    ForEach((targeted.state?.interventions ?? []).reversed()) { entry in
                        NavigationLink { WordLearningRecordView(interventionID: entry.id) } label: {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(entry.content).font(.system(.title3, design: .rounded, weight: .bold))
                                    Text(entry.lesson == nil ? "旧版补练记录" : targeted.report(for: entry).state.title)
                                        .font(.caption).foregroundStyle(WordLessonPalette.muted)
                                    Text(entry.createdAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2).foregroundStyle(WordLessonPalette.muted)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right").font(.subheadline).foregroundStyle(WordLessonPalette.accent)
                            }.modifier(WordLessonSurface())
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(WordLessonPalette.background.ignoresSafeArea()).foregroundStyle(WordLessonPalette.ink).tint(WordLessonPalette.accent)
        .navigationTitle("学习记录").navigationBarTitleDisplayMode(.inline)
    }
}

private struct WordLearningRecordView: View {
    @Environment(TargetedCoachCoordinator.self) private var targeted
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speech = WordLessonSpeech()
    let interventionID: UUID
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let entry = targeted.state?.interventions.first(where: { $0.id == interventionID }) {
                    HStack(spacing: 4) {
                        Text(entry.content).font(.system(.largeTitle, design: .rounded, weight: .bold))
                        WordLessonReadButton(speech: speech, key: entry.id.uuidString + ".word", title: entry.type == "单词" ? "单词" : "词语",
                            text: entry.content, language: .forItem(type: entry.type), identifier: "targeted.speech.word")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        Text(entry.isAIGenerated ? "AI 讲解／补练" : "基础讲解／补练")
                            .font(.caption2).foregroundStyle(WordLessonPalette.muted).fixedSize()
                        WordLessonSpeechStatus(speech: speech)
                    }
                    if let lesson = entry.lesson {
                        WordLessonExplanation(meaning: lesson.meaning, structure: lesson.structure, example: lesson.example, translation: lesson.exampleTranslation,
                            speech: speech, speechScope: entry.id.uuidString, speechLanguage: .forItem(type: entry.type))
                            .modifier(WordLessonSurface())
                    } else { Text(entry.strategy).modifier(WordLessonSurface()) }
                    Text("本次完成 \(entry.attempts.count)/\(entry.exercises.count) 题，答对 \(entry.attempts.filter(\.correct).count) 题。")
                        .font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("之后的表现").font(.system(.headline, design: .rounded))
                        let report = targeted.report(for: entry)
                        Text(report.state.title)
                        if report.evidence.isEmpty {
                            Text("完成后，等待之后不同日期的正常听写或复习，不额外加题。")
                                .font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                        }
                        ForEach(report.evidence) { CoachingEvidenceRow(evidence: $0) }
                    }.modifier(WordLessonSurface(tint: WordLessonPalette.soft))
                    DisclosureGroup("推荐依据") { ForEach(entry.baseline.reversed()) { CoachingEvidenceRow(evidence: $0) } }
                        .font(.subheadline).foregroundStyle(WordLessonPalette.muted)
                }
            }.padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(WordLessonPalette.background.ignoresSafeArea()).foregroundStyle(WordLessonPalette.ink).tint(WordLessonPalette.accent)
        .navigationTitle("学习详情").navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in if phase != .active { speech.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { _ in speech.stop() }
        .onDisappear { speech.stop() }
    }
}

private struct CoachingEvidenceRow: View {
    let evidence: CoachingEvidence
    var body: some View {
        HStack(spacing: 12) {
            Text(evidence.date.formatted(date: .abbreviated, time: .omitted))
            Spacer(minLength: 4)
            Text(evidence.mode == "dictation" ? "听写" : (evidence.mode == "retry" ? "重练" : "复习"))
            Text(evidence.correct ? "正确" : "错误").fontWeight(.medium)
        }.font(.caption).foregroundStyle(WordLessonPalette.muted).padding(.vertical, 4)
    }
}
