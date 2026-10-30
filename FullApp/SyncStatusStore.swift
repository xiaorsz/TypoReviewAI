import CloudKit
import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class SyncStatusStore {
    private enum RefreshError: Error {
        case cloudAccountStatusTimeout
    }

    private struct LocalDataCounts {
        let reviewItemCount: Int
        let reviewRecordCount: Int
        let taskCount: Int
        let scheduleCount: Int
        let dictationSessionCount: Int
        let dictationEntryCount: Int

        var summaryText: String {
            "题库 \(reviewItemCount) 条，记录 \(reviewRecordCount) 条，待办 \(taskCount) 条，日程 \(scheduleCount) 条，听写 \(dictationSessionCount) 组 / \(dictationEntryCount) 条"
        }
    }

    private struct LocalDataSummaryResult {
        let counts: LocalDataCounts?
        let errorDescription: String?
    }

    enum SyncNoticeKind: Equatable {
        case checking
        case ready
        case caution
        case blocked
    }

    enum CloudAccountState {
        case unknown
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case couldNotDetermine(String)

        var title: String {
            switch self {
            case .unknown:
                return "未检查"
            case .available:
                return "可用"
            case .noAccount:
                return "未登录 iCloud"
            case .restricted:
                return "受限"
            case .temporarilyUnavailable:
                return "暂时不可用"
            case .couldNotDetermine:
                return "检查失败"
            }
        }

        var detail: String {
            switch self {
            case .unknown:
                return "还没有进行 CloudKit 账户检查。"
            case .available:
                return "当前 iCloud 账户可用；仍需检查同步区域访问和实际上传、下载结果。"
            case .noAccount:
                return "这台设备没有登录 iCloud，或当前账号未启用 iCloud。"
            case .restricted:
                return "系统限制了 CloudKit 访问，常见于家长控制或企业设备策略。"
            case .temporarilyUnavailable:
                return "CloudKit 当前暂时不可用，可以稍后再试一次。"
            case .couldNotDetermine(let message):
                return message
            }
        }
    }

    enum Trigger {
        case launch
        case foreground
        case manual
    }

    private let fallbackContainerIdentifier = "iCloud.cc.xiaorsz.dictation-coach-lab"

    struct CloudKitSyncEvent: Identifiable {
        let id = UUID()
        let timestamp: Date
        let typeName: String
        let succeeded: Bool
        let errorDescription: String?
    }

    private struct CloudKitWriteProbe {
        let label: String
        let recordType: String
        let populateRecord: (CKRecord, UUID) -> Void
    }

    struct CloudKitWriteProbeResult {
        let label: String
        let recordType: String
        let succeeded: Bool
        let detail: String
    }

    enum CloudKitDirectStage {
        case account, zones, models
    }

    var isRefreshing = false
    var lastRefreshAt: Date?
    var lastErrorMessage = ""
    var lastTrigger: Trigger = .launch
    var cloudKitEnabled = false
    var serverSyncEnabled = false
    var containerIdentifier = "iCloud.cc.xiaorsz.dictation-coach-lab"
    var cloudAccountState: CloudAccountState = .unknown
    var localDataSummary = "尚未检查本地数据"
    var cloudKitInitializationError = ""
    var cloudKitEnvironment = "未检查"
    var buildConfiguration = "未检查"
    var recentCloudKitEvents: [CloudKitSyncEvent] = []
    var cloudKitDirectTestResult = ""
    var isTestingCloudKit = false
    private var cloudKitEventObserver: NSObjectProtocol?

    func configure(
        cloudKitEnabled: Bool,
        serverSyncEnabled: Bool = false,
        containerIdentifier: String? = nil,
        initializationError: String = ""
    ) {
        self.cloudKitEnabled = cloudKitEnabled
        self.serverSyncEnabled = serverSyncEnabled
        self.containerIdentifier = containerIdentifier ?? fallbackContainerIdentifier
        self.cloudKitInitializationError = initializationError
        refreshBuildDiagnostics()
        if cloudKitEnabled {
            startMonitoringCloudKitEvents()
        }
    }

    func refresh(using modelContext: ModelContext, trigger: Trigger) async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        lastTrigger = trigger
        lastErrorMessage = ""
        localDataSummary = "检查中..."

        #if DEBUG
        DebugPerf.mark("SyncStatusStore refresh begin trigger=\(trigger)")
        DebugPerf.watchMainThread("SyncStatusStore refresh \(trigger)")
        #endif

        let summaryResult = await fetchLocalDataSummary(using: modelContext.container)
        if let counts = summaryResult.counts {
            localDataSummary = counts.summaryText
            lastRefreshAt = .now
        } else {
            lastErrorMessage = summaryResult.errorDescription ?? "未知错误"
            localDataSummary = "本地数据检查失败"
        }

        await refreshCloudAccountState()

        #if DEBUG
        DebugPerf.mark("SyncStatusStore refresh end trigger=\(trigger) localSummary=\(localDataSummary)")
        #endif
    }

    private func fetchLocalDataSummary(using container: ModelContainer) async -> LocalDataSummaryResult {
        #if DEBUG
        DebugPerf.mark("SyncStatusStore local summary fetch begin")
        #endif

        let result = await Task.detached(priority: .utility) {
            PersistentStoreAccessGate.withAccess {
                let backgroundContext = ModelContext(container)

                do {
                    let counts = LocalDataCounts(
                        reviewItemCount: try backgroundContext.fetchCount(FetchDescriptor<ReviewItem>()),
                        reviewRecordCount: try backgroundContext.fetchCount(FetchDescriptor<ReviewRecord>()),
                        taskCount: try backgroundContext.fetchCount(FetchDescriptor<TaskItem>()),
                        scheduleCount: try backgroundContext.fetchCount(FetchDescriptor<ScheduleItem>()),
                        dictationSessionCount: try backgroundContext.fetchCount(FetchDescriptor<DictationSession>()),
                        dictationEntryCount: try backgroundContext.fetchCount(FetchDescriptor<DictationEntry>())
                    )
                    return LocalDataSummaryResult(counts: counts, errorDescription: nil)
                } catch {
                    return LocalDataSummaryResult(counts: nil, errorDescription: error.localizedDescription)
                }
            }
        }.value

        #if DEBUG
        if let counts = result.counts {
            DebugPerf.mark("SyncStatusStore local summary fetch end success reviews=\(counts.reviewItemCount) records=\(counts.reviewRecordCount) tasks=\(counts.taskCount) schedules=\(counts.scheduleCount) sessions=\(counts.dictationSessionCount) entries=\(counts.dictationEntryCount)")
        } else {
            DebugPerf.mark("SyncStatusStore local summary fetch end failed error=\(result.errorDescription ?? "unknown")")
        }
        #endif

        return result
    }

    private func refreshCloudAccountState() async {
        if serverSyncEnabled {
            cloudAccountState = .couldNotDetermine("当前使用上海服务器同步，不依赖 CloudKit 账户状态。")
            return
        }
        guard cloudKitEnabled else {
            cloudAccountState = .couldNotDetermine("当前运行的是本地存储模式，CloudKit 没有启用。")
            return
        }

        do {
            let containerIdentifier = containerIdentifier
            let status = try await withThrowingTaskGroup(of: CKAccountStatus.self) { group in
                group.addTask {
                    try await CKContainer(identifier: containerIdentifier).accountStatus()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw RefreshError.cloudAccountStatusTimeout
                }

                guard let status = try await group.next() else {
                    throw RefreshError.cloudAccountStatusTimeout
                }
                group.cancelAll()
                return status
            }

            switch status {
            case .available:
                cloudAccountState = .available
            case .noAccount:
                cloudAccountState = .noAccount
            case .restricted:
                cloudAccountState = .restricted
            case .temporarilyUnavailable:
                cloudAccountState = .temporarilyUnavailable
            case .couldNotDetermine:
                cloudAccountState = .couldNotDetermine("系统无法确定 CloudKit 账户状态。")
            @unknown default:
                cloudAccountState = .couldNotDetermine("遇到了未知的 CloudKit 账户状态。")
            }
        } catch RefreshError.cloudAccountStatusTimeout {
            cloudAccountState = .couldNotDetermine("CloudKit 账户检查超过 5 秒，已停止等待。")
        } catch {
            cloudAccountState = .couldNotDetermine(error.localizedDescription)
        }
    }

    var statusText: String {
        if !cloudKitEnabled && !serverSyncEnabled { return cloudKitInitializationError.isEmpty ? "独立本机存储" : "iCloud 暂不可用，数据已保存在本机" }
        if isRefreshing {
            return "同步中..."
        }

        if !lastErrorMessage.isEmpty {
            return "同步检查失败"
        }

        guard let lastRefreshAt else {
            return "等待首次同步检查"
        }

        return "最近同步检查 \(lastRefreshAt.formatted(date: .omitted, time: .shortened))"
    }

    var detailText: String {
        if !lastErrorMessage.isEmpty {
            return lastErrorMessage
        }

        switch lastTrigger {
        case .launch:
            return "App 启动后会自动检查一次同步状态。"
        case .foreground:
            return "每次回到前台都会自动检查一次同步状态。"
        case .manual:
            return "这是你刚刚手动触发的一次同步检查。"
        }
    }

    var cloudKitModeText: String {
        if serverSyncEnabled {
            return "上海服务器同步已启用"
        }
        return cloudKitEnabled ? "CloudKit 已启用" : "CloudKit 未启用"
    }

    var cloudAccountTitle: String {
        cloudAccountState.title
    }

    var cloudAccountDetail: String {
        cloudAccountState.detail
    }

    var isUsingLocalFallback: Bool {
        !cloudKitEnabled && !serverSyncEnabled && !cloudKitInitializationError.isEmpty
    }

    var storageModeTitle: String {
        if !cloudKitEnabled && !serverSyncEnabled { return cloudKitInitializationError.isEmpty ? "独立本机存储" : "暂存本机（iCloud 待恢复）" }
        if serverSyncEnabled {
            return "服务器同步存储"
        }
        return isUsingLocalFallback ? "已退回本地存储" : "CloudKit 同步存储"
    }

    var storageModeDetail: String {
        if !cloudKitEnabled && !serverSyncEnabled { return "实验数据独立保存在本 App 内，可通过备份文件复制。" }
        if serverSyncEnabled {
            return "结构化数据由上海服务器同步；听写音视频资源仍使用原来的存储方式。"
        }
        if isUsingLocalFallback {
            return "这台设备当前只保存在本机，不会把改动同步到其他设备。"
        }
        return "这台设备当前使用 CloudKit 存储，具备参与多设备同步的前提。"
    }

    var syncNoticeKind: SyncNoticeKind {
        if !cloudKitEnabled && !serverSyncEnabled && cloudKitInitializationError.isEmpty { return .ready }
        if serverSyncEnabled {
            return .ready
        }
        if isRefreshing || lastRefreshAt == nil {
            return .checking
        }

        if !cloudKitEnabled {
            return .blocked
        }

        switch cloudAccountState {
        case .available:
            return .ready
        case .temporarilyUnavailable, .unknown:
            return .caution
        case .noAccount, .restricted, .couldNotDetermine:
            return .blocked
        }
    }

    var syncNoticeTitle: String {
        if serverSyncEnabled {
            return "这台设备已连接上海服务器同步"
        }
        switch syncNoticeKind {
        case .checking:
            return "这台设备的同步状态还在检查中"
        case .ready:
            return "这台设备的同步前提看起来正常"
        case .caution:
            return "这台设备的同步现在不太稳定"
        case .blocked:
            return "这台设备当前不会和别的设备同步"
        }
    }

    var syncNoticeMessage: String {
        if serverSyncEnabled {
            return "题库、复习记录、任务、听写计划、日程和积分会在家庭账号的设备之间同步。"
        }
        if !cloudKitEnabled {
            return "当前已经退回本地存储模式。除非 CloudKit 初始化恢复成功，否则这台设备上的改动不会同步到 iPad 或 iPhone。"
        }

        switch cloudAccountState {
        case .unknown:
            return "请点一次“立即检查”，确认这台设备有没有真正连上 iCloud。"
        case .available:
            return "CloudKit 已启用，iCloud 账户也可用。这只说明同步前提正常，不代表最近的云端上传、下载已经成功完成。"
        case .noAccount:
            return "这台设备没有登录 iCloud，或者当前 Apple ID 没有开启 iCloud，所以它不会收到别的设备的数据。"
        case .restricted:
            return "系统限制了这台设备访问 iCloud，常见于家长控制、企业设备策略，或者系统层面的云服务限制。"
        case .temporarilyUnavailable:
            return "iCloud 当前暂时不可用。通常等一会儿、切一下网络，或者把 App 重新拉到前台后会恢复。"
        case .couldNotDetermine(let message):
            return "系统没能确认这台设备的 CloudKit 状态。\(message)"
        }
    }

    // MARK: - CloudKit Event Monitoring

    private func startMonitoringCloudKitEvents() {
        guard cloudKitEnabled else { return }
        guard cloudKitEventObserver == nil else { return }

        cloudKitEventObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSPersistentCloudKitContainerEventChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleCloudKitEvent(notification)
            }
        }
    }

    private func handleCloudKitEvent(_ notification: Notification) {
        guard let event = notification.userInfo?["event"] as? NSObject else { return }

        let endDate = event.value(forKey: "endDate") as? Date
        guard endDate != nil else { return }

        let typeRawValue = (event.value(forKey: "type") as? Int) ?? -1
        let typeName: String
        switch typeRawValue {
        case 0: typeName = "初始化"
        case 1: typeName = "下载"
        case 2: typeName = "上传"
        default: typeName = "未知(\(typeRawValue))"
        }

        let succeeded = (event.value(forKey: "succeeded") as? Bool) ?? false
        let error = event.value(forKey: "error") as? NSError

        let errorDetail: String? = error.map { Self.deepErrorDescription($0) }

        let syncEvent = CloudKitSyncEvent(
            timestamp: endDate ?? Date(),
            typeName: typeName,
            succeeded: succeeded,
            errorDescription: errorDetail
        )

        recentCloudKitEvents.insert(syncEvent, at: 0)
        if recentCloudKitEvents.count > 50 {
            recentCloudKitEvents = Array(recentCloudKitEvents.prefix(50))
        }
    }

    static func deepErrorDescription(_ error: NSError, depth: Int = 0) -> String {
        let prefix = depth > 0 ? String(repeating: "  ", count: depth) + "↳ " : ""
        var parts: [String] = []

        // Main error info
        parts.append("\(prefix)[\(error.domain) \(error.code)] \(safeDiagnosticText(error.localizedDescription))")
        // Only inspect known textual reasons, never dump userInfo, records or
        // request headers. Redact credentials even if a service echoes them.
        let reasonKeys = [
            (NSLocalizedFailureReasonErrorKey, "失败原因"),
            (NSLocalizedRecoverySuggestionErrorKey, "恢复建议"),
            ("CKErrorServerDescriptionKey", "服务器说明"),
            ("ServerDescription", "服务器说明"),
            ("NSDebugDescription", "调试说明")
        ]
        var seenReasons = Set<String>()
        for (key, label) in reasonKeys {
            guard let text = error.userInfo[key] as? String, !text.isEmpty else { continue }
            let safe = safeDiagnosticText(text)
            if seenReasons.insert(safe).inserted { parts.append("\(prefix)  \(label): \(safe)") }
        }
        guard depth < 5 else {
            parts.append("\(prefix)  ...错误链过深，已停止展开")
            return parts.joined(separator: "\n")
        }

        // CKError specific info
        if error.domain == "CKErrorDomain" || error.domain == CKError.errorDomain {
            if error.code == CKError.Code.partialFailure.rawValue {
                parts.append("\(prefix)  说明: 这是一批记录的部分失败，请继续查看下方子错误。")
            }

            // Retry after hint
            if let retryAfter = (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue,
               retryAfter.isFinite, retryAfter >= 0 {
                // CKError userInfo may contain an integer NSNumber or a Double.
                // Round up so the displayed wait never shortens the server hint.
                let seconds = String(format: "%.0f", retryAfter.rounded(.up))
                parts.append("\(prefix)  重试等待: \(seconds)秒")
            }

            // Partial errors (CKError.partialFailure contains per-item errors)
            let partialErrors = cloudKitPartialErrors(from: error)
            if !partialErrors.isEmpty {
                let sample = partialErrors.prefix(8)
                for (key, subError) in sample {
                    parts.append("\(prefix)  子错误[\(safeDiagnosticText(key))]:")
                    parts.append(deepErrorDescription(subError, depth: depth + 1))
                }
                if partialErrors.count > 8 {
                    parts.append("\(prefix)  ...还有 \(partialErrors.count - 8) 个子错误")
                }
            }
        }

        // Underlying error chain
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(deepErrorDescription(underlying, depth: depth + 1))
        }

        return parts.joined(separator: "\n")
    }

    private static func safeDiagnosticText(_ text: String) -> String {
        var value = text
        let patterns = [
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)[\"']?\b(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|authorization|token|password|secret)\b[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            #"\bsk-[A-Za-z0-9_-]{6,}\b"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: "[已隐藏凭据]", options: .regularExpression)
        }
        return String(value.prefix(2000))
    }

    private static func cloudKitPartialErrors(from error: NSError) -> [(String, NSError)] {
        guard let rawPartialErrors = error.userInfo[CKPartialErrorsByItemIDKey] else {
            return []
        }

        let entries: [(AnyHashable, NSError)]
        if let partialErrors = rawPartialErrors as? [AnyHashable: NSError] {
            entries = Array(partialErrors)
        } else if let partialErrors = rawPartialErrors as? NSDictionary {
            entries = partialErrors.compactMap { key, value in
                guard let key = key as? AnyHashable, let error = value as? NSError else {
                    return nil
                }
                return (key, error)
            }
        } else {
            return []
        }

        return entries
            .map { (String(describing: $0.0), $0.1) }
            .sorted { $0.0 < $1.0 }
    }

    // MARK: - CloudKit Direct Test

    func testCloudKitDirectly() async {
        isTestingCloudKit = true
        cloudKitDirectTestResult = "检查中..."
        defer { isTestingCloudKit = false }

        guard cloudKitEnabled else {
            cloudKitDirectTestResult = "❌ CloudKit 未启用"
            return
        }

        var stage = CloudKitDirectStage.account
        do {
            let ckContainer = CKContainer(identifier: containerIdentifier)
            let database = ckContainer.privateCloudDatabase

            // 1. Check account status
            let accountStatus = try await ckContainer.accountStatus()
            let accountLabel: String
            switch accountStatus {
            case .available: accountLabel = "✅ 可用"
            case .noAccount: accountLabel = "❌ 未登录 iCloud"
            case .restricted: accountLabel = "⚠️ 受限"
            case .temporarilyUnavailable: accountLabel = "⚠️ 暂时不可用"
            case .couldNotDetermine: accountLabel = "⚠️ 无法确定"
            @unknown default: accountLabel = "⚠️ 未知(\(accountStatus.rawValue))"
            }

            var lines: [String] = ["iCloud 账户: \(accountLabel)"]
            guard accountStatus == .available else {
                cloudKitDirectTestResult = "❌ iCloud 账户当前不可用，尚未检查同步区域或模型写入。\n" + lines.joined(separator: "\n")
                return
            }

            // 2. Check zones
            stage = .zones
            let zones = try await database.allRecordZones()
            let cdZone = zones.first(where: {
                $0.zoneID.zoneName == "com.apple.coredata.cloudkit.zone"
            })

            if let cdZone = cdZone {
                lines.append("✅ CoreData 同步区域存在")
                stage = .models
                let coreResults = await Self.runCloudKitWriteProbes(
                    Self.coreCloudKitWriteProbes(),
                    database: database,
                    zoneID: cdZone.zoneID
                )
                let taskResults = await Self.runCloudKitWriteProbes(
                    Self.taskCloudKitWriteProbes(),
                    database: database,
                    zoneID: cdZone.zoneID
                )
                let pointsResults = await Self.runCloudKitWriteProbes(
                    Self.pointsCloudKitWriteProbes(),
                    database: database,
                    zoneID: cdZone.zoneID
                )

                lines.insert(
                    Self.cloudKitDirectTestSummary(
                        accountStatus: accountStatus,
                        coreResults: coreResults,
                        taskResults: taskResults,
                        pointsResults: pointsResults
                    ),
                    at: 0
                )
                lines.append("")
                lines.append("题库 / 听写 / 日程 / 设置 / 媒体 / 删除 / 计算模型检查")
                lines.append(contentsOf: Self.formattedProbeLines(for: coreResults))
                lines.append("")
                lines.append("任务系统模型检查")
                lines.append(contentsOf: Self.formattedProbeLines(for: taskResults))
                lines.append("")
                lines.append("积分系统模型检查")
                lines.append(contentsOf: Self.formattedProbeLines(for: pointsResults))
            } else {
                let zoneNames = zones.map(\.zoneID.zoneName).joined(separator: ", ")
                lines.insert("❌ 账户可用且区域查询成功，但未找到 CoreData 同步区域。尚未执行模型写入测试，请查看初始化事件及当前容器的环境配置。", at: 0)
                lines.append("可用区域: \(zoneNames)")
            }

            cloudKitDirectTestResult = lines.joined(separator: "\n")
        } catch {
            let nsError = error as NSError
            cloudKitDirectTestResult = Self.cloudKitDirectFailure(stage: stage, error: nsError)
        }
    }

    static func cloudKitDirectFailure(stage: CloudKitDirectStage, error: NSError) -> String {
        let message: String
        switch stage {
        case .account:
            message = "❌ iCloud 账户检查失败，尚未检查同步区域或模型写入。"
        case .zones:
            message = "❌ iCloud 账户可用，但同步区域访问失败。尚未执行模型写入测试；请核查当前容器、环境、权限或服务状态，不能据此判定缺少哪类模型字段。"
        case .models:
            message = "❌ 账户和同步区域检查通过，但模型写入测试未完成，请查看具体原因。"
        }
        return message + "\n" + deepErrorDescription(error)
    }

    // MARK: - Force Sync

    func triggerForcePush(using modelContext: ModelContext) {
        let dummyRecord = ReviewRecord(
            itemID: UUID(),
            reviewedAt: .distantPast,
            result: .correct,
            mode: .scheduled,
            oldStage: 0,
            newStage: 0,
            note: "__sync_test__"
        )
        modelContext.insert(dummyRecord)
        try? modelContext.save()
        modelContext.delete(dummyRecord)
        try? modelContext.save()
    }

    // MARK: - Build Diagnostics

    private func refreshBuildDiagnostics() {
        if let receiptName = Bundle.main.appStoreReceiptURL?.lastPathComponent {
            switch receiptName {
            case "sandboxReceipt":
                cloudKitEnvironment = "sandboxReceipt（TestFlight 或开发安装都可能出现）"
            case "receipt":
                cloudKitEnvironment = "receipt（更像正式分发）"
            default:
                cloudKitEnvironment = receiptName
            }
        } else {
            cloudKitEnvironment = "未知"
        }

#if DEBUG
        buildConfiguration = "Debug 构建"
#else
        buildConfiguration = "Release 构建"
#endif
    }

    private static func coreCloudKitWriteProbes() -> [CloudKitWriteProbe] {
        [
            CloudKitWriteProbe(label: "题库条目", recordType: "CD_ReviewItem") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_typeRawValue"] = ReviewItemType.chineseCharacter.rawValue as CKRecordValue
                record["CD_content"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_prompt"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_note"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_source"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_stage"] = NSNumber(value: 0)
                record["CD_nextReviewAt"] = Date() as CKRecordValue
                record["CD_lastReviewedAt"] = Date() as CKRecordValue
                record["CD_consecutiveCorrectCount"] = NSNumber(value: 0)
                record["CD_consecutiveWrongCount"] = NSNumber(value: 0)
                record["CD_isPriority"] = NSNumber(value: false)
                record["CD_reviewTrackRawValue"] = ReviewTrack.standard.rawValue as CKRecordValue
                record["CD_dictationFollowUpStep"] = NSNumber(value: 1)
                record["CD_isDictationPassRaw"] = NSNumber(value: true)
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "复习记录", recordType: "CD_ReviewRecord") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_itemID"] = UUID().uuidString as CKRecordValue
                record["CD_reviewedAt"] = Date() as CKRecordValue
                record["CD_resultRawValue"] = ReviewResult.correct.rawValue as CKRecordValue
                record["CD_modeRawValue"] = ReviewMode.scheduled.rawValue as CKRecordValue
                record["CD_oldStage"] = NSNumber(value: 0)
                record["CD_newStage"] = NSNumber(value: 0)
                record["CD_note"] = "__cloudkit_probe__" as CKRecordValue
            },
            CloudKitWriteProbe(label: "每日复习清单", recordType: "CD_ReviewDailyPlan") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_dayKey"] = ReviewDailyPlan.dayKey(for: .now) as CKRecordValue
                record["CD_itemIDsRawValue"] = "[]" as CKRecordValue
                record["CD_coachSubjectRawValue"] = "chinese" as CKRecordValue
                record["CD_coachRationale"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_startedAt"] = Date() as CKRecordValue
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "删除标记", recordType: "CD_SyncDeletion") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                // An unknown entity and random ID cannot refer to user data.
                record["CD_entityType"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_recordID"] = testID.uuidString as CKRecordValue
                record["CD_deletedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "既有计算记录", recordType: "CD_CalculationRound") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_dayKey"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_roundIndex"] = NSNumber(value: 0)
                record["CD_generatorVersion"] = NSNumber(value: CalculationGenerator.currentVersion)
                record["CD_questionsRawValue"] = "[]" as CKRecordValue
                record["CD_answersRawValue"] = "[]" as CKRecordValue
                record["CD_correctCount"] = NSNumber(value: 0)
                record["CD_startedAt"] = Date() as CKRecordValue
                record["CD_submittedAt"] = Date() as CKRecordValue
                record["CD_durationSeconds"] = NSNumber(value: 0)
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "听写组", recordType: "CD_DictationSession") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_title"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_typeRawValue"] = ReviewItemType.chineseCharacter.rawValue as CKRecordValue
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
                record["CD_scheduledDate"] = Date() as CKRecordValue
                record["CD_finishedAt"] = Date() as CKRecordValue
                record["CD_reviewedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "听写条目", recordType: "CD_DictationEntry") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_sessionID"] = UUID().uuidString as CKRecordValue
                record["CD_sortOrder"] = NSNumber(value: 0)
                record["CD_typeRawValue"] = ReviewItemType.chineseCharacter.rawValue as CKRecordValue
                record["CD_content"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_prompt"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_note"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_source"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_resultRawValue"] = DictationResult.pending.rawValue as CKRecordValue
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "日程", recordType: "CD_ScheduleItem") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_title"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_note"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_startTime"] = Date() as CKRecordValue
                record["CD_endTime"] = Date() as CKRecordValue
                record["CD_repeatRuleRawValue"] = ScheduleRepeatRule.once.rawValue as CKRecordValue
                record["CD_weekdaysJSON"] = "[]" as CKRecordValue
                record["CD_effectiveStartDate"] = Date() as CKRecordValue
                record["CD_effectiveEndDate"] = Date() as CKRecordValue
                record["CD_isArchived"] = NSNumber(value: false)
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "应用设置", recordType: "CD_AppSettings") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_childName"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_dailyLimit"] = NSNumber(value: AppSettings.defaultDailyLimit)
                record["CD_remindHour"] = NSNumber(value: AppSettings.defaultRemindHour)
                record["CD_remindMinute"] = NSNumber(value: AppSettings.defaultRemindMinute)
                record["CD_reviewInteractionStyleRawValue"] = AppSettings.defaultReviewInteractionStyle.rawValue as CKRecordValue
                record["CD_boardAutoplayEnabled"] = NSNumber(value: AppSettings.defaultBoardAutoplayEnabled)
                record["CD_boardAutoplayStartHour"] = NSNumber(value: AppSettings.defaultBoardAutoplayStartHour)
                record["CD_boardAutoplayStartMinute"] = NSNumber(value: AppSettings.defaultBoardAutoplayStartMinute)
                record["CD_boardAutoplayEndHour"] = NSNumber(value: AppSettings.defaultBoardAutoplayEndHour)
                record["CD_boardAutoplayEndMinute"] = NSNumber(value: AppSettings.defaultBoardAutoplayEndMinute)
                record["CD_boardAutoplayDurationMinutes"] = NSNumber(value: AppSettings.defaultBoardAutoplayDurationMinutes)
                record["CD_boardAutoplaySlotsRawValue"] = AppSettings.defaultBoardAutoplaySlotsRawValue as CKRecordValue
                record["CD_boardManualPlaybackOptionRawValue"] = AppSettings.defaultBoardManualPlaybackOption as CKRecordValue
                record["CD_boardAutoplaySkipWeekends"] = NSNumber(value: AppSettings.defaultBoardAutoplaySkipWeekends)
                record["CD_boardAutoplaySkipChinaHolidays"] = NSNumber(value: AppSettings.defaultBoardAutoplaySkipChinaHolidays)
                record["CD_aiSummaryEnabled"] = NSNumber(value: AppSettings.defaultAISummaryEnabled)
                record["CD_aiSummaryModelRawValue"] = AppSettings.defaultAISummaryModelRawValue as CKRecordValue
            },
            CloudKitWriteProbe(label: "媒体索引", recordType: "CD_MediaAsset") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_title"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_originalFilename"] = "__cloudkit_probe__.mp3" as CKRecordValue
                record["CD_storedFilename"] = "__cloudkit_probe__.\(testID.uuidString).mp3" as CKRecordValue
                record["CD_mediaTypeRawValue"] = MediaAssetType.audio.rawValue as CKRecordValue
                record["CD_storageScopeRawValue"] = MediaStorageScope.local.rawValue as CKRecordValue
                record["CD_playlistOrder"] = NSNumber(value: 0)
                record["CD_isIncludedInPlaylist"] = NSNumber(value: true)
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            }
        ]
    }

    private static func taskCloudKitWriteProbes() -> [CloudKitWriteProbe] {
        [
            CloudKitWriteProbe(label: "任务", recordType: "CD_TaskItem") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_title"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_note"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_recurrenceJSON"] = #"{"kind":"once","weekdays":[]}"# as CKRecordValue
                record["CD_skipPolicyRawValue"] = TaskSkipPolicy.skippable.rawValue as CKRecordValue
                record["CD_startDate"] = Date() as CKRecordValue
                record["CD_endDate"] = Date() as CKRecordValue
                record["CD_isArchived"] = NSNumber(value: false)
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "旧任务完成记录", recordType: "CD_TaskCompletion") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_taskID"] = UUID().uuidString as CKRecordValue
                record["CD_completedDate"] = Date() as CKRecordValue
                record["CD_completedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "任务执行记录", recordType: "CD_TaskExecutionRecord") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_taskID"] = UUID().uuidString as CKRecordValue
                record["CD_occurrenceDate"] = Date() as CKRecordValue
                record["CD_detail"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_statusRawValue"] = TaskExecutionStatus.pending.rawValue as CKRecordValue
                record["CD_completedAt"] = Date() as CKRecordValue
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "任务子项", recordType: "CD_TaskSubitem") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_parentTaskID"] = UUID().uuidString as CKRecordValue
                record["CD_taskExecutionIDRawValue"] = "" as CKRecordValue
                record["CD_title"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_note"] = "" as CKRecordValue
                record["CD_detail"] = "" as CKRecordValue
                record["CD_statusRawValue"] = TaskExecutionStatus.pending.rawValue as CKRecordValue
                record["CD_sortOrder"] = NSNumber(value: 0)
                record["CD_isArchived"] = NSNumber(value: false)
                record["CD_completedAt"] = Date() as CKRecordValue
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "任务子项执行记录", recordType: "CD_TaskSubitemExecutionRecord") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_taskExecutionID"] = UUID().uuidString as CKRecordValue
                record["CD_subtaskID"] = UUID().uuidString as CKRecordValue
                record["CD_detail"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_statusRawValue"] = TaskExecutionStatus.pending.rawValue as CKRecordValue
                record["CD_completedAt"] = Date() as CKRecordValue
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            }
        ]
    }

    private static func pointsCloudKitWriteProbes() -> [CloudKitWriteProbe] {
        [
            CloudKitWriteProbe(label: "积分记录", recordType: "CD_PointLedgerEntry") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_amount"] = NSNumber(value: 0)
                record["CD_kindRawValue"] = PointLedgerKind.reward.rawValue as CKRecordValue
                record["CD_sourceTypeRawValue"] = PointLedgerSourceType.reviewRecord.rawValue as CKRecordValue
                record["CD_sourceIDRawValue"] = testID.uuidString as CKRecordValue
                record["CD_idempotencyKey"] = "__cloudkit_probe__.\(testID.uuidString)" as CKRecordValue
                record["CD_note"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_isReversal"] = NSNumber(value: false)
                record["CD_reversesEntryIDRawValue"] = testID.uuidString as CKRecordValue
            },
            CloudKitWriteProbe(label: "积分状态", recordType: "CD_PointRewardState") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_currentStreak"] = NSNumber(value: 0)
                record["CD_lastActiveDay"] = Date() as CKRecordValue
                record["CD_longestStreak"] = NSNumber(value: 0)
                record["CD_updatedAt"] = Date() as CKRecordValue
            }
        ]
    }

    private static func runCloudKitWriteProbes(
        _ probes: [CloudKitWriteProbe],
        database: CKDatabase,
        zoneID: CKRecordZone.ID
    ) async -> [CloudKitWriteProbeResult] {
        var results: [CloudKitWriteProbeResult] = []
        for probe in probes {
            let result = await runCloudKitWriteProbe(probe, database: database, zoneID: zoneID)
            results.append(result)
        }
        return results
    }

    private static func runCloudKitWriteProbe(
        _ probe: CloudKitWriteProbe,
        database: CKDatabase,
        zoneID: CKRecordZone.ID
    ) async -> CloudKitWriteProbeResult {
        let testID = UUID()
        let recordID = CKRecord.ID(
            recordName: "diag.\(probe.recordType).\(testID.uuidString)",
            zoneID: zoneID
        )
        let record = CKRecord(recordType: probe.recordType, recordID: recordID)
        probe.populateRecord(record, testID)

        do {
            let savedRecord = try await database.save(record)
            do {
                try await database.deleteRecord(withID: savedRecord.recordID)
                return CloudKitWriteProbeResult(
                    label: probe.label,
                    recordType: probe.recordType,
                    succeeded: true,
                    detail: "写入和删除测试记录都成功。"
                )
            } catch {
                return CloudKitWriteProbeResult(
                    label: probe.label,
                    recordType: probe.recordType,
                    succeeded: true,
                    detail: "写入成功，但清理测试记录失败：\n\(deepErrorDescription(error as NSError))"
                )
            }
        } catch {
            let nsError = error as NSError
            return CloudKitWriteProbeResult(
                label: probe.label,
                recordType: probe.recordType,
                succeeded: false,
                detail: deepErrorDescription(nsError)
            )
        }
    }

    static func cloudKitDirectTestSummary(
        accountStatus: CKAccountStatus,
        coreResults: [CloudKitWriteProbeResult],
        taskResults: [CloudKitWriteProbeResult],
        pointsResults: [CloudKitWriteProbeResult]
    ) -> String {
        let accountAvailable = accountStatus == .available
        let coreFailures = coreResults.filter { !$0.succeeded }
        let taskFailures = taskResults.filter { !$0.succeeded }
        let pointsFailures = pointsResults.filter { !$0.succeeded }
        let failureCount = coreFailures.count + taskFailures.count + pointsFailures.count

        guard accountAvailable else {
            return "❌ iCloud 账户当前不可用，先解决账号或系统层限制。"
        }

        if failureCount > 0 {
            return "⚠️ \(failureCount) 类模型的测试写入失败，请查看逐项原因。若明确提示记录类型或字段缺失，再检查当前环境的 Schema 部署；其他错误继续核查容器权限或服务状态。"
        }

        let count = coreResults.count + taskResults.count + pointsResults.count
        return "✅ \(count) 类模型的测试字段写入成功；实际 SwiftData 数据上传、下载是否完成，仍需查看同步事件。"
    }

    /// Materialize exactly the definitions used by the direct test, without
    /// performing network operations. Used to verify schema coverage locally.
    static func cloudKitDiagnosticProbeRecords(zoneID: CKRecordZone.ID) -> [CKRecord] {
        (coreCloudKitWriteProbes() + taskCloudKitWriteProbes() + pointsCloudKitWriteProbes()).map { probe in
            let id = UUID()
            let record = CKRecord(recordType: probe.recordType,
                recordID: CKRecord.ID(recordName: "diag.\(probe.recordType).\(id.uuidString)", zoneID: zoneID))
            probe.populateRecord(record, id)
            return record
        }
    }

    private static func formattedProbeLines(for results: [CloudKitWriteProbeResult]) -> [String] {
        results.flatMap { result in
            let statusPrefix = result.succeeded ? "✅" : "❌"
            var lines = ["\(statusPrefix) \(result.label)（\(result.recordType)）"]
            if !result.detail.isEmpty {
                lines.append(indentedDetailLines(result.detail))
            }
            return lines
        }
    }

    private static func indentedDetailLines(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}
