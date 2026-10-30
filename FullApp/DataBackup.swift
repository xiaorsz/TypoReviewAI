import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum DataBackupError: LocalizedError {
    case unsupportedVersion(Int)
    case missingFileData

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "暂不支持导入这个备份版本（v\(version)）。请先升级到支持该备份格式的 App 版本。"
        case .missingFileData:
            return "无法读取备份文件内容，请重新选择文件后再试。"
        }
    }
}

struct DataBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var payload: DataBackupPayload

    init(payload: DataBackupPayload) {
        self.payload = payload
    }

    init(data: Data) throws {
        payload = try DataBackupPayload.decode(from: data)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw DataBackupError.missingFileData
        }
        try self.init(data: data)
    }

    static var empty: DataBackupDocument {
        DataBackupDocument(payload: .placeholder)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try payload.encodedData())
    }
}

struct DataBackupPayload: Codable, @unchecked Sendable {
    static let currentVersion = 5

    let version: Int
    let exportedAt: Date
    let appVersion: String
    let settings: AppSettingsSnapshot?
    let reviewItems: [ReviewItemSnapshot]
    let reviewRecords: [ReviewRecordSnapshot]
    let taskItems: [TaskItemSnapshot]
    let taskCompletions: [TaskCompletionSnapshot]
    let taskSubitems: [TaskSubitemSnapshot]
    let taskExecutionRecords: [TaskExecutionRecordSnapshot]
    let taskSubitemExecutionRecords: [TaskSubitemExecutionRecordSnapshot]
    let dictationSessions: [DictationSessionSnapshot]
    let dictationEntries: [DictationEntrySnapshot]
    let scheduleItems: [ScheduleItemSnapshot]
    let mediaAssets: [MediaAssetSnapshot]
    let pointLedgerEntries: [PointLedgerEntrySnapshot]
    let pointRewardStates: [PointRewardStateSnapshot]
    let calculationRounds: [CalculationRoundSnapshot]

    enum CodingKeys: String, CodingKey {
        case version
        case exportedAt
        case appVersion
        case settings
        case reviewItems
        case reviewRecords
        case taskItems
        case taskCompletions
        case taskSubitems
        case taskExecutionRecords
        case taskSubitemExecutionRecords
        case dictationSessions
        case dictationEntries
        case scheduleItems
        case mediaAssets
        case pointLedgerEntries
        case pointRewardStates
        case calculationRounds
    }

    init(
        version: Int = DataBackupPayload.currentVersion,
        exportedAt: Date = .now,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知版本",
        settings: AppSettingsSnapshot?,
        reviewItems: [ReviewItemSnapshot],
        reviewRecords: [ReviewRecordSnapshot],
        taskItems: [TaskItemSnapshot],
        taskCompletions: [TaskCompletionSnapshot],
        taskSubitems: [TaskSubitemSnapshot],
        taskExecutionRecords: [TaskExecutionRecordSnapshot],
        taskSubitemExecutionRecords: [TaskSubitemExecutionRecordSnapshot],
        dictationSessions: [DictationSessionSnapshot],
        dictationEntries: [DictationEntrySnapshot],
        scheduleItems: [ScheduleItemSnapshot],
        mediaAssets: [MediaAssetSnapshot] = [],
        pointLedgerEntries: [PointLedgerEntrySnapshot] = [],
        pointRewardStates: [PointRewardStateSnapshot] = [],
        calculationRounds: [CalculationRoundSnapshot] = []
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.settings = settings
        self.reviewItems = reviewItems
        self.reviewRecords = reviewRecords
        self.taskItems = taskItems
        self.taskCompletions = taskCompletions
        self.taskSubitems = taskSubitems
        self.taskExecutionRecords = taskExecutionRecords
        self.taskSubitemExecutionRecords = taskSubitemExecutionRecords
        self.dictationSessions = dictationSessions
        self.dictationEntries = dictationEntries
        self.scheduleItems = scheduleItems
        self.mediaAssets = mediaAssets
        self.pointLedgerEntries = pointLedgerEntries
        self.pointRewardStates = pointRewardStates
        self.calculationRounds = calculationRounds
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        settings = try container.decodeIfPresent(AppSettingsSnapshot.self, forKey: .settings)
        reviewItems = try container.decode([ReviewItemSnapshot].self, forKey: .reviewItems)
        reviewRecords = try container.decode([ReviewRecordSnapshot].self, forKey: .reviewRecords)
        taskItems = try container.decode([TaskItemSnapshot].self, forKey: .taskItems)
        taskCompletions = try container.decode([TaskCompletionSnapshot].self, forKey: .taskCompletions)
        taskSubitems = try container.decodeIfPresent([TaskSubitemSnapshot].self, forKey: .taskSubitems) ?? []
        taskExecutionRecords = try container.decodeIfPresent([TaskExecutionRecordSnapshot].self, forKey: .taskExecutionRecords) ?? []
        taskSubitemExecutionRecords = try container.decodeIfPresent([TaskSubitemExecutionRecordSnapshot].self, forKey: .taskSubitemExecutionRecords) ?? []
        dictationSessions = try container.decode([DictationSessionSnapshot].self, forKey: .dictationSessions)
        dictationEntries = try container.decode([DictationEntrySnapshot].self, forKey: .dictationEntries)
        scheduleItems = try container.decode([ScheduleItemSnapshot].self, forKey: .scheduleItems)
        mediaAssets = try container.decodeIfPresent([MediaAssetSnapshot].self, forKey: .mediaAssets) ?? []
        pointLedgerEntries = try container.decodeIfPresent([PointLedgerEntrySnapshot].self, forKey: .pointLedgerEntries) ?? []
        pointRewardStates = try container.decodeIfPresent([PointRewardStateSnapshot].self, forKey: .pointRewardStates) ?? []
        calculationRounds = try container.decodeIfPresent([CalculationRoundSnapshot].self, forKey: .calculationRounds) ?? []
    }

