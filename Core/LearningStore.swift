import Foundation

@MainActor public extension LabStore {
    func setPreferences(_ preferences: PracticePreferences) throws {
        guard [2, 3, 5, 8, 10].contains(preferences.writingInterval), (1...3).contains(preferences.repeatCount),
              (0.3...0.6).contains(preferences.speechRate), (1...100).contains(preferences.reviewDailyLimit),
              (0...23).contains(preferences.reminderHour), (0...59).contains(preferences.reminderMinute) else {
            throw LabError.invalid("听写或提醒设置超出允许范围。")
        }
        var next = state; next.preferences = preferences; try commit(next)
    }

    func addItems(type: ContentType, rows: [ParsedLearningLine], note: String = "") throws -> Int {
        guard !rows.isEmpty, rows.count <= 500 else { throw LabError.invalid("请选择 1–500 条内容。") }
        var next = state
        var identities = Set(next.items.map(\.identity)), count = 0
        for row in rows {
            try Self.validate(row)
            var item = ReviewItem(type: type.rawValue, content: row.content, prompt: row.prompt)
            guard identities.insert(item.identity).inserted else { continue }
            item.source = row.source; item.note = note; next.items.append(item); count += 1
        }
        try commit(next); return count
    }

    func updateItem(_ item: ReviewItem) throws {
        var next = state
        guard let index = next.items.firstIndex(where: { $0.id == item.id }), ContentType(rawValue: item.typeRawValue) != nil else { throw LabError.invalid("题目不存在或类型无效。") }
        try Self.validate(ParsedLearningLine(content: item.content, prompt: item.prompt, source: item.source))
        guard !next.items.contains(where: { $0.id != item.id && $0.identity == item.identity }) else { throw LabError.invalid("题库已有相同类型和内容。") }
        var updated = item; updated.updatedAt = .now; next.items[index] = updated; try commit(next)
    }
    func deleteItem(_ id: UUID) throws {
        var next = state
        guard !next.entries.contains(where: { entry in
            entry.itemID == id && next.sessions.contains { $0.id == entry.sessionID && $0.isFormalReview && $0.startedAt != nil && $0.reviewedAt == nil && $0.cancelledAt == nil }
        }) else { throw LabError.invalid("这道题正在正式复习中，请先完成或结束本轮复习。") }
        next.items.removeAll { $0.id == id }; next.records.removeAll { $0.itemID == id }
        for index in next.entries.indices where next.entries[index].itemID == id { next.entries[index].itemID = nil }
        try commit(next)
    }
    func setPriority(_ id: UUID, enabled: Bool) throws {
        guard var item = state.items.first(where: { $0.id == id }) else { return }
        item.isPriority = enabled; try updateItem(item)
    }

    @discardableResult func saveDictation(id: UUID? = nil, title: String, type: ContentType, date: Date,
                                         rows: [ParsedLearningLine], shuffle: Bool = false, now: Date = .now) throws -> UUID {
        guard !rows.isEmpty, rows.count <= 500, title.count <= 120 else { throw LabError.invalid("计划需包含 1–500 条内容，标题不超过 120 字。") }
        var next = state
        let sessionID = id ?? UUID()
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (type == .recitation ? "英语背诵" : "今日听写") : title
        if let id {
            guard let index = next.sessions.firstIndex(where: { $0.id == id }), next.sessions[index].isUntouched,
                  !next.sessions[index].isFormalReview else { throw LabError.invalid("只能修改尚未开始的听写计划。") }
            next.sessions[index].title = resolvedTitle; next.sessions[index].typeRawValue = type.rawValue
            next.sessions[index].scheduledDate = date; next.sessions[index].updatedAt = now
            // A parent-edited AI plan becomes manual so subsequent AI runs cannot overwrite it.
            next.plans.removeAll { $0.sessionID == id }
        } else {
            next.sessions.append(DictationSession(id: sessionID, title: resolvedTitle, type: type.rawValue, date: date, now: now))
        }
        next.entries.removeAll { $0.sessionID == sessionID }
        let ordered = shuffle ? rows.shuffled() : rows
        for (index, row) in ordered.enumerated() {
            try Self.validate(row)
            var item = ReviewItem(type: type.rawValue, content: row.content, prompt: row.prompt, now: now)
            item.source = row.source
            var entry = DictationEntry(sessionID: sessionID, item: item, order: index, now: now)
            entry.itemID = next.items.first(where: { $0.identity == item.identity })?.id
            next.entries.append(entry)
        }
        try commit(next); return sessionID
    }
    func deleteDictation(_ id: UUID) throws {
        var next = state
        guard let session = next.sessions.first(where: { $0.id == id }), !session.isFormalReview else { throw LabError.invalid("正式复习请使用结束本轮操作。") }
        next.sessions.removeAll { $0.id == id }; next.entries.removeAll { $0.sessionID == id }
        next.plans.removeAll { $0.sessionID == id }; next.pendingFeedbackSessionIDs.removeAll { $0 == id }
        // Retain completed learning records attached to their actual items.
        try commit(next)
    }
    @discardableResult func practiceItems(_ ids: [UUID], shuffle: Bool = false, now: Date = .now) throws -> UUID {
        let items = ids.compactMap { id in state.items.first { $0.id == id } }
        guard items.count == ids.count, Set(ids).count == ids.count, let first = items.first,
              items.allSatisfy({ $0.typeRawValue == first.typeRawValue }), let type = ContentType(rawValue: first.typeRawValue) else {
            throw LabError.invalid("请从同一类型选择题目一起听写。")
        }
        return try saveDictation(title: "自选\(type == .recitation ? "背诵" : "听写")", type: type, date: Calendar.current.startOfDay(for: now),
            rows: items.map { ParsedLearningLine(content: $0.content, prompt: $0.prompt, source: $0.source) }, shuffle: shuffle, now: now)
    }
    func markAll(_ sessionID: UUID, result: String, now: Date = .now) throws {
        var next = state
        guard ["未判定", "正确", "错误"].contains(result), let session = next.sessions.first(where: { $0.id == sessionID }),
              session.startedAt != nil, session.reviewedAt == nil, session.cancelledAt == nil else { throw LabError.invalid("不能批量修改这组练习。") }
        for index in next.entries.indices where next.entries[index].sessionID == sessionID && next.entries[index].submittedRecordID == nil {
            next.entries[index].resultRawValue = result; next.entries[index].updatedAt = now
        }
        try commit(next)
    }

