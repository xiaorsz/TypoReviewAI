import Foundation
import SwiftData
import Observation
import CoachCore

enum AICoachSignals {
    static let changed = Notification.Name("coachLab.practiceSignal")
    static func post(_ action: String, id: UUID? = nil, itemIDs: [UUID] = [], recordIDs: [UUID] = []) {
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["action": action, "id": id as Any, "itemIDs": itemIDs, "recordIDs": recordIDs])
    }
}

/// The original SwiftData models remain the authority. Core contains only AI metadata and
/// a planning snapshot; generated selections update ReviewDailyPlan, never dictation input.
@MainActor @Observable final class AICoachCoordinator {
    private(set) var store: CoachCore.LabStore?
    private(set) var agent: CoachCore.CoachAgent?
    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var status = "尚未检查学习记录。"
    private var task: Task<Void, Never>?
    private var activeRunID: UUID?
    private let transport: any CoachCore.ChatTransport
    private var pendingSignals: [Notification] = []
    // An undo belongs to the still-open review screen. Keep exact versions so it
    // can invalidate that feedback without deleting later edits or started work.
    private struct NativePlanRevision {
        let id: UUID
        let itemIDs: [UUID]
        let subject: String
        let rationale: String
        let updatedAt: Date
        init(_ plan: ReviewDailyPlan) {
            id = plan.id; itemIDs = plan.itemIDs
            subject = plan.coachSubjectRawValue; rationale = plan.coachRationale; updatedAt = plan.updatedAt
        }
        func matches(_ plan: ReviewDailyPlan) -> Bool {
            plan.id == id && plan.startedAt == nil && plan.itemIDs == itemIDs
                && plan.coachSubjectRawValue == subject && plan.coachRationale == rationale && plan.updatedAt == updatedAt
        }
    }
    private struct FeedbackPlanChange {
        let plan: CoachCore.CoachPlan
        let dayKey: String
        var native: [NativePlanRevision] = []
    }
    private var activeFeedbackBaseline: (id: UUID, plans: [UUID: CoachCore.CoachPlan])?
    private var feedbackPlanChanges: [UUID: [UUID: FeedbackPlanChange]] = [:]
    private var protectedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "coachLab.protectedSessions") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "coachLab.protectedSessions") }
    }
    init(fileURL: URL? = nil, transport: any CoachCore.ChatTransport = CoachCore.DeepSeekTransport()) {
        self.transport = transport
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            var url = support.appendingPathComponent("cc.xiaorsz.dictation-coach-lab/lab.json")
            if let fileURL { url = fileURL }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                url = FileManager.default.temporaryDirectory.appendingPathComponent("full-coach-test-\(UUID()).json")
            }
            #endif
            let store = try CoachCore.LabStore(fileURL: url, persistsLearningSnapshot: false)
            self.store = store; agent = CoachCore.CoachAgent(store: store, transport: transport, reviewsOnly: true)
        } catch { self.error = error.localizedDescription }
    }

    func bootstrap(context: ModelContext, settings: AppSettingsStore) {
        guard let store else { return }
        do {
            if !ProcessInfo.processInfo.arguments.contains("--ui-testing") && !UserDefaults.standard.bool(forKey: "coachLab.fullCopyMigration.v1") {
                let items = try context.fetch(FetchDescriptor<ReviewItem>())
                let sessions = try context.fetch(FetchDescriptor<DictationSession>())
                let legacySessions = store.state.sessions.filter { $0.practiceMode != "coachReview" && $0.practiceMode != "feedback" }
                let legacySessionIDs = Set(legacySessions.map(\.id))
                if items.isEmpty && sessions.isEmpty && (!store.state.items.isEmpty || !legacySessions.isEmpty) {
                    for snapshot in try convert(store.state.items, to: [ReviewItemSnapshot].self) { context.insert(snapshot.makeModel()) }
                    for snapshot in try convert(store.state.records, to: [ReviewRecordSnapshot].self) { context.insert(snapshot.makeModel()) }
                    for snapshot in try convert(legacySessions, to: [DictationSessionSnapshot].self) { context.insert(snapshot.makeModel()) }
                    for snapshot in try convert(store.state.entries.filter { legacySessionIDs.contains($0.sessionID) }, to: [DictationEntrySnapshot].self) { context.insert(snapshot.makeModel()) }
                    try context.save()
                    settings.childName = store.state.configuration.childName
                    settings.dailyLimit = store.state.configuration.dailyLimit
                    settings.persist(using: context)
                    AppDataChangeCenter.post()
                }
                UserDefaults.standard.set(true, forKey: "coachLab.fullCopyMigration.v1")
            }
            if store.state.reviewPlannerVersion != 1 {
                var next = store.state
                next.plans = []; next.completedTriggers = []; next.pendingFeedbackSessionIDs = []
                next.reviewPlannerVersion = 1
                // Existing dictation input and answers remain in SwiftData.
                try store.commit(next)
            }
            try mirror(context: context, settings: settings)
        } catch { context.rollback(); self.error = "实验数据迁移／读取失败：\(error.localizedDescription)" }
    }

    func refresh(context: ModelContext, settings: AppSettingsStore) {
        guard !isRunning else { return }
        do { try mirror(context: context, settings: settings) } catch { self.error = error.localizedDescription }
    }
    func run(context: ModelContext, settings: AppSettingsStore, apiKey: String? = nil, now: Date = .now, manual: Bool = false) {
        guard !isRunning else { return }
        guard let store, let agent else { error = "教练数据未能打开，请重试或重新打开 App。"; status = "教练尚未就绪。"; return }
        guard store.state.configuration.isEnabled else {
            status = "请先打开「授权 AI 安排每日复习」。"; error = nil; return
        }
        error = nil; isRunning = true; status = "正在读取学习记录…"
        let runID = UUID(), datasetID = store.state.datasetID
        activeRunID = runID
        let container = context.container
        task = Task { @MainActor in
            do {
                // Let SwiftUI present progress before starting any database work.
                await Task.yield()
                guard activeRunID == runID, !Task.isCancelled else { return }
                let source = try await Task.detached(priority: .userInitiated) {
                    try CoachNativeSnapshot.load(from: container)
                }.value
                guard activeRunID == runID, !Task.isCancelled, store.state.datasetID == datasetID else { return }
                try merge(source, settings: settings)
                let config = store.state.configuration
                let feedbackID = store.state.pendingFeedbackSessionIDs.first { id in
                    store.entries(for: id).contains { config.subject.contains($0.typeRawValue) }
                }
                if let feedbackID { try validateReviewFeedback(feedbackID, context: context) }
                let todayKey = ReviewDailyPlan.dayKey(for: now)
                if feedbackID == nil && source.startedDays[todayKey] != nil {
                    // Recover already-saved future selections from an earlier
                    // failed native write without reopening today's locked list.
                    try flushPlans(context: context, dailyLimit: settings.dailyLimit, now: now)
                    status = "今日复习已开始，清单已锁定。请在首页继续复习；判定后 AI 会调整后续日期。"
                } else {
                    status = "正在检查 API Key…"
                    let key: String
                    if let apiKey { key = apiKey }
                    else { key = try await Task.detached(priority: .utility) { try LabKeychain.load() }.value }
                    guard activeRunID == runID, !Task.isCancelled, store.state.datasetID == datasetID else { return }
                    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw CoachCore.LabError.invalid("请填写或保存 DeepSeek API Key，再检查记录。")
                    }
                    status = "正在查询历史并安排复习…"
                    if let feedbackID {
                        activeFeedbackBaseline = (feedbackID, Dictionary(uniqueKeysWithValues: store.state.plans.map { ($0.id, $0) }))
                    }
                    await agent.run(apiKey: key, now: now, forceDailyRecheck: manual, deferTriggerCompletion: true)
                    guard activeRunID == runID, !Task.isCancelled, store.state.datasetID == datasetID else { return }
                    rememberFeedbackPlanChanges()
                    if let feedbackID { try validateReviewFeedback(feedbackID, context: context) }
                    if let message = agent.lastError {
                        error = "AI 暂不可用，未生成的日期按原规则复习。" + message
                    }
                    var nativeSaved = false
                    do {
                        try flushPlans(context: context, dailyLimit: settings.dailyLimit, now: now)
                        nativeSaved = true
                        // Only consume feedback/daily completion after the
                        // actionable plans have reached the native database.
                        if let trigger = agent.completionTrigger { try store.finishTrigger(trigger) }
                        status = agent.status.isEmpty ? "检查已完成，请查看下方安排或首页复习。" : agent.status
                        AppDataChangeCenter.post()
                    } catch {
                        context.rollback()
                        self.error = (nativeSaved ? "复习安排已保存，但教练执行状态未能保存，可再次检查。" : "AI 复习安排未保存，可再次点击检查重试；原有记录保留。") + error.localizedDescription
                        status = nativeSaved ? "安排已保存，执行状态待重试。" : "安排未保存。"
                    }
                    if let feedbackID { try captureNativePlanRevisions(for: feedbackID, context: context) }
                    activeFeedbackBaseline = nil
                }
            } catch {
                guard activeRunID == runID else { return }
                self.error = "AI 不可用，按原规则复习。" + error.localizedDescription
                status = "本轮未完成，可重试。"
            }
            guard activeRunID == runID else { return }
            activeFeedbackBaseline = nil
            isRunning = false; task = nil; activeRunID = nil
            while !isRunning && !pendingSignals.isEmpty {
                let pending = pendingSignals.removeFirst()
                receive(pending, context: context, settings: settings)
            }
        }
    }
    func cancel() {
        rememberFeedbackPlanChanges(); activeFeedbackBaseline = nil
        activeRunID = nil; agent?.cancel(); task?.cancel(); task = nil; isRunning = false
        status = "已停止本轮安排；已有记录与计划保留。"
    }

    func waitForPendingRun() async { await task?.value }

    func saveConfiguration(_ configuration: CoachCore.CoachConfiguration, context: ModelContext, settings: AppSettingsStore, startAutomatically: Bool = true) throws {
        guard let store else { return }
        cancel()
        let previous = store.state.configuration
        try store.configure(configuration)
        settings.dailyLimit = configuration.dailyLimit
        settings.persist(using: context)
        if !configuration.isEnabled || configuration.subject != previous.subject {
            for plan in try context.fetch(FetchDescriptor<ReviewDailyPlan>()) where plan.startedAt == nil {
                plan.coachSubjectRawValue = ""; plan.coachRationale = ""
            }
            var next = store.state
            next.plans = []; next.sessions.removeAll { $0.practiceMode == "coachReview" }
            let sessionIDs = Set(next.sessions.map(\.id))
            next.entries.removeAll { !sessionIDs.contains($0.sessionID) }
            next.completedTriggers = []
            try store.commit(next)
            try context.save()
        }
        AppDataChangeCenter.post()
        if configuration.isEnabled && startAutomatically { run(context: context, settings: settings) }
    }

    func receive(_ notification: Notification, context: ModelContext, settings: AppSettingsStore) {
        guard let action = notification.userInfo?["action"] as? String, let store else { return }
        let id = notification.userInfo?["id"] as? UUID
        if action == "started", let id { var ids = protectedIDs; ids.insert(id.uuidString); protectedIDs = ids; return }
        if action == "reviewUndo", let id {
            cancel()
            pendingSignals.removeAll { ($0.userInfo?["id"] as? UUID) == id }
            do {
                try invalidateReviewFeedback(id, context: context)
                try mirror(context: context, settings: settings)
                error = nil
                status = "已撤回本次学情；重新判定后再调整后续复习。"
            } catch { context.rollback(); self.error = "撤回教练学情未完成，请重试。" + error.localizedDescription }
            while !isRunning && !pendingSignals.isEmpty {
                receive(pendingSignals.removeFirst(), context: context, settings: settings)
            }
            return
        }
        if action == "restore" {
            cancel()
            do {
                var next = store.state; next.datasetID = UUID(); next.plans = []
                next.pendingFeedbackSessionIDs = []; next.completedTriggers = []
                next.sessions.removeAll { $0.practiceMode == "coachReview" || $0.practiceMode == "feedback" }
                let remainingIDs = Set(next.sessions.map(\.id))
                next.entries.removeAll { !remainingIDs.contains($0.sessionID) }
                pendingSignals = []; protectedIDs = []; feedbackPlanChanges = [:]
                try store.commit(next); try mirror(context: context, settings: settings)
            } catch { self.error = error.localizedDescription }
            return
        }
        if ["manualEdit", "deleted"].contains(action), let id {
            do {
                var next = store.state; next.plans.removeAll { $0.sessionID == id }; try store.commit(next)
                if action == "deleted" { var ids = protectedIDs; ids.insert(id.uuidString); protectedIDs = ids }
            } catch { self.error = error.localizedDescription }
            return
        }
        guard !isRunning else { pendingSignals.append(notification); return }
        do {
            try mirror(context: context, settings: settings)
            var next = store.state
            if action == "dictation", let id, next.sessions.contains(where: { $0.id == id && $0.reviewedAt != nil }) {
                if !next.pendingFeedbackSessionIDs.contains(id) { next.pendingFeedbackSessionIDs.append(id) }
            } else if action == "review" {
                let recordIDs = notification.userInfo?["recordIDs"] as? [UUID] ?? []
                let recordsByID = Dictionary(next.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let records = recordIDs.compactMap { recordsByID[$0] }
                // Queued notifications may outlive an undo or a cloud merge. Only
                // the records actually saved by this submission are evidence.
                guard let id, !recordIDs.isEmpty, Set(recordIDs).count == recordIDs.count,
                      records.count == recordIDs.count, records.allSatisfy({ $0.modeRawValue != "dictation" }) else { return }
                // A stable submission ID remains consumed after its temporary
                // feedback snapshot is pruned. Undo explicitly reopens it.
                guard !next.completedTriggers.contains("feedback:\(id.uuidString)") else { return }
                let itemsByID = Dictionary(next.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let pairs = records.compactMap { record in itemsByID[record.itemID].map { ($0, record) } }
                guard pairs.count == records.count, let first = pairs.first?.0 else { return }
                let previous = store.entries(for: id)
                let unchanged = previous.count == pairs.count && pairs.allSatisfy { item, record in
                    previous.contains { $0.itemID == item.id && $0.submittedRecordID == record.id
                        && $0.resultRawValue == (record.resultRawValue == "correct" ? "正确" : "错误") }
                }
                if !unchanged {
                    next.sessions.removeAll { $0.id == id && $0.practiceMode == "feedback" }
                    next.entries.removeAll { $0.sessionID == id }
                    next.completedTriggers.removeAll { $0 == "feedback:\(id.uuidString)" }
                    var session = CoachCore.DictationSession(id: id, title: "本次正式复习学情", type: first.typeRawValue, date: .now)
                    session.practiceMode = "feedback"; session.reviewedAt = .now
                    next.sessions.append(session)
                    for (order, pair) in pairs.enumerated() {
                        let (item, record) = pair
                        var entry = CoachCore.DictationEntry(sessionID: session.id, item: item, order: order, now: .now)
                        entry.resultRawValue = record.resultRawValue == "correct" ? "正确" : "错误"
                        entry.submittedRecordID = record.id
                        next.entries.append(entry)
                    }
                }
                if !next.pendingFeedbackSessionIDs.contains(id) { next.pendingFeedbackSessionIDs.append(id) }
            }
            try store.commit(next)
            if next.configuration.isEnabled { run(context: context, settings: settings) }
        } catch { self.error = error.localizedDescription }
    }

    private func mirror(context: ModelContext, settings: AppSettingsStore) throws {
        try merge(CoachNativeSnapshot.load(from: context), settings: settings)
    }

    private func rememberFeedbackPlanChanges() {
        guard let store, let baseline = activeFeedbackBaseline else { return }
        var changes = feedbackPlanChanges[baseline.id] ?? [:]
        for plan in store.state.plans where baseline.plans[plan.id] != plan {
            guard let session = store.state.sessions.first(where: { $0.id == plan.sessionID && $0.practiceMode == "coachReview" }) else { continue }
            if changes[plan.id]?.plan != plan {
                changes[plan.id] = FeedbackPlanChange(plan: plan, dayKey: ReviewDailyPlan.dayKey(for: session.scheduledDate))
            }
        }
        feedbackPlanChanges[baseline.id] = changes
    }

    private func captureNativePlanRevisions(for feedbackID: UUID, context: ModelContext) throws {
        guard var changes = feedbackPlanChanges[feedbackID] else { return }
        let native = try context.fetch(FetchDescriptor<ReviewDailyPlan>())
        for (id, change) in changes {
            changes[id]?.native = native.filter {
                $0.dayKey == change.dayKey && $0.startedAt == nil
                    && $0.coachSubjectRawValue == change.plan.subject.rawValue
                    && $0.coachRationale == change.plan.rationale
            }.map(NativePlanRevision.init)
        }
        feedbackPlanChanges[feedbackID] = changes
    }

    private func validateReviewFeedback(_ id: UUID, context: ModelContext) throws {
        guard let store, store.state.sessions.contains(where: { $0.id == id && $0.practiceMode == "feedback" }) else { return }
        let entries = store.entries(for: id)
        // Legacy/imported feedback and native dictations have a different source;
        // only new formal review signals carry exact submitted record IDs.
        guard !entries.isEmpty, entries.allSatisfy({ $0.submittedRecordID != nil }) else { return }
        let valid = try PersistentStoreAccessGate.withAccess {
            let live = ModelContext(context.container)
            live.autosaveEnabled = false
            let records = Dictionary(try live.fetch(FetchDescriptor<ReviewRecord>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return entries.allSatisfy { entry in
                guard let recordID = entry.submittedRecordID, let record = records[recordID] else { return false }
                return record.itemID == entry.itemID && record.mode != .dictation
                    && (record.result == .correct ? "正确" : "错误") == entry.resultRawValue
            }
        }
        guard valid else {
            try invalidateReviewFeedback(id, context: context)
            activeFeedbackBaseline = nil
            throw CoachCore.LabError.invalid("本次复习判定已撤回或同步更新，已停止使用旧学情；请按当前记录重新检查。")
        }
    }

    private func invalidateReviewFeedback(_ id: UUID, context: ModelContext) throws {
        guard let store else { return }
        var next = store.state
        let native = try context.fetch(FetchDescriptor<ReviewDailyPlan>())
        let lockedDays = Set(native.filter { $0.startedAt != nil }.map(\.dayKey))
        var removedSessions = Set<UUID>()
        for change in (feedbackPlanChanges[id] ?? [:]).values {
            guard !lockedDays.contains(change.dayKey),
                  next.plans.contains(change.plan),
                  next.sessions.contains(where: { $0.id == change.plan.sessionID && $0.isUntouched }) else { continue }
            next.plans.removeAll { $0.id == change.plan.id }
            removedSessions.insert(change.plan.sessionID)
            for plan in native where change.native.contains(where: { $0.matches(plan) }) { context.delete(plan) }
            next.completedTriggers.removeAll { $0.hasPrefix("daily:\(change.dayKey):") }
        }
        next.sessions.removeAll { removedSessions.contains($0.id) || ($0.id == id && $0.practiceMode == "feedback") }
        next.entries.removeAll { removedSessions.contains($0.sessionID) || $0.sessionID == id }
        next.pendingFeedbackSessionIDs.removeAll { $0 == id }
        next.completedTriggers.removeAll { $0 == "feedback:\(id.uuidString)" }
        try store.commit(next)
        try context.save()
        feedbackPlanChanges.removeValue(forKey: id)
        AppDataChangeCenter.post()
    }

    private func merge(_ source: CoachNativeSnapshot, settings: AppSettingsStore) throws {
        guard let store else { return }
        let items = unique(source.items, id: \.id)
        let records = unique(source.records, id: \.id)
        let sessions = unique(source.sessions, id: \.id)
        let entries = unique(source.entries, id: \.id)
        var next = store.state
        var virtualSessions = next.sessions.filter {
            $0.practiceMode == "coachReview" || ($0.practiceMode == "feedback" && next.pendingFeedbackSessionIDs.contains($0.id))
        }
        for index in virtualSessions.indices where virtualSessions[index].practiceMode == "coachReview" {
            let day = ReviewDailyPlan.dayKey(for: virtualSessions[index].scheduledDate)
            if let startedAt = source.startedDays[day] {
                virtualSessions[index].startedAt = startedAt
            }
        }
        let virtualIDs = Set(virtualSessions.map(\.id))
        let virtualEntries = next.entries.filter { virtualIDs.contains($0.sessionID) }
        let old = Dictionary(uniqueKeysWithValues: next.sessions.map { ($0.id, $0) })
        next.items = items
        let itemIDs = Set(next.items.map(\.id))
        next.records = records.filter { itemIDs.contains($0.itemID) }
        next.sessions = sessions
        for index in next.sessions.indices {
            let session = next.sessions[index]
            if protectedIDs.contains(session.id.uuidString) || session.currentEntryIndex > 0 || session.finishedAt != nil || session.reviewedAt != nil {
                next.sessions[index].startedAt = old[session.id]?.startedAt ?? session.updatedAt
            }
        }
        next.sessions += virtualSessions
        let sessionIDs = Set(next.sessions.map(\.id))
        next.entries = entries.filter { sessionIDs.contains($0.sessionID) }
        let byIdentity = Dictionary(grouping: next.items, by: \.identity)
        for index in next.entries.indices { next.entries[index].itemID = byIdentity[next.entries[index].identity]?.first?.id }
        next.entries += virtualEntries
        let oldCount = next.plans.count
        next.plans.removeAll { !sessionIDs.contains($0.sessionID) || !Set($0.itemIDs).isSubset(of: itemIDs) }
        if next.plans.count != oldCount {
            next.completedTriggers.removeAll { $0.hasPrefix("daily:") }
            let validPlanIDs = Set(next.plans.map(\.sessionID))
            next.sessions.removeAll { $0.practiceMode == "coachReview" && !validPlanIDs.contains($0.id) }
            let remainingIDs = Set(next.sessions.map(\.id))
            next.entries.removeAll { !remainingIDs.contains($0.sessionID) }
        }
        next.pendingFeedbackSessionIDs.removeAll { !sessionIDs.contains($0) }
        next.configuration.childName = settings.childName
        next.configuration.dailyLimit = settings.dailyLimit
        try store.commit(next)
    }

    func flushPlans(context: ModelContext, dailyLimit: Int? = nil, now: Date = .now) throws {
        guard let store, store.state.configuration.isEnabled else { return }
        // Re-read live state after the model request: new answers or a started
        // review may have arrived while the network was running.
        for plan in store.state.plans.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            guard let proposed = store.state.sessions.first(where: { $0.id == plan.sessionID }),
                  proposed.practiceMode == "coachReview", proposed.cancelledAt == nil,
                  proposed.startedAt == nil,
                  proposed.scheduledDate >= Calendar.current.startOfDay(for: now) else { continue }
            try DailyReviewPlanner.apply(itemIDs: plan.itemIDs, subject: plan.subject,
                rationale: plan.rationale, date: proposed.scheduledDate,
                dailyLimit: dailyLimit ?? store.state.configuration.dailyLimit, in: context)
        }
    }
    private func convert<Input: Encodable, Output: Decodable>(_ input: Input, to: Output.Type) throws -> Output {
        try CoachCore.Codec.decoder().decode(Output.self, from: CoachCore.Codec.encoder().encode(input))
    }
    private func unique<T>(_ values: [T], id: KeyPath<T, UUID>) -> [T] {
        var seen = Set<UUID>(); return values.filter { seen.insert($0[keyPath: id]).inserted }
    }
}
