import CryptoKit
import Foundation
import Observation
import Network
import SwiftData
import WidgetKit

private struct SyncRecordKey: Hashable {
    let entityType: String
    let recordID: String

    init(entityType: String, recordID: String) {
        self.entityType = entityType
        self.recordID = recordID
    }

    init(_ change: ServerChange) {
        entityType = change.entityType
        recordID = change.recordID.uuidString
    }
}

private enum IncrementalConflictResolution {
    case acceptRemote
    case keepLocal
    case mergeDictationSession
    case mergeDictationEntry
}

/// Owns an entire pull/merge/upload cycle across network suspension points.
/// Callers that arrive while busy wait for their turn instead of losing refreshes.
@MainActor
final class ServerSyncOperationQueue {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
@Observable
final class ServerSyncCoordinator {
    static let shared = ServerSyncCoordinator()

    private static let receiptsKey = "typo_review_sync_receipts_v2"
    private static let outboxKey = "typo_review_sync_outbox_v2"
    private static let blockedHashesKey = "typo_review_sync_blocked_hashes_v2"
    private static let pendingUploadKey = "typo_review_pending_upload_v2"
    private static let baselineDefaultsKey = "typo_review_server_sync_baseline_v1"
    private static let bootstrapInProgressDefaultsKey = "typo_review_server_bootstrap_in_progress_v1"
    private static let changeCursorDefaultsKey = "typo_review_server_change_cursor_v1"
    nonisolated private static let entityOrder = [
        "reviewRecords",
        "reviewItems",
        "taskItems",
        "taskCompletions",
        "taskSubitems",
        "taskExecutionRecords",
        "taskSubitemExecutionRecords",
        "dictationSessions",
        "dictationEntries",
        "scheduleItems",
        "calculationRounds",
        "pointLedgerEntries",
        "pointRewardStates",
        "settings",
    ]

    @ObservationIgnored private let client: any ServerSyncAPI
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let enabled: () -> Bool
    @ObservationIgnored private let operationQueue = ServerSyncOperationQueue()
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var networkGeneration = 0
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var uploadRequested = false
    @ObservationIgnored private var uploadNeedsMerge = false

    init(
        client: any ServerSyncAPI = ServerAPIClient.shared,
        defaults: UserDefaults = .standard,
        enabled: @escaping () -> Bool = { ServerAPIConfiguration.current != nil }
    ) {
        self.client = client
        self.defaults = defaults
        self.enabled = enabled
        if defaults.data(forKey: Self.outboxKey) != nil {
            self.uploadError = "有数据等待上传，将在连接恢复后重试。"
        } else if let data = defaults.data(forKey: Self.blockedHashesKey),
                  let blocked = try? JSONDecoder().decode([String: String].self, from: data), !blocked.isEmpty {
            self.uploadError = "有复习记录与服务器冲突，已保留在本机；其他数据可正常同步。"
        }
    }
    private var isPulling = false
    private var isUploading = false
    private var activeSyncPhase: String?
    private(set) var isApplyingRemoteSnapshot = false
    private var transferError: String?
    private var uploadError: String?
    private(set) var lastErrorDescription: String? {
        get { uploadError ?? transferError }
        set { transferError = newValue }
    }
    private(set) var lastSuccessfulConnectionAt: Date?
    private(set) var lastSuccessfulPullAt: Date?
    private(set) var lastSuccessfulUploadAt: Date?
    private(set) var lastPulledDataSummary = "尚未完成服务器下载"

    var isEnabled: Bool { enabled() }
    var isSynchronizing: Bool { isPulling || isUploading || isApplyingRemoteSnapshot }
    var serverStatusText: String {
        if let activeSyncPhase {
            return activeSyncPhase
        }
        return lastErrorDescription == nil ? "正常" : "等待重试"
    }

    @discardableResult
    func synchronize(
        modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        guard isEnabled else { return false }
        await operationQueue.acquire()
        defer { operationQueue.release() }
        guard !Task.isCancelled else { return false }
        return await performSynchronization(modelContext: modelContext, settingsStore: settingsStore)
    }

    private func performSynchronization(
        modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        if loadBaseline() == nil {
            return await performPull(into: modelContext, settingsStore: settingsStore)
        }

        if loadChangeCursor() != nil {
            // Re-read the cursor after acquiring the queue and on each retry.
            // Automatic saves must merge too, including our own server-normalized
            // review progress from the preceding upload.
            for _ in 0..<3 {
                guard !Task.isCancelled, let cursor = loadChangeCursor() else { return false }
                guard await pullIncremental(after: cursor, into: modelContext, settingsStore: settingsStore) else {
                    return false
                }
                let previousUploadAt = lastSuccessfulUploadAt
                if await performUpload(from: modelContext, settingsStore: settingsStore) {
                    if lastSuccessfulUploadAt != previousUploadAt, let cursor = loadChangeCursor() {
                        return await pullIncremental(after: cursor, into: modelContext, settingsStore: settingsStore)
                    }
                    return true
                }
                guard uploadNeedsMerge else { return false }
            }
            return false
        }

        // Snapshot-only clients also upgrade through the non-destructive merge.
        return await performPull(into: modelContext, settingsStore: settingsStore)
    }

    /// Lightweight foreground polling. The board has no local edits to upload;
    /// full verification remains reserved for entry and manual refresh.
    @discardableResult
    func checkForServerUpdates(
        modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        guard isEnabled else { return false }
        await operationQueue.acquire()
        defer { operationQueue.release() }
        guard !Task.isCancelled else { return false }
        guard loadBaseline() != nil, let cursor = loadChangeCursor() else {
            return await performSynchronization(modelContext: modelContext, settingsStore: settingsStore)
        }
        return await pullIncremental(after: cursor, into: modelContext, settingsStore: settingsStore)
    }