    func dueItems(now: Date = .now, type: ContentType? = nil) -> [ReviewItem] {
        let today = Calendar.current.startOfDay(for: now)
        let reviewed = Set(state.records.filter { $0.modeRawValue == "scheduled" && Calendar.current.isDate($0.reviewedAt, inSameDayAs: now) }.map(\.itemID))
        var seen = Set<String>()
        return state.items.filter { (type == nil || $0.typeRawValue == type!.rawValue) && $0.nextReviewAt != .distantFuture && Calendar.current.startOfDay(for: $0.nextReviewAt) <= today && !reviewed.contains($0.id) }
            .sorted {
                if $0.isPriority != $1.isPriority { return $0.isPriority }
                if $0.nextReviewAt != $1.nextReviewAt { return $0.nextReviewAt < $1.nextReviewAt }
                return $0.id.uuidString < $1.id.uuidString
            }.filter { seen.insert($0.identity).inserted }
    }

    @discardableResult func createFormalReview(style: GradingStyle, type: ContentType? = nil, now: Date = .now) throws -> UUID {
        if let existing = state.sessions.first(where: { $0.isFormalReview && $0.reviewedAt == nil && $0.cancelledAt == nil }) { return existing.id }
        let completedIDs = Set(state.records.filter { $0.modeRawValue == "scheduled" && Calendar.current.isDate($0.reviewedAt, inSameDayAs: now) }.map(\.itemID))
        let remaining = max(0, state.practicePreferences.reviewDailyLimit - completedIDs.count)
        let due = Array(dueItems(now: now, type: type).prefix(remaining))
        guard let first = due.first else { throw LabError.invalid("当前没有到期复习题目。") }
        var next = state
        var session = DictationSession(title: "\(Codec.day(now)) 到期复习", type: first.typeRawValue, date: Calendar.current.startOfDay(for: now), now: now)
        session.practiceMode = "scheduled"; session.gradingStyle = style
        next.sessions.append(session)
        next.entries += due.enumerated().map { DictationEntry(sessionID: session.id, item: $0.element, order: $0.offset, now: now) }
        try commit(next); return session.id
    }
    func gradeOne(_ entryID: UUID, correct: Bool, now: Date = .now) throws {
        var next = state
        guard let index = next.entries.firstIndex(where: { $0.id == entryID }),
              let s = next.sessions.firstIndex(where: { $0.id == next.entries[index].sessionID }),
              next.sessions[s].startedAt != nil, next.sessions[s].reviewedAt == nil, next.sessions[s].cancelledAt == nil,
              next.entries[index].submittedRecordID == nil else { throw LabError.invalid("这条判定不能再次提交。") }
        next.entries[index].resultRawValue = correct ? "正确" : "错误"
        next.entries[index].updatedAt = now
        if next.sessions[s].isFormalReview { try Self.applyEntryResult(index: index, in: &next, now: now) }
        next.sessions[s].currentEntryIndex = min(next.entries[index].sortOrder + 1, entries(for: next.sessions[s].id).count)
        try commit(next)
    }
    func undoLastGrade(_ sessionID: UUID) throws {
        var next = state
        guard let s = next.sessions.firstIndex(where: { $0.id == sessionID }), next.sessions[s].reviewedAt == nil else { throw LabError.invalid("已经结束的练习不能撤销。") }
        let candidates = next.entries.indices.filter { next.entries[$0].sessionID == sessionID && next.entries[$0].resultRawValue != "未判定" }
        guard let index = candidates.max(by: { next.entries[$0].sortOrder < next.entries[$1].sortOrder }) else { throw LabError.invalid("没有可撤销的判定。") }
        if let recordID = next.entries[index].submittedRecordID, let before = next.entries[index].beforeReviewItem {
            guard next.records.last(where: { $0.itemID == before.id })?.id == recordID,
                  let itemIndex = next.items.firstIndex(where: { $0.id == before.id }) else { throw LabError.invalid("这道题已有后续练习记录，不能撤销较早的结果。") }
            next.items[itemIndex] = before; next.records.removeAll { $0.id == recordID }
        }
        next.entries[index].resultRawValue = "未判定"; next.entries[index].submittedRecordID = nil
        next.entries[index].beforeReviewItem = nil
        next.sessions[s].currentEntryIndex = next.entries[index].sortOrder; next.sessions[s].finishedAt = nil
        try commit(next)
    }
    func abandonReview(_ id: UUID) throws {
        var next = state
        guard let index = next.sessions.firstIndex(where: { $0.id == id }), next.sessions[index].isFormalReview,
              next.sessions[index].reviewedAt == nil else { throw LabError.invalid("本轮复习已经结束。") }
        next.sessions[index].cancelledAt = .now; try commit(next)
    }