    static var placeholder: DataBackupPayload {
        DataBackupPayload(
            settings: nil,
            reviewItems: [],
            reviewRecords: [],
            taskItems: [],
            taskCompletions: [],
            taskSubitems: [],
            taskExecutionRecords: [],
            taskSubitemExecutionRecords: [],
            dictationSessions: [],
            dictationEntries: [],
            scheduleItems: [],
            mediaAssets: [],
            pointLedgerEntries: [],
            pointRewardStates: [],
            calculationRounds: []
        )
    }

    static func capture(from modelContext: ModelContext, mediaAssets: [MediaLibraryAsset]) throws -> DataBackupPayload {
        try capture(from: modelContext, settings: nil, mediaAssets: mediaAssets)
    }

    static func capture(
        from modelContext: ModelContext,
        settings: AppSettingsSnapshot?,
        mediaAssets: [MediaLibraryAsset],
        recordIDs: [String: [UUID]]? = nil
    ) throws -> DataBackupPayload {
        // A scoped capture is for incremental conflict checks. Ordinary backups
        // and upload discovery continue to capture the complete store.
        func fetch<T: PersistentModel>(
            _ entity: String,
            predicate: ([UUID]) -> Predicate<T>
        ) throws -> [T] {
            guard let recordIDs else { return try modelContext.fetch(FetchDescriptor<T>()) }
            let ids = Array(Set(recordIDs[entity] ?? []))
            var models: [T] = []
            // Full verification can contain many thousands of IDs. Keep SQL
            // predicates bounded instead of one enormous IN expression.
            for start in stride(from: 0, to: ids.count, by: 256) {
                let batch = Array(ids[start..<min(start + 256, ids.count)])
                models.append(contentsOf: try modelContext.fetch(
                    FetchDescriptor<T>(predicate: predicate(batch))
                ))
            }
            return models
        }
        let reviewItems = try fetch("reviewItems") { ids in
            #Predicate<ReviewItem> { ids.contains($0.id) }
        }.map(ReviewItemSnapshot.init)
        let reviewRecords = try fetch("reviewRecords") { ids in
            #Predicate<ReviewRecord> { ids.contains($0.id) }
        }.map(ReviewRecordSnapshot.init)
        let taskItems = try fetch("taskItems") { ids in
            #Predicate<TaskItem> { ids.contains($0.id) }
        }.map(TaskItemSnapshot.init)
        let taskCompletions = try fetch("taskCompletions") { ids in
            #Predicate<TaskCompletion> { ids.contains($0.id) }
        }.map(TaskCompletionSnapshot.init)
        let taskSubitems = try fetch("taskSubitems") { ids in
            #Predicate<TaskSubitem> { ids.contains($0.id) }
        }.map(TaskSubitemSnapshot.init)
        let taskExecutionRecords = try fetch("taskExecutionRecords") { ids in
            #Predicate<TaskExecutionRecord> { ids.contains($0.id) }
        }.map(TaskExecutionRecordSnapshot.init)
        let taskSubitemExecutionRecords = try fetch("taskSubitemExecutionRecords") { ids in
            #Predicate<TaskSubitemExecutionRecord> { ids.contains($0.id) }
        }.map(TaskSubitemExecutionRecordSnapshot.init)
        let dictationSessions = try fetch("dictationSessions") { ids in
            #Predicate<DictationSession> { ids.contains($0.id) }
        }.map(DictationSessionSnapshot.init)
        let dictationEntries = try fetch("dictationEntries") { ids in
            #Predicate<DictationEntry> { ids.contains($0.id) }
        }.map(DictationEntrySnapshot.init)
        let scheduleItems = try fetch("scheduleItems") { ids in
            #Predicate<ScheduleItem> { ids.contains($0.id) }
        }.map(ScheduleItemSnapshot.init)
        let mediaAssetSnapshots = mediaAssets.map(MediaAssetSnapshot.init)
        var pointModels: [PointLedgerEntry] = try fetch("pointLedgerEntries") { ids in
            #Predicate<PointLedgerEntry> { ids.contains($0.id) }
        }
        if recordIDs != nil, !pointModels.isEmpty {
            // Include competing entries for the same reward key so scoped captures
            // choose exactly the same canonical row as full backups.
            let keys = Array(Set(pointModels.map(\.idempotencyKey).filter { !$0.isEmpty }))
            for start in stride(from: 0, to: keys.count, by: 256) {
                let batch = Array(keys[start..<min(start + 256, keys.count)])
                pointModels.append(contentsOf: try modelContext.fetch(FetchDescriptor<PointLedgerEntry>(
                    predicate: #Predicate<PointLedgerEntry> { batch.contains($0.idempotencyKey) }
                )))
            }
        }
        let pointLedgerEntries = PointLedgerService.canonicalEntries(pointModels)
            .map(PointLedgerEntrySnapshot.init)
        let pointRewardStates = try fetch("pointRewardStates") { ids in
            #Predicate<PointRewardState> { ids.contains($0.id) }
        }.map(PointRewardStateSnapshot.init)
        let calculationRounds = try fetch("calculationRounds") { ids in
            #Predicate<CalculationRound> { ids.contains($0.id) }
        }.map(CalculationRoundSnapshot.init)

        return DataBackupPayload(
            settings: settings,
            reviewItems: reviewItems,
            reviewRecords: reviewRecords,
            taskItems: taskItems,
            taskCompletions: taskCompletions,
            taskSubitems: taskSubitems,
            taskExecutionRecords: taskExecutionRecords,
            taskSubitemExecutionRecords: taskSubitemExecutionRecords,
            dictationSessions: dictationSessions,
            dictationEntries: dictationEntries,
            scheduleItems: scheduleItems,
            mediaAssets: mediaAssetSnapshots,
            pointLedgerEntries: pointLedgerEntries,
            pointRewardStates: pointRewardStates,
            calculationRounds: calculationRounds
        )
    }