    /// A manual refresh verifies all server rows, including versions already
    /// passed by the incremental cursor. Merge in place so unsent local edits
    /// survive; a destructive snapshot restore would discard them.
    @discardableResult
    func refreshFromServer(
        modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        guard isEnabled else { return false }
        await operationQueue.acquire()
        defer { operationQueue.release() }
        guard !Task.isCancelled else { return false }
        guard loadBaseline() != nil else {
            return await performSynchronization(modelContext: modelContext, settingsStore: settingsStore)
        }

        var verificationCursor: Int64 = 0
        do {
            if let manifest = try await client.syncManifest(), manifest.protocolVersion >= 2,
               let cursor = loadChangeCursor(), cursor <= manifest.cursor {
                let receipts = loadReceipts()
                let local = try Self.captureStructuredSnapshot(from: modelContext.container, settings: settingsStore.snapshot)
                let context = ModelContext(modelContext.container)
                let deleted = Set(try context.fetch(FetchDescriptor<SyncDeletion>()).map {
                    $0.entityType + "/" + $0.recordID.uuidString
                })
                let intact = manifest.records.allSatisfy { row in
                    let id = row.recordID.uuidString
                    let key = row.entityType + "/" + id
                    let versionKnown = row.serverVersion > cursor || receipts[key] == row.serverVersion
                    let present = row.deleted || local.hashes[row.entityType]?[id] != nil || deleted.contains(key)
                    return versionKnown && present
                }
                if intact { verificationCursor = cursor }
            }
        } catch {
            // The full change stream is the compatibility and repair path.
            verificationCursor = 0
        }
        let pullSucceeded = await pullIncremental(
            after: verificationCursor,
            into: modelContext,
            settingsStore: settingsStore,
            pageSize: 5_000
        )
        guard pullSucceeded else { return false }
        scheduleUpload(
            from: modelContext,
            settingsStore: settingsStore,
            delayNanoseconds: 450_000_000
        )
        return true
    }

    @discardableResult
    func pull(
        into modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        await refreshFromServer(modelContext: modelContext, settingsStore: settingsStore)
    }

    private func performPull(
        into modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        // Bootstrap uses the same merge as refresh. Never replace the local store:
        // it may already contain work created offline or during a download.
        if loadBaseline() == nil { saveBaseline([:]) }
        guard await pullIncremental(after: 0, into: modelContext, settingsStore: settingsStore) else {
            return false
        }
        defaults.removeObject(forKey: Self.bootstrapInProgressDefaultsKey)
        await synchronizeDeepSeekAPIKey()
        return await performUpload(from: modelContext, settingsStore: settingsStore)
    }

    @discardableResult
    private func pullIncremental(
        after initialCursor: Int64,
        into modelContext: ModelContext,
        settingsStore: AppSettingsStore,
        pageSize: Int = 1_000
    ) async -> Bool {
        guard isEnabled, !isPulling, !isUploading, !isApplyingRemoteSnapshot else { return false }

        isPulling = true
        lastErrorDescription = nil
        activeSyncPhase = "正在检查更新"
        defer {
            activeSyncPhase = nil
            isPulling = false
        }

        do {
            guard let baseline = loadBaseline() else { return false }
            var cursor = initialCursor
            var receivedChanges: [ServerChange] = []
            var dataChanged = false
            while true {
                try Task.checkCancellation()
                let batch = try await client.changes(after: cursor, limit: pageSize)
                guard batch.changes.isEmpty || batch.cursor > cursor else {
                    throw ServerAPIError.invalidResponse
                }
                receivedChanges.append(contentsOf: batch.changes)
                cursor = batch.cursor
                if batch.changes.count < pageSize { break }
            }

            let changes = Self.latestChangesByRecord(receivedChanges)
            if !changes.isEmpty {
                activeSyncPhase = "正在合并更新"
                let container = modelContext.container
                let remoteHashes = try await Task.detached(priority: .utility) {
                    var hashes: [SyncRecordKey: String] = [:]
                    for change in changes {
                        try Task.checkCancellation()
                        hashes[SyncRecordKey(change)] = try change.normalizedPayloadHash()
                    }
                    return hashes
                }.value
                // No suspension between reading local values, applying the merge,
                // and recording its baseline. UI edits cannot interleave here.
                let recordIDs = Dictionary(grouping: changes, by: \.entityType).mapValues { $0.map(\.recordID) }
                try PersistentStoreAccessGate.withAccess {
                let localSnapshot = try Self.captureStructuredSnapshot(
                    from: container, settings: settingsStore.snapshot,
                    recordIDs: recordIDs
                )
                var resolutions = try Self.conflictResolutions(
                    for: changes,
                    localSnapshot: localSnapshot,
                    baseline: baseline,
                    remoteHashes: remoteHashes
                )
                let deletionContext = ModelContext(container)
                for deletion in try deletionContext.fetch(FetchDescriptor<SyncDeletion>()) {
                    resolutions[SyncRecordKey(entityType: deletion.entityType,
                                              recordID: deletion.recordID.uuidString)] = .keepLocal
                }
                // Full verification usually finds unchanged rows. Compare their
                // decoded payloads at local wire precision before touching SwiftData.
                let changedRecords = changes.filter { change in
                    let key = SyncRecordKey(change)
                    return change.deletedAt != nil || localSnapshot.hashes[key.entityType]?[key.recordID]
                        != remoteHashes[key]
                }
                dataChanged = try applyIncrementalChanges(
                    changedRecords,
                    to: modelContext.container,
                    settingsStore: settingsStore,
                    resolutions: resolutions
                )

                // Verification often only confirms existing rows. Reuse their
                // hashes instead of materializing the same models a second time.
                let mergedSnapshot = dataChanged
                    ? try Self.captureStructuredSnapshot(
                        from: container, settings: settingsStore.snapshot,
                        recordIDs: recordIDs
                    )
                    : localSnapshot
                let pendingLocalKeys = Self.pendingLocalKeys(
                    localSnapshot: localSnapshot,
                    baseline: baseline,
                    resolutions: resolutions
                )
                saveBaseline(
                    Self.baselineForPendingUpload(
                        original: baseline,
                        mergedSnapshot: mergedSnapshot,
                        pendingLocalKeys: pendingLocalKeys,
                        changes: changes,
                        resolutions: resolutions
                    )
                )
            }
            }

            var receipts = loadReceipts()
            for change in changes {
                receipts[change.entityType + "/" + change.recordID.uuidString] = change.serverVersion
            }
            defaults.set(try JSONEncoder().encode(receipts), forKey: Self.receiptsKey)

            // Daily plans are server-owned and are not part of the incremental
            // record stream. Refresh them even when there were no record changes;
            // otherwise an upgraded client can keep syncing successfully while
            // the server's plan remains stuck on an earlier day.
            activeSyncPhase = "正在更新今日计划"
            let dailyPlanChanged = try await installServerDailyPlan(
                in: modelContext.container,
                dailyLimit: settingsStore.dailyLimit
            )
            saveChangeCursor(cursor)
            lastErrorDescription = nil
            lastSuccessfulPullAt = .now
            if dataChanged || dailyPlanChanged {
                AppDataChangeCenter.post(source: .server)
                WidgetCenter.shared.reloadAllTimelinesInBackground()
            }
            return true
        } catch where Self.isCancellation(error) {
            return false
        } catch {
            lastErrorDescription = Self.userFacingDescription(for: error, phase: activeSyncPhase)
            #if DEBUG
            print("Incremental server pull failed: \(error)")
            #endif
            return false
        }
    }

