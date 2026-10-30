import Foundation
import SwiftData
import Observation
import CoachCore

/// Supplemental work is metadata, never formal grades, points or a second daily plan.
@MainActor @Observable final class TargetedCoachCoordinator {
    private(set) var state: TargetedCoachingState?
    private(set) var findings: [RepeatedErrorFinding] = []
    private(set) var recommendations: [RepeatedErrorFinding] = []
    private(set) var isLoading = false
    private(set) var isGenerating = false
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var notice: String?
    private var source: CoachNativeSnapshot?
    private var revision = UUID()
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    private var generationTaskID: UUID?
    private let fileURL: URL
    private let transport: any ChatTransport
    var hasLoaded: Bool { state != nil }

    init(fileURL: URL? = nil, transport: any ChatTransport = DeepSeekTransport(planningToolsEnabled: false)) {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("cc.xiaorsz.dictation-coach-lab/targeted-coach.json")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("targeted-ui-\(UUID()).json")
        }
        #endif
        self.fileURL = fileURL ?? url; self.transport = transport
    }

    func cancel() {
        scheduledRefresh?.cancel(); scheduledRefresh = nil
        generationTask?.cancel(); generationTask = nil; generationTaskID = nil
        revision = UUID(); isLoading = false; isGenerating = false; isSaving = false
    }

    func refresh(context: ModelContext, datasetID: UUID, subject: Subject, now: Date = .now) async {
        guard !isGenerating, !isSaving else { return }
        let token = UUID(); revision = token; isLoading = true; error = nil
        defer { if revision == token { isLoading = false } }
        let container = context.container, url = fileURL
        let needsLoad = state == nil || state?.datasetID != datasetID
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let snapshot = try CoachNativeSnapshot.load(from: container, canonicalRecords: true)
                var loaded: TargetedCoachingState?
                if needsLoad {
                    if FileManager.default.fileExists(atPath: url.path) {
                        let saved = try TargetedCoachingState.decoder().decode(TargetedCoachingState.self, from: Data(contentsOf: url))
                        guard saved.schemaVersion == 2 else { throw LabError.invalid("补练记录版本不支持，原文件已保留。") }
                        loaded = saved.datasetID == datasetID ? saved : TargetedCoachingState(datasetID: datasetID)
                    } else { loaded = TargetedCoachingState(datasetID: datasetID) }
                }
                let findings = TargetedCoaching.findings(items: snapshot.items, records: snapshot.records, subject: subject, now: now)
                return (snapshot, loaded, findings)
            }.value
            guard revision == token, !Task.isCancelled else { return }
            if let loaded = result.1 { try persist(loaded) }
            source = result.0; findings = result.2
            recommendations = recommendations(now: now)
        } catch {
            if revision == token { self.error = "读取补练记录失败：" + error.localizedDescription }
        }
    }

    func dataChanged(action: String, context: ModelContext, datasetID: UUID, subject: Subject) {
        cancel()
        if action == "restore" {
            source = nil; findings = []; recommendations = []
            do { try persist(TargetedCoachingState(datasetID: datasetID)) }
            catch { self.error = "补练记录重置失败：" + error.localizedDescription }
        }
        guard hasLoaded else { return }
        scheduledRefresh = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await refresh(context: context, datasetID: datasetID, subject: subject)
        }
    }

    func report(for intervention: CoachingIntervention, now: Date = .now) -> CoachingVerificationReport {
        guard let source else { return .init(state: .invalidated, evidence: []) }
        return TargetedCoaching.verification(intervention, items: source.items, records: source.records, now: now)
    }

    func existing(for finding: RepeatedErrorFinding, now: Date = .now) -> CoachingIntervention? {
        state?.interventions.last {
            guard $0.identity == finding.item.identity else { return false }
            let phase = report(for: $0, now: now).state
            guard phase != .invalidated else { return false }
            return [.draft, .practicing, .awaiting, .oneCorrect].contains(phase)
                || $0.baseline.contains { $0.id == finding.lastWrongID }
        }
    }

    func generate(findingID: UUID, observation: ParentObservation, mistake: String, context: ModelContext,
                  coach: AICoachCoordinator, apiKey: String? = nil, now: Date = .now) async {
        guard generationTask == nil, !isLoading, !isGenerating, !isSaving else { return }
        let taskID = UUID(); generationTaskID = taskID
        let task = Task { await generateImpl(findingID: findingID, observation: observation, mistake: mistake,
            context: context, coach: coach, apiKey: apiKey, now: now) }
        generationTask = task
        await task.value
        if generationTaskID == taskID { generationTask = nil; generationTaskID = nil }
    }

    private func generateImpl(findingID: UUID, observation: ParentObservation, mistake: String, context: ModelContext,
                              coach: AICoachCoordinator, apiKey: String?, now: Date) async {
        guard !isLoading, !isGenerating, !isSaving, let state, let finding = findings.first(where: { $0.id == findingID }) else { return }
        guard existing(for: finding, now: now) == nil else { notice = "这次错题已有补练，请继续原有记录。"; return }
        guard mistake.count <= 120 else { error = "实际错写请控制在 120 字以内。"; return }
        guard let config = coach.store?.state.configuration, config.isEnabled, config.subject.contains(finding.item.typeRawValue),
              coach.store?.state.datasetID == state.datasetID else {
            error = "请先在 AI 教练中保存授权，并选择包含这道题的科目。"; return
        }
        let token = UUID(); revision = token; isGenerating = true; error = nil; notice = nil
        defer { if revision == token { isGenerating = false } }
        do {
            let key: String
            if let apiKey { key = apiKey }
            else { key = try await Task.detached(priority: .utility) { try LabKeychain.load() }.value }
            guard revision == token, !Task.isCancelled, coach.store?.state.configuration == config,
                  coach.store?.state.datasetID == state.datasetID else { return }
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LabError.invalid("请先保存 DeepSeek API Key；也可选择本地基础补练。") }
            let previous = state.interventions.filter { $0.identity == finding.item.identity && report(for: $0, now: now).state != .invalidated }
                .suffix(3).map { CoachingFollowUpContext(intervention: $0, report: report(for: $0, now: now)) }
            let messages = try TargetedCoaching.messages(finding: finding, observation: observation, mistake: mistake, previous: previous)
            let reply = try await transport.complete(messages: messages, model: config.model, apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
            guard (reply.message.tool_calls ?? []).isEmpty, reply.message.role == "assistant", let text = reply.message.content else {
                throw LabError.invalid("AI 没有返回有效补练题。")
            }
            let draft = try TargetedCoaching.aiDraft(text, finding: finding, observation: observation, mistake: mistake, now: now)
            guard revision == token, !Task.isCancelled, coach.store?.state.configuration == config,
                  coach.store?.state.datasetID == state.datasetID else { return }
            // Read again after the model returns: undo, edits and cloud changes
            // invalidate the response rather than resurrecting an old finding.
            let container = context.container
            let fresh = try await Task.detached { try CoachNativeSnapshot.load(from: container, canonicalRecords: true) }.value
            guard revision == token, !Task.isCancelled, coach.store?.state.configuration == config,
                  coach.store?.state.datasetID == state.datasetID else { return }
            guard TargetedCoaching.sourceIsValid(draft, items: fresh.items, records: fresh.records) else {
                throw LabError.invalid("原题或来源判定已变化，请刷新后再生成。")
            }
            var next = self.state ?? state
            guard !next.interventions.contains(where: { $0.identity == draft.identity && $0.baseline.contains { $0.id == finding.lastWrongID } }) else { return }
            next.interventions.append(draft); try persist(next); source = fresh
            notice = "补练草稿已保存，请家长先核对题干和答案。"
        } catch {
            if revision == token { self.error = "未保存新的 AI 补练：" + error.localizedDescription }
        }
    }

    func createLocal(findingID: UUID, observation: ParentObservation, mistake: String, context: ModelContext, now: Date = .now) async throws {
        guard !isGenerating, !isLoading, !isSaving, let initial = state,
              let finding = findings.first(where: { $0.id == findingID }), existing(for: finding, now: now) == nil else { throw LabError.invalid("请刷新记录或继续已有补练。") }
        guard mistake.count <= 120 else { throw LabError.invalid("实际错写过长。") }
        let token = UUID(); revision = token; isSaving = true
        defer { if revision == token { isSaving = false } }
        let container = context.container
        let fresh = try await Task.detached { try CoachNativeSnapshot.load(from: container, canonicalRecords: true) }.value
        guard revision == token, !Task.isCancelled, var next = state, next.datasetID == initial.datasetID else { throw CancellationError() }
        let draft = TargetedCoaching.localDraft(finding, observation: observation, mistake: mistake, now: now)
        guard TargetedCoaching.sourceIsValid(draft, items: fresh.items, records: fresh.records) else { throw LabError.invalid("来源记录已变化，请刷新。") }
        next.interventions.append(draft); try persist(next); source = fresh; error = nil
        notice = "已保存本地基础补练；这份题目不是 AI 生成。"
    }

    func approve(_ id: UUID, context: ModelContext, now: Date = .now) async throws {
        try await mutate(id, context: context) { $0.approve(now: now) }
    }

    func answer(_ id: UUID, exerciseID: UUID, response: String, parentJudgment: Bool?, revealed: Bool,
                context: ModelContext, now: Date = .now) async throws {
        try await mutate(id, context: context) {
            try $0.answer(exerciseID: exerciseID, response: response, parentJudgment: parentJudgment, revealed: revealed, now: now)
        }
    }

    private func mutate(_ id: UUID, context: ModelContext, operation: (inout CoachingIntervention) throws -> Void) async throws {
        guard !isLoading, !isGenerating, !isSaving, let initial = state else { throw LabError.invalid("补练记录尚未就绪。") }
        let token = UUID(); revision = token; isSaving = true
        defer { if revision == token { isSaving = false } }
        let container = context.container
        let fresh = try await Task.detached { try CoachNativeSnapshot.load(from: container, canonicalRecords: true) }.value
        guard revision == token, !Task.isCancelled, var next = state, next.datasetID == initial.datasetID,
              let index = next.interventions.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        guard TargetedCoaching.sourceIsValid(next.interventions[index], items: fresh.items, records: fresh.records) else {
            source = fresh; throw LabError.invalid("题目或来源判定已撤销／修改，此份补练已停止使用。")
        }
        try operation(&next.interventions[index]); try persist(next); source = fresh
    }

    func recommendations(now: Date) -> [RepeatedErrorFinding] {
        guard let state, let source else { return [] }
        return TargetedCoaching.recommendations(findings: findings, state: state, items: source.items, records: source.records, now: now)
    }

    func activeGroup(subject: Subject) -> CoachingStudyGroup? {
        state?.groups.last { group in
            group.targets.allSatisfy { subject.contains($0.type) }
                && group.firstUnfinished(in: state?.interventions ?? []) != nil
        }
    }

    func startGroup(context: ModelContext, coach: AICoachCoordinator, now: Date = .now) async -> UUID? {
        guard !isLoading, !isGenerating, !isSaving, let store = coach.store else { return nil }
        let datasetID = store.state.datasetID, subject = store.state.configuration.subject
        await refresh(context: context, datasetID: datasetID, subject: subject, now: now)
        guard error == nil, !isLoading, !isGenerating, !isSaving, var next = state,
              coach.store?.state.datasetID == datasetID, coach.store?.state.configuration.subject == subject else { return nil }
        if let existing = activeGroup(subject: subject) { return existing.id }
        let selected = recommendations(now: now)
        guard !selected.isEmpty else { notice = "今天的新词已学完，之后有新的反复错题再来看看。"; return nil }
        let group = CoachingStudyGroup(findings: selected, now: now)
        next.groups.append(group)
        do { try persist(next); recommendations = recommendations(now: now); error = nil; return group.id }
        catch { self.error = "未能保存学习进度：" + error.localizedDescription; return nil }
    }

    func prepareLesson(groupID: UUID, targetID: UUID, basic: Bool = false, context: ModelContext,
                       coach: AICoachCoordinator, apiKey: String? = nil, now: Date = .now) async {
        guard generationTask == nil, !isLoading, !isGenerating, !isSaving else { return }
        let taskID = UUID(); generationTaskID = taskID
        let task = Task { await prepareLessonImpl(groupID: groupID, targetID: targetID, basic: basic,
            context: context, coach: coach, apiKey: apiKey, now: now) }
        generationTask = task
        await task.value
        if generationTaskID == taskID { generationTask = nil; generationTaskID = nil }
    }

    private func prepareLessonImpl(groupID: UUID, targetID: UUID, basic: Bool, context: ModelContext,
                                   coach: AICoachCoordinator, apiKey: String?, now: Date) async {
        guard let initial = state, let group = initial.groups.first(where: { $0.id == groupID }),
              let target = group.targets.first(where: { $0.id == targetID }), !target.skipped, target.interventionID == nil else { return }
        guard let finding = findings.first(where: { $0.id == targetID }), finding.item.identity == target.identity,
              finding.item.content == target.content,
              let config = coach.store?.state.configuration, config.subject.contains(target.type),
              coach.store?.state.datasetID == initial.datasetID else { error = "词语或学习范围已变化，请跳过这一词或返回刷新。"; return }
        guard basic || config.isEnabled else { error = "AI 尚未开启，可使用基础讲解，或到设置请家长完成首次配置。"; return }
        let token = UUID(); revision = token; isGenerating = true; error = nil; notice = nil
        defer { if revision == token { isGenerating = false } }
        do {
            let meaning = await Task.detached(priority: .utility) {
                let hint = finding.item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !hint.isEmpty { return hint }
                return finding.item.typeRawValue == "单词" ? (EnglishGlossService.shared.lookup(text: finding.item.content)?.translation ?? "") : ""
            }.value
            guard revision == token, !Task.isCancelled else { return }
            let draft: CoachingIntervention
            if basic {
                draft = try TargetedCoaching.basicLesson(finding, meaning: meaning, now: now)
            } else {
                let key: String
                if let apiKey { key = apiKey }
                else { key = try await Task.detached(priority: .utility) { try LabKeychain.load() }.value }
                guard revision == token, !Task.isCancelled, coach.store?.state.configuration == config else { return }
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LabError.invalid("AI 还未配置好，可以先用基础讲解。") }
                let previous = initial.interventions.filter { $0.identity == target.identity && report(for: $0, now: now).state != .invalidated }
                    .suffix(3).map { CoachingFollowUpContext(intervention: $0, report: report(for: $0, now: now)) }
                let messages = try TargetedCoaching.lessonMessages(finding: finding, referenceMeaning: meaning, previous: previous)
                let reply = try await transport.complete(messages: messages, model: config.model, apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
                guard reply.message.role == "assistant", (reply.message.tool_calls ?? []).isEmpty, let raw = reply.message.content else {
                    throw LabError.invalid("没有收到有效讲解，请重试。")
                }
                draft = try TargetedCoaching.lessonDraft(raw, finding: finding, now: now)
            }
            guard revision == token, !Task.isCancelled, coach.store?.state.configuration == config,
                  coach.store?.state.datasetID == initial.datasetID else { return }
            let container = context.container
            let fresh = try await Task.detached { try CoachNativeSnapshot.load(from: container, canonicalRecords: true) }.value
            guard revision == token, !Task.isCancelled, coach.store?.state.configuration == config,
                  coach.store?.state.datasetID == initial.datasetID else { return }
            guard TargetedCoaching.sourceIsValid(draft, items: fresh.items, records: fresh.records) else {
                throw LabError.invalid("词语或原判定已变化，请跳过这一词或返回刷新。")
            }
            guard var next = state, let gi = next.groups.firstIndex(where: { $0.id == groupID }),
                  let ti = next.groups[gi].targets.firstIndex(where: { $0.id == targetID }),
                  next.groups[gi].targets[ti].interventionID == nil, !next.groups[gi].targets[ti].skipped else { return }
            next.interventions.append(draft); next.groups[gi].targets[ti].interventionID = draft.id
            next.groups[gi].usesBasic = basic
            try persist(next); source = fresh
        } catch {
            if revision == token { self.error = "这一词暂时没准备好：" + error.localizedDescription }
        }
    }

    func skipTarget(groupID: UUID, targetID: UUID) throws {
        guard !isLoading, !isGenerating, !isSaving, var next = state,
              let gi = next.groups.firstIndex(where: { $0.id == groupID }),
              let ti = next.groups[gi].targets.firstIndex(where: { $0.id == targetID }) else { throw LabError.invalid("请稍后再试。") }
        next.groups[gi].targets[ti].skipped = true
        try persist(next); recommendations = recommendations(now: .now); error = nil
    }

    func startLesson(_ id: UUID, context: ModelContext) async throws {
        try await approve(id, context: context)
    }

    private func persist(_ next: TargetedCoachingState) throws {
        let data = try TargetedCoachingState.encoder().encode(next)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        state = next
    }
}

