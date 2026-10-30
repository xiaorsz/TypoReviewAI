import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppSettingsStore {
    private enum StorageKeys {
        static let snapshot = "app_settings_snapshot_v1"
        static let legacyReviewInteractionStyle = "reviewInteractionStyle"
        static let legacyAISummarySettingsMigrated = "daily_summary_ai_settings_migrated_to_app_settings_v1"
        static let ubiquitousAISummaryUpdatedAt = "daily_summary_ai_ubiquitous_updated_at_v1"
    }

    private enum UbiquitousKeys {
        static let aiSummaryEnabled = "daily_summary_ai_enabled_v1"
        static let aiSummaryModelRawValue = "daily_summary_ai_model_v1"
        static let aiSummaryUpdatedAt = "daily_summary_ai_updated_at_v1"
    }

    @ObservationIgnored private var cachedRepresentation: (snapshot: AppSettingsSnapshot, model: AppSettings)?
    private var userDefaults: UserDefaults
    private let appGroupIdentifier: String?
    private let ubiquitousStore = UserDefaults.standard
    private(set) var revision: Int = 0
    private(set) var lastSwiftDataError = ""

    var id: UUID
    var childName: String
    var dailyLimit: Int
    var remindHour: Int
    var remindMinute: Int
    var reviewInteractionStyle: ReviewInteractionStyle
    var boardAutoplayEnabled: Bool
    var boardAutoplayStartHour: Int
    var boardAutoplayStartMinute: Int
    var boardAutoplayEndHour: Int
    var boardAutoplayEndMinute: Int
    var boardAutoplayDurationMinutes: Int
    var boardAutoplaySlotsRawValue: String
    var boardManualPlaybackOptionRawValue: String
    var boardAutoplaySkipWeekends: Bool
    var boardAutoplaySkipChinaHolidays: Bool
    var aiSummaryEnabled: Bool
    var aiSummaryModelRawValue: String
    private var settingsUpdatedAt: Date

    private var hasBootstrapped = false
    private var hasActivatedExternalStores = false
    private var pendingLegacyAISummaryEnabled: Bool?
    private var pendingLegacyAISummaryModelRawValue: String?
    private var shouldMigrateLegacyAISummarySettings = false
    private var lastSyncedAISummaryEnabled: Bool
    private var lastSyncedAISummaryModelRawValue: String

    init(appGroupIdentifier: String? = nil) {
        self.appGroupIdentifier = appGroupIdentifier
        // Keep App construction free of App Group and iCloud reads. On a real device those
        // services can be temporarily unavailable and block the main thread before SwiftUI
        // has created its first scene. Shared settings are activated later by bootstrap().
        userDefaults = .standard

        // ⚠️ 注意：不能在这里实例化 AppSettings()。
        // AppSettings 是 @Model 类，实例化时 SwiftData 会调用 ModelContainer.currentContainer()，
        // 但 AppSettingsStore 在 TypoReviewApp.init() 的最开头就被创建，ModelContainer 还不存在。
        // iOS 17 上这会触发 _assertionFailure 崩溃。改为直接使用静态默认常量。
        id = AppSettings.syncSingletonID
        childName = AppSettings.defaultChildName
        dailyLimit = AppSettings.defaultDailyLimit
        remindHour = AppSettings.defaultRemindHour
        remindMinute = AppSettings.defaultRemindMinute
        reviewInteractionStyle = AppSettings.defaultReviewInteractionStyle
        boardAutoplayEnabled = AppSettings.defaultBoardAutoplayEnabled
        boardAutoplayStartHour = AppSettings.defaultBoardAutoplayStartHour
        boardAutoplayStartMinute = AppSettings.defaultBoardAutoplayStartMinute
        boardAutoplayEndHour = AppSettings.defaultBoardAutoplayEndHour
        boardAutoplayEndMinute = AppSettings.defaultBoardAutoplayEndMinute
        boardAutoplayDurationMinutes = AppSettings.defaultBoardAutoplayDurationMinutes
        boardAutoplaySlotsRawValue = AppSettings.defaultBoardAutoplaySlotsRawValue
        boardManualPlaybackOptionRawValue = AppSettings.defaultBoardManualPlaybackOption
        boardAutoplaySkipWeekends = AppSettings.defaultBoardAutoplaySkipWeekends
        boardAutoplaySkipChinaHolidays = AppSettings.defaultBoardAutoplaySkipChinaHolidays
        aiSummaryEnabled = AppSettings.defaultAISummaryEnabled
        aiSummaryModelRawValue = AppSettings.defaultAISummaryModelRawValue
        settingsUpdatedAt = AppSettingsSnapshot.legacyUpdatedAt
        lastSyncedAISummaryEnabled = AppSettings.defaultAISummaryEnabled
        lastSyncedAISummaryModelRawValue = AppSettings.defaultAISummaryModelRawValue

    }

    var boardManualPlaybackOption: BoardManualPlaybackOption {
        // ⚠️ 不能调 modelRepresentation.boardManualPlaybackOption —— 那会造成循环：
        // modelRepresentation → self.boardManualPlaybackOption → modelRepresentation → ∞ 栈溢出
        get { BoardManualPlaybackOption(rawValue: boardManualPlaybackOptionRawValue) ?? .untilPlaylistEnds }
        set { boardManualPlaybackOptionRawValue = newValue.rawValue }
    }

    var boardAutoplaySlots: [BoardAutoplaySlot] {
        get { modelRepresentation.boardAutoplaySlots }
        set {
            let settings = modelRepresentation
            settings.boardAutoplaySlots = newValue
            apply(from: settings, incrementRevision: false)
        }
    }

    var boardAutoplayTimeSummary: String {
        modelRepresentation.boardAutoplayTimeSummary
    }

    var boardAutoplayDurationSummary: String {
        modelRepresentation.boardAutoplayDurationSummary
    }

    var boardManualPlaybackOptionSummary: String {
        modelRepresentation.boardManualPlaybackOptionSummary
    }

    var boardAutoplayRuleSummary: String {
        modelRepresentation.boardAutoplayRuleSummary
    }

    var hasValidBoardAutoplayWindow: Bool {
        modelRepresentation.hasValidBoardAutoplayWindow
    }

    var snapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(
            id: id, childName: childName, dailyLimit: dailyLimit,
            remindHour: remindHour, remindMinute: remindMinute,
            reviewInteractionStyleRawValue: reviewInteractionStyle.rawValue,
            boardAutoplayEnabled: boardAutoplayEnabled,
            boardAutoplayStartHour: boardAutoplayStartHour, boardAutoplayStartMinute: boardAutoplayStartMinute,
            boardAutoplayEndHour: boardAutoplayEndHour, boardAutoplayEndMinute: boardAutoplayEndMinute,
            boardAutoplayDurationMinutes: boardAutoplayDurationMinutes,
            boardAutoplaySlotsRawValue: boardAutoplaySlotsRawValue,
            boardManualPlaybackOptionRawValue: boardManualPlaybackOptionRawValue,
            boardAutoplaySkipWeekends: boardAutoplaySkipWeekends,
            boardAutoplaySkipChinaHolidays: boardAutoplaySkipChinaHolidays,
            aiSummaryEnabled: aiSummaryEnabled, aiSummaryModelRawValue: aiSummaryModelRawValue,
            updatedAt: settingsUpdatedAt
        )
    }

    // ⚠️ 只能在 ModelContainer 创建完成（bootstrap 被调用）之后调用此属性。
    // AppSettings 是 @Model 类，实例化需要 ModelContainer.currentContainer 已存在。
    // 在 TypoReviewApp.init() → AppSettingsStore.init() 阶段禁止调用。
    var modelRepresentation: AppSettings {
        let current = snapshot
        if let cachedRepresentation, cachedRepresentation.snapshot == current {
            return cachedRepresentation.model
        }
        let settings = AppSettings(
            id: id,
            childName: childName,
            dailyLimit: dailyLimit,
            remindHour: remindHour,
            remindMinute: remindMinute,
            reviewInteractionStyle: reviewInteractionStyle,
            boardAutoplayEnabled: boardAutoplayEnabled,
            boardAutoplayStartHour: boardAutoplayStartHour,
            boardAutoplayStartMinute: boardAutoplayStartMinute,
            boardAutoplayEndHour: boardAutoplayEndHour,
            boardAutoplayEndMinute: boardAutoplayEndMinute,
            boardAutoplayDurationMinutes: boardAutoplayDurationMinutes,
            boardAutoplaySlots: [],
            boardManualPlaybackOption: .untilPlaylistEnds, // 固定传常量，rawValue 在下方立即被覆盖；不能传 self.boardManualPlaybackOption（循环）
            boardAutoplaySkipWeekends: boardAutoplaySkipWeekends,
            boardAutoplaySkipChinaHolidays: boardAutoplaySkipChinaHolidays,
            aiSummaryEnabled: aiSummaryEnabled,
            aiSummaryModelRawValue: aiSummaryModelRawValue
        )
        settings.reviewInteractionStyleRawValue = reviewInteractionStyle.rawValue
        settings.boardAutoplaySlotsRawValue = boardAutoplaySlotsRawValue
        settings.boardManualPlaybackOptionRawValue = boardManualPlaybackOptionRawValue
        cachedRepresentation = (current, settings)
        return settings
    }

    func bootstrap(using modelContext: ModelContext) {
        activateExternalStoresIfNeeded()
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        if loadSnapshotFromDefaults() != nil {
            persistLegacyAISummarySettingsMigrationIfNeeded(using: modelContext)
            return
        }

        let previousSnapshot = snapshot

        if let migratedSnapshot = loadSnapshotFromSwiftData(using: modelContext) {
            apply(snapshot: migratedSnapshot, incrementRevision: false)
        }
        applyPendingLegacyAISummarySettings()

        persistToDefaults()
        completeLegacyAISummarySettingsMigrationIfNeeded(using: modelContext)
        if snapshot != previousSnapshot {
            markChanged()
        }
    }

    func refreshFromSwiftDataIfPossible(using modelContext: ModelContext) {
        activateExternalStoresIfNeeded()
        guard let remoteSnapshot = loadSnapshotFromSwiftData(using: modelContext) else {
            return
        }

        guard remoteSnapshot != snapshot else { return }
        apply(snapshot: remoteSnapshot, incrementRevision: false)
        persistToDefaults()
        syncAISummarySettingsToUbiquitousStoreIfNeeded()
        markChanged()
    }

    func refreshFromUbiquitousStoreIfPossible(using modelContext: ModelContext) {
        activateExternalStoresIfNeeded()
        guard applyAISummarySettingsFromUbiquitousStoreIfNewer(incrementRevision: false) else {
            return
        }
        persistToDefaults()
        syncToSwiftDataIfPossible(using: modelContext)
        lastSyncedAISummaryEnabled = aiSummaryEnabled
        lastSyncedAISummaryModelRawValue = aiSummaryModelRawValue
        markChanged()
    }

    func persist(using modelContext: ModelContext) {
        activateExternalStoresIfNeeded()
        settingsUpdatedAt = .now
        persistCurrentValues(using: modelContext)
        AppDataChangeCenter.post()
    }

    private func persistCurrentValues(using modelContext: ModelContext) {
        persistToDefaults()
        syncAISummarySettingsToUbiquitousStoreIfNeeded()
        markChanged()
        syncToSwiftDataIfPossible(using: modelContext)
    }

    func restore(
        from snapshot: AppSettingsSnapshot?,
        using modelContext: ModelContext,
        source: AppDataChangeCenter.Source = .local
    ) {
        activateExternalStoresIfNeeded()
        if let snapshot {
            apply(snapshot: snapshot, incrementRevision: false)
        } else {
            // 不实例化 AppSettings()（@Model 类需要 ModelContainer），改为直接应用默认 snapshot
            apply(snapshot: makeDefaultSnapshot(), incrementRevision: false)
        }
        persistCurrentValues(using: modelContext)
        AppDataChangeCenter.post(source: source)
    }

    private func makeDefaultSnapshot() -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            id: AppSettings.syncSingletonID,
            childName: AppSettings.defaultChildName,
            dailyLimit: AppSettings.defaultDailyLimit,
            remindHour: AppSettings.defaultRemindHour,
            remindMinute: AppSettings.defaultRemindMinute,
            reviewInteractionStyleRawValue: AppSettings.defaultReviewInteractionStyle.rawValue,
            boardAutoplayEnabled: AppSettings.defaultBoardAutoplayEnabled,
            boardAutoplayStartHour: AppSettings.defaultBoardAutoplayStartHour,
            boardAutoplayStartMinute: AppSettings.defaultBoardAutoplayStartMinute,
            boardAutoplayEndHour: AppSettings.defaultBoardAutoplayEndHour,
            boardAutoplayEndMinute: AppSettings.defaultBoardAutoplayEndMinute,
            boardAutoplayDurationMinutes: AppSettings.defaultBoardAutoplayDurationMinutes,
            boardAutoplaySlotsRawValue: AppSettings.defaultBoardAutoplaySlotsRawValue,
            boardManualPlaybackOptionRawValue: AppSettings.defaultBoardManualPlaybackOption,
            boardAutoplaySkipWeekends: AppSettings.defaultBoardAutoplaySkipWeekends,
            boardAutoplaySkipChinaHolidays: AppSettings.defaultBoardAutoplaySkipChinaHolidays,
            aiSummaryEnabled: AppSettings.defaultAISummaryEnabled,
            aiSummaryModelRawValue: AppSettings.defaultAISummaryModelRawValue,
            updatedAt: AppSettingsSnapshot.legacyUpdatedAt
        )
    }

    private func activateExternalStoresIfNeeded() {
        guard !hasActivatedExternalStores else { return }
        hasActivatedExternalStores = true

        if let appGroupIdentifier,
           let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            userDefaults = sharedDefaults
        }

        if let storedSnapshot = loadSnapshotFromDefaults() {
            apply(snapshot: storedSnapshot, incrementRevision: false)
        }
        prepareLegacyAISummarySettingsMigrationIfNeeded()
        applyAISummarySettingsFromUbiquitousStoreIfNewer(incrementRevision: false)

        if shouldSeedAISummarySettingsToUbiquitousStore {
            syncAISummarySettingsToUbiquitousStoreIfNeeded()
        } else {
            lastSyncedAISummaryEnabled = aiSummaryEnabled
            lastSyncedAISummaryModelRawValue = aiSummaryModelRawValue
        }
    }

    func boardAutoplayWindow(on date: Date) -> (start: Date, end: Date)? {
        modelRepresentation.boardAutoplayWindow(on: date)
    }

    func currentBoardAutoplayWindow(on date: Date) -> (start: Date, end: Date)? {
        modelRepresentation.currentBoardAutoplayWindow(on: date)
    }

    func nextBoardAutoplayWindow(on date: Date) -> (start: Date, end: Date)? {
        modelRepresentation.nextBoardAutoplayWindow(on: date)
    }

    func isBoardAutoplayActive(on date: Date) -> Bool {
        modelRepresentation.isBoardAutoplayActive(on: date)
    }

    func boardAutoplayBlockedReason(on date: Date) -> String? {
        modelRepresentation.boardAutoplayBlockedReason(on: date)
    }

    func addBoardAutoplaySlot() {
        let settings = modelRepresentation
        settings.addBoardAutoplaySlot()
        apply(from: settings, incrementRevision: false)
    }

    func updateBoardAutoplaySlot(id: UUID, _ update: (inout BoardAutoplaySlot) -> Void) {
        let settings = modelRepresentation
        settings.updateBoardAutoplaySlot(id: id, update)
        apply(from: settings, incrementRevision: false)
    }

    func removeBoardAutoplaySlot(id: UUID) {
        let settings = modelRepresentation
        settings.removeBoardAutoplaySlot(id: id)
        apply(from: settings, incrementRevision: false)
    }

    private func apply(snapshot: AppSettingsSnapshot, incrementRevision: Bool) {
        id = AppSettings.syncSingletonID
        childName = snapshot.childName
        dailyLimit = snapshot.dailyLimit
        remindHour = snapshot.remindHour
        remindMinute = snapshot.remindMinute
        reviewInteractionStyle = ReviewInteractionStyle(rawValue: snapshot.reviewInteractionStyleRawValue)
            ?? AppSettings.defaultReviewInteractionStyle
        boardAutoplayEnabled = snapshot.boardAutoplayEnabled
        boardAutoplayStartHour = snapshot.boardAutoplayStartHour
        boardAutoplayStartMinute = snapshot.boardAutoplayStartMinute
        boardAutoplayEndHour = snapshot.boardAutoplayEndHour
        boardAutoplayEndMinute = snapshot.boardAutoplayEndMinute
        boardAutoplayDurationMinutes = snapshot.boardAutoplayDurationMinutes
        boardAutoplaySlotsRawValue = snapshot.boardAutoplaySlotsRawValue
        boardManualPlaybackOptionRawValue = snapshot.boardManualPlaybackOptionRawValue
        boardAutoplaySkipWeekends = snapshot.boardAutoplaySkipWeekends
        boardAutoplaySkipChinaHolidays = snapshot.boardAutoplaySkipChinaHolidays
        aiSummaryEnabled = snapshot.aiSummaryEnabled
        aiSummaryModelRawValue = snapshot.aiSummaryModelRawValue
        settingsUpdatedAt = snapshot.updatedAt

        if incrementRevision {
            markChanged()
        }
    }

    private func apply(from settings: AppSettings, incrementRevision: Bool) {
        apply(
            snapshot: AppSettingsSnapshot(settings, updatedAt: settingsUpdatedAt),
            incrementRevision: incrementRevision
        )
    }

    private func persistToDefaults() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            userDefaults.set(data, forKey: StorageKeys.snapshot)
        }
        UserDefaults.standard.set(reviewInteractionStyle.rawValue, forKey: StorageKeys.legacyReviewInteractionStyle)
        UserDefaults.standard.set(aiSummaryEnabled, forKey: DailySummaryAISettings.isEnabledKey)
        UserDefaults.standard.set(aiSummaryModelRawValue, forKey: DailySummaryAISettings.modelKey)
    }

    private func syncAISummarySettingsToUbiquitousStoreIfNeeded() {
        guard aiSummaryEnabled != lastSyncedAISummaryEnabled ||
              aiSummaryModelRawValue != lastSyncedAISummaryModelRawValue else {
            return
        }

        let updatedAt = Date().timeIntervalSince1970
        ubiquitousStore.set(aiSummaryEnabled, forKey: UbiquitousKeys.aiSummaryEnabled)
        ubiquitousStore.set(aiSummaryModelRawValue, forKey: UbiquitousKeys.aiSummaryModelRawValue)
        ubiquitousStore.set(updatedAt, forKey: UbiquitousKeys.aiSummaryUpdatedAt)

        userDefaults.set(updatedAt, forKey: StorageKeys.ubiquitousAISummaryUpdatedAt)
        lastSyncedAISummaryEnabled = aiSummaryEnabled
        lastSyncedAISummaryModelRawValue = aiSummaryModelRawValue
    }

    private var shouldSeedAISummarySettingsToUbiquitousStore: Bool {
        let hasRemoteTimestamp = ubiquitousStore.double(forKey: UbiquitousKeys.aiSummaryUpdatedAt) > 0
        let hasLocalTimestamp = userDefaults.double(forKey: StorageKeys.ubiquitousAISummaryUpdatedAt) > 0
        guard !hasRemoteTimestamp, !hasLocalTimestamp else { return false }

        return aiSummaryEnabled != AppSettings.defaultAISummaryEnabled ||
            aiSummaryModelRawValue != AppSettings.defaultAISummaryModelRawValue
    }

    @discardableResult
    private func applyAISummarySettingsFromUbiquitousStoreIfNewer(incrementRevision: Bool) -> Bool {
        let remoteUpdatedAt = ubiquitousStore.double(forKey: UbiquitousKeys.aiSummaryUpdatedAt)
        guard remoteUpdatedAt > 0 else { return false }

        let localUpdatedAt = userDefaults.double(forKey: StorageKeys.ubiquitousAISummaryUpdatedAt)
        guard remoteUpdatedAt > localUpdatedAt else { return false }

        let remoteEnabled = ubiquitousStore.object(forKey: UbiquitousKeys.aiSummaryEnabled) as? Bool
            ?? AppSettings.defaultAISummaryEnabled
        let remoteModel = ubiquitousStore.string(forKey: UbiquitousKeys.aiSummaryModelRawValue)
            ?? AppSettings.defaultAISummaryModelRawValue

        guard aiSummaryEnabled != remoteEnabled || aiSummaryModelRawValue != remoteModel else {
            userDefaults.set(remoteUpdatedAt, forKey: StorageKeys.ubiquitousAISummaryUpdatedAt)
            lastSyncedAISummaryEnabled = aiSummaryEnabled
            lastSyncedAISummaryModelRawValue = aiSummaryModelRawValue
            return false
        }

        aiSummaryEnabled = remoteEnabled
        aiSummaryModelRawValue = remoteModel
        userDefaults.set(remoteUpdatedAt, forKey: StorageKeys.ubiquitousAISummaryUpdatedAt)
        lastSyncedAISummaryEnabled = remoteEnabled
        lastSyncedAISummaryModelRawValue = remoteModel

        if incrementRevision {
            markChanged()
        }
        return true
    }

    private func loadSnapshotFromDefaults() -> AppSettingsSnapshot? {
        guard let data = userDefaults.data(forKey: StorageKeys.snapshot) else {
            return nil
        }
        return try? JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
    }

    private func loadSnapshotFromSwiftData(using modelContext: ModelContext) -> AppSettingsSnapshot? {
        do {
            return try safelyAccessSwiftData {
                let existing = try modelContext.fetch(FetchDescriptor<AppSettings>())
                return AppSettings.chooseCanonical(from: existing).map {
                    AppSettingsSnapshot($0, updatedAt: settingsUpdatedAt)
                }
            }
        } catch {
            lastSwiftDataError = error.localizedDescription
            print("AppSettings migration from SwiftData skipped: \(error)")
            return nil
        }
    }

    @discardableResult
    private func syncToSwiftDataIfPossible(using modelContext: ModelContext) -> Bool {
        do {
            try safelyAccessSwiftData {
                let existing = try modelContext.fetch(FetchDescriptor<AppSettings>())
                let target: AppSettings
                if let canonical = AppSettings.chooseCanonical(from: existing) {
                    target = canonical
                } else {
                    target = AppSettings()
                    modelContext.insert(target)
                }

                target.id = id
                target.childName = childName
                target.dailyLimit = dailyLimit
                target.remindHour = remindHour
                target.remindMinute = remindMinute
                target.reviewInteractionStyleRawValue = reviewInteractionStyle.rawValue
                target.boardAutoplayEnabled = boardAutoplayEnabled
                target.boardAutoplayStartHour = boardAutoplayStartHour
                target.boardAutoplayStartMinute = boardAutoplayStartMinute
                target.boardAutoplayEndHour = boardAutoplayEndHour
                target.boardAutoplayEndMinute = boardAutoplayEndMinute
                target.boardAutoplayDurationMinutes = boardAutoplayDurationMinutes
                target.boardAutoplaySlotsRawValue = boardAutoplaySlotsRawValue
                target.boardManualPlaybackOptionRawValue = boardManualPlaybackOptionRawValue
                target.boardAutoplaySkipWeekends = boardAutoplaySkipWeekends
                target.boardAutoplaySkipChinaHolidays = boardAutoplaySkipChinaHolidays
                target.aiSummaryEnabled = aiSummaryEnabled
                target.aiSummaryModelRawValue = aiSummaryModelRawValue

                for duplicate in existing where duplicate.persistentModelID != target.persistentModelID {
                    modelContext.delete(duplicate)
                }

                if modelContext.hasChanges {
                    try modelContext.save()
                }
            }
            lastSwiftDataError = ""
            return true
        } catch {
            lastSwiftDataError = error.localizedDescription
            print("AppSettings sync to SwiftData skipped: \(error)")
            return false
        }
    }

    private func markChanged() {
        revision &+= 1
    }

    private func prepareLegacyAISummarySettingsMigrationIfNeeded() {
        guard !userDefaults.bool(forKey: StorageKeys.legacyAISummarySettingsMigrated) else { return }

        pendingLegacyAISummaryEnabled = UserDefaults.standard.object(forKey: DailySummaryAISettings.isEnabledKey) as? Bool
        pendingLegacyAISummaryModelRawValue = UserDefaults.standard.string(forKey: DailySummaryAISettings.modelKey)
        shouldMigrateLegacyAISummarySettings =
            pendingLegacyAISummaryEnabled != nil || pendingLegacyAISummaryModelRawValue != nil
        applyPendingLegacyAISummarySettings()
    }

    private func applyPendingLegacyAISummarySettings() {
        if let pendingLegacyAISummaryEnabled {
            aiSummaryEnabled = pendingLegacyAISummaryEnabled
        }
        if let pendingLegacyAISummaryModelRawValue {
            aiSummaryModelRawValue = pendingLegacyAISummaryModelRawValue
        }
    }

    private func persistLegacyAISummarySettingsMigrationIfNeeded(using modelContext: ModelContext) {
        guard shouldMigrateLegacyAISummarySettings else { return }
        applyPendingLegacyAISummarySettings()
        persistToDefaults()
        completeLegacyAISummarySettingsMigrationIfNeeded(using: modelContext)
        markChanged()
    }

    private func completeLegacyAISummarySettingsMigrationIfNeeded(using modelContext: ModelContext) {
        guard shouldMigrateLegacyAISummarySettings else { return }
        guard syncToSwiftDataIfPossible(using: modelContext) else { return }
        userDefaults.set(true, forKey: StorageKeys.legacyAISummarySettingsMigrated)
        shouldMigrateLegacyAISummarySettings = false
    }

    private func safelyAccessSwiftData<T>(_ work: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        do {
            try ObjectiveCExceptionCatcher.perform {
                result = Result(catching: work)
            }
        } catch {
            throw error
        }

        guard let result else {
            throw NSError(
                domain: "cc.xiaorsz.dictation-coach-lab.app-settings",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "设置读取没有返回结果。"]
            )
        }

        return try result.get()
    }
}
