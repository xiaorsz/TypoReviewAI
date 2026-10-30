import Foundation
import Observation

@MainActor @Observable public final class LabStore {
    public private(set) var state: LabState
    public let fileURL: URL
    private let persistsLearningSnapshot: Bool

    public init(fileURL: URL, persistsLearningSnapshot: Bool = true) throws {
        self.fileURL = fileURL
        self.persistsLearningSnapshot = persistsLearningSnapshot
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let loaded = try Codec.decoder().decode(LabState.self, from: Data(contentsOf: fileURL))
            guard loaded.schemaVersion == 1 else { throw LabError.invalid("实验数据版本不受支持，原文件已保留。") }
            state = loaded
        } else { state = LabState() }
    }

    /// Disk write happens before observable state changes. A failed import/grade cannot partially commit.
    public func commit(_ candidate: LabState) throws {
        var durable = candidate
        if !persistsLearningSnapshot {
            // SwiftData owns the learning data in the full app. Persist only
            // configuration, AI plans and feedback, rather than copying the
            // entire read snapshot to disk for every model log/tool operation.
            durable.items = []; durable.records = []
            durable.sessions = candidate.sessions.filter { $0.practiceMode == "coachReview" || $0.practiceMode == "feedback" }
            let sessionIDs = Set(durable.sessions.map(\.id))
            durable.entries = candidate.entries.filter { sessionIDs.contains($0.sessionID) }
        }
        let data = try Codec.encoder().encode(durable)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        state = candidate
    }
    public func replace(with preview: ImportPreview) throws { try commit(preview.state) }
    public func reset() throws { try commit(LabState()) }
    public func configure(_ configuration: CoachConfiguration) throws {
        guard (1...50).contains(configuration.dailyLimit), configuration.childName.count <= 40,
              ["deepseek-flash", "deepseek-v4-pro"].contains(configuration.model) else {
            throw LabError.invalid("请使用有效的每日复习题量（1–50）和模型。")
        }
        var next = state; next.configuration = configuration; try commit(next)
    }
    public func addItem(subject: Subject, content: String, prompt: String) throws {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 120, prompt.count <= 300 else { throw LabError.invalid("内容需为 1–120 字，提示不超过 300 字。") }
        let type = subject == .chinese ? "词语" : "单词"
        let item = ReviewItem(type: type, content: text, prompt: prompt)
        guard !state.items.contains(where: { $0.identity == item.identity }) else { throw LabError.invalid("题库已包含这个内容。") }
        var next = state; next.items.append(item); try commit(next)
    }
    public func entries(for sessionID: UUID) -> [DictationEntry] {
        state.entries.filter { $0.sessionID == sessionID }.sorted {
            $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder
        }
    }
    @discardableResult public func createManualPractice(itemID: UUID, now: Date = .now) throws -> UUID {
        guard let item = state.items.first(where: { $0.id == itemID }) else { throw LabError.invalid("题目不存在。") }
        var next = state
        let session = DictationSession(title: "练习：\(item.content)", type: item.typeRawValue,
            date: Calendar.current.startOfDay(for: now), now: now)
        next.sessions.append(session)
        next.entries.append(DictationEntry(sessionID: session.id, item: item, order: 0, now: now))
        try commit(next); return session.id
    }
    public func begin(_ sessionID: UUID, now: Date = .now) throws {
        var next = state
        guard let index = next.sessions.firstIndex(where: { $0.id == sessionID }),
              next.sessions[index].reviewedAt == nil, next.sessions[index].cancelledAt == nil,
              Calendar.current.startOfDay(for: next.sessions[index].scheduledDate) <= Calendar.current.startOfDay(for: now),
              !entries(for: sessionID).isEmpty else { throw LabError.invalid("这组练习尚未到日期、已经结束或没有有效内容。") }
        next.sessions[index].startedAt = next.sessions[index].startedAt ?? now
        next.sessions[index].updatedAt = now; try commit(next)
    }
    public func advance(_ sessionID: UUID, to index: Int, now: Date = .now) throws {
        var next = state
        guard let i = next.sessions.firstIndex(where: { $0.id == sessionID }),
              next.sessions[i].startedAt != nil, next.sessions[i].reviewedAt == nil,
              next.sessions[i].cancelledAt == nil, (0...entries(for: sessionID).count).contains(index) else {
            throw LabError.invalid("练习进度无效。")
        }
        next.sessions[i].currentEntryIndex = index; next.sessions[i].updatedAt = now
        if index == entries(for: sessionID).count { next.sessions[i].finishedAt = now }
        try commit(next)
    }
    public func mark(_ entryID: UUID, correct: Bool, now: Date = .now) throws {
        var next = state
        guard let i = next.entries.firstIndex(where: { $0.id == entryID }),
              let session = next.sessions.first(where: { $0.id == next.entries[i].sessionID }),
              session.startedAt != nil, session.cancelledAt == nil, session.reviewedAt == nil else {
            throw LabError.invalid("这组练习不能修改判定。")
        }
        next.entries[i].resultRawValue = correct ? "正确" : "错误"; next.entries[i].updatedAt = now
        guard next.entries[i].submittedRecordID == nil else { throw LabError.invalid("这条复习结果已经保存，请先撤销后重判。") }
        try commit(next)
    }
    @discardableResult public func submit(_ sessionID: UUID, now: Date = .now) throws -> Bool {
        var next = state
        guard let s = next.sessions.firstIndex(where: { $0.id == sessionID }) else { throw LabError.invalid("找不到练习。") }
        if next.sessions[s].reviewedAt != nil { return false }
        let indices = next.entries.indices.filter { next.entries[$0].sessionID == sessionID }
        guard next.sessions[s].startedAt != nil, next.sessions[s].cancelledAt == nil, !indices.isEmpty,
              indices.allSatisfy({ ["正确", "错误"].contains(next.entries[$0].resultRawValue) }) else {
            throw LabError.invalid("请先完成全部条目的对错判定。")
        }
        for index in indices { try Self.applyEntryResult(index: index, in: &next, now: now) }
        next.sessions[s].reviewedAt = now; next.sessions[s].finishedAt = next.sessions[s].finishedAt ?? now
        next.sessions[s].updatedAt = now
        if next.configuration.isEnabled { next.pendingFeedbackSessionIDs.append(sessionID) }
        try commit(next); return true
    }
    public func cancel(_ sessionID: UUID, now: Date = .now) throws {
        var next = state
        guard let i = next.sessions.firstIndex(where: { $0.id == sessionID }), next.sessions[i].isUntouched,
              next.plans.contains(where: { $0.sessionID == sessionID }) else { throw LabError.invalid("只能取消尚未开始的 AI 计划。") }
        next.sessions[i].cancelledAt = now; next.sessions[i].updatedAt = now; try commit(next)
    }
    public func appendLog(runID: UUID, kind: String, message: String) throws {
        var next = state
        next.logs.append(CoachLog(runID: runID, kind: kind, message: String(message.prefix(3000))))
        next.logs = Array(next.logs.suffix(500))
        try commit(next)
    }
    public func finishTrigger(_ trigger: String) throws {
        var next = state
        if !next.completedTriggers.contains(trigger) { next.completedTriggers.append(trigger) }
        if trigger.hasPrefix("feedback:"), let id = UUID(uuidString: String(trigger.dropFirst(9))) {
            next.pendingFeedbackSessionIDs.removeAll { $0 == id }
        }
        try commit(next)
    }
}