    internal static func applyEntryResult(index: Int, in next: inout LabState, now: Date) throws {
        let entry = next.entries[index]
        if let recordID = entry.submittedRecordID {
            guard next.records.contains(where: { $0.id == recordID }) else { throw LabError.invalid("已提交判定缺少对应记录，请重新打开本轮练习。") }
            return
        }
        guard let session = next.sessions.first(where: { $0.id == entry.sessionID }) else { throw LabError.invalid("练习不存在。") }
        var itemIndex = entry.itemID.flatMap { id in next.items.firstIndex { $0.id == id } } ?? next.items.firstIndex { $0.identity == entry.identity }
        let isNew = itemIndex == nil
        if isNew {
            guard !session.isFormalReview else { throw LabError.invalid("复习题目已被移除，请结束本轮并重新安排。") }
            var item = ReviewItem(type: entry.typeRawValue, content: entry.content, prompt: entry.prompt, now: now)
            item.source = entry.source; item.note = entry.note; next.items.append(item); itemIndex = next.items.count - 1
        }
        let i = itemIndex!, correct = entry.resultRawValue == "正确"
        if session.isFormalReview {
            guard !next.records.contains(where: { $0.itemID == next.items[i].id && $0.modeRawValue == "scheduled" && Calendar.current.isDate($0.reviewedAt, inSameDayAs: now) }) else {
                throw LabError.invalid("这道题今天已经完成正式复习，不能重复推进阶段。")
            }
        }
        next.entries[index].itemID = next.items[i].id; next.entries[index].beforeReviewItem = next.items[i]
        var record: ReviewRecord
        if isNew {
            // Original dictation onboarding: correct -> day 3/day 7 follow-ups; wrong -> tomorrow.
            next.items[i].stage = correct ? 1 : 0
            next.items[i].reviewTrackRawValue = correct ? "dictationFollowUp" : "standard"
            next.items[i].dictationFollowUpStep = correct ? 1 : 0; next.items[i].isDictationPassRaw = correct
            next.items[i].nextReviewAt = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: correct ? 2 : 1, to: now)!)
            next.items[i].lastReviewedAt = now; next.items[i].updatedAt = now
            next.items[i].consecutiveCorrectCount = correct ? 1 : 0; next.items[i].consecutiveWrongCount = correct ? 0 : 1
            record = ReviewRecord(itemID: next.items[i].id, correct: correct, oldStage: 0, newStage: next.items[i].stage, now: now)
        } else { record = ReviewScheduler.apply(correct: correct, to: &next.items[i], now: now) }
        record.modeRawValue = session.isFormalReview ? "scheduled" : "dictation"; record.sessionID = session.id
        next.entries[index].submittedRecordID = record.id; next.records.append(record)
    }
    private static func validate(_ row: ParsedLearningLine) throws {
        guard !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, row.content.count <= 2000,
              row.prompt.count <= 2000, row.source.count <= 2000 else { throw LabError.invalid("内容不能为空，每个字段不超过 2000 字。") }
    }
}
