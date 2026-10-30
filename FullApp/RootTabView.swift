import SwiftUI
import SwiftData
import CoreData
import UIKit

@MainActor
private final class AppBackgroundTask {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.end()
            }
        }
    }

    func end() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Environment(MediaLibraryStore.self) private var mediaLibraryStore
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @EnvironmentObject private var startupMaintenanceCoordinator: StartupMaintenanceCoordinator
    @State private var refreshAppStateTask: Task<Void, Never>?
    @State private var ios17ShieldStartTask: Task<Void, Never>?
    @State private var remoteChangeDebounceTask: Task<Void, Never>?
    @State private var startupMaintenanceTask: Task<Void, Never>?
    @State private var serverPullTask: Task<Void, Never>?
    @State private var cloudKitSettleBackgroundTask: AppBackgroundTask?
    @State private var cloudKitSettleEndTask: Task<Void, Never>?
    @State private var hasStartedIOS17BackgroundShield = false
    @State private var selectedLegacyTab: LegacyTab = .home
    @State private var visitedLegacyTabs: Set<LegacyTab> = [.home]
    @State private var aiCoach = AICoachCoordinator()
    @State private var targetedCoach = TargetedCoachCoordinator()

    private enum LegacyTab: Hashable {
        case home
        case library
        case dictation
        case tasks
        case settings
    }

    init() {
        let initialTab = Self.initialPreviewTab
        _selectedLegacyTab = State(initialValue: initialTab)
        _visitedLegacyTabs = State(initialValue: [.home, initialTab])
    }

    var body: some View {
        Group {
            if ServerSyncCoordinator.shared.isApplyingRemoteSnapshot {
                serverRestoreView
            } else {
                if #available(iOS 18.0, *) {
                    modernTabView
                } else {
                    legacyTabView
                }
            }
        }
        .environment(aiCoach)
        .environment(targetedCoach)
        .onReceive(NotificationCenter.default.publisher(for: AICoachSignals.changed)) { notification in
            aiCoach.receive(notification, context: modelContext, settings: appSettingsStore)
            if let action = notification.userInfo?["action"] as? String,
               ["review", "reviewUndo", "dictation", "restore", "manualEdit", "deleted"].contains(action), let store = aiCoach.store {
                targetedCoach.dataChanged(action: action, context: modelContext,
                    datasetID: store.state.datasetID, subject: store.state.configuration.subject)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            if targetedCoach.hasLoaded, let store = aiCoach.store {
                targetedCoach.dataChanged(action: "remote", context: modelContext,
                    datasetID: store.state.datasetID, subject: store.state.configuration.subject)
            }
        }
        .onChange(of: selectedLegacyTab) { _, newTab in
            markLegacyTabVisited(newTab)
            #if DEBUG
            DebugPerf.mark("RootTabView selectedLegacyTab=\(newTab)")
            #endif
        }
        .task {
            #if DEBUG
            TargetedCoachUITestSeed.seed(in: modelContext)
            #endif
            aiCoach.bootstrap(context: modelContext, settings: appSettingsStore)
            aiCoach.run(context: modelContext, settings: appSettingsStore)
            #if DEBUG
            if AppStorePreviewMode.isEnabled {
                AppStorePreviewData.seedIfNeeded(in: modelContext)
                appSettingsStore.bootstrap(using: modelContext)
                appSettingsStore.refreshFromSwiftDataIfPossible(using: modelContext)
                if !ServerSyncCoordinator.shared.isEnabled {
                    appSettingsStore.refreshFromUbiquitousStoreIfPossible(using: modelContext)
                }
            }
            #endif
            #if DEBUG
            DebugPerf.mark("RootTabView .task scenePhase=\(scenePhase)")
            #endif
            guard canRefreshLiveAppState else { return }
            mediaLibraryStore.startObservingChangesIfNeeded()
            mediaLibraryStore.reload()
            scheduleIOS17BackgroundShieldStartIfNeeded()
            scheduleStartupMaintenanceIfNeeded()
            scheduleAppStateRefresh(trigger: .launch, delay: launchRefreshDelay)
            scheduleServerSync(delayNanoseconds: 1_500_000_000)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                aiCoach.run(context: modelContext, settings: appSettingsStore)
                if targetedCoach.hasLoaded, let store = aiCoach.store {
                    targetedCoach.dataChanged(action: "foreground", context: modelContext,
                        datasetID: store.state.datasetID, subject: store.state.configuration.subject)
                }
                endCloudKitSettleBackgroundTask()
                mediaLibraryStore.startObservingChangesIfNeeded()
                mediaLibraryStore.reload()
                scheduleIOS17BackgroundShieldStartIfNeeded()
                scheduleStartupMaintenanceIfNeeded()
                scheduleAppStateRefresh(trigger: .foreground, delay: foregroundRefreshDelay)
                scheduleServerSync(delayNanoseconds: 1_500_000_000)
            } else {
                aiCoach.cancel()
                targetedCoach.cancel()
                Task { @MainActor in
                    await ServerSyncCoordinator.shared.uploadChanges(
                        from: modelContext,
                        settingsStore: appSettingsStore
                    )
                }
                refreshAppStateTask?.cancel()
                ios17ShieldStartTask?.cancel()
                remoteChangeDebounceTask?.cancel()
                startupMaintenanceTask?.cancel()
                serverPullTask?.cancel()
                beginCloudKitSettleBackgroundTask()
            }
        }
        .onDisappear {
            refreshAppStateTask?.cancel()
            ios17ShieldStartTask?.cancel()
            remoteChangeDebounceTask?.cancel()
            startupMaintenanceTask?.cancel()
            serverPullTask?.cancel()
            endCloudKitSettleBackgroundTask()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            #if DEBUG
            DebugPerf.mark("RootTabView received NSPersistentStoreRemoteChange")
            #endif
            remoteChangeDebounceTask?.cancel()
            let container = modelContext.container
            remoteChangeDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled else { return }
                guard canRefreshLiveAppState else { return }
                let reconciliation = await Task.detached(priority: .utility) {
                    PersistentStoreAccessGate.withAccess {
                        let backgroundContext = ModelContext(container)
                        do {
                            _ = try Grade5EnglishDictationPlanImporter.deduplicateImportedPlan(
                                in: backgroundContext
                            )
                            _ = try ReviewScheduler.reconcileStandardReviewProgress(in: backgroundContext)
                            _ = try ReviewScheduler.deduplicateDailyReviewPlans(in: backgroundContext)
                            _ = try PointLedgerService.reconcileMissingAutomaticRewards(in: backgroundContext)
                            let didChange = backgroundContext.hasChanges
                            if didChange {
                                try backgroundContext.save()
                            }
                            return (didChange: didChange, error: nil as String?)
                        } catch {
                            return (didChange: false, error: error.localizedDescription as String?)
                        }
                    }
                }.value
                guard !Task.isCancelled else { return }
                if let reconciliationError = reconciliation.error {
                    #if DEBUG
                    DebugPerf.mark("RootTabView remote review reconciliation failed error=\(reconciliationError)")
                    #endif
                }
                appSettingsStore.refreshFromSwiftDataIfPossible(using: modelContext)
                if !ServerSyncCoordinator.shared.isEnabled {
                    appSettingsStore.refreshFromUbiquitousStoreIfPossible(using: modelContext)
                }
                #if DEBUG
                DebugPerf.mark("RootTabView posting appDataDidMutate from remote change")
                #endif
                AppDataChangeCenter.post(source: reconciliation.didChange ? .local : .server)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            guard canRefreshLiveAppState else { return }
            guard !ServerSyncCoordinator.shared.isEnabled else { return }
            appSettingsStore.refreshFromUbiquitousStoreIfPossible(using: modelContext)
            AppDataChangeCenter.post()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDataDidChange)) { notification in
            guard canRefreshLiveAppState else { return }
            guard AppDataChangeCenter.requiresUpload(notification) else { return }
            ServerSyncCoordinator.shared.scheduleUpload(
                from: modelContext,
                settingsStore: appSettingsStore
            )
        }
    }

    private var serverRestoreView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在安全更新本机数据…")
                .font(.headline)
            Text("请保持 App 在前台")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView(selection: $selectedLegacyTab) {
            Tab("首页", systemImage: "house.fill", value: LegacyTab.home) {
                tabRoot(for: .home) {
                    HomeView()
                }
            }

            Tab("题库", systemImage: "square.grid.2x2.fill", value: LegacyTab.library) {
                tabRoot(for: .library) {
                    DeferredTabContent(
                        title: "题库",
                        loadingMessage: "正在打开题库...",
                        delayNanoseconds: 120_000_000
                    ) {
                        LibraryView()
                    }
                }
            }

            Tab("听写", systemImage: "text.book.closed.fill", value: LegacyTab.dictation) {
                tabRoot(for: .dictation) {
                    DeferredDictationHomeView()
                }
            }

            Tab("待办", systemImage: "checklist", value: LegacyTab.tasks) {
                tabRoot(for: .tasks) {
                    DeferredTasksHomeView()
                }
            }

            Tab("设置", systemImage: "gearshape.fill", value: LegacyTab.settings) {
                tabRoot(for: .settings) {
                    DeferredTabContent(
                        title: "设置",
                        loadingMessage: "正在打开设置...",
                        delayNanoseconds: 80_000_000
                    ) {
                        SettingsView()
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    private var legacyTabView: some View {
        TabView(selection: $selectedLegacyTab) {
            tabRoot(for: .home) {
                HomeView()
            }
            .tabItem {
                Label("首页", systemImage: "house.fill")
            }
            .tag(LegacyTab.home)

            tabRoot(for: .library) {
                DeferredTabContent(
                    title: "题库",
                    loadingMessage: "正在打开题库...",
                    delayNanoseconds: 120_000_000
                ) {
                    LibraryView()
                }
            }
            .tabItem {
                Label("题库", systemImage: "square.grid.2x2.fill")
            }
            .tag(LegacyTab.library)

            tabRoot(for: .dictation) {
                DeferredDictationHomeView()
            }
            .tabItem {
                Label("听写", systemImage: "text.book.closed.fill")
            }
            .tag(LegacyTab.dictation)

            tabRoot(for: .tasks) {
                DeferredTasksHomeView()
            }
            .tabItem {
                Label("待办", systemImage: "checklist")
            }
            .tag(LegacyTab.tasks)

            tabRoot(for: .settings) {
                DeferredTabContent(
                    title: "设置",
                    loadingMessage: "正在打开设置...",
                    delayNanoseconds: 80_000_000
                ) {
                    SettingsView()
                }
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(LegacyTab.settings)
        }
    }

    @ViewBuilder
    private func tabRoot<Content: View>(
        for tab: LegacyTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            if shouldMaterializeLegacyTab(tab) {
                content()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            NavigationLink { AICoachView() } label: { Label("AI 教练", systemImage: "sparkles") }
                        }
                    }
                    .onAppear {
                        markLegacyTabVisited(tab)
                        #if DEBUG
                        DebugPerf.mark("RootTabView legacy tab content appear \(tab)")
                        #endif
                    }
            } else {
                Color.clear
                    .onAppear {
                        #if DEBUG
                        DebugPerf.mark("RootTabView legacy tab placeholder appear \(tab)")
                        #endif
                    }
            }
        }
    }

    private func shouldMaterializeLegacyTab(_ tab: LegacyTab) -> Bool {
        selectedLegacyTab == tab || visitedLegacyTabs.contains(tab)
    }

    private func markLegacyTabVisited(_ tab: LegacyTab) {
        visitedLegacyTabs.insert(tab)
    }

    private func scheduleAppStateRefresh(trigger: SyncStatusStore.Trigger, delay: TimeInterval) {
        #if DEBUG
        DebugPerf.mark("RootTabView scheduleAppStateRefresh trigger=\(trigger) delay=\(delay)")
        #endif
        refreshAppStateTask?.cancel()
        guard shouldRefreshAppState(for: trigger) else { return }

        refreshAppStateTask = Task { @MainActor in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard canRefreshLiveAppState else { return }
            guard shouldRefreshAppState(for: trigger) else { return }
            await refreshAppState(trigger: trigger)
        }
    }

    private func scheduleServerSync(delayNanoseconds: UInt64) {
        // The independent CloudKit app has no server sync configured. Do not
        // enqueue a disabled path that cancels the automatic account check.
        guard ServerSyncCoordinator.shared.isEnabled else { return }
        serverPullTask?.cancel()
        serverPullTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, canRefreshLiveAppState, ServerSyncCoordinator.shared.isEnabled else { return }
            refreshAppStateTask?.cancel()
            remoteChangeDebounceTask?.cancel()
            startupMaintenanceTask?.cancel()
            let succeeded = await ServerSyncCoordinator.shared.synchronize(
                modelContext: modelContext,
                settingsStore: appSettingsStore
            )
            if !succeeded {
                ServerSyncCoordinator.shared.scheduleUpload(from: modelContext, settingsStore: appSettingsStore)
            }
        }
    }

    private func shouldRefreshAppState(for trigger: SyncStatusStore.Trigger) -> Bool {
        guard !syncStatusStore.isRefreshing else { return false }

        guard trigger == .foreground, let lastRefreshAt = syncStatusStore.lastRefreshAt else {
            return true
        }

        return Date.now.timeIntervalSince(lastRefreshAt) >= 10 * 60
    }

    private func refreshAppState(trigger: SyncStatusStore.Trigger) async {
        let backgroundTask = AppBackgroundTask(name: "TypoReviewAppStateRefresh")
        defer {
            backgroundTask.end()
        }

        mediaLibraryStore.reload()
        appSettingsStore.bootstrap(using: modelContext)
        appSettingsStore.refreshFromSwiftDataIfPossible(using: modelContext)
        if !ServerSyncCoordinator.shared.isEnabled {
            appSettingsStore.refreshFromUbiquitousStoreIfPossible(using: modelContext)
        }
        await syncStatusStore.refresh(using: modelContext, trigger: trigger)
    }

    private func beginCloudKitSettleBackgroundTask() {
        guard cloudKitSettleBackgroundTask == nil else { return }

        cloudKitSettleBackgroundTask = AppBackgroundTask(name: "TypoReviewCloudKitSettle")
        cloudKitSettleEndTask?.cancel()
        cloudKitSettleEndTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled else { return }
            endCloudKitSettleBackgroundTask()
        }
    }

    private func endCloudKitSettleBackgroundTask() {
        cloudKitSettleEndTask?.cancel()
        cloudKitSettleEndTask = nil
        cloudKitSettleBackgroundTask?.end()
        cloudKitSettleBackgroundTask = nil
    }

    private func scheduleStartupMaintenanceIfNeeded() {
        startupMaintenanceTask?.cancel()
        guard canRefreshLiveAppState else { return }
        guard !startupMaintenanceCoordinator.hasCompleted else { return }

        startupMaintenanceTask = Task { @MainActor in
            let nanoseconds = UInt64(startupMaintenanceDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard canRefreshLiveAppState else { return }

            let didRun = startupMaintenanceCoordinator.runIfNeeded(using: modelContext)
            guard didRun else { return }

            appSettingsStore.refreshFromSwiftDataIfPossible(using: modelContext)
            if !ServerSyncCoordinator.shared.isEnabled {
                appSettingsStore.refreshFromUbiquitousStoreIfPossible(using: modelContext)
            }
            AppDataChangeCenter.post()
        }
    }

    private var canRefreshLiveAppState: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active
    }

    private var startupMaintenanceDelay: TimeInterval {
        if #available(iOS 18.0, *) {
            return 0.4
        }
        return 0.8
    }

    private var launchRefreshDelay: TimeInterval {
        if #available(iOS 18.0, *) {
            return 1.5
        }
        return 6.0
    }

    private var foregroundRefreshDelay: TimeInterval {
        if #available(iOS 18.0, *) {
            return 2.0
        }
        return 5.0
    }

    private static var initialPreviewTab: LegacyTab {
        guard AppStorePreviewMode.isEnabled else { return .home }

        switch ProcessInfo.processInfo.environment["APP_STORE_PREVIEW_TAB"]?.lowercased() {
        case "library":
            return .library
        case "dictation":
            return .dictation
        case "tasks":
            return .tasks
        case "settings":
            return .settings
        default:
            return .home
        }
    }

    private func scheduleIOS17BackgroundShieldStartIfNeeded() {
        if #available(iOS 18.0, *) {
            return
        }

        ios17ShieldStartTask?.cancel()
        guard !hasStartedIOS17BackgroundShield else { return }
        guard canRefreshLiveAppState else { return }

        #if DEBUG
        DebugPerf.mark("RootTabView schedule iOS17 background scene shield start")
        #endif

        ios17ShieldStartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            guard canRefreshLiveAppState else { return }

            hasStartedIOS17BackgroundShield = true
            #if DEBUG
            DebugPerf.mark("RootTabView starting iOS17 background scene shield after settle")
            #endif
            IOS17BackgroundSceneShield.shared.start()
        }
    }
}

private struct DeferredTabContent<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReady = false
    @State private var activationTask: Task<Void, Never>?

    let title: String
    let loadingMessage: String
    let delayNanoseconds: UInt64
    private let content: () -> Content

    init(
        title: String,
        loadingMessage: String,
        delayNanoseconds: UInt64 = 120_000_000,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.loadingMessage = loadingMessage
        self.delayNanoseconds = delayNanoseconds
        self.content = content
    }

    var body: some View {
        Group {
            if isReady {
                content()
            } else {
                List {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(loadingMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
            }
        }
        .onAppear {
            activateAfterTabTransition()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                activateAfterTabTransition()
            } else {
                activationTask?.cancel()
            }
        }
        .onDisappear {
            activationTask?.cancel()
        }
    }

    private func activateAfterTabTransition() {
        activationTask?.cancel()
        guard !isReady, scenePhase == .active else { return }

        activationTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, scenePhase == .active else { return }
            isReady = true
        }
    }
}