    static func decode(from data: Data) throws -> DataBackupPayload {
        let decoder = JSONDecoder.typoReviewISO8601

        let payload = try decoder.decode(DataBackupPayload.self, from: data)
        guard payload.version <= currentVersion else {
            throw DataBackupError.unsupportedVersion(payload.version)
        }
        return payload
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "听写复习本AI版备份-\(formatter.string(from: exportedAt))"
    }

    var summaryText: String {
        [
            settings == nil ? nil : "设置 1 条",
            "题库 \(reviewItems.count) 条",
            "复习记录 \(reviewRecords.count) 条",
            "待办 \(taskItems.count) 条",
            "执行记录 \(max(taskExecutionRecords.count, taskCompletions.count)) 条",
            "子任务 \(taskSubitems.count) 条",
            "听写计划 \(dictationSessions.count) 组",
            "听写条目 \(dictationEntries.count) 条",
            "日程 \(scheduleItems.count) 条",
            "晨读资源 \(mediaAssets.count) 条",
            "积分流水 \(pointLedgerEntries.count) 条",
            "计算练习 \(calculationRounds.count) 轮"
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

enum DataBackupService {
    @MainActor
    static func makeDocument(
        from modelContext: ModelContext,
        settingsStore: AppSettingsStore,
        mediaAssets: [MediaLibraryAsset]
    ) throws -> DataBackupDocument {
        DataBackupDocument(
            payload: try DataBackupPayload.capture(
                from: modelContext,
                settings: settingsStore.snapshot,
                mediaAssets: mediaAssets
            )
        )
    }

    @MainActor
    static func restore(
        _ payload: DataBackupPayload,
        into modelContext: ModelContext,
        settingsStore: AppSettingsStore,
        mediaLibraryStore: MediaLibraryStore
    ) throws {
        try restoreStructuredDataUsingIsolatedContext(
            payload,
            basedOn: modelContext,
            settingsStore: settingsStore
        )
        try mediaLibraryStore.replaceAll(with: payload.mediaAssets.map { $0.makeModel() })
    }

    /// Replaces only the structured cache. Media indexes and media files stay local/iCloud-based.
    @MainActor
    static func restoreStructuredData(
        _ payload: DataBackupPayload,
        into modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) throws {
        try deleteAll(ReviewItem.self, in: modelContext)
        try deleteAll(ReviewRecord.self, in: modelContext)
        try deleteAll(ReviewDailyPlan.self, in: modelContext)
        try deleteAll(TaskItem.self, in: modelContext)
        try deleteAll(TaskCompletion.self, in: modelContext)
        try deleteAll(TaskSubitem.self, in: modelContext)
        try deleteAll(TaskExecutionRecord.self, in: modelContext)
        try deleteAll(TaskSubitemExecutionRecord.self, in: modelContext)
        try deleteAll(DictationSession.self, in: modelContext)
        try deleteAll(DictationEntry.self, in: modelContext)
        try deleteAll(ScheduleItem.self, in: modelContext)
        try deleteAll(PointLedgerEntry.self, in: modelContext)
        try deleteAll(PointRewardState.self, in: modelContext)
        try deleteAll(CalculationRound.self, in: modelContext)

        payload.reviewItems
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.reviewRecords
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.taskItems
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.taskCompletions
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.taskSubitems
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        let restoredTaskExecutions: [TaskExecutionRecord] = {
            if payload.taskExecutionRecords.isEmpty {
                return payload.taskCompletions.map { snapshot in
                    TaskExecutionRecord(
                        id: snapshot.id,
                        taskID: snapshot.taskID,
                        occurrenceDate: snapshot.completedDate,
                        detail: "",
                        status: .completed,
                        completedAt: snapshot.completedAt,
                        createdAt: snapshot.completedAt,
                        updatedAt: snapshot.completedAt
                    )
                }
            }
            return payload.taskExecutionRecords.map { $0.makeModel() }
        }()
        restoredTaskExecutions.forEach { modelContext.insert($0) }
        payload.taskSubitemExecutionRecords
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.dictationSessions
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.dictationEntries
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.scheduleItems
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.pointLedgerEntries
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.pointRewardStates
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }
        payload.calculationRounds
            .map { $0.makeModel() }
            .forEach { modelContext.insert($0) }

        TaskExecutionSupport.migrateLegacySubtasksIfNeeded(in: modelContext)
        _ = try TaskExecutionSupport.deduplicateSubtasks(in: modelContext)
        _ = try ReviewScheduler.normalizeStoredReviewDates(in: modelContext)

        if modelContext.hasChanges {
            try modelContext.save()
        }
        settingsStore.restore(from: payload.settings, using: modelContext)
    }

    /// Server bootstrap path. The actual replacement uses a short-lived context
    /// so a long-lived SwiftUI context cannot contribute stale object versions.
    @MainActor
    static func restoreStructuredDataInBatches(
        _ payload: DataBackupPayload,
        into modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async throws {
        try restoreStructuredDataUsingIsolatedContext(
            payload,
            basedOn: modelContext,
            settingsStore: settingsStore
        )
    }

    @MainActor
    private static func restoreStructuredDataUsingIsolatedContext(
        _ payload: DataBackupPayload,
        basedOn modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) throws {
        let container = modelContext.container
        try PersistentStoreAccessGate.withAccess {
            // The SwiftUI environment context can retain an older Core Data
            // generation after another context saves. Deleting those stale
            // registered models makes save() hit an optimistic-locking trap.
            // Fetch and replace through a newly-created context while holding
            // the store gate so every deleted object starts at the latest
            // committed generation.
            let restorationContext = ModelContext(container)
            restorationContext.autosaveEnabled = false
            try restoreStructuredData(
                payload,
                into: restorationContext,
                settingsStore: settingsStore
            )
        }
    }

    @MainActor
    private static func deleteAllInBatches<Model: PersistentModel>(
        _ type: Model.Type,
        in modelContext: ModelContext,
        batchSize: Int = 100
    ) async throws {
        let models = try modelContext.fetch(FetchDescriptor<Model>())
        for start in stride(from: 0, to: models.count, by: batchSize) {
            let end = min(start + batchSize, models.count)
            for model in models[start..<end] {
                modelContext.delete(model)
            }
            await Task.yield()
        }
    }

    @MainActor
    private static func insertInBatches<Snapshot, Model: PersistentModel>(
        _ snapshots: [Snapshot],
        into modelContext: ModelContext,
        batchSize: Int = 100,
        makeModel: (Snapshot) -> Model
    ) async {
        for start in stride(from: 0, to: snapshots.count, by: batchSize) {
            let end = min(start + batchSize, snapshots.count)
            for snapshot in snapshots[start..<end] {
                modelContext.insert(makeModel(snapshot))
            }
            await Task.yield()
        }
    }

    private static func deleteAll<Model: PersistentModel>(_ type: Model.Type, in modelContext: ModelContext) throws {
        try modelContext.fetch(FetchDescriptor<Model>()).forEach(modelContext.delete)
    }
}

extension JSONDecoder {
    static var typoReviewISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }
}

struct AppSettingsSnapshot: Codable, Equatable, Sendable {
    static let legacyUpdatedAt = Date(timeIntervalSince1970: 0)

    let id: UUID
    let childName: String
    let dailyLimit: Int
    let remindHour: Int
    let remindMinute: Int
    let reviewInteractionStyleRawValue: String
    let boardAutoplayEnabled: Bool
    let boardAutoplayStartHour: Int
    let boardAutoplayStartMinute: Int
    let boardAutoplayEndHour: Int
    let boardAutoplayEndMinute: Int
    let boardAutoplayDurationMinutes: Int
    let boardAutoplaySlotsRawValue: String
    let boardManualPlaybackOptionRawValue: String
    let boardAutoplaySkipWeekends: Bool
    let boardAutoplaySkipChinaHolidays: Bool
    let aiSummaryEnabled: Bool
    let aiSummaryModelRawValue: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case childName
        case dailyLimit
        case remindHour
        case remindMinute
        case reviewInteractionStyleRawValue
        case boardAutoplayEnabled
        case boardAutoplayStartHour
        case boardAutoplayStartMinute
        case boardAutoplayEndHour
        case boardAutoplayEndMinute
        case boardAutoplayDurationMinutes
        case boardAutoplaySlotsRawValue
        case boardManualPlaybackOptionRawValue
        case boardAutoplaySkipWeekends
        case boardAutoplaySkipChinaHolidays
        case aiSummaryEnabled
        case aiSummaryModelRawValue
        case updatedAt
    }

    init(_ settings: AppSettings, updatedAt: Date = AppSettingsSnapshot.legacyUpdatedAt) {
        id = settings.id
        childName = settings.childName
        dailyLimit = settings.dailyLimit
        remindHour = settings.remindHour
        remindMinute = settings.remindMinute
        reviewInteractionStyleRawValue = settings.reviewInteractionStyleRawValue
        boardAutoplayEnabled = settings.boardAutoplayEnabled
        boardAutoplayStartHour = settings.boardAutoplayStartHour
        boardAutoplayStartMinute = settings.boardAutoplayStartMinute
        boardAutoplayEndHour = settings.boardAutoplayEndHour
        boardAutoplayEndMinute = settings.boardAutoplayEndMinute
        boardAutoplayDurationMinutes = settings.boardAutoplayDurationMinutes
        boardAutoplaySlotsRawValue = settings.boardAutoplaySlotsRawValue
        boardManualPlaybackOptionRawValue = settings.boardManualPlaybackOptionRawValue
        boardAutoplaySkipWeekends = settings.boardAutoplaySkipWeekends
        boardAutoplaySkipChinaHolidays = settings.boardAutoplaySkipChinaHolidays
        aiSummaryEnabled = settings.aiSummaryEnabled
        aiSummaryModelRawValue = settings.aiSummaryModelRawValue
        self.updatedAt = updatedAt
    }

    // 内部用：不依赖 AppSettings 实例直接构造快照（避免 @Model 实例化问题）
    init(
        id: UUID,
        childName: String,
        dailyLimit: Int,
        remindHour: Int,
        remindMinute: Int,
        reviewInteractionStyleRawValue: String,
        boardAutoplayEnabled: Bool,
        boardAutoplayStartHour: Int,
        boardAutoplayStartMinute: Int,
        boardAutoplayEndHour: Int,
        boardAutoplayEndMinute: Int,
        boardAutoplayDurationMinutes: Int,
        boardAutoplaySlotsRawValue: String,
        boardManualPlaybackOptionRawValue: String,
        boardAutoplaySkipWeekends: Bool,
        boardAutoplaySkipChinaHolidays: Bool,
        aiSummaryEnabled: Bool,
        aiSummaryModelRawValue: String,
        updatedAt: Date = AppSettingsSnapshot.legacyUpdatedAt
    ) {
        self.id = id
        self.childName = childName
        self.dailyLimit = dailyLimit
        self.remindHour = remindHour
        self.remindMinute = remindMinute
        self.reviewInteractionStyleRawValue = reviewInteractionStyleRawValue
        self.boardAutoplayEnabled = boardAutoplayEnabled
        self.boardAutoplayStartHour = boardAutoplayStartHour
        self.boardAutoplayStartMinute = boardAutoplayStartMinute
        self.boardAutoplayEndHour = boardAutoplayEndHour
        self.boardAutoplayEndMinute = boardAutoplayEndMinute
        self.boardAutoplayDurationMinutes = boardAutoplayDurationMinutes
        self.boardAutoplaySlotsRawValue = boardAutoplaySlotsRawValue
        self.boardManualPlaybackOptionRawValue = boardManualPlaybackOptionRawValue
        self.boardAutoplaySkipWeekends = boardAutoplaySkipWeekends
        self.boardAutoplaySkipChinaHolidays = boardAutoplaySkipChinaHolidays
        self.aiSummaryEnabled = aiSummaryEnabled
        self.aiSummaryModelRawValue = aiSummaryModelRawValue
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        childName = try container.decode(String.self, forKey: .childName)
        dailyLimit = try container.decode(Int.self, forKey: .dailyLimit)
        remindHour = try container.decode(Int.self, forKey: .remindHour)
        remindMinute = try container.decode(Int.self, forKey: .remindMinute)
        reviewInteractionStyleRawValue = try container.decode(String.self, forKey: .reviewInteractionStyleRawValue)
        boardAutoplayEnabled = try container.decodeIfPresent(Bool.self, forKey: .boardAutoplayEnabled)
            ?? AppSettings.defaultBoardAutoplayEnabled
        boardAutoplayStartHour = try container.decodeIfPresent(Int.self, forKey: .boardAutoplayStartHour)
            ?? AppSettings.defaultBoardAutoplayStartHour
        boardAutoplayStartMinute = try container.decodeIfPresent(Int.self, forKey: .boardAutoplayStartMinute)
            ?? AppSettings.defaultBoardAutoplayStartMinute
        boardAutoplayEndHour = try container.decodeIfPresent(Int.self, forKey: .boardAutoplayEndHour)
            ?? AppSettings.defaultBoardAutoplayEndHour
        boardAutoplayEndMinute = try container.decodeIfPresent(Int.self, forKey: .boardAutoplayEndMinute)
            ?? AppSettings.defaultBoardAutoplayEndMinute
        let legacyDuration = max(
            1,
            (boardAutoplayEndHour * 60 + boardAutoplayEndMinute) - (boardAutoplayStartHour * 60 + boardAutoplayStartMinute)
        )
        boardAutoplayDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .boardAutoplayDurationMinutes)
            ?? legacyDuration
        boardAutoplaySlotsRawValue = try container.decodeIfPresent(String.self, forKey: .boardAutoplaySlotsRawValue)
            ?? ""
        boardManualPlaybackOptionRawValue = try container.decodeIfPresent(String.self, forKey: .boardManualPlaybackOptionRawValue)
            ?? AppSettings.defaultBoardManualPlaybackOption
        boardAutoplaySkipWeekends = try container.decodeIfPresent(Bool.self, forKey: .boardAutoplaySkipWeekends)
            ?? AppSettings.defaultBoardAutoplaySkipWeekends
        boardAutoplaySkipChinaHolidays = try container.decodeIfPresent(Bool.self, forKey: .boardAutoplaySkipChinaHolidays)
            ?? AppSettings.defaultBoardAutoplaySkipChinaHolidays
        aiSummaryEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiSummaryEnabled)
            ?? AppSettings.defaultAISummaryEnabled
        aiSummaryModelRawValue = try container.decodeIfPresent(String.self, forKey: .aiSummaryModelRawValue)
            ?? AppSettings.defaultAISummaryModelRawValue
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? AppSettingsSnapshot.legacyUpdatedAt
    }

    func makeModel() -> AppSettings {
        let settings = AppSettings(
            id: id,
            childName: childName,
            dailyLimit: dailyLimit,
            remindHour: remindHour,
            remindMinute: remindMinute,
            reviewInteractionStyle: ReviewInteractionStyle(rawValue: reviewInteractionStyleRawValue) ?? AppSettings.defaultReviewInteractionStyle,
            boardAutoplayEnabled: boardAutoplayEnabled,
            boardAutoplayStartHour: boardAutoplayStartHour,
            boardAutoplayStartMinute: boardAutoplayStartMinute,
            boardAutoplayEndHour: boardAutoplayEndHour,
            boardAutoplayEndMinute: boardAutoplayEndMinute,
            boardAutoplayDurationMinutes: boardAutoplayDurationMinutes,
            boardAutoplaySlots: nil,
            boardManualPlaybackOption: BoardManualPlaybackOption(rawValue: boardManualPlaybackOptionRawValue) ?? .untilPlaylistEnds,
            boardAutoplaySkipWeekends: boardAutoplaySkipWeekends,
            boardAutoplaySkipChinaHolidays: boardAutoplaySkipChinaHolidays,
            aiSummaryEnabled: aiSummaryEnabled,
            aiSummaryModelRawValue: aiSummaryModelRawValue
        )
        settings.reviewInteractionStyleRawValue = reviewInteractionStyleRawValue
        settings.boardAutoplaySlotsRawValue = boardAutoplaySlotsRawValue
        return settings
    }
}