#if DEBUG
enum TargetedCoachUITestSeed {
    @MainActor static func seed(in context: ModelContext) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"), arguments.contains("--ui-testing-targeted"),
              (try? context.fetchCount(FetchDescriptor<ReviewItem>())) == 0 else { return }
        let now = Date()
        let words = [("辨别", "区分不同的事物"), ("观察", "仔细地看"), ("勇敢", "遇到困难不害怕"),
                     ("整齐", "有次序，不杂乱"), ("温暖", "不冷不热，让人舒服"), ("保护", "照顾，使不受损害"), ("认真", "用心对待，不马虎")]
        for (word, meaning) in words {
            let item = ReviewItem(type: .phrase, content: word, prompt: meaning, stage: 2, nextReviewAt: now)
            context.insert(item)
            for days in [-4, -3, -1] {
                context.insert(ReviewRecord(itemID: item.id, reviewedAt: now.addingTimeInterval(Double(days) * 86400),
                    result: .wrong, mode: .scheduled, oldStage: 2, newStage: 0))
            }
        }
        try? context.save()
    }
}
#endif

#if DEBUG
extension TargetedCoachCoordinator {
    /// Only the isolated UI-test store can receive this deterministic teaching example.
    func seedRichLessonForUITesting() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"), arguments.contains("--ui-testing-targeted"),
              arguments.contains("--ui-testing-targeted-rich"), var next = state, next.groups.isEmpty,
              let finding = findings.first(where: { $0.item.content == "辨别" }) else { return }
        let ordered = [finding] + findings.filter { $0.id != finding.id }
        var group = CoachingStudyGroup(findings: ordered, now: .now)
        let lesson = CoachingWordLesson(meaning: "仔细看出事物之间有什么不同，分清它们。",
            structure: "“辨”有分辨、分清的意思；“别”也有区别的意思。两个字放在一起，都是在说把不同的事物分清楚。注意“辨”字中间的部分。",
            example: arguments.contains("--ui-testing-targeted-speech")
                ? "观察叶子的形状和颜色，可以帮助我们辨别不同的树。我们还可以比较树干的粗细、树皮的纹路，把观察到的不同特点一一记下来，再仔细核对。"
                : "观察叶子的形状，可以帮助我们辨别不同的树。")
        let entry = CoachingIntervention(finding: finding, observation: .unknown, actualMistake: "", strategy: lesson.structure,
            exercises: [.init(kind: .cloze, prompt: "我们需要仔细____两片叶子的不同。", answer: "辨别")], isAI: true, now: .now, lesson: lesson)
        group.targets[0].interventionID = entry.id
        next.interventions.append(entry); next.groups.append(group)
        do { try persist(next) } catch { self.error = error.localizedDescription }
    }
}
#endif
