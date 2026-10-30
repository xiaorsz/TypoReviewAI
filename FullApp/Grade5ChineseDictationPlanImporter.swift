import Foundation
import SwiftData

struct Grade5ChineseDictationPlanImportResult: Equatable {
    let insertedSessions: Int
    let refreshedSessions: Int
    let insertedEntries: Int
}

enum Grade5ChineseDictationPlanImporter {
    static let launchArgument = "--import-grade5-dictation-20260715"
    static let planSource = "人教版五年级语文上册"
    static let officialWordSource = "人教版五上·词语表"
    static let writingWordSource = "人教版五上·写字表组词"

    struct PlanEntry: Equatable {
        let content: String
        let isWritingSupplement: Bool
    }

    struct PlanDay: Equatable {
        let dayNumber: Int
        let lessonTitle: String
        let entries: [PlanEntry]

        var id: UUID {
            UUID(uuidString: String(format: "5A202607-1500-4000-8000-%012d", dayNumber))!
        }

        var title: String {
            String(format: "五上语文听写 第%02d天｜%@", dayNumber, lessonTitle)
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

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static let plan: [PlanDay] = [
        makeDay(1, "第1课《白鹭》", "精巧、配合、身段、适宜、白鹤、生硬、寻常、忘却、镜匣、孤独、悠然"),
        makeDay(2, "第1课《白鹭》＋第2课《落花生》", "嗜好、黄昏、恩惠、美中不足、★嫌弃、★朱红、★嵌入、★玻璃框、★望哨、★韵味、播种"),
        makeDay(3, "第2课《落花生》＋第3课《桂花雨》", "浇水、吩咐、榨油、爱慕、体面、深夜、★半亩、★茅亭、★矮小、★谈话、桂花"),
        makeDay(4, "第3课《桂花雨》＋第5课《搭石》", "懂得、糕饼、茶叶、★木兰花、★箩筐、★老婆婆、★沉浸、★缠绕、★捡起、汛期、山洪"),
        makeDay(5, "第5课《搭石》", "暴发、间隔、唯独、懒惰、平稳、保持、平衡、协调、美感、示意、家常"),
        makeDay(6, "第5课《搭石》＋第6课《将相和》", "假如、理所当然、联结、★访友、★脱鞋挽裤、★人影绰绰、无价之宝、召集、大臣、商议、解决"),
        makeDay(7, "第6课《将相和》", "完好无缺、称赞、商量、允诺、典礼、得罪、胆怯、示弱、拒绝、职位、同心协力"),
        makeDay(8, "第6课《将相和》＋第7课《什么比猎豹的速度更快》", "★进宫、★献上、★抄小路、★负荆请罪、猎豹、冠军、陆地、俯冲、高速公路、搭乘、火箭"),
        makeDay(9, "第7课《什么比猎豹的速度更快》＋第8课《冀中的地道战》", "发动机、手电筒、赤道、难以置信、★喷气式飞机、★一枚火箭、★一束光柱、★圆圈、侵略、修筑、粉碎"),
        makeDay(10, "第8课《冀中的地道战》", "领导、不计其数、打击、坚持、游击、隐蔽、陷坑、拐弯、无穷无尽、★堡垒、★中国共产党"),
        makeDay(11, "第8课《冀中的地道战》＋第9课《猎人海力布》", "★任丘、★妨碍、猎物、酬谢、珍宝、叮嘱、复活、议论、崩塌、焦急、发誓"),
        makeDay(12, "第9课《猎人海力布》＋第10课《牛郎织女（一）》", "千真万确、谎话、迟延、镇定、后悔、悲痛、震天动地、★扶着老人、嫂子、剩饭、床铺"),
        makeDay(13, "第10课《牛郎织女（一）》", "亲密、笑嘻嘻、成家立业、好歹、稀罕、妻子、晚霞、一辈子、结婚、相依为命、★牛郎"),
        makeDay(14, "第10课《牛郎织女（一）》＋第12课《古诗三首》", "★爹娘、★一辆车、★纱衣、★一趟、★托着、★溜出来、★挨着、★家祭、★乃翁、★熏得、★杭州"),
        makeDay(15, "第12课《古诗三首》＋第13课《少年中国说（节选）》", "★己亥、★恃风雷、★悲哀、★不拘一格、★一泻汪洋、★潜龙腾渊、★试翼、★初胎、★富丽堂皇、★地履其黄、★与国无疆"),
        makeDay(16, "第14课《圆明园的毁灭》", "毁灭、不可估量、举世闻名、众星拱月、金碧辉煌、殿堂、象征、仿照、诗情画意、建筑、漫游"),
        makeDay(17, "第14课《圆明园的毁灭》", "天南海北、饱览、风景名胜、境界、宏伟、奇珍异宝、博物馆、统统、搬运、销毁、罪证"),
        makeDay(18, "第14课《圆明园的毁灭》＋第16课《太阳》", "奉命、★武陵春色、★唐宋元明清、★闯进圆明园、寸草不生、摄氏度、繁殖、粮食、煤炭、飘浮、地区"),
        makeDay(19, "第16课《太阳》＋第17课《松鼠》", "杀菌、治疗、松鼠、乖巧、清秀、玲珑、歇凉、追逐、警觉、触动、光滑"),
        makeDay(20, "第17课《松鼠》＋第18课《慈母情深》", "狭窄、勉强、脱落、梳理、★做窝、★拾榛子、长篇、连续、广播、铁路、辞退"),
        makeDay(21, "第18课《慈母情深》", "挣钱、压抑、潮湿、忙碌、阴暗、酷暑、炎夏、噪声、瘦弱、脊背、口罩"),
        makeDay(22, "第18课《慈母情深》＋第19课《父爱之舟》", "忍心、机械、数落、权利、★吊着、★竟然、★好哇、★鼻子一酸、渔船、报考、教训"),
        makeDay(23, "第19课《父爱之舟》", "心疼、席子、庙会、彩排、糖果、抽象、启迪、毕业、寄宿、师范、路费"),
        makeDay(24, "第19课《父爱之舟》", "轮换、领略、意境、磨灭、精致、★蚕宝宝、★纸屑、★钉鞋、★陪嫁、★煮饭"),
        makeDay(25, "第19课《父爱之舟》＋第21课《古诗词三首》＋第22课《四季之美》", "★枕边、★王孙、★枫桥夜泊、★对愁眠、★寒山寺、★那畔行、黎明、红晕、漆黑、萤火虫"),
        makeDay(26, "第22课《四季之美》", "大雁、夜幕、降临、心旷神怡、炭火、火盆、走廊、闲逸、未免、★愈发"),
        makeDay(27, "第23课《鸟的天堂》", "陆续、白茫茫、榕树、纠正、不可计数、照耀、涨潮、树梢、应接不暇、画眉"),
        makeDay(28, "第23课《鸟的天堂》＋第25课《古人谈读书》＋第26课《忆读书》", "★三支桨、★木桩、★高塔、★抛在后面、★不耻下问、★诲人不倦、★余尝谓、★诵读、★岂不到乎、舅父"),
        makeDay(29, "第26课《忆读书》", "津津有味、英雄、无限、一知半解、述说、厌烦、荒唐、辛酸、访问、书刊"),
        makeDay(30, "第26课《忆读书》", "烦琐、真情实感、质朴、刊物、★斩黄巾、★凯旋、★诸葛亮、★贾宝玉、★兴亡盛衰、★某年")
    ]

    @MainActor
    static func importIfRequested(
        in modelContext: ModelContext,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        now: Date = .now
    ) throws -> Grade5ChineseDictationPlanImportResult? {
        guard arguments.contains(launchArgument) else { return nil }

        return try importPlan(in: modelContext, now: now)
    }

    @MainActor
    static func importPlan(
        in modelContext: ModelContext,
        now: Date = .now
    ) throws -> Grade5ChineseDictationPlanImportResult {

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
                session.type = .phrase
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
                    type: .phrase,
                    createdAt: now,
                    updatedAt: now,
                    scheduledDate: day.scheduledDate
                )
                modelContext.insert(session)
                insertedSessions += 1
            }

            for (index, entry) in day.entries.enumerated() {
                modelContext.insert(
                    DictationEntry(
                        sessionID: session.id,
                        sortOrder: index,
                        type: .phrase,
                        content: entry.content,
                        prompt: "",
                        note: entry.isWritingSupplement ? "写字表补充组词" : "课本词语表",
                        source: entry.isWritingSupplement ? writingWordSource : officialWordSource,
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

        return Grade5ChineseDictationPlanImportResult(
            insertedSessions: insertedSessions,
            refreshedSessions: refreshedSessions,
            insertedEntries: insertedEntries
        )
    }

    private static func makeDay(_ number: Int, _ lessonTitle: String, _ rawEntries: String) -> PlanDay {
        PlanDay(
            dayNumber: number,
            lessonTitle: lessonTitle,
            entries: rawEntries.split(separator: "、").map { rawEntry in
                let isWritingSupplement = rawEntry.hasPrefix("★")
                let content = isWritingSupplement ? rawEntry.dropFirst() : rawEntry[rawEntry.startIndex...]
                return PlanEntry(content: String(content), isWritingSupplement: isWritingSupplement)
            }
        )
    }
}
