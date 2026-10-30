import Foundation

public struct ImportPreview: Sendable {
    public let state: LabState
    public let version: Int
    public let exportedAt: Date
    public let skippedItems: Int
    public let skippedSessions: Int
    public let skippedReviewRecords: Int
    public let skippedDictationEntries: Int
    public let orphanReviewRecords: Int
    public let orphanDictationEntries: Int
    public var summary: String {
        var lines = [
            "可导入题库 \(state.items.count) 条 · 复习记录 \(state.records.count) 条",
            "听写计划 \(state.sessions.count) 组 · 判定条目 \(state.entries.count) 条"
        ]
        if skippedItems + skippedSessions + skippedReviewRecords + skippedDictationEntries > 0 {
            lines.append("将跳过：题目 \(skippedItems) 条、复习记录 \(skippedReviewRecords) 条、听写计划 \(skippedSessions) 组、听写条目 \(skippedDictationEntries) 条。")
        }
        if orphanReviewRecords > 0 { lines.append("其中缺少对应题目：\(orphanReviewRecords) 条复习记录。") }
        if orphanDictationEntries > 0 { lines.append("其中缺少对应计划：\(orphanDictationEntries) 条听写条目。") }
        if orphanReviewRecords + orphanDictationEntries > 0 {
            lines.append("无法关联的记录只跳过，不猜测其归属；其余有效数据可正常导入。")
        }
        return lines.joined(separator: "\n")
    }
}

public enum BackupImporter {
    private struct Settings: Decodable { let childName: String?; let dailyLimit: Int? }
    private struct Payload: Decodable {
        let version: Int
        let exportedAt: Date
        let settings: Settings?
        let reviewItems: [ReviewItem]
        let reviewRecords: [ReviewRecord]
        let dictationSessions: [DictationSession]
        let dictationEntries: [DictationEntry]
    }
    private struct Header: Decodable { let version: Int }

    public static func preview(_ data: Data, now: Date = .now) throws -> ImportPreview {
        guard data.count <= 50 * 1024 * 1024 else { throw LabError.invalid("备份超过 50 MB，请选择较小的 JSON 备份。") }
        let decoder = Codec.decoder()
        let header = try decoder.decode(Header.self, from: data)
        guard (1...5).contains(header.version) else { throw LabError.invalid("暂不支持备份 v\(header.version)，支持 v1–v5。") }
        let payload = try decoder.decode(Payload.self, from: data)
        try unique(payload.reviewItems.map(\.id), label: "题库")
        try unique(payload.reviewRecords.map(\.id), label: "复习记录")
        try unique(payload.dictationSessions.map(\.id), label: "听写计划")
        try unique(payload.dictationEntries.map(\.id), label: "听写条目")
        let allItemIDs = Set(payload.reviewItems.map(\.id))
        let allSessionIDs = Set(payload.dictationSessions.map(\.id))
        // Source deletions can leave historical records behind. Keep only exact parent-ID
        // matches below, and report orphan counts before the user confirms replacement.
        let orphanReviewRecords = payload.reviewRecords.filter { !allItemIDs.contains($0.itemID) }.count
        let orphanDictationEntries = payload.dictationEntries.filter { !allSessionIDs.contains($0.sessionID) }.count
        guard payload.reviewItems.allSatisfy({ (0...7).contains($0.stage) && $0.consecutiveWrongCount >= 0 && $0.consecutiveCorrectCount >= 0 }),
              payload.reviewRecords.allSatisfy({ ["correct", "wrong"].contains($0.resultRawValue) && (0...7).contains($0.oldStage) && (0...7).contains($0.newStage) }),
              payload.dictationEntries.allSatisfy({ ["未判定", "正确", "错误"].contains($0.resultRawValue) && $0.sortOrder >= 0 }) else {
            throw LabError.invalid("备份中存在无效的阶段、对错结果或排序值。")
        }
        var state = LabState()
        state.items = payload.reviewItems.filter { Subject.supports($0.typeRawValue) && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let itemIDs = Set(state.items.map(\.id))
        state.records = payload.reviewRecords.filter { itemIDs.contains($0.itemID) }
        state.sessions = payload.dictationSessions.filter { Subject.supports($0.typeRawValue) }
        let sessionIDs = Set(state.sessions.map(\.id))
        state.entries = payload.dictationEntries.filter { sessionIDs.contains($0.sessionID) && Subject.supports($0.typeRawValue) && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let entriesBySession = Dictionary(grouping: state.entries, by: \.sessionID)
        for index in state.sessions.indices {
            let session = state.sessions[index]
            let entries = entriesBySession[session.id] ?? []
            guard session.currentEntryIndex >= 0, session.currentEntryIndex <= entries.count else {
                throw LabError.invalid("听写进度超出条目范围，备份未导入。")
            }
            // Imported in-progress sessions must also be protected from editing.
            if session.currentEntryIndex > 0 || entries.contains(where: { $0.resultRawValue != "未判定" }) {
                state.sessions[index].startedAt = session.startedAt ?? session.updatedAt
            }
        }
        let canonical = Dictionary(grouping: state.items, by: \.identity)
        for index in state.entries.indices {
            // Never trust extra lab-only fields in a source file.
            state.entries[index].itemID = canonical[state.entries[index].identity]?.max { $0.updatedAt < $1.updatedAt }?.id
            state.entries[index].submittedRecordID = nil
            state.entries[index].beforeReviewItem = nil
        }
        state.configuration.childName = String((payload.settings?.childName ?? "").prefix(40))
        state.configuration.dailyLimit = min(30, max(1, payload.settings?.dailyLimit ?? 15))
        state.configuration.isEnabled = false
        state.importedAt = now; state.sourceExportedAt = payload.exportedAt
        return ImportPreview(state: state, version: payload.version, exportedAt: payload.exportedAt,
                             skippedItems: payload.reviewItems.count - state.items.count,
                             skippedSessions: payload.dictationSessions.count - state.sessions.count,
                             skippedReviewRecords: payload.reviewRecords.count - state.records.count,
                             skippedDictationEntries: payload.dictationEntries.count - state.entries.count,
                             orphanReviewRecords: orphanReviewRecords,
                             orphanDictationEntries: orphanDictationEntries)
    }
    private static func unique(_ ids: [UUID], label: String) throws {
        guard Set(ids).count == ids.count else { throw LabError.invalid("\(label)包含重复 ID，无法安全导入。") }
    }
}