    func applyIncrementalChanges(
        _ changes: [ServerChange],
        to container: ModelContainer,
        settingsStore: AppSettingsStore
    ) throws {
        _ = try applyIncrementalChanges(
            changes,
            to: container,
            settingsStore: settingsStore,
            resolutions: [:]
        )
    }

    @discardableResult
    private func applyIncrementalChanges(
        _ changes: [ServerChange],
        to container: ModelContainer,
        settingsStore: AppSettingsStore,
        resolutions: [SyncRecordKey: IncrementalConflictResolution]
    ) throws -> Bool {
        try PersistentStoreAccessGate.withAccess {
            let context = ModelContext(container)
            context.autosaveEnabled = false

            // Populate only the caches needed by this change batch. A dictation-
            // only pull should not fetch every review, task, schedule and points
            // row merely to update one visible session.
            var loadedEntities: Set<String> = []
            var reviewItems: [UUID: ReviewItem] = [:]
            var reviewRecords: [UUID: ReviewRecord] = [:]
            var taskItems: [UUID: TaskItem] = [:]
            var taskCompletions: [UUID: TaskCompletion] = [:]
            var taskSubitems: [UUID: TaskSubitem] = [:]
            var taskExecutions: [UUID: TaskExecutionRecord] = [:]
            var taskSubitemExecutions: [UUID: TaskSubitemExecutionRecord] = [:]
            var dictationSessions: [UUID: DictationSession] = [:]
            var dictationEntries: [UUID: DictationEntry] = [:]
            var scheduleItems: [UUID: ScheduleItem] = [:]
            var calculationRounds: [UUID: CalculationRound] = [:]
            var pointEntries: [UUID: PointLedgerEntry] = [:]
            var pointStates: [UUID: PointRewardState] = [:]
            var settingsSnapshot: AppSettingsSnapshot?

            let recordIDs = Dictionary(grouping: changes, by: \.entityType).mapValues { $0.map(\.recordID) }
            func fetch<T: PersistentModel>(
                _ entity: String, predicate: ([UUID]) -> Predicate<T>
            ) throws -> [T] {
                let ids = Array(Set(recordIDs[entity] ?? []))
                var models: [T] = []
                for start in stride(from: 0, to: ids.count, by: 256) {
                    let batch = Array(ids[start..<min(start + 256, ids.count)])
                    models.append(contentsOf: try context.fetch(FetchDescriptor<T>(predicate: predicate(batch))))
                }
                return models
            }
            for change in changes {
                let key = SyncRecordKey(change)
                let resolution = resolutions[key] ?? .acceptRemote
                guard resolution != .keepLocal else { continue }
                let isDeletion = change.deletedAt != nil
                switch change.entityType {
                case "reviewItems":
                    if loadedEntities.insert(change.entityType).inserted {
                        reviewItems = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<ReviewItem> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: ReviewItemSnapshot.self, in: context, cache: &reviewItems, makeModel: { $0.makeModel() }) { value, model in
                        model.typeRawValue = value.typeRawValue
                        model.content = value.content
                        model.prompt = value.prompt
                        model.note = value.note
                        model.source = value.source
                        model.stage = value.stage
                        model.nextReviewAt = value.nextReviewAt
                        model.lastReviewedAt = value.lastReviewedAt
                        model.consecutiveCorrectCount = value.consecutiveCorrectCount
                        model.consecutiveWrongCount = value.consecutiveWrongCount
                        model.isPriority = value.isPriority
                        model.reviewTrackRawValue = value.reviewTrackRawValue ?? ReviewTrack.standard.rawValue
                        model.dictationFollowUpStep = value.dictationFollowUpStep ?? 0
                        model.isDictationPassRaw = value.isDictationPassRaw
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "reviewRecords":
                    if loadedEntities.insert(change.entityType).inserted {
                        reviewRecords = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<ReviewRecord> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: ReviewRecordSnapshot.self, in: context, cache: &reviewRecords, makeModel: { $0.makeModel() }) { value, model in
                        model.itemID = value.itemID
                        model.reviewedAt = value.reviewedAt
                        model.resultRawValue = value.resultRawValue
                        model.modeRawValue = value.modeRawValue
                        model.oldStage = value.oldStage
                        model.newStage = value.newStage
                        model.note = value.note
                    }
                case "taskItems":
                    if loadedEntities.insert(change.entityType).inserted {
                        taskItems = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<TaskItem> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: TaskItemSnapshot.self, in: context, cache: &taskItems, makeModel: { $0.makeModel() }) { value, model in
                        model.title = value.title
                        model.note = value.note
                        model.recurrenceJSON = value.recurrenceJSON
                        model.skipPolicyRawValue = value.skipPolicyRawValue
                        model.timingModeRawValue = value.timingModeRawValue
                        model.startDate = value.startDate
                        model.endDate = value.endDate
                        model.deadline = value.deadline
                        model.pauseIntervalsJSON = value.pauseIntervalsJSON
                        model.pauseStartedAt = value.pauseStartedAt
                        model.isArchived = value.isArchived
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "taskCompletions":
                    if loadedEntities.insert(change.entityType).inserted {
                        taskCompletions = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<TaskCompletion> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: TaskCompletionSnapshot.self, in: context, cache: &taskCompletions, makeModel: { $0.makeModel() }) { value, model in
                        model.taskID = value.taskID
                        model.completedDate = value.completedDate
                        model.completedAt = value.completedAt
                    }
                case "taskSubitems":
                    if loadedEntities.insert(change.entityType).inserted {
                        taskSubitems = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<TaskSubitem> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: TaskSubitemSnapshot.self, in: context, cache: &taskSubitems, makeModel: { $0.makeModel() }) { value, model in
                        model.parentTaskID = value.parentTaskID
                        model.taskExecutionIDRawValue = value.taskExecutionIDRawValue
                        model.title = value.title
                        model.note = value.note
                        model.detail = value.detail
                        model.statusRawValue = value.statusRawValue
                        model.sortOrder = value.sortOrder
                        model.isArchived = value.isArchived
                        model.completedAt = value.completedAt
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "taskExecutionRecords":
                    if loadedEntities.insert(change.entityType).inserted {
                        taskExecutions = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<TaskExecutionRecord> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: TaskExecutionRecordSnapshot.self, in: context, cache: &taskExecutions, makeModel: { $0.makeModel() }) { value, model in
                        model.taskID = value.taskID
                        model.occurrenceDate = value.occurrenceDate
                        model.detail = value.detail
                        model.statusRawValue = value.statusRawValue
                        model.completedAt = value.completedAt
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "taskSubitemExecutionRecords":
                    if loadedEntities.insert(change.entityType).inserted {
                        taskSubitemExecutions = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<TaskSubitemExecutionRecord> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: TaskSubitemExecutionRecordSnapshot.self, in: context, cache: &taskSubitemExecutions, makeModel: { $0.makeModel() }) { value, model in
                        model.taskExecutionID = value.taskExecutionID
                        model.subtaskID = value.subtaskID
                        model.detail = value.detail
                        model.statusRawValue = value.statusRawValue
                        model.completedAt = value.completedAt
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "dictationSessions":
                    if loadedEntities.insert(change.entityType).inserted {
                        dictationSessions = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<DictationSession> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: DictationSessionSnapshot.self, in: context, cache: &dictationSessions, makeModel: { $0.makeModel() }) { value, model in
                        if resolution == .mergeDictationSession {
                            Self.mergeDictationSession(value, into: model)
                        } else {
                            model.title = value.title
                            model.typeRawValue = value.typeRawValue
                            model.createdAt = value.createdAt
                            model.updatedAt = value.updatedAt
                            model.scheduledDate = value.scheduledDate
                            model.finishedAt = value.finishedAt
                            model.reviewedAt = value.reviewedAt
                            model.currentEntryIndex = value.currentEntryIndex
                        }
                    }
                case "dictationEntries":
                    if loadedEntities.insert(change.entityType).inserted {
                        dictationEntries = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<DictationEntry> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: DictationEntrySnapshot.self, in: context, cache: &dictationEntries, makeModel: { $0.makeModel() }) { value, model in
                        if resolution == .mergeDictationEntry {
                            Self.mergeDictationEntry(value, into: model)
                        } else {
                            model.sessionID = value.sessionID
                            model.sortOrder = value.sortOrder
                            model.typeRawValue = value.typeRawValue
                            model.content = value.content
                            model.prompt = value.prompt
                            model.note = value.note
                            model.source = value.source
                            model.resultRawValue = value.resultRawValue
                            model.createdAt = value.createdAt
                            model.updatedAt = value.updatedAt
                        }
                    }
                case "scheduleItems":
                    if loadedEntities.insert(change.entityType).inserted {
                        scheduleItems = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<ScheduleItem> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: ScheduleItemSnapshot.self, in: context, cache: &scheduleItems, makeModel: { $0.makeModel() }) { value, model in
                        model.title = value.title
                        model.note = value.note
                        model.startTime = value.startTime
                        model.endTime = value.endTime
                        model.repeatRuleRawValue = value.repeatRuleRawValue
                        model.weekdaysJSON = value.weekdaysJSON
                        model.effectiveStartDate = value.effectiveStartDate
                        model.effectiveEndDate = value.effectiveEndDate
                        model.isArchived = value.isArchived
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "calculationRounds":
                    if loadedEntities.insert(change.entityType).inserted {
                        calculationRounds = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<CalculationRound> { ids.contains($0.id) }
                            },
                            id: \.id
                        )
                    }
                    try apply(
                        change,
                        deleting: isDeletion,
                        as: CalculationRoundSnapshot.self,
                        in: context,
                        cache: &calculationRounds,
                        makeModel: { $0.makeModel() }
                    ) { value, model in
                        model.dayKey = value.dayKey
                        model.roundIndex = value.roundIndex
                        model.generatorVersion = value.generatorVersion
                        model.questionsRawValue = value.questionsRawValue
                        model.answersRawValue = value.answersRawValue
                        model.correctCount = value.correctCount
                        model.startedAt = value.startedAt
                        model.submittedAt = value.submittedAt
                        model.durationSeconds = value.durationSeconds
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "pointLedgerEntries":
                    if loadedEntities.insert(change.entityType).inserted {
                        pointEntries = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<PointLedgerEntry> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: PointLedgerEntrySnapshot.self, in: context, cache: &pointEntries, makeModel: { $0.makeModel() }) { value, model in
                        model.createdAt = value.createdAt
                        model.amount = value.amount
                        model.kindRawValue = value.kindRawValue
                        model.sourceTypeRawValue = value.sourceTypeRawValue
                        model.sourceIDRawValue = value.sourceIDRawValue
                        model.idempotencyKey = value.idempotencyKey
                        model.note = value.note
                        model.isReversal = value.isReversal
                        model.reversesEntryIDRawValue = value.reversesEntryIDRawValue
                    }
                case "pointRewardStates":
                    if loadedEntities.insert(change.entityType).inserted {
                        pointStates = modelsByID(
                            try fetch(change.entityType) { ids in
                                #Predicate<PointRewardState> { ids.contains($0.id) }
                            }, id: \.id
                        )
                    }
                    try apply(change, deleting: isDeletion, as: PointRewardStateSnapshot.self, in: context, cache: &pointStates, makeModel: { $0.makeModel() }) { value, model in
                        model.currentStreak = value.currentStreak
                        model.lastActiveDay = value.lastActiveDay
                        model.longestStreak = value.longestStreak
                        model.updatedAt = value.updatedAt
                    }
                case "settings":
                    if !isDeletion {
                        settingsSnapshot = try change.decodePayload(AppSettingsSnapshot.self)
                    }
                default:
                    continue
                }
            }

            let modelDataChanged = context.hasChanges
            if modelDataChanged {
                try context.save()
            }
            if let settingsSnapshot {
                settingsStore.restore(from: settingsSnapshot, using: context, source: .server)
            }
            return modelDataChanged || settingsSnapshot != nil
        }
    }

    nonisolated private static func captureStructuredSnapshot(
        from container: ModelContainer,
        settings: AppSettingsSnapshot,
        recordIDs: [String: [UUID]]? = nil
    ) throws -> StructuredSnapshot {
        try PersistentStoreAccessGate.withAccess {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let payload = try DataBackupPayload.capture(
                from: context,
                settings: settings,
                mediaAssets: [],
                recordIDs: recordIDs
            )
            return try StructuredSnapshot(payload: payload)
        }
    }

    private static func latestChangesByRecord(_ changes: [ServerChange]) -> [ServerChange] {
        var latest: [SyncRecordKey: ServerChange] = [:]
        for change in changes {
            let key = SyncRecordKey(change)
            if let existing = latest[key], existing.serverVersion >= change.serverVersion {
                continue
            }
            latest[key] = change
        }
        return latest.values.sorted { $0.serverVersion < $1.serverVersion }
    }

    private static func conflictResolutions(
        for changes: [ServerChange],
        localSnapshot: StructuredSnapshot,
        baseline: [String: [String: String]],
        remoteHashes: [SyncRecordKey: String]
    ) throws -> [SyncRecordKey: IncrementalConflictResolution] {
        var result: [SyncRecordKey: IncrementalConflictResolution] = [:]
        for change in changes {
            let key = SyncRecordKey(change)
            guard let localRecord = localSnapshot.records[key.entityType]?[key.recordID] else {
                result[key] = .acceptRemote
                continue
            }
            let localHash = localSnapshot.hashes[key.entityType]?[key.recordID]
            let baselineHash = baseline[key.entityType]?[key.recordID]
            if change.deletedAt == nil, localHash == remoteHashes[key] {
                result[key] = .acceptRemote
                continue
            }
            guard localHash != baselineHash else {
                result[key] = .acceptRemote
                continue
            }

            if change.deletedAt != nil {
                // A tombstone is an explicit user deletion. Recreating content
                // requires a new ID, so stale offline edits cannot resurrect it.
                result[key] = .acceptRemote
            } else if key.entityType == "dictationSessions" {
                result[key] = .mergeDictationSession
            } else if key.entityType == "dictationEntries" {
                result[key] = .mergeDictationEntry
            } else {
                let remoteRecord = try change.payloadDictionary()
                result[key] = StructuredSnapshot.remoteRecordWinsConflict(
                    entityType: key.entityType,
                    local: localRecord,
                    remote: remoteRecord
                ) ? .acceptRemote : .keepLocal
            }
        }
        return result
    }

    private static func pendingLocalKeys(
        localSnapshot: StructuredSnapshot,
        baseline: [String: [String: String]],
        resolutions: [SyncRecordKey: IncrementalConflictResolution]
    ) -> Set<SyncRecordKey> {
        var pending: Set<SyncRecordKey> = []
        for (entityType, records) in localSnapshot.hashes {
            for (recordID, hash) in records where hash != baseline[entityType]?[recordID] {
                pending.insert(SyncRecordKey(entityType: entityType, recordID: recordID))
            }
        }
        for (key, resolution) in resolutions where resolution == .acceptRemote {
            pending.remove(key)
        }
        return pending
    }

    private static func baselineForPendingUpload(
        original: [String: [String: String]],
        mergedSnapshot: StructuredSnapshot,
        pendingLocalKeys: Set<SyncRecordKey>,
        changes: [ServerChange],
        resolutions: [SyncRecordKey: IncrementalConflictResolution]
    ) -> [String: [String: String]] {
        var result = original
        for change in changes where change.deletedAt == nil {
            let key = SyncRecordKey(change)
            if !pendingLocalKeys.contains(key),
               let hash = mergedSnapshot.hashes[key.entityType]?[key.recordID] {
                result[key.entityType, default: [:]][key.recordID] = hash
            }
        }
        for change in changes where change.deletedAt != nil {
            let key = SyncRecordKey(change)
            if resolutions[key] == .acceptRemote {
                result[key.entityType]?.removeValue(forKey: key.recordID)
            }
        }
        return result
    }

    static func mergeDictationSession(
        _ remote: DictationSessionSnapshot,
        into local: DictationSession
    ) {
        let localUpdatedAt = local.updatedAt
        if remote.updatedAt >= localUpdatedAt {
            local.title = remote.title
            local.typeRawValue = remote.typeRawValue
            local.createdAt = remote.createdAt
            local.scheduledDate = remote.scheduledDate
            local.currentEntryIndex = remote.currentEntryIndex
        }
        local.finishedAt = latest(local.finishedAt, remote.finishedAt)
        local.reviewedAt = latest(local.reviewedAt, remote.reviewedAt)
        local.updatedAt = max(localUpdatedAt, remote.updatedAt)
    }

    static func mergeDictationEntry(
        _ remote: DictationEntrySnapshot,
        into local: DictationEntry
    ) {
        let localUpdatedAt = local.updatedAt
        let localResult = DictationResult(rawValue: local.resultRawValue) ?? .pending
        let remoteResult = DictationResult(rawValue: remote.resultRawValue) ?? .pending
        let resolvedResult: DictationResult
        switch (localResult, remoteResult) {
        case (.pending, let remoteValue) where remoteValue != .pending:
            resolvedResult = remoteValue
        case (let localValue, .pending) where localValue != .pending:
            resolvedResult = localValue
        default:
            if remote.updatedAt != localUpdatedAt {
                resolvedResult = remote.updatedAt > localUpdatedAt ? remoteResult : localResult
            } else {
                resolvedResult = remote.resultRawValue > local.resultRawValue ? remoteResult : localResult
            }
        }

        if remote.updatedAt >= localUpdatedAt {
            local.sessionID = remote.sessionID
            local.sortOrder = remote.sortOrder
            local.typeRawValue = remote.typeRawValue
            local.content = remote.content
            local.prompt = remote.prompt
            local.note = remote.note
            local.source = remote.source
            local.createdAt = remote.createdAt
        }
        local.resultRawValue = resolvedResult.rawValue
        local.updatedAt = max(localUpdatedAt, remote.updatedAt)
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.none, .none): return nil
        case (.some(let value), .none), (.none, .some(let value)): return value
        case (.some(let lhs), .some(let rhs)): return max(lhs, rhs)
        }
    }

    private func modelsByID<Model: PersistentModel>(
        _ models: [Model],
        id: KeyPath<Model, UUID>
    ) -> [UUID: Model] {
        var result: [UUID: Model] = [:]
        for model in models {
            result[model[keyPath: id]] = model
        }
        return result
    }

    private func apply<Snapshot: Decodable, Model: PersistentModel>(
        _ change: ServerChange,
        deleting: Bool,
        as type: Snapshot.Type,
        in context: ModelContext,
        cache: inout [UUID: Model],
        makeModel: (Snapshot) -> Model,
        updateModel: (Snapshot, Model) -> Void
    ) throws {
        if deleting {
            if let existing = cache.removeValue(forKey: change.recordID) {
                context.delete(existing)
            }
            return
        }

        let value = try change.decodePayload(type)
        if let existing = cache[change.recordID] {
            updateModel(value, existing)
            return
        }

        let model = makeModel(value)
        context.insert(model)
        cache[change.recordID] = model
    }

    func scheduleUpload(
        from modelContext: ModelContext,
        settingsStore: AppSettingsStore,
        delayNanoseconds: UInt64 = 700_000_000
    ) {
        guard isEnabled else { return }
        if networkMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor [weak self] in self?.networkGeneration += 1 }
            }
            monitor.start(queue: DispatchQueue(label: "typo-review.sync-connectivity"))
            networkMonitor = monitor
        }
        uploadRequested = true
        defaults.set(true, forKey: Self.pendingUploadKey)
        // A new save only requests another pass. Never cancel a request which
        // may already have committed on the server, or drop a save while busy.
        guard uploadTask == nil else { return }
        uploadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.uploadTask = nil }
            var failures = 0
            while self.uploadRequested, !Task.isCancelled {
                let delay = failures == 0 ? delayNanoseconds : UInt64(min(60, 1 << min(failures, 6))) * 1_000_000_000
                do {
                    var remaining = delay
                    let generation = self.networkGeneration
                    while remaining > 0 {
                        let step = min(remaining, 1_000_000_000)
                        try await Task.sleep(nanoseconds: step)
                        remaining -= step
                        if failures > 0 && generation != self.networkGeneration { break }
                    }
                } catch { return }
                self.uploadRequested = false
                let succeeded = await self.synchronize(modelContext: modelContext, settingsStore: settingsStore)
                if succeeded {
                    failures = 0
                    if !self.uploadRequested { self.defaults.removeObject(forKey: Self.pendingUploadKey) }
                } else {
                    failures += 1
                    guard self.isEnabled else { return }
                    self.uploadRequested = true
                }
            }
        }
    }

    @discardableResult
    func uploadChanges(
        from modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        // Includes background flushes: an upload-only retry with an old cursor
        // otherwise repeats the same 409 indefinitely.
        await synchronize(modelContext: modelContext, settingsStore: settingsStore)
    }

    private func performUpload(
        from modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        guard let baseline = loadBaseline() else { return false }
        uploadNeedsMerge = false
        isUploading = true
        activeSyncPhase = "正在上传数据"
        defer {
            activeSyncPhase = nil
            isUploading = false
        }
        do {
            let container = modelContext.container
            let settings = settingsStore.snapshot
            let baseCursor = loadChangeCursor()
            var blocked = loadBlockedHashes()
            var preparedUpload: PreparedServerUpload
            if let data = defaults.data(forKey: Self.outboxKey) {
                preparedUpload = try JSONDecoder().decode(PreparedServerUpload.self, from: data)
            } else {
            let blockedAtCapture = blocked
            preparedUpload = try await Task.detached(priority: .utility) {
                try Self.prepareUpload(
                    from: container,
                    settings: settings,
                    baseline: baseline,
                    baseCursor: baseCursor,
                    blocked: blockedAtCapture
                )
            }.value
            defaults.set(try JSONEncoder().encode(preparedUpload), forKey: Self.outboxKey)
            }
            blocked = blocked.filter { key, hash in
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                return parts.count == 2 && preparedUpload.hashes[parts[0]]?[parts[1]] == hash
            }
            defaults.set(try JSONEncoder().encode(blocked), forKey: Self.blockedHashesKey)
            guard !preparedUpload.bodies.isEmpty else {
                defaults.removeObject(forKey: Self.outboxKey)
                if !blocked.isEmpty {
                    uploadError = "有复习记录与服务器冲突，已保留在本机；其他数据可正常同步。"
                    return true
                }
                uploadError = nil
                lastErrorDescription = nil
                return true
            }

            while let body = preparedUpload.bodies.first {
                try Task.checkCancellation()
                var object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                let held = loadBlockedHashes()
                let mutations = (object["mutations"] as! [[String: Any]]).filter { mutation in
                    guard mutation["operation"] as? String == "upsert",
                          let entity = mutation["entityType"] as? String,
                          let record = mutation["recordID"] as? String else { return true }
                    return held[entity + "/" + record] != preparedUpload.hashes[entity]?[record]
                }
                if mutations.isEmpty {
                    preparedUpload.bodies.removeFirst()
                    defaults.set(try JSONEncoder().encode(preparedUpload), forKey: Self.outboxKey)
                    continue
                }
                object["mutations"] = mutations
                let wireBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                let response = try await client.pushMutations(wireBody)
                let acknowledged = Set(response.appliedMutationIDs.map(\.uuidString))
                var nextBaseline = loadBaseline() ?? baseline
                var blockedHashes = loadBlockedHashes()
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let deletions = try context.fetch(FetchDescriptor<SyncDeletion>())
                let conflicts = Set((response.conflicts ?? []).map { $0.mutationID.uuidString })
                for mutation in mutations {
                    guard let id = mutation["mutationID"] as? String,
                          let entity = mutation["entityType"] as? String,
                          let record = mutation["recordID"] as? String else { continue }
                    let key = entity + "/" + record
                    if acknowledged.contains(id) {
                        nextBaseline[entity, default: [:]][record] = preparedUpload.hashes[entity]?[record]
                        blockedHashes.removeValue(forKey: key)
                        for deletion in deletions where deletion.id.uuidString == id { context.delete(deletion) }
                    } else if conflicts.contains(id) {
                        blockedHashes[key] = preparedUpload.hashes[entity]?[record]
                        if entity == "reviewRecords", let payload = mutation["payload"] as? [String: Any],
                           let itemID = payload["itemID"] as? String {
                            let canonicalID = UUID(uuidString: itemID)?.uuidString ?? itemID
                            blockedHashes["reviewItems/" + canonicalID] = preparedUpload.hashes["reviewItems"]?[canonicalID]
                        }
                    } else {
                        throw ServerAPIError.invalidResponse
                    }
                }
                try context.save()
                saveBaseline(nextBaseline)
                defaults.set(try JSONEncoder().encode(blockedHashes), forKey: Self.blockedHashesKey)
                preparedUpload.bodies.removeFirst()
                defaults.set(try JSONEncoder().encode(preparedUpload), forKey: Self.outboxKey)
            }
            defaults.removeObject(forKey: Self.outboxKey)
            uploadError = loadBlockedHashes().isEmpty ? nil : "有复习记录与服务器冲突，已保留在本机；其他数据可正常同步。"
            lastErrorDescription = nil
            lastSuccessfulUploadAt = .now
            let latestSettings = settingsStore.snapshot
            let latestBaseline = loadBaseline() ?? [:]
            let latestCursor = loadChangeCursor()
            let latestBlocked = loadBlockedHashes()
            let remaining = try await Task.detached(priority: .utility) {
                try Self.prepareUpload(from: container, settings: latestSettings,
                                       baseline: latestBaseline, baseCursor: latestCursor,
                                       blocked: latestBlocked)
            }.value
            if !remaining.bodies.isEmpty {
                scheduleUpload(from: modelContext, settingsStore: settingsStore)
            }
            return true
        } catch where Self.isCancellation(error) {
            return false
        } catch {
            if case ServerAPIError.rejected(let statusCode, let message) = error,
               statusCode == 409,
               message.contains("sync_record_changed") {
                defaults.removeObject(forKey: Self.outboxKey)
                uploadNeedsMerge = true
                uploadError = "其他设备更新了同一条数据，本机记录已保留，正在等待合并重试。"
            } else {
                uploadError = error.localizedDescription
            }
            #if DEBUG
            print("Server upload failed: \(error)")
            #endif
            return false
        }
    }

    nonisolated private static func prepareUpload(
        from container: ModelContainer,
        settings: AppSettingsSnapshot,
        baseline: [String: [String: String]],
        baseCursor: Int64?,
        blocked: [String: String]
    ) throws -> PreparedServerUpload {
        return try PersistentStoreAccessGate.withAccess {
        let context = ModelContext(container)
        let payload = try DataBackupPayload.capture(
            from: context,
            settings: settings,
            mediaAssets: []
        )
        let snapshot = try StructuredSnapshot(payload: payload)
        var mutations = try snapshot.mutations(comparedWith: baseline)
        mutations.removeAll { mutation in
            guard let entity = mutation["entityType"] as? String,
                  let id = mutation["recordID"] as? String else { return false }
            return blocked[entity + "/" + id] == snapshot.hashes[entity]?[id]
        }
        let deletions = try context.fetch(FetchDescriptor<SyncDeletion>())
        let formatter = ISO8601DateFormatter()
        for deletion in deletions {
            mutations.removeAll { ($0["entityType"] as? String) == deletion.entityType &&
                ($0["recordID"] as? String) == deletion.recordID.uuidString }
            mutations.append([
                "mutationID": deletion.id.uuidString, "entityType": deletion.entityType,
                "recordID": deletion.recordID.uuidString, "operation": "delete",
                "deletionIntent": "explicit", "updatedAt": formatter.string(from: deletion.deletedAt)
            ])
        }
        var bodies: [Data] = []
        bodies.reserveCapacity((mutations.count + 499) / 500)
        for batchStart in stride(from: 0, to: mutations.count, by: 500) {
            let batchEnd = min(batchStart + 500, mutations.count)
            var body: [String: Any] = [
                "mutations": Array(mutations[batchStart..<batchEnd]),
                "isolateConflicts": true
            ]
            if let baseCursor {
                body["baseCursor"] = baseCursor
            }
            bodies.append(
                try JSONSerialization.data(
                    withJSONObject: body,
                    options: [.sortedKeys]
                )
            )
        }
        return PreparedServerUpload(bodies: bodies, hashes: snapshot.hashes)
        }
    }

    nonisolated static func requiresSnapshotRestore(
        remoteHashes: [String: [String: String]],
        baseline: [String: [String: String]]?
    ) -> Bool {
        guard let baseline else { return true }
        return remoteHashes != baseline
    }

    private static func dataSummary(for payload: DataBackupPayload) -> String {
        "题库 \(payload.reviewItems.count) 条，复习记录 \(payload.reviewRecords.count) 条，听写 \(payload.dictationSessions.count) 组 / \(payload.dictationEntries.count) 条，计算 \(payload.calculationRounds.count) 轮"
    }

    private func synchronizeDeepSeekAPIKey() async {
        do {
            let remote = try await client.deepSeekAPIKey()
            if let value = remote.value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                try DeepSeekAPIKeyStore.saveAPIKey(value)
                return
            }

            let local = try DeepSeekAPIKeyStore.loadAPIKey()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !local.isEmpty {
                _ = try await client.saveDeepSeekAPIKey(local)
            }
        } catch {
            #if DEBUG
            print("DeepSeek API Key sync failed: \(error)")
            #endif
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func userFacingDescription(for error: Error, phase: String?) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return "\(phase ?? "服务器请求")超时。请切换 Wi‑Fi/蜂窝网络后重试；本机数据不会因此丢失。"
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
            return "当前网络不可用，请恢复网络后重试。"
        }
        return error.localizedDescription
    }

    private func installServerDailyPlan(
        in container: ModelContainer,
        dailyLimit: Int
    ) async throws -> Bool {
        let dayKey = ReviewDailyPlan.dayKey(for: .now)
        let serverPlan = try await client.dailyPlan(
            day: dayKey,
            dailyLimit: dailyLimit
        )
        return try PersistentStoreAccessGate.withAccess {
            // The restore context must not be kept alive across the network
            // request above. Use another fresh context so its store generation
            // includes the completed snapshot replacement.
            let modelContext = ModelContext(container)
            modelContext.autosaveEnabled = false
            let plans = try modelContext.fetch(
                FetchDescriptor<ReviewDailyPlan>(
                    predicate: #Predicate<ReviewDailyPlan> { $0.dayKey == dayKey }
                )
            )
            if plans.count == 1,
               let existingPlan = plans.first,
               existingPlan.id == serverPlan.id,
               existingPlan.itemIDs == serverPlan.items.map(\.itemID),
               existingPlan.createdAt == serverPlan.createdAt,
               existingPlan.updatedAt == serverPlan.updatedAt {
                return false
            }

            if let existingPlan = plans.first {
                existingPlan.id = serverPlan.id
                existingPlan.dayKey = serverPlan.day
                existingPlan.itemIDs = serverPlan.items.map(\.itemID)
                existingPlan.createdAt = serverPlan.createdAt
                existingPlan.updatedAt = serverPlan.updatedAt
                plans.dropFirst().forEach(modelContext.delete)
            } else {
                modelContext.insert(
                    ReviewDailyPlan(
                    id: serverPlan.id,
                    dayKey: serverPlan.day,
                    itemIDs: serverPlan.items.map(\.itemID),
                    createdAt: serverPlan.createdAt,
                    updatedAt: serverPlan.updatedAt
                    )
                )
            }
            if modelContext.hasChanges {
                try modelContext.save()
            }
            return true
        }
    }

    private func loadBaseline() -> [String: [String: String]]? {
        guard let data = defaults.data(forKey: Self.baselineDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    private func loadChangeCursor() -> Int64? {
        guard defaults.object(forKey: Self.changeCursorDefaultsKey) != nil else { return nil }
        return defaults.object(forKey: Self.changeCursorDefaultsKey) as? Int64
            ?? Int64(defaults.integer(forKey: Self.changeCursorDefaultsKey))
    }

    private func saveChangeCursor(_ cursor: Int64) {
        defaults.set(cursor, forKey: Self.changeCursorDefaultsKey)
    }

    private func loadReceipts() -> [String: Int64] {
        guard let data = defaults.data(forKey: Self.receiptsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
    }

    private func loadBlockedHashes() -> [String: String] {
        guard let data = defaults.data(forKey: Self.blockedHashesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveBaseline(_ baseline: [String: [String: String]]) {
        if let data = try? JSONEncoder().encode(baseline) {
            defaults.set(data, forKey: Self.baselineDefaultsKey)
        }
    }

    struct StructuredSnapshot {
        private static let timestampFields: [String: String] = [
            "reviewItems": "updatedAt",
            "reviewRecords": "reviewedAt",
            "taskItems": "updatedAt",
            "taskCompletions": "completedAt",
            "taskSubitems": "updatedAt",
            "taskExecutionRecords": "updatedAt",
            "taskSubitemExecutionRecords": "updatedAt",
            "dictationSessions": "updatedAt",
            "dictationEntries": "updatedAt",
            "scheduleItems": "updatedAt",
            "calculationRounds": "updatedAt",
            "pointLedgerEntries": "createdAt",
            "pointRewardStates": "updatedAt",
            "settings": "updatedAt",
        ]

        let records: [String: [String: [String: Any]]]
        let hashes: [String: [String: String]]

        static func timestamp(
            in record: [String: Any],
            entityType: String
        ) -> Date? {
            guard let field = timestampFields[entityType],
                  let value = record[field] as? String,
                  let data = try? JSONEncoder().encode(value) else {
                return nil
            }
            return try? JSONDecoder.typoReviewISO8601.decode(Date.self, from: data)
        }

        static func remoteRecordWinsConflict(
            entityType: String,
            local: [String: Any],
            remote: [String: Any]
        ) -> Bool {
            let localTimestamp = timestamp(in: local, entityType: entityType)
            let remoteTimestamp = timestamp(in: remote, entityType: entityType)
            if localTimestamp != remoteTimestamp {
                return (remoteTimestamp ?? .distantPast) > (localTimestamp ?? .distantPast)
            }

            // Equal edit times still need a deterministic winner so all devices
            // converge on the same payload after reconnecting.
            guard let localData = try? JSONSerialization.data(
                withJSONObject: local,
                options: [.sortedKeys]
            ), let remoteData = try? JSONSerialization.data(
                withJSONObject: remote,
                options: [.sortedKeys]
            ) else {
                return false
            }
            return localData.lexicographicallyPrecedes(remoteData)
        }

        init(payload: DataBackupPayload) throws {
            let data = try payload.encodedData()
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ServerAPIError.invalidResponse
            }
            var records: [String: [String: [String: Any]]] = [:]
            for entity in ServerSyncCoordinator.entityOrder {
                let values: [[String: Any]]
                if entity == "settings" {
                    values = (root["settings"] as? [String: Any]).map { [$0] } ?? []
                } else {
                    values = root[entity] as? [[String: Any]] ?? []
                }
                records[entity] = try Self.deduplicated(
                    values,
                    timestampField: Self.timestampFields[entity]
                )
            }
            self.records = records
            hashes = try records.mapValues { values in
                try values.mapValues { value in
                    let canonical = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                    return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
                }
            }
        }

        func mutations(comparedWith baseline: [String: [String: String]]) throws -> [[String: Any]] {
            let timestamp = ISO8601DateFormatter().string(from: .now)
            var mutations: [[String: Any]] = []
            for entity in ServerSyncCoordinator.entityOrder {
                let currentRecords = records[entity] ?? [:]
                let currentHashes = hashes[entity] ?? [:]
                let previousHashes = baseline[entity] ?? [:]

                for id in currentRecords.keys.sorted() where currentHashes[id] != previousHashes[id] {
                    mutations.append([
                        "mutationID": UUID().uuidString,
                        "entityType": entity,
                        "recordID": id,
                        "operation": "upsert",
                        "updatedAt": timestamp,
                        "payload": currentRecords[id]!,
                    ])
                }
                // A missing local record is not proof that the user explicitly
                // deleted it. The local store can be incomplete during a schema
                // migration, restore, reinstall, or multi-device bootstrap. The
                // previous implementation inferred deletes here and could erase
                // a complete server snapshot from one partial device. Explicit
                // deletion tombstones must use a separate protocol instead.
            }
            return mutations
        }

        private static func deduplicated(
            _ values: [[String: Any]],
            timestampField: String?
        ) throws -> [String: [String: Any]] {
            var result: [String: [String: Any]] = [:]
            for value in values {
                guard let id = value["id"] as? String else { continue }
                guard let existing = result[id] else {
                    result[id] = value
                    continue
                }

                let existingTimestamp = timestampField.flatMap { existing[$0] as? String } ?? ""
                let candidateTimestamp = timestampField.flatMap { value[$0] as? String } ?? ""
                if candidateTimestamp != existingTimestamp {
                    if candidateTimestamp > existingTimestamp {
                        result[id] = value
                    }
                    continue
                }

                // Equal timestamps still need a stable winner so every device hashes
                // the same physical duplicates in the same way.
                let existingData = try JSONSerialization.data(
                    withJSONObject: existing,
                    options: [.sortedKeys]
                )
                let candidateData = try JSONSerialization.data(
                    withJSONObject: value,
                    options: [.sortedKeys]
                )
                if existingData.lexicographicallyPrecedes(candidateData) {
                    result[id] = value
                }
            }
            return result
        }
    }
}

private extension ServerChange {
    func normalizedPayloadHash() throws -> String? {
        guard deletedAt == nil else { return nil }
        switch entityType {
        case "reviewItems": return try payloadHash(ReviewItemSnapshot.self)
        case "reviewRecords": return try payloadHash(ReviewRecordSnapshot.self)
        case "taskItems": return try payloadHash(TaskItemSnapshot.self)
        case "taskCompletions": return try payloadHash(TaskCompletionSnapshot.self)
        case "taskSubitems": return try payloadHash(TaskSubitemSnapshot.self)
        case "taskExecutionRecords": return try payloadHash(TaskExecutionRecordSnapshot.self)
        case "taskSubitemExecutionRecords": return try payloadHash(TaskSubitemExecutionRecordSnapshot.self)
        case "dictationSessions": return try payloadHash(DictationSessionSnapshot.self)
        case "dictationEntries": return try payloadHash(DictationEntrySnapshot.self)
        case "scheduleItems": return try payloadHash(ScheduleItemSnapshot.self)
        case "calculationRounds": return try payloadHash(CalculationRoundSnapshot.self)
        case "pointLedgerEntries": return try payloadHash(PointLedgerEntrySnapshot.self)
        case "pointRewardStates": return try payloadHash(PointRewardStateSnapshot.self)
        case "settings": return try payloadHash(AppSettingsSnapshot.self)
        default: return nil
        }
    }

    private func payloadHash<Value: Codable>(_ type: Value.Type) throws -> String {
        let value = try decodePayload(type)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    func payloadDictionary() throws -> [String: Any] {
        guard let payload else { throw ServerAPIError.invalidResponse }
        let data = try JSONEncoder().encode(payload)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerAPIError.invalidResponse
        }
        return value
    }
}

private struct PreparedServerUpload: Codable, Sendable {
    var bodies: [Data]
    let hashes: [String: [String: String]]
}