struct ReviewItemSnapshot: Codable {
    let id: UUID
    let typeRawValue: String
    let content: String
    let prompt: String
    let note: String
    let source: String
    let stage: Int
    let nextReviewAt: Date
    let lastReviewedAt: Date?
    let consecutiveCorrectCount: Int
    let consecutiveWrongCount: Int
    let isPriority: Bool
    let reviewTrackRawValue: String?
    let dictationFollowUpStep: Int?
    let isDictationPassRaw: Bool?
    let createdAt: Date
    let updatedAt: Date

    init(_ item: ReviewItem) {
        id = item.id
        typeRawValue = item.typeRawValue
        content = item.content
        prompt = item.prompt
        note = item.note
        source = item.source
        stage = item.stage
        nextReviewAt = item.nextReviewAt
        lastReviewedAt = item.lastReviewedAt
        consecutiveCorrectCount = item.consecutiveCorrectCount
        consecutiveWrongCount = item.consecutiveWrongCount
        isPriority = item.isPriority
        reviewTrackRawValue = item.reviewTrackRawValue
        dictationFollowUpStep = item.dictationFollowUpStep
        isDictationPassRaw = item.isDictationPassRaw
        createdAt = item.createdAt
        updatedAt = item.updatedAt
    }

    func makeModel() -> ReviewItem {
        let item = ReviewItem(
            id: id,
            type: ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter,
            content: content,
            prompt: prompt,
            note: note,
            source: source,
            stage: stage,
            nextReviewAt: nextReviewAt,
            lastReviewedAt: lastReviewedAt,
            consecutiveCorrectCount: consecutiveCorrectCount,
            consecutiveWrongCount: consecutiveWrongCount,
            isPriority: isPriority,
            reviewTrack: ReviewTrack(rawValue: reviewTrackRawValue ?? "") ?? .standard,
            dictationFollowUpStep: dictationFollowUpStep ?? 0,
            isDictationPass: isDictationPassRaw ?? false,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        item.typeRawValue = typeRawValue
        if let reviewTrackRawValue {
            item.reviewTrackRawValue = reviewTrackRawValue
        }
        item.dictationFollowUpStep = dictationFollowUpStep ?? item.dictationFollowUpStep
        item.isDictationPassRaw = isDictationPassRaw
        return item
    }
}

struct ReviewRecordSnapshot: Codable {
    let id: UUID
    let itemID: UUID
    let reviewedAt: Date
    let resultRawValue: String
    let modeRawValue: String
    let oldStage: Int
    let newStage: Int
    let note: String

