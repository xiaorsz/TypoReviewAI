import Foundation
import SwiftData

struct Grade5EnglishDictationPlanImportResult: Equatable {
    let insertedSessions: Int
    let refreshedSessions: Int
    let insertedEntries: Int
}

struct Grade5EnglishDictationPlanDeduplicationResult: Equatable {
    let removedSessions: Int
    let removedEntries: Int

    var removedTotal: Int {
        removedSessions + removedEntries
    }
}

enum Grade5EnglishDictationPlanImporter {
    static let planSource = "2026秋新人教版五年级英语上册·单元词汇表"

    struct VocabularyEntry: Equatable {
        let unit: Int
        let word: String
        let meaning: String
        let isLevelTwo: Bool
        let isRequired: Bool
        let page: Int
    }

    struct PlanDay: Equatable {
        let dayNumber: Int
        let unit: Int
        let topic: String
        let entries: [VocabularyEntry]

        var id: UUID {
            UUID(uuidString: String(format: "5E202607-1500-4000-8000-%012d", dayNumber))!
        }

        var title: String {
            String(format: "五上英语听写 第%02d天｜Unit %d %@", dayNumber, unit, topic)
        }

        var scheduledDate: Date {
            Self.calendar.date(byAdding: .day, value: dayNumber - 1, to: Self.startDate)!
        }

        private static var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            return calendar
        }

