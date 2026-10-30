import SwiftUI
import SwiftData
import SQLite3
import UIKit

@main
struct TypoReviewApp: App {
    private static let cloudKitContainerIdentifierValue = CloudStorageConfiguration.containerIdentifier
    private static let appGroupIdentifierValue = "group.cc.xiaorsz.dictation-coach-lab"
    private static let reviewDateNormalizationMigrationKey = "review_dates_normalized_to_natural_day_v1"

    @State private var syncStatusStore = SyncStatusStore()
    @State private var mediaLibraryStore = MediaLibraryStore()
    @State private var appSettingsStore: AppSettingsStore
    private let sharedModelContainer: ModelContainer
    private let startupMaintenanceCoordinator: StartupMaintenanceCoordinator
    private var persistenceInitializationFailure: PersistenceInitializationFailure?

    init() {
        _appSettingsStore = State(initialValue: AppSettingsStore(appGroupIdentifier: nil))
        let schema = Schema([
            ReviewItem.self, ReviewRecord.self, SyncDeletion.self, ReviewDailyPlan.self,
            TaskItem.self, TaskCompletion.self, TaskSubitem.self, TaskExecutionRecord.self,
            TaskSubitemExecutionRecord.self, AppSettings.self, DictationSession.self,
            DictationEntry.self, ScheduleItem.self, MediaAsset.self, PointLedgerEntry.self,
            PointRewardState.self, CalculationRound.self
        ])
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeURL = support.appendingPathComponent("coach-full.store")
        var maintenanceURL: URL? = storeURL
        var isTest = false
        #if DEBUG
        isTest = CloudStorageConfiguration.isTestRuntime || AppStorePreviewMode.isEnabled
        #endif
        var cloudKitEnabled = false
        var cloudInitializationError = ""
        if isTest {
            maintenanceURL = nil
            sharedModelContainer = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            persistenceInitializationFailure = nil
        } else {
            do {
                try CloudStorageConfiguration.backupLocalStoreIfNeeded(at: storeURL)
                sharedModelContainer = try ModelContainer(for: schema, configurations: [CloudStorageConfiguration.cloudConfiguration(schema: schema, storeURL: storeURL)])
                cloudKitEnabled = true
                UserDefaults.standard.set(true, forKey: CloudStorageConfiguration.migrationKey)
                persistenceInitializationFailure = nil
            } catch {
                let cloudFailure = error as NSError
                cloudInitializationError = cloudFailure.localizedDescription
                do {
                    sharedModelContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)])
                    persistenceInitializationFailure = nil
                } catch {
                    sharedModelContainer = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
                    maintenanceURL = nil
                    persistenceInitializationFailure = PersistenceInitializationFailure(cloudError: cloudFailure, localError: error as NSError)
                }
            }
        }
        let sync = SyncStatusStore()
        sync.configure(cloudKitEnabled: cloudKitEnabled, serverSyncEnabled: false,
            containerIdentifier: Self.cloudKitContainerIdentifierValue, initializationError: cloudInitializationError)
        _syncStatusStore = State(initialValue: sync)
        startupMaintenanceCoordinator = StartupMaintenanceCoordinator(storeURL: maintenanceURL, pendingExecutionTableRepairStoreURL: nil, appGroupIdentifier: nil)
    }

    @MainActor
    static func performDeferredStartupMaintenance(
        using modelContext: ModelContext,
        storeURL: URL?,
        pendingExecutionTableRepairStoreURL: URL?,
        appGroupIdentifier: String?
    ) {
        guard let storeURL else { return }

        let fileManager = FileManager.default

        #if DEBUG
        DebugPerf.mark("TypoReviewApp deferred startup maintenance begin store=\(storeURL.lastPathComponent)")
        #endif

        Self.ensureTaskSystemTablesExist(
            in: modelContext,
            storeURL: storeURL
        )
        Self.importLegacyStoreForMissingExecutionTableRepairIfNeeded(
            from: pendingExecutionTableRepairStoreURL,
            into: modelContext,
            fileManager: fileManager
        )
        Self.ensureTaskSystemTablesExist(
            in: modelContext,
            storeURL: storeURL
        )
        Self.migrateLegacyTaskExecutionsIfNeeded(in: modelContext)
        TaskExecutionSupport.migrateLegacySubtasksIfNeeded(in: modelContext)
        do {
            let removedSubtaskCount = try TaskExecutionSupport.deduplicateSubtasks(in: modelContext)
            #if DEBUG
            if removedSubtaskCount > 0 {
                DebugPerf.mark("TypoReviewApp deduplicated task subtasks count=\(removedSubtaskCount)")
            }
            #endif
        } catch {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp task subtask deduplication failed error=\(error.localizedDescription)")
            #endif
            print("Task subtask deduplication failed: \(error)")
        }
        _ = try? AppSettings.ensureSingleton(in: modelContext)
        Self.normalizeReviewDatesIfNeeded(
            in: modelContext,
            appGroupIdentifier: appGroupIdentifier
        )
        Self.deduplicateReviewItemsIfNeeded(
            in: modelContext,
            appGroupIdentifier: appGroupIdentifier
        )
        Self.migrateLegacyStageSevenCapsIfNeeded(
            in: modelContext,
            appGroupIdentifier: appGroupIdentifier
        )
        Self.reconcileStandardReviewProgressIfNeeded(in: modelContext)
        Self.deduplicateDailyReviewPlansIfNeeded(in: modelContext)
        Self.deduplicateReviewItemsIfNeeded(
            in: modelContext,
            appGroupIdentifier: appGroupIdentifier
        )

        do {
            if let result = try Grade5ChineseDictationPlanImporter.importIfRequested(in: modelContext) {
                #if DEBUG
                DebugPerf.mark(
                    "Grade 5 dictation plan import insertedSessions=\(result.insertedSessions) refreshedSessions=\(result.refreshedSessions) entries=\(result.insertedEntries)"
                )
                #endif
            }
        } catch {
            #if DEBUG
            DebugPerf.mark("Grade 5 dictation plan import failed error=\(error.localizedDescription)")
            #endif
            print("Grade 5 dictation plan import failed: \(error)")
        }

        do {
            let result = try Grade5EnglishDictationPlanImporter.deduplicateImportedPlan(
                in: modelContext
            )
            #if DEBUG
            if result.removedTotal > 0 {
                DebugPerf.mark(
                    "Grade 5 English plan deduplicated sessions=\(result.removedSessions) entries=\(result.removedEntries)"
                )
            }
            #endif
        } catch {
            #if DEBUG
            DebugPerf.mark("Grade 5 English plan deduplication failed error=\(error.localizedDescription)")
            #endif
            print("Grade 5 English plan deduplication failed: \(error)")
        }

        Self.reconcilePointRewardsIfNeeded(in: modelContext)

        #if DEBUG
        DebugPerf.mark("TypoReviewApp deferred startup maintenance end")
        #endif
    }

    private static func migrateLegacyStoreIfNeeded(
        candidates: [URL],
        targetStoreURL: URL,
        fileManager: FileManager
    ) {
        guard !fileManager.fileExists(atPath: targetStoreURL.path) else { return }

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            do {
                try moveStoreBundle(from: candidate, to: targetStoreURL, fileManager: fileManager)
                configurePersistentStoreFileProtection(for: [targetStoreURL], fileManager: fileManager)
                print("Migrated legacy SwiftData store from \(candidate.path) to \(targetStoreURL.path)")
                return
            } catch {
                print("Legacy store migration failed from \(candidate.path): \(error)")
            }
        }
    }

    private static func moveStoreBundle(
        from sourceURL: URL,
        to targetURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        removeStoreBundle(at: targetURL, fileManager: fileManager)

        for (source, target) in zip(storeArtifactURLs(for: sourceURL), storeArtifactURLs(for: targetURL)) {
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(at: source, to: target)
        }
    }

    private static func removeStoreBundle(
        at baseURL: URL,
        fileManager: FileManager
    ) {
        for url in storeArtifactURLs(for: baseURL) where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func prepareMissingTaskExecutionTableRepairIfNeeded(
        at storeURL: URL,
        fileManager: FileManager
    ) -> URL? {
        guard canRunDirectSQLiteStoreMaintenance else { return nil }
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database {
                sqlite3_close(database)
            }
            return nil
        }

        defer { sqlite3_close(database) }
        guard let database else { return nil }

        let hasTaskSubitemTable = tableExists(named: "ZTASKSUBITEM", in: database)
        let hasTaskExecutionRecordTable = tableExists(named: "ZTASKEXECUTIONRECORD", in: database)
        let hasTaskSubitemExecutionRecordTable = tableExists(named: "ZTASKSUBITEMEXECUTIONRECORD", in: database)
        guard !hasTaskSubitemTable || !hasTaskExecutionRecordTable || !hasTaskSubitemExecutionRecordTable else {
            return nil
        }

        let backupURL = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(storeURL.deletingPathExtension().lastPathComponent)-execution-table-repair.store")

        removeStoreBundle(at: backupURL, fileManager: fileManager)

        do {
            try moveStoreBundle(from: storeURL, to: backupURL, fileManager: fileManager)
            configurePersistentStoreFileProtection(for: [backupURL], fileManager: fileManager)
            #if DEBUG
            DebugPerf.mark("TypoReviewApp prepared missing execution table repair backup=\(backupURL.lastPathComponent) missingTaskSubitem=\(!hasTaskSubitemTable) missingTaskExecution=\(!hasTaskExecutionRecordTable) missingSubitemExecution=\(!hasTaskSubitemExecutionRecordTable)")
            #endif
            return backupURL
        } catch {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp failed to prepare missing execution table repair error=\(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private static func importLegacyStoreForMissingExecutionTableRepairIfNeeded(
        from legacyStoreURL: URL?,
        into modelContext: ModelContext,
        fileManager: FileManager
    ) {
        guard let legacyStoreURL else { return }
        guard fileManager.fileExists(atPath: legacyStoreURL.path) else { return }

        let legacySchema = Schema([
            ReviewItem.self,
            ReviewRecord.self,
            TaskItem.self,
            TaskCompletion.self,
            TaskSubitem.self,
            AppSettings.self,
            DictationSession.self,
            DictationEntry.self,
            ScheduleItem.self,
            MediaAsset.self
        ])

        do {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp missing execution table repair import begin backup=\(legacyStoreURL.lastPathComponent)")
            #endif

            let legacyConfiguration = ModelConfiguration(
                schema: legacySchema,
                url: legacyStoreURL,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(for: legacySchema, configurations: [legacyConfiguration])
            let legacyContext = legacyContainer.mainContext

            if let settings = (try? legacyContext.fetch(FetchDescriptor<AppSettings>()))?.first {
                modelContext.insert(AppSettingsSnapshot(settings).makeModel())
            }

            ((try? legacyContext.fetch(FetchDescriptor<ReviewItem>())) ?? [])
                .map(ReviewItemSnapshot.init)
                .map { $0.makeModel() }
                .forEach(modelContext.insert)
            ((try? legacyContext.fetch(FetchDescriptor<ReviewRecord>())) ?? [])
                .map(ReviewRecordSnapshot.init)
                .map { $0.makeModel() }
                .forEach(modelContext.insert)
            ((try? legacyContext.fetch(FetchDescriptor<TaskItem>())) ?? [])
                .map(TaskItemSnapshot.init)
                .map { $0.makeModel() }
                .forEach(modelContext.insert)
            ((try? legacyContext.fetch(FetchDescriptor<TaskCompletion>())) ?? [])
                .map(TaskCompletionSnapshot.init)
                .map { $0.makeModel() }
                .forEach(modelContext.insert)
            ((try? legacyContext.fetch(FetchDescriptor<TaskSubitem>())) ?? [])
                .map(TaskSubitemSnapshot.init)
                .map { $0.makeModel() }
                .forEach(modelContext.insert)
            ((try? legacyContext.fetch(FetchDescriptor<DictationSession>())) ?? [])
                .map(DictationSessionSnapshot.init)
                .map { $0.makeModel() }
                .forEach(modelContext.insert)
            ((try? legacyContext.fetch(FetchDescriptor<DictationEntry>())) ?? [])
                .map(DictationEntrySnapshot.init)
                .map { $0.makeModel() }
                .forEach(modelContext.insert)
            ((try? legacyContext.fetch(FetchDescriptor<ScheduleItem>())) ?? [])
                .map(ScheduleItemSnapshot.init)
                .map { $0.makeModel() }
                .forEach(modelContext.insert)
            ((try? legacyContext.fetch(FetchDescriptor<MediaAsset>())) ?? [])
                .map { asset in
                    MediaAsset(
                        id: asset.id,
                        title: asset.title,
                        originalFilename: asset.originalFilename,
                        storedFilename: asset.storedFilename,
                        mediaTypeRawValue: asset.mediaTypeRawValue,
                        storageScopeRawValue: asset.storageScopeRawValue,
                        playlistOrder: asset.playlistOrder,
                        isIncludedInPlaylist: asset.isIncludedInPlaylist,
                        createdAt: asset.createdAt,
                        updatedAt: asset.updatedAt
                    )
                }
                .forEach(modelContext.insert)

            if modelContext.hasChanges {
                try modelContext.save()
            }

            #if DEBUG
            let taskCount = (try? modelContext.fetchCount(FetchDescriptor<TaskItem>())) ?? 0
            let completionCount = (try? modelContext.fetchCount(FetchDescriptor<TaskCompletion>())) ?? 0
            DebugPerf.mark("TypoReviewApp missing execution table repair import end tasks=\(taskCount) completions=\(completionCount)")
            #endif
        } catch {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp missing execution table repair import failed error=\(error.localizedDescription)")
            #endif
        }
    }

    private static func ensureTaskSystemTablesExist(
        in modelContext: ModelContext,
        storeURL: URL?
    ) {
        let missingTableNames = missingTaskSystemTableNames(at: storeURL)
        guard missingTableNames.isEmpty == false else { return }

        #if DEBUG
        DebugPerf.mark(
            "TypoReviewApp ensureTaskSystemTablesExist begin missing=\(missingTableNames.joined(separator: ",")) store=\(storeURL?.lastPathComponent ?? "unknown")"
        )
        #endif

        let placeholderTaskID = UUID()
        let placeholderExecution = TaskExecutionRecord(
            taskID: placeholderTaskID,
            occurrenceDate: .distantPast,
            detail: "__schema_repair__"
        )
        let placeholderSubitem = TaskSubitem(
            parentTaskID: placeholderTaskID,
            taskExecutionID: placeholderExecution.id,
            title: "__schema_repair__",
            note: "",
            detail: "",
            status: .pending,
            sortOrder: 0,
            isArchived: true
        )
        let placeholderSubitemExecution = TaskSubitemExecutionRecord(
            taskExecutionID: placeholderExecution.id,
            subtaskID: placeholderSubitem.id,
            detail: "",
            status: .pending
        )

        modelContext.insert(placeholderExecution)
        modelContext.insert(placeholderSubitem)
        modelContext.insert(placeholderSubitemExecution)

        do {
            try modelContext.save()
            modelContext.delete(placeholderSubitemExecution)
            modelContext.delete(placeholderSubitem)
            modelContext.delete(placeholderExecution)
            try modelContext.save()
            #if DEBUG
            let remainingMissingTableNames = missingTaskSystemTableNames(at: storeURL)
            DebugPerf.mark(
                "TypoReviewApp ensureTaskSystemTablesExist end remaining=\(remainingMissingTableNames.joined(separator: ","))"
            )
            #endif
        } catch {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp ensureTaskSystemTablesExist failed error=\(error.localizedDescription)")
            #endif
        }
    }

    private static func missingTaskSystemTableNames(at storeURL: URL?) -> [String] {
        guard let storeURL else {
            return [
                "ZTASKSUBITEM",
                "ZTASKEXECUTIONRECORD",
                "ZTASKSUBITEMEXECUTIONRECORD"
            ]
        }

        let requiredTableNames = [
            "ZTASKSUBITEM",
            "ZTASKEXECUTIONRECORD",
            "ZTASKSUBITEMEXECUTIONRECORD"
        ]

        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return requiredTableNames
        }

        guard canRunDirectSQLiteStoreMaintenance else {
            return []
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database {
                sqlite3_close(database)
            }
            return requiredTableNames
        }

        defer { sqlite3_close(database) }
        guard let database else { return requiredTableNames }

        return requiredTableNames.filter { tableExists(named: $0, in: database) == false }
    }

    private static func repairLegacySchemaIfNeeded(
        at storeURL: URL,
        fileManager: FileManager
    ) {
        guard canRunDirectSQLiteStoreMaintenance else { return }
        guard fileManager.fileExists(atPath: storeURL.path) else { return }

        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let database {
                sqlite3_close(database)
            }
            print("Failed to open legacy store for schema repair at \(storeURL.path)")
            return
        }

        defer { sqlite3_close(database) }

        guard let database else { return }
        guard tableExists(named: "ZAPPSETTINGS", in: database) else { return }

        let existingColumns = fetchColumnNames(for: "ZAPPSETTINGS", in: database)
        let requiredStatements = [
            ("ZBOARDAUTOPLAYENABLED", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYENABLED INTEGER NOT NULL DEFAULT 1"),
            ("ZBOARDAUTOPLAYSTARTHOUR", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYSTARTHOUR INTEGER NOT NULL DEFAULT 7"),
            ("ZBOARDAUTOPLAYSTARTMINUTE", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYSTARTMINUTE INTEGER NOT NULL DEFAULT 0"),
            ("ZBOARDAUTOPLAYENDHOUR", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYENDHOUR INTEGER NOT NULL DEFAULT 7"),
            ("ZBOARDAUTOPLAYENDMINUTE", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYENDMINUTE INTEGER NOT NULL DEFAULT 30"),
            ("ZBOARDAUTOPLAYDURATIONMINUTES", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYDURATIONMINUTES INTEGER NOT NULL DEFAULT 30"),
            ("ZBOARDAUTOPLAYSLOTSRAWVALUE", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYSLOTSRAWVALUE TEXT NOT NULL DEFAULT ''"),
            ("ZBOARDMANUALPLAYBACKOPTIONRAWVALUE", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDMANUALPLAYBACKOPTIONRAWVALUE TEXT NOT NULL DEFAULT 'until_playlist_ends'"),
            ("ZBOARDAUTOPLAYSKIPWEEKENDS", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYSKIPWEEKENDS INTEGER NOT NULL DEFAULT 1"),
            ("ZBOARDAUTOPLAYSKIPCHINAHOLIDAYS", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYSKIPCHINAHOLIDAYS INTEGER NOT NULL DEFAULT 1")
        ]

        for (columnName, statement) in requiredStatements where !existingColumns.contains(columnName) {
            if sqlite3_exec(database, statement, nil, nil, nil) != SQLITE_OK {
                let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown"
                print("Failed to add \(columnName) to legacy store: \(message)")
            }
        }

        if tableExists(named: "ZTASKSUBITEM", in: database) {
            let subtaskColumns = fetchColumnNames(for: "ZTASKSUBITEM", in: database)
            let subtaskStatements = [
                ("ZTASKEXECUTIONIDRAWVALUE", "ALTER TABLE ZTASKSUBITEM ADD COLUMN ZTASKEXECUTIONIDRAWVALUE TEXT NOT NULL DEFAULT ''"),
                ("ZDETAIL", "ALTER TABLE ZTASKSUBITEM ADD COLUMN ZDETAIL TEXT NOT NULL DEFAULT ''"),
                ("ZSTATUSRAWVALUE", "ALTER TABLE ZTASKSUBITEM ADD COLUMN ZSTATUSRAWVALUE TEXT NOT NULL DEFAULT '待处理'"),
                ("ZCOMPLETEDAT", "ALTER TABLE ZTASKSUBITEM ADD COLUMN ZCOMPLETEDAT DOUBLE")
            ]

            for (columnName, statement) in subtaskStatements where !subtaskColumns.contains(columnName) {
                if sqlite3_exec(database, statement, nil, nil, nil) != SQLITE_OK {
                    let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown"
                    print("Failed to add \(columnName) to legacy subtask store: \(message)")
                }
            }
        }

    }

    private static func tableExists(named tableName: String, in database: OpaquePointer) -> Bool {
        let escapedTableName = tableName.replacingOccurrences(of: "'", with: "''")
        let query = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(escapedTableName)' LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func fetchColumnNames(for tableName: String, in database: OpaquePointer) -> Set<String> {
        let query = "PRAGMA table_info(\(tableName))"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let rawName = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: rawName))
            }
        }
        return columns
    }

    private static func storeArtifactURLs(for baseURL: URL) -> [URL] {
        [
            baseURL,
            URL(fileURLWithPath: baseURL.path + "-wal"),
            URL(fileURLWithPath: baseURL.path + "-shm"),
            storeSupportDirectoryURL(for: baseURL)
        ]
    }

    private static func storeSupportDirectoryURL(for baseURL: URL) -> URL {
        baseURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(baseURL.deletingPathExtension().lastPathComponent)_SUPPORT")
    }

    private static var canRunDirectSQLiteStoreMaintenance: Bool {
        UIApplication.shared.applicationState != .background &&
            UIApplication.shared.isProtectedDataAvailable
    }

    private static func configurePersistentStoreFileProtection(
        for storeURLs: [URL],
        fileManager: FileManager
    ) {
        for storeURL in storeURLs {
            let directoryURL = storeURL.deletingLastPathComponent()
            try? fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            setCompleteUntilFirstAuthenticationProtection(at: directoryURL, fileManager: fileManager)

            for url in storeArtifactURLs(for: storeURL) where fileManager.fileExists(atPath: url.path) {
                setCompleteUntilFirstAuthenticationProtection(at: url, fileManager: fileManager)
            }
        }
    }

    private static func setCompleteUntilFirstAuthenticationProtection(
        at url: URL,
        fileManager: FileManager
    ) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func migrateLegacyTaskExecutionsIfNeeded(in modelContext: ModelContext) {
        let executionCount = (try? modelContext.fetchCount(FetchDescriptor<TaskExecutionRecord>())) ?? 0
        guard executionCount == 0 else { return }

        let legacyCompletions = (try? modelContext.fetch(FetchDescriptor<TaskCompletion>())) ?? []
        guard !legacyCompletions.isEmpty else { return }

        let calendar = Calendar.current
        for completion in legacyCompletions {
            let record = TaskExecutionRecord(
                id: completion.id,
                taskID: completion.taskID,
                occurrenceDate: calendar.startOfDay(for: completion.completedDate),
                detail: "",
                status: .completed,
                completedAt: completion.completedAt,
                createdAt: completion.completedAt,
                updatedAt: completion.completedAt
            )
            modelContext.insert(record)
        }

        if modelContext.hasChanges {
            try? modelContext.save()
        }
    }

    private static func normalizeReviewDatesIfNeeded(
        in modelContext: ModelContext,
        appGroupIdentifier: String?
    ) {
        let defaults = appGroupIdentifier
            .flatMap(UserDefaults.init(suiteName:))
            ?? .standard
        guard !defaults.bool(forKey: reviewDateNormalizationMigrationKey) else { return }

        do {
            let normalizedCount = try ReviewScheduler.normalizeStoredReviewDates(in: modelContext)
            if modelContext.hasChanges {
                try modelContext.save()
            }
            defaults.set(true, forKey: reviewDateNormalizationMigrationKey)
            #if DEBUG
            DebugPerf.mark("TypoReviewApp normalized review dates count=\(normalizedCount)")
            #endif
        } catch {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp review date normalization failed error=\(error.localizedDescription)")
            #endif
            print("Review date normalization failed: \(error)")
        }
    }

    private static func migrateLegacyStageSevenCapsIfNeeded(
        in modelContext: ModelContext,
        appGroupIdentifier _: String?
    ) {
        do {
            let migratedCount = try ReviewScheduler.migrateLegacyStageSevenCaps(in: modelContext)
            if modelContext.hasChanges {
                try modelContext.save()
            }
            #if DEBUG
            DebugPerf.mark("TypoReviewApp migrated legacy stage 7 caps count=\(migratedCount)")
            #endif
        } catch {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp legacy stage 7 cap migration failed error=\(error.localizedDescription)")
            #endif
            print("Legacy stage 7 cap migration failed: \(error)")
        }
    }

    private static func deduplicateReviewItemsIfNeeded(
        in modelContext: ModelContext,
        appGroupIdentifier _: String?
    ) {
        do {
            let deduplicatedCount = try ReviewScheduler.deduplicateReviewItems(in: modelContext)
            if modelContext.hasChanges {
                try modelContext.save()
            }
            #if DEBUG
            DebugPerf.mark("TypoReviewApp deduplicated review items count=\(deduplicatedCount)")
            #endif
        } catch {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp review item deduplication failed error=\(error.localizedDescription)")
            #endif
            print("Review item deduplication failed: \(error)")
        }
    }

    private static func reconcileStandardReviewProgressIfNeeded(in modelContext: ModelContext) {
        do {
            let reconciledCount = try ReviewScheduler.reconcileStandardReviewProgress(in: modelContext)
            if modelContext.hasChanges {
                try modelContext.save()
            }
            #if DEBUG
            DebugPerf.mark("TypoReviewApp reconciled review progress count=\(reconciledCount)")
            #endif
        } catch {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp review progress reconciliation failed error=\(error.localizedDescription)")
            #endif
            print("Review progress reconciliation failed: \(error)")
        }
    }

    private static func deduplicateDailyReviewPlansIfNeeded(in modelContext: ModelContext) {
        do {
            let deletedCount = try ReviewScheduler.deduplicateDailyReviewPlans(in: modelContext)
            if modelContext.hasChanges {
                try modelContext.save()
            }
            #if DEBUG
            DebugPerf.mark("TypoReviewApp deduplicated daily review plans count=\(deletedCount)")
            #endif
        } catch {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp daily review plan deduplication failed error=\(error.localizedDescription)")
            #endif
            print("Daily review plan deduplication failed: \(error)")
        }
    }

    private static func reconcilePointRewardsIfNeeded(in modelContext: ModelContext) {
        do {
            let result = try PointLedgerService.reconcileMissingAutomaticRewards(in: modelContext)
            if modelContext.hasChanges {
                try modelContext.save()
            }
            #if DEBUG
            if result.totalAdded > 0 {
                DebugPerf.mark(
                    "TypoReviewApp reconciled point rewards reviews=\(result.reviewRewardsAdded) dictation=\(result.dictationRewardsAdded) accuracy=\(result.dictationAccuracyBonusesAdded) calculation=\(result.dailyCalculationRewardsAdded)"
                )
            }
            #endif
        } catch {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp point reward reconciliation failed error=\(error.localizedDescription)")
            #endif
            print("Point reward reconciliation failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let persistenceInitializationFailure {
                    PersistenceRecoveryView(failure: persistenceInitializationFailure)
                } else {
                    RootTabView()
                        .environment(syncStatusStore)
                        .environment(mediaLibraryStore)
                        .environment(appSettingsStore)
                        .environmentObject(startupMaintenanceCoordinator)
                }
            }
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                #if DEBUG
                DebugPerf.flushRecentEvents()
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                #if DEBUG
                DebugPerf.flushRecentEvents()
                #endif
            }
        }
        .modelContainer(sharedModelContainer)
    }
}

private struct PersistenceInitializationFailure {
    let cloudError: NSError
    let localError: NSError

    var diagnosticText: String {
        [
            "听写复习本AI版数据存储初始化失败",
            "时间：\(Date.now.formatted(.iso8601))",
            "CloudKit：\(Self.describe(cloudError))",
            "本地存储：\(Self.describe(localError))"
        ].joined(separator: "\n")
    }

    private static func describe(_ error: NSError) -> String {
        "domain=\(error.domain), code=\(error.code), description=\(error.localizedDescription)"
    }
}

private struct PersistenceRecoveryView: View {
    let failure: PersistenceInitializationFailure
    @State private var didCopyDiagnostics = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("暂时无法打开学习数据")
                            .font(.title2.bold())
                        Text("为了避免新内容退出 App 后丢失，当前已暂停录入和复习操作。原有数据不会在这里被覆盖。")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        recoveryStep(number: 1, text: "完全退出 App 后重新打开。")
                        recoveryStep(number: 2, text: "确认设备有足够存储空间，并保持 iCloud 可用。")
                        recoveryStep(number: 3, text: "如果仍然出现此页面，请复制诊断信息并联系开发者。")
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

                    Button {
                        UIPasteboard.general.string = failure.diagnosticText
                        didCopyDiagnostics = true
                    } label: {
                        Label(didCopyDiagnostics ? "已复制诊断信息" : "复制诊断信息", systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("请勿卸载 App，以免影响尚未同步的本地数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("数据恢复模式")
        }
    }

    private func recoveryStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
final class StartupMaintenanceCoordinator: ObservableObject {
    private let storeURL: URL?
    private let pendingExecutionTableRepairStoreURL: URL?
    private let appGroupIdentifier: String?

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @Published private(set) var isRunning = false
    @Published private(set) var hasCompleted = false

    init(
        storeURL: URL?,
        pendingExecutionTableRepairStoreURL: URL?,
        appGroupIdentifier: String?
    ) {
        self.storeURL = storeURL
        self.pendingExecutionTableRepairStoreURL = pendingExecutionTableRepairStoreURL
        self.appGroupIdentifier = appGroupIdentifier
    }

    func runIfNeeded(using modelContext: ModelContext) -> Bool {
        guard !hasCompleted else { return false }
        guard !isRunning else { return false }

        guard let storeURL else {
            hasCompleted = true
            return false
        }

        isRunning = true
        beginBackgroundTask()

        defer {
            endBackgroundTask()
            isRunning = false
            hasCompleted = true
        }

        TypoReviewApp.performDeferredStartupMaintenance(
            using: modelContext,
            storeURL: storeURL,
            pendingExecutionTableRepairStoreURL: pendingExecutionTableRepairStoreURL,
            appGroupIdentifier: appGroupIdentifier
        )
        return true
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "TypoReviewStartupMaintenance") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

@MainActor
final class IOS17BackgroundSceneShield {
    static let shared = IOS17BackgroundSceneShield()

    private struct ShieldedWindow {
        weak var window: UIWindow?
        let rootViewController: UIViewController
    }

    private var isStarted = false
    private var observers: [NSObjectProtocol] = []
    private var shieldedWindows: [ObjectIdentifier: ShieldedWindow] = [:]

    func start() {
        guard !isStarted else { return }
        guard isEnabled else { return }

        isStarted = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIScene.willDeactivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.shieldScene(from: notification)
                }
            },
            center.addObserver(
                forName: UIScene.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.shieldScene(from: notification)
                }
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.shieldActiveWindows()
                }
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.shieldActiveWindows()
                }
            },
            center.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.restoreScene(from: notification)
                }
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restoreShieldedWindows()
                }
            }
        ]
    }

    private var isEnabled: Bool {
        false
    }

    private func shieldActiveWindows() {
        guard isEnabled else { return }

        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard windowScene.session.role == .windowApplication else { continue }

            shield(windowScene)
        }
    }

    private func shieldScene(from notification: Notification) {
        guard let windowScene = notification.object as? UIWindowScene else {
            shieldActiveWindows()
            return
        }
        shield(windowScene)
    }

    private func shield(_ windowScene: UIWindowScene) {
        guard isEnabled else { return }
        guard windowScene.session.role == .windowApplication else { return }

        for window in windowScene.windows where shouldShield(window) {
            guard let rootViewController = window.rootViewController else { continue }

            let windowID = ObjectIdentifier(window)
            shieldedWindows[windowID] = ShieldedWindow(
                window: window,
                rootViewController: rootViewController
            )

            UIView.performWithoutAnimation {
                removeContextMenuInteractions(from: window)
                window.rootViewController = IOS17BackgroundShieldViewController()
                window.layoutIfNeeded()
            }
        }
    }

    private func removeContextMenuInteractions(from view: UIView) {
        for interaction in view.interactions where interaction is UIContextMenuInteraction {
            view.removeInteraction(interaction)
        }

        for subview in view.subviews {
            removeContextMenuInteractions(from: subview)
        }
    }

    private func shouldShield(_ window: UIWindow) -> Bool {
        guard !DashboardBoardWakeCoordinator.shared.isActive else { return false }
        guard !window.isHidden else { return false }
        guard window.windowLevel == .normal else { return false }
        guard window.rootViewController != nil else { return false }
        return !(window.rootViewController is IOS17BackgroundShieldViewController)
    }

    private func restoreShieldedWindows() {
        for (_, shieldedWindow) in shieldedWindows {
            guard let window = shieldedWindow.window else { continue }
            guard window.rootViewController is IOS17BackgroundShieldViewController else { continue }
            window.rootViewController = shieldedWindow.rootViewController
            window.makeKeyAndVisible()
        }
        shieldedWindows.removeAll()
    }

    private func restoreScene(from notification: Notification) {
        guard let windowScene = notification.object as? UIWindowScene else {
            restoreShieldedWindows()
            return
        }

        let windowIDs = Set(windowScene.windows.map(ObjectIdentifier.init))
        for (windowID, shieldedWindow) in shieldedWindows where windowIDs.contains(windowID) {
            guard let window = shieldedWindow.window else { continue }
            guard window.rootViewController is IOS17BackgroundShieldViewController else { continue }
            window.rootViewController = shieldedWindow.rootViewController
            window.makeKeyAndVisible()
            shieldedWindows.removeValue(forKey: windowID)
        }
    }
}