    init(_ record: ReviewRecord) {
        id = record.id
        itemID = record.itemID
        reviewedAt = record.reviewedAt
        resultRawValue = record.resultRawValue
        modeRawValue = record.modeRawValue
        oldStage = record.oldStage
        newStage = record.newStage
        note = record.note
    }

    func makeModel() -> ReviewRecord {
        let record = ReviewRecord(
            id: id,
            itemID: itemID,
            reviewedAt: reviewedAt,
            result: ReviewResult(rawValue: resultRawValue) ?? .correct,
            mode: ReviewMode(rawValue: modeRawValue) ?? .scheduled,
            oldStage: oldStage,
            newStage: newStage,
            note: note
        )
        record.resultRawValue = resultRawValue
        record.modeRawValue = modeRawValue
        return record
    }
}

struct TaskItemSnapshot: Codable {
    let id: UUID
    let title: String
    let note: String
    let recurrenceJSON: String?
    let skipPolicyRawValue: String?
    let timingModeRawValue: String?
    let startDate: Date
    let endDate: Date?
    let deadline: Date?
    let pauseIntervalsJSON: String?
    let pauseStartedAt: Date?
    let isArchived: Bool
    let createdAt: Date
    let updatedAt: Date

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        note = task.note
        recurrenceJSON = task.recurrenceJSON
        skipPolicyRawValue = task.skipPolicyRawValue
        timingModeRawValue = task.timingModeRawValue
        startDate = task.startDate
        endDate = task.endDate
        deadline = task.deadline
        pauseIntervalsJSON = task.pauseIntervalsJSON
        pauseStartedAt = task.pauseStartedAt
        isArchived = task.isArchived
        createdAt = task.createdAt
        updatedAt = task.updatedAt
    }