        private static var startDate: Date {
            calendar.date(from: DateComponents(
                timeZone: calendar.timeZone,
                year: 2026,
                month: 7,
                day: 15,
                hour: 12
            ))!
        }
    }

    static let topics: [Int: String] = [
        1: "Different friends",
        2: "My feelings",
        3: "Work and play",
        4: "Healthy habits",
        5: "Food we eat",
        6: "Nature and us"
    ]

    static let vocabulary: [VocabularyEntry] = parseVocabulary("""
    1|team|（游戏或运动的）队；（一起工作的）组，班|0|0|4
    1|player|运动员；参赛选手|0|0|4
    1|him|他|1|1|4
    1|lovely|美丽的；优美的|1|1|5
    1|clever|聪明的；聪颖的|1|1|5
    1|young|幼小的；年轻的|1|1|5
    1|hard-working|工作努力的；辛勤的|0|1|5
    1|science|科学；自然科学|1|0|7
    1|robot|机器人|1|1|7
    1|jump|跳；跃|1|1|8
    1|rope|绳；粗绳|0|1|8
    1|piano|钢琴|1|1|8
    1|chess|国际象棋|0|1|8
    1|front|前部|1|0|9
    1|easy|容易的；轻易的|1|0|9
    1|star|歌唱（或表演）明星|1|0|9
    1|wonderful|精彩的；绝妙的|1|0|9
    1|Australia|澳大利亚|0|0|4
    2|sad|悲哀的；难过的|1|1|16
    2|matter|事情；问题|0|0|16
    2|project|项目；方案|0|0|16
    2|centre|中心|0|0|16
    2|agree|同意；赞成|0|0|16
    2|finish|完成；做好|0|0|16
    2|Monday|星期一|0|0|16
    2|worried|担心的；担忧的|0|1|16
    2|both|两者|0|0|16
    2|excited|激动的；兴奋的|1|1|17
    2|wrong|错误的|1|0|17
    2|angry|愤怒的；生气的|1|1|17
    2|afraid|担心；害怕|0|0|19
    2|parent|父亲；母亲|1|1|20
    2|ask|问；询问|1|1|20
    2|move|搬家；移动|1|0|21
    2|yours|您的（用于书信结尾的签名前）|0|0|21
    3|Wednesday|星期三|0|1|28
    3|subject|科目；学科|1|0|28
    3|Monday|星期一|0|1|16
    3|Tuesday|星期二|0|1|28
    3|Friday|星期五|0|1|28
    3|because|因为|1|0|28
    3|Thursday|星期四|0|1|29
    3|start|开始|0|0|29
    3|usually|通常地；经常地|0|0|31
    3|weekend|周末|0|0|31
    3|sometimes|有时；间或|1|0|31
    3|Saturday|星期六|0|1|31
    3|Sunday|星期日|0|1|31
    3|lesson|课；一节课|1|1|31
    3|evening|晚上；傍晚|1|0|32
    3|answer|答复；回答|1|0|33
    3|ping-pong|乒乓球|1|0|33
    3|night|夜；夜晚|1|0|33
    3|visit|看望；拜访；参观|1|0|33
    3|grandparent|祖父；祖母；外祖父；外祖母|0|0|33
    4|stay|待；保持；继续是|0|0|40
    4|should|（提出或征询建议）该，可以|1|0|40
    4|flu|流行性感冒；流感|0|0|40
    4|else|其他的；别的|0|0|40
    4|exercise|锻炼；训练；操练|1|1|40
    4|enough|足够的；充足的；充分的|0|0|40
    4|if|如果；假若；倘若|0|0|40
    4|habit|习惯|0|0|41
    4|show|（电视或广播）节目|1|0|43
    4|phone|电话；电话机|1|1|43
    4|then|那么；因此；既然如此|1|0|43
    4|rest|休息；放松|0|1|43
    4|take care of|爱护；照顾|0|0|44
    4|check|查看；查明|0|1|44
    4|less|（与不可数名词连用）较少的，更少的|0|1|44
    4|brush|（用刷子）刷净，刷亮，刷平顺|0|1|44
    4|tooth|（复数 teeth）牙；齿|0|1|44
    4|twice|两次；两遍|0|0|44
    4|hour|小时|1|0|45
    4|free|没有安排活动的；空闲的|1|0|45
    5|hungry|感到饿的|1|0|52
    5|beef|牛肉|0|1|52
    5|ice cream|（一份）冰激凌|1|1|52
    5|little|少许；一点|1|0|52
    5|dumpling|饺子；汤圆|0|1|53
    5|tea|茶叶；茶；茶水|1|1|53
    5|hamburger|汉堡包；汉堡牛肉饼|0|1|53
    5|Mrs|（用于女子的姓氏或姓名前）太太，夫人|1|0|55
    5|coconut|椰子|0|0|55
    5|interesting|有趣的；有吸引力的|1|0|55
    5|seed|种子；籽|0|1|56
    5|pull|拔出；抽出|0|0|56
    5|pull up|拔出|0|0|56
    5|stem|（花草的）茎；（花或叶的）梗，柄|0|1|56
    5|root|根；根茎|0|1|56
    5|lotus|莲属植物|0|0|57
    5|lake|湖；湖泊|1|0|57
    5|world|世界；地球；天下|1|0|57
    5|round|圆形的；环形的；球形的|0|0|57
    5|different|不同的；有区别的；有差异的|0|0|57
    5|way|方法；手段；途径；方式|1|0|57
    6|river|河；江|1|1|64
    6|nature|自然界；大自然|0|0|64
    6|waterfall|瀑布|0|1|64
    6|forest|森林；林区|0|1|64
    6|famous|著名的；出名的|1|0|64
    6|mountain|高山；山岳|0|1|64
    6|wind|风；气流|0|0|67
    6|trip|（尤指短程往返的）旅行，旅游，出行|0|0|67
    6|dangerous|有危险的；不安全的|0|0|67
    6|heavy|程度大的；严重的|1|0|67
    6|hotel|旅馆；旅社|0|0|67
    6|close|关；关闭；闭上|1|0|67
    6|umbrella|伞；雨伞|1|0|67
    6|raincoat|雨衣|0|0|67
    6|worry|担心；担忧；发愁|1|0|67
    6|fine|晴朗的|1|0|67
    6|fog|雾|0|1|68
    6|flood|洪水；水灾|0|1|68
    6|fire|火；火灾|1|1|68
    6|know|知道；了解|1|0|69
    6|before|在……之前|1|0|69
    6|go hiking|徒步旅行|0|0|69
    6|bring|带……到某处；带来；取来|1|0|69
    """)

    static let plan: [PlanDay] = makePlan()

    @MainActor
    static func importPlan(
        in modelContext: ModelContext,
        now: Date = .now
    ) throws -> Grade5EnglishDictationPlanImportResult {
        let existingSessions = try modelContext.fetch(FetchDescriptor<DictationSession>())
        let existingEntries = try modelContext.fetch(FetchDescriptor<DictationEntry>())
        var sessionsByID: [UUID: DictationSession] = [:]
        for session in existingSessions where sessionsByID[session.id] == nil {
            sessionsByID[session.id] = session
        }
        let entriesBySessionID = Dictionary(grouping: existingEntries, by: \DictationEntry.sessionID)

        var insertedSessions = 0
        var refreshedSessions = 0
        var insertedEntries = 0

        for day in plan {
            let session: DictationSession
            if let existingSession = sessionsByID[day.id] {
                session = existingSession
                session.title = day.title
                session.type = .englishWord
                session.scheduledDate = day.scheduledDate
                session.updatedAt = now
                session.finishedAt = nil
                session.reviewedAt = nil

                for entry in entriesBySessionID[session.id] ?? [] {
                    modelContext.delete(entry)
                }
                refreshedSessions += 1
            } else {
                session = DictationSession(
                    id: day.id,
                    title: day.title,
                    type: .englishWord,
                    createdAt: now,
                    updatedAt: now,
                    scheduledDate: day.scheduledDate
                )
                modelContext.insert(session)
                insertedSessions += 1
            }

            for (index, entry) in day.entries.enumerated() {
                var noteParts = ["Unit \(entry.unit)", "p.\(entry.page)"]
                if entry.isLevelTwo { noteParts.append("二级词") }
                noteParts.append(entry.isRequired ? "重点运用" : "语境理解")

                modelContext.insert(
                    DictationEntry(
                        sessionID: session.id,
                        sortOrder: index,
                        type: .englishWord,
                        content: entry.word,
                        prompt: entry.meaning,
                        note: noteParts.joined(separator: " · "),
                        source: planSource,
                        result: .pending,
                        createdAt: now,
                        updatedAt: now
                    )
                )
                insertedEntries += 1
            }
        }

        try modelContext.save()
        AppDataChangeCenter.post()

        return Grade5EnglishDictationPlanImportResult(
            insertedSessions: insertedSessions,
            refreshedSessions: refreshedSessions,
            insertedEntries: insertedEntries
        )
    }

    /// Repairs duplicate plan records created when another device launched before its
    /// initial CloudKit download completed. This can safely run after every remote change.
    @discardableResult
    static func deduplicateImportedPlan(
        in modelContext: ModelContext
    ) throws -> Grade5EnglishDictationPlanDeduplicationResult {
        let planIDs = Set(plan.map(\.id))
        let sessions = try modelContext.fetch(FetchDescriptor<DictationSession>())
            .filter { planIDs.contains($0.id) }
        let entries = try modelContext.fetch(FetchDescriptor<DictationEntry>())
            .filter { planIDs.contains($0.sessionID) && $0.source == planSource }

        var removedSessions = 0
        var removedEntries = 0

        for duplicates in Dictionary(grouping: sessions, by: \.id).values where duplicates.count > 1 {
            let keeper = duplicates.sorted(by: sessionIsPreferred).first!
            mergeSessionProgress(from: duplicates, into: keeper)

            for duplicate in duplicates where duplicate !== keeper {
                modelContext.delete(duplicate)
                removedSessions += 1
            }
        }

        for duplicates in Dictionary(grouping: entries, by: EntryDeduplicationKey.init).values
            where duplicates.count > 1 {
            let keeper = duplicates.sorted(by: entryIsPreferred).first!

            for duplicate in duplicates where duplicate !== keeper {
                modelContext.delete(duplicate)
                removedEntries += 1
            }
        }

        if removedSessions > 0 || removedEntries > 0 {
            try modelContext.save()
            AppDataChangeCenter.post()
        }

        return Grade5EnglishDictationPlanDeduplicationResult(
            removedSessions: removedSessions,
            removedEntries: removedEntries
        )
    }

    private struct EntryDeduplicationKey: Hashable {
        let sessionID: UUID
        let sortOrder: Int
        let content: String

        init(_ entry: DictationEntry) {
            sessionID = entry.sessionID
            sortOrder = entry.sortOrder
            content = entry.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func sessionIsPreferred(_ lhs: DictationSession, _ rhs: DictationSession) -> Bool {
        let lhsProgress = sessionProgressRank(lhs)
        let rhsProgress = sessionProgressRank(rhs)
        if lhsProgress != rhsProgress { return lhsProgress > rhsProgress }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.title < rhs.title
    }

    private static func sessionProgressRank(_ session: DictationSession) -> Int {
        if session.reviewedAt != nil { return 2 }
        if session.finishedAt != nil { return 1 }
        return 0
    }

    private static func mergeSessionProgress(
        from sessions: [DictationSession],
        into keeper: DictationSession
    ) {
        keeper.createdAt = sessions.map(\.createdAt).min() ?? keeper.createdAt
        keeper.updatedAt = sessions.map(\.updatedAt).max() ?? keeper.updatedAt
        keeper.finishedAt = sessions.compactMap(\.finishedAt).max()
        keeper.reviewedAt = sessions.compactMap(\.reviewedAt).max()
    }

    private static func entryIsPreferred(_ lhs: DictationEntry, _ rhs: DictationEntry) -> Bool {
        let lhsHasResult = lhs.result != .pending
        let rhsHasResult = rhs.result != .pending
        if lhsHasResult != rhsHasResult { return lhsHasResult }
        if lhsHasResult, lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func makePlan() -> [PlanDay] {
        let dayCountsByUnit = [1: 6, 2: 6, 3: 7, 4: 7, 5: 7, 6: 7]
        var days: [PlanDay] = []
        var dayNumber = 1

        for unit in 1...6 {
            let unitEntries = vocabulary.filter { $0.unit == unit }
            let dayCount = dayCountsByUnit[unit]!
            let baseSize = unitEntries.count / dayCount
            let largerDayCount = unitEntries.count % dayCount
            var startIndex = 0

            for unitDayIndex in 0..<dayCount {
                let size = baseSize + (unitDayIndex < largerDayCount ? 1 : 0)
                let endIndex = startIndex + size
                days.append(
                    PlanDay(
                        dayNumber: dayNumber,
                        unit: unit,
                        topic: topics[unit]!,
                        entries: Array(unitEntries[startIndex..<endIndex])
                    )
                )
                startIndex = endIndex
                dayNumber += 1
            }
        }

        return days
    }

    private static func parseVocabulary(_ rawValue: String) -> [VocabularyEntry] {
        rawValue.split(separator: "\n").map { line in
            let columns = line.split(separator: "|", omittingEmptySubsequences: false)
            precondition(columns.count == 6, "Invalid Grade 5 English vocabulary row: \(line)")
            return VocabularyEntry(
                unit: Int(columns[0])!,
                word: String(columns[1]),
                meaning: String(columns[2]),
                isLevelTwo: columns[3] == "1",
                isRequired: columns[4] == "1",
                page: Int(columns[5])!
            )
        }
    }
}