private final class IOS17BackgroundShieldViewController: UIViewController {
    override func loadView() {
        let shieldView = UIView()
        shieldView.backgroundColor = .systemBackground
        view = shieldView
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .all
    }
}

enum AppStorePreviewMode {
    static var isEnabled: Bool {
        #if DEBUG
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--app-store-preview-mode") ||
            processInfo.environment["APP_STORE_PREVIEW_MODE"] == "1"
        #else
        return false
        #endif
    }
}

#if DEBUG
enum AppStorePreviewData {
    @MainActor
    static func seedIfNeeded(in modelContext: ModelContext) {
        let existingItems = (try? modelContext.fetch(FetchDescriptor<ReviewItem>())) ?? []
        guard existingItems.isEmpty else { return }

        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: today) ?? today
        }
        func time(hour: Int, minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today
        }

        let settings = AppSettings(
            childName: "小夏",
            dailyLimit: 8,
            remindHour: 19,
            remindMinute: 30,
            reviewInteractionStyle: .batch
        )
        modelContext.insert(settings)

        let reviewItems = [
            ReviewItem(
                type: .phrase,
                content: "清澈",
                prompt: "注意右边是“曷”，不要写成“喝”。",
                note: "语文第三单元",
                source: "错题本",
                stage: 2,
                nextReviewAt: day(0),
                lastReviewedAt: day(-2),
                consecutiveWrongCount: 1,
                isPriority: true,
                createdAt: day(-12),
                updatedAt: now
            ),
            ReviewItem(
                type: .chineseCharacter,
                content: "辨",
                prompt: "组词：分辨、辨认；中间是点撇。",
                source: "周三听写",
                stage: 1,
                nextReviewAt: day(0),
                createdAt: day(-6),
                updatedAt: now
            ),
            ReviewItem(
                type: .phrase,
                content: "融化",
                prompt: "“融”左下不是“虫”少一横。",
                source: "看拼音写词语",
                stage: 3,
                nextReviewAt: day(0),
                lastReviewedAt: day(-1),
                createdAt: day(-18),
                updatedAt: now
            ),
            ReviewItem(
                type: .englishWord,
                content: "environment",
                prompt: "en-vi-ron-ment，注意中间 ron。",
                source: "英语单词",
                stage: 2,
                nextReviewAt: day(1),
                createdAt: day(-8),
                updatedAt: now
            ),
            ReviewItem(
                type: .phrase,
                content: "坚持",
                prompt: "已经稳定掌握，进入长期复习。",
                source: "已掌握",
                stage: 5,
                nextReviewAt: day(14),
                lastReviewedAt: day(-1),
                consecutiveCorrectCount: 4,
                createdAt: day(-30),
                updatedAt: now
            )
        ]

        for item in reviewItems {
            modelContext.insert(item)
        }

        let reviewRecords = [
            ReviewRecord(itemID: reviewItems[0].id, reviewedAt: time(hour: 8, minute: 10), result: .wrong, mode: .scheduled, oldStage: 2, newStage: 1, note: "偏旁写错"),
            ReviewRecord(itemID: reviewItems[2].id, reviewedAt: time(hour: 8, minute: 12), result: .correct, mode: .scheduled, oldStage: 2, newStage: 3),
            ReviewRecord(itemID: reviewItems[4].id, reviewedAt: time(hour: 8, minute: 15), result: .correct, mode: .scheduled, oldStage: 4, newStage: 5),
            ReviewRecord(itemID: reviewItems[1].id, reviewedAt: day(-1), result: .correct, mode: .retry, oldStage: 0, newStage: 1)
        ]
        for record in reviewRecords {
            modelContext.insert(record)
            _ = PointLedgerService.awardReviewRecord(record, in: modelContext)
        }

        let dictationTodayID = UUID()
        let dictationTomorrowID = UUID()
        let sessions = [
            DictationSession(id: dictationTodayID, title: "第三单元词语听写", type: .phrase, createdAt: day(-1), updatedAt: now, scheduledDate: day(0)),
            DictationSession(id: dictationTomorrowID, title: "英语高频词复习", type: .englishWord, createdAt: day(-2), updatedAt: now, scheduledDate: day(1))
        ]
        for session in sessions {
            modelContext.insert(session)
        }

        let dictationEntries = [
            DictationEntry(sessionID: dictationTodayID, sortOrder: 0, type: .phrase, content: "清澈", prompt: "湖水很清澈", source: "语文书"),
            DictationEntry(sessionID: dictationTodayID, sortOrder: 1, type: .phrase, content: "辨认", prompt: "辨认方向", source: "语文书"),
            DictationEntry(sessionID: dictationTodayID, sortOrder: 2, type: .phrase, content: "融化", prompt: "冰雪融化", source: "错题本"),
            DictationEntry(sessionID: dictationTomorrowID, sortOrder: 0, type: .englishWord, content: "environment", prompt: "环境", source: "英语课本"),
            DictationEntry(sessionID: dictationTomorrowID, sortOrder: 1, type: .englishWord, content: "important", prompt: "重要的", source: "英语课本")
        ]
        for entry in dictationEntries {
            modelContext.insert(entry)
        }

        let taskIDs = [UUID(), UUID(), UUID()]
        let tasks = [
            TaskItem(
                id: taskIDs[0],
                title: "完成语文订正并拍照",
                note: "订正后家长检查错别字",
                recurrence: .daily,
                skipPolicy: .unskippable,
                startDate: day(-2),
                createdAt: day(-2),
                updatedAt: now
            ),
            TaskItem(
                id: taskIDs[1],
                title: "睡前 8 分钟错字复盘",
                note: "只看重点复习",
                recurrence: .daily,
                startDate: day(0),
                createdAt: day(-3),
                updatedAt: now
            ),
            TaskItem(
                id: taskIDs[2],
                title: "整理本周听写错词",
                note: "周末前完成",
                recurrence: .once,
                startDate: day(2),
                createdAt: day(-1),
                updatedAt: now
            )
        ]
        for task in tasks {
            modelContext.insert(task)
        }

        modelContext.insert(TaskSubitem(parentTaskID: taskIDs[0], title: "把“清澈”重写 3 遍", sortOrder: 0, createdAt: day(-2), updatedAt: now))
        modelContext.insert(TaskSubitem(parentTaskID: taskIDs[0], title: "读一遍第三单元词语表", sortOrder: 1, createdAt: day(-2), updatedAt: now))
        let completedTaskRecord = TaskExecutionRecord(
            taskID: taskIDs[1],
            occurrenceDate: day(0),
            status: .completed,
            completedAt: time(hour: 7, minute: 50),
            createdAt: now,
            updatedAt: now
        )
        modelContext.insert(completedTaskRecord)
        _ = PointLedgerService.awardTaskExecution(completedTaskRecord, taskTitle: tasks[1].title, in: modelContext)

        let schedules = [
            ScheduleItem(
                title: "晚饭后听写",
                note: "先听写，再复盘错词",
                startTime: time(hour: 19, minute: 30),
                endTime: time(hour: 20, minute: 0),
                repeatRule: .daily,
                effectiveStartDate: day(-5),
                createdAt: day(-5),
                updatedAt: now
            ),
            ScheduleItem(
                title: "周末错题整理",
                note: "把本周错词加入题库",
                startTime: day(2),
                endTime: calendar.date(byAdding: .minute, value: 45, to: day(2)) ?? day(2),
                repeatRule: .once,
                createdAt: day(-1),
                updatedAt: now
            )
        ]
        for schedule in schedules {
            modelContext.insert(schedule)
        }

        modelContext.insert(
            PointRewardState(
                currentStreak: 6,
                lastActiveDay: today,
                longestStreak: 12,
                updatedAt: now
            )
        )

        try? modelContext.save()
        AppDataChangeCenter.post()
    }
}
#endif