    func makeModel() -> TaskItem {
        let task = TaskItem(
            id: id,
            title: title,
            note: note,
            recurrence: recurrenceJSON.map(TaskRecurrence.fromJSON) ?? .once,
            skipPolicy: skipPolicyRawValue.flatMap(TaskSkipPolicy.init(rawValue:)) ?? .skippable,
            timingMode: timingModeRawValue.flatMap(TaskTimingMode.init(rawValue:)) ?? .scheduled,
            startDate: startDate,
            endDate: endDate,
            deadline: deadline,
            pauseIntervalsJSON: pauseIntervalsJSON,
            pauseStartedAt: pauseStartedAt,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        task.recurrenceJSON = recurrenceJSON
        task.skipPolicyRawValue = skipPolicyRawValue
        task.timingModeRawValue = timingModeRawValue
        return task
    }
}

struct TaskCompletionSnapshot: Codable {
    let id: UUID
    let taskID: UUID
    let completedDate: Date
    let completedAt: Date

    init(_ completion: TaskCompletion) {
        id = completion.id
        taskID = completion.taskID
        completedDate = completion.completedDate
        completedAt = completion.completedAt
    }

    func makeModel() -> TaskCompletion {
        TaskCompletion(
            id: id,
            taskID: taskID,
            completedDate: completedDate,
            completedAt: completedAt
        )
    }
}

struct TaskSubitemSnapshot: Codable {
    let id: UUID
    let parentTaskID: UUID
    let taskExecutionIDRawValue: String
    let title: String
    let note: String
    let detail: String
    let statusRawValue: String
    let sortOrder: Int
    let isArchived: Bool
    let completedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case parentTaskID
        case taskExecutionIDRawValue
        case title
        case note
        case detail
        case statusRawValue
        case sortOrder
        case isArchived
        case completedAt
        case createdAt
        case updatedAt
    }

    init(_ subtask: TaskSubitem) {
        id = subtask.id
        parentTaskID = subtask.parentTaskID
        taskExecutionIDRawValue = subtask.taskExecutionIDRawValue
        title = subtask.title
        note = subtask.note
        detail = subtask.detail
        statusRawValue = subtask.statusRawValue
        sortOrder = subtask.sortOrder
        isArchived = subtask.isArchived
        completedAt = subtask.completedAt
        createdAt = subtask.createdAt
        updatedAt = subtask.updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        parentTaskID = try container.decode(UUID.self, forKey: .parentTaskID)
        taskExecutionIDRawValue = try container.decodeIfPresent(String.self, forKey: .taskExecutionIDRawValue) ?? ""
        title = try container.decode(String.self, forKey: .title)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        statusRawValue = try container.decodeIfPresent(String.self, forKey: .statusRawValue) ?? TaskExecutionStatus.pending.rawValue
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func makeModel() -> TaskSubitem {
        TaskSubitem(
            id: id,
            parentTaskID: parentTaskID,
            taskExecutionID: UUID(uuidString: taskExecutionIDRawValue),
            title: title,
            note: note,
            detail: detail,
            status: TaskExecutionStatus(rawValue: statusRawValue) ?? .pending,
            sortOrder: sortOrder,
            isArchived: isArchived,
            completedAt: completedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct TaskExecutionRecordSnapshot: Codable {
    let id: UUID
    let taskID: UUID
    let occurrenceDate: Date
    let detail: String
    let statusRawValue: String
    let completedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(_ record: TaskExecutionRecord) {
        id = record.id
        taskID = record.taskID
        occurrenceDate = record.occurrenceDate
        detail = record.detail
        statusRawValue = record.statusRawValue
        completedAt = record.completedAt
        createdAt = record.createdAt
        updatedAt = record.updatedAt
    }

    func makeModel() -> TaskExecutionRecord {
        let record = TaskExecutionRecord(
            id: id,
            taskID: taskID,
            occurrenceDate: occurrenceDate,
            detail: detail,
            status: TaskExecutionStatus(rawValue: statusRawValue) ?? .pending,
            completedAt: completedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        record.statusRawValue = statusRawValue
        return record
    }
}

struct TaskSubitemExecutionRecordSnapshot: Codable {
    let id: UUID
    let taskExecutionID: UUID
    let subtaskID: UUID
    let detail: String
    let statusRawValue: String
    let completedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(_ record: TaskSubitemExecutionRecord) {
        id = record.id
        taskExecutionID = record.taskExecutionID
        subtaskID = record.subtaskID
        detail = record.detail
        statusRawValue = record.statusRawValue
        completedAt = record.completedAt
        createdAt = record.createdAt
        updatedAt = record.updatedAt
    }

    func makeModel() -> TaskSubitemExecutionRecord {
        let record = TaskSubitemExecutionRecord(
            id: id,
            taskExecutionID: taskExecutionID,
            subtaskID: subtaskID,
            detail: detail,
            status: TaskExecutionStatus(rawValue: statusRawValue) ?? .pending,
            completedAt: completedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        record.statusRawValue = statusRawValue
        return record
    }
}

struct DictationSessionSnapshot: Codable {
    let id: UUID
    let title: String
    let typeRawValue: String
    let createdAt: Date
    let updatedAt: Date
    let scheduledDate: Date
    let finishedAt: Date?
    let reviewedAt: Date?
    let currentEntryIndex: Int

    init(_ session: DictationSession) {
        id = session.id
        title = session.title
        typeRawValue = session.typeRawValue
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        scheduledDate = session.scheduledDate
        finishedAt = session.finishedAt
        reviewedAt = session.reviewedAt
        currentEntryIndex = session.currentEntryIndex
    }

    // 向后兼容：旧备份和旧版本推送的同步载荷没有 currentEntryIndex 字段。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        typeRawValue = try container.decode(String.self, forKey: .typeRawValue)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        scheduledDate = try container.decode(Date.self, forKey: .scheduledDate)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        reviewedAt = try container.decodeIfPresent(Date.self, forKey: .reviewedAt)
        currentEntryIndex = try container.decodeIfPresent(Int.self, forKey: .currentEntryIndex) ?? 0
    }

    func makeModel() -> DictationSession {
        let session = DictationSession(
            id: id,
            title: title,
            type: ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter,
            createdAt: createdAt,
            updatedAt: updatedAt,
            scheduledDate: scheduledDate,
            finishedAt: finishedAt,
            reviewedAt: reviewedAt,
            currentEntryIndex: currentEntryIndex
        )
        session.typeRawValue = typeRawValue
        return session
    }
}

struct DictationEntrySnapshot: Codable {
    let id: UUID
    let sessionID: UUID
    let sortOrder: Int
    let typeRawValue: String
    let content: String
    let prompt: String
    let note: String
    let source: String
    let resultRawValue: String
    let createdAt: Date
    let updatedAt: Date

    init(_ entry: DictationEntry) {
        id = entry.id
        sessionID = entry.sessionID
        sortOrder = entry.sortOrder
        typeRawValue = entry.typeRawValue
        content = entry.content
        prompt = entry.prompt
        note = entry.note
        source = entry.source
        resultRawValue = entry.resultRawValue
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
    }

    func makeModel() -> DictationEntry {
        let entry = DictationEntry(
            id: id,
            sessionID: sessionID,
            sortOrder: sortOrder,
            type: ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter,
            content: content,
            prompt: prompt,
            note: note,
            source: source,
            result: DictationResult(rawValue: resultRawValue) ?? .pending,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        entry.typeRawValue = typeRawValue
        entry.resultRawValue = resultRawValue
        return entry
    }
}

struct ScheduleItemSnapshot: Codable {
    let id: UUID
    let title: String
    let note: String
    let startTime: Date
    let endTime: Date
    let repeatRuleRawValue: String
    let weekdaysJSON: String
    let effectiveStartDate: Date
    let effectiveEndDate: Date?
    let isArchived: Bool
    let createdAt: Date
    let updatedAt: Date

    init(_ schedule: ScheduleItem) {
        id = schedule.id
        title = schedule.title
        note = schedule.note
        startTime = schedule.startTime
        endTime = schedule.endTime
        repeatRuleRawValue = schedule.repeatRuleRawValue
        weekdaysJSON = schedule.weekdaysJSON
        effectiveStartDate = schedule.effectiveStartDate
        effectiveEndDate = schedule.effectiveEndDate
        isArchived = schedule.isArchived
        createdAt = schedule.createdAt
        updatedAt = schedule.updatedAt
    }

    func makeModel() -> ScheduleItem {
        let schedule = ScheduleItem(
            id: id,
            title: title,
            note: note,
            startTime: startTime,
            endTime: endTime,
            repeatRule: ScheduleRepeatRule(rawValue: repeatRuleRawValue) ?? .once,
            weekdays: (try? JSONDecoder().decode([Int].self, from: Data(weekdaysJSON.utf8))) ?? [],
            effectiveStartDate: effectiveStartDate,
            effectiveEndDate: effectiveEndDate,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        schedule.repeatRuleRawValue = repeatRuleRawValue
        schedule.weekdaysJSON = weekdaysJSON
        return schedule
    }
}

struct MediaAssetSnapshot: Codable {
    let id: UUID
    let title: String
    let originalFilename: String
    let storedFilename: String
    let mediaTypeRawValue: String
    let storageScopeRawValue: String
    let playlistOrder: Int
    let isIncludedInPlaylist: Bool
    let createdAt: Date
    let updatedAt: Date

    init(_ asset: MediaLibraryAsset) {
        id = asset.id
        title = asset.title
        originalFilename = asset.originalFilename
        storedFilename = asset.storedFilename
        mediaTypeRawValue = asset.mediaTypeRawValue
        storageScopeRawValue = asset.storageScopeRawValue
        playlistOrder = asset.playlistOrder
        isIncludedInPlaylist = asset.isIncludedInPlaylist
        createdAt = asset.createdAt
        updatedAt = asset.updatedAt
    }

    func makeModel() -> MediaLibraryAsset {
        MediaLibraryAsset(
            id: id,
            title: title,
            originalFilename: originalFilename,
            storedFilename: storedFilename,
            mediaType: MediaAssetType(rawValue: mediaTypeRawValue) ?? .audio,
            storageScope: MediaStorageScope(rawValue: storageScopeRawValue) ?? .local,
            playlistOrder: playlistOrder,
            isIncludedInPlaylist: isIncludedInPlaylist,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct PointLedgerEntrySnapshot: Codable {
    let id: UUID
    let createdAt: Date
    let amount: Int
    let kindRawValue: String
    let sourceTypeRawValue: String
    let sourceIDRawValue: String
    let idempotencyKey: String
    let note: String
    let isReversal: Bool
    let reversesEntryIDRawValue: String?

    init(_ entry: PointLedgerEntry) {
        id = entry.id
        createdAt = entry.createdAt
        amount = entry.amount
        kindRawValue = entry.kindRawValue
        sourceTypeRawValue = entry.sourceTypeRawValue
        sourceIDRawValue = entry.sourceIDRawValue
        idempotencyKey = entry.idempotencyKey
        note = entry.note
        isReversal = entry.isReversal
        reversesEntryIDRawValue = entry.reversesEntryIDRawValue
    }

    func makeModel() -> PointLedgerEntry {
        let entry = PointLedgerEntry(
            id: id,
            createdAt: createdAt,
            amount: amount,
            kind: PointLedgerKind(rawValue: kindRawValue) ?? .reward,
            sourceType: PointLedgerSourceType(rawValue: sourceTypeRawValue) ?? .reviewRecord,
            sourceIDRawValue: sourceIDRawValue,
            idempotencyKey: idempotencyKey,
            note: note,
            isReversal: isReversal,
            reversesEntryIDRawValue: reversesEntryIDRawValue
        )
        entry.kindRawValue = kindRawValue
        entry.sourceTypeRawValue = sourceTypeRawValue
        return entry
    }
}

struct PointRewardStateSnapshot: Codable {
    let id: UUID
    let currentStreak: Int
    let lastActiveDay: Date?
    let longestStreak: Int
    let updatedAt: Date

    init(_ state: PointRewardState) {
        id = state.id
        currentStreak = state.currentStreak
        lastActiveDay = state.lastActiveDay
        longestStreak = state.longestStreak
        updatedAt = state.updatedAt
    }

    func makeModel() -> PointRewardState {
        PointRewardState(
            id: id,
            currentStreak: currentStreak,
            lastActiveDay: lastActiveDay,
            longestStreak: longestStreak,
            updatedAt: updatedAt
        )
    }
}

struct CalculationRoundSnapshot: Codable, Sendable {
    let id: UUID
    let dayKey: String
    let roundIndex: Int
    let generatorVersion: Int
    let questionsRawValue: String
    let answersRawValue: String
    let correctCount: Int
    let startedAt: Date
    let submittedAt: Date?
    let durationSeconds: Double
    let createdAt: Date
    let updatedAt: Date

    init(_ round: CalculationRound) {
        id = round.id
        dayKey = round.dayKey
        roundIndex = round.roundIndex
        generatorVersion = round.generatorVersion
        questionsRawValue = round.questionsRawValue
        answersRawValue = round.answersRawValue
        correctCount = round.correctCount
        startedAt = round.startedAt
        submittedAt = round.submittedAt
        durationSeconds = round.durationSeconds
        createdAt = round.createdAt
        updatedAt = round.updatedAt
    }

    func makeModel() -> CalculationRound {
        let round = CalculationRound(
            id: id,
            dayKey: dayKey,
            roundIndex: roundIndex,
            generatorVersion: generatorVersion,
            questions: [],
            answers: [],
            correctCount: correctCount,
            startedAt: startedAt,
            submittedAt: submittedAt,
            durationSeconds: durationSeconds,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        round.questionsRawValue = questionsRawValue
        round.answersRawValue = answersRawValue
        return round
    }
}
