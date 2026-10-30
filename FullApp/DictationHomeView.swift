import SwiftUI
import SwiftData
import UIKit

private struct DictationSessionProjection: Identifiable, Hashable {
    let id: UUID
    let title: String
    let type: ReviewItemType
    let createdAt: Date
    let updatedAt: Date
    let scheduledDate: Date
    let finishedAt: Date?
    let reviewedAt: Date?
    let currentEntryIndex: Int

    init(_ session: DictationSession) {
        id = session.id
        title = session.title
        type = session.type
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        scheduledDate = session.scheduledDate
        finishedAt = session.finishedAt
        reviewedAt = session.reviewedAt
        currentEntryIndex = session.currentEntryIndex
    }

    var isFinished: Bool {
        finishedAt != nil
    }

    var isReviewed: Bool {
        reviewedAt != nil
    }
}

private struct DictationEntryProjection: Identifiable, Hashable {
    let id: UUID
    let sessionID: UUID
    let sortOrder: Int
    let type: ReviewItemType
    let content: String
    let prompt: String
    let note: String
    let source: String
    let result: DictationResult

    init(_ entry: DictationEntry) {
        id = entry.id
        sessionID = entry.sessionID
        sortOrder = entry.sortOrder
        type = entry.type
        content = entry.content
        prompt = entry.prompt
        note = entry.note
        source = entry.source
        result = entry.result
    }
}

private struct DictationRoute: Identifiable, Hashable {
    enum Kind: Hashable {
        case session
        case review
    }

    let sessionID: UUID
    let title: String
    let kind: Kind

    var id: String {
        "\(sessionID.uuidString)-\(kind)"
    }
}

private struct DictationEditRoute: Identifiable {
    let id: UUID
    let title: String
}

struct DeferredDictationHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReady = false
    @State private var activationTask: Task<Void, Never>?

    private var canActivate: Bool {
        scenePhase == .active
    }

    var body: some View {
        Group {
            if isReady {
                DictationHomeView()
            } else {
                List {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在打开听写安排...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("听写安排")
                .navigationBarTitleDisplayMode(.large)
            }
        }
        .onAppear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationHomeView onAppear")
            #endif
            activateAfterNavigationSettles()
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG
            DebugPerf.mark("DeferredDictationHomeView scenePhase=\(newPhase)")
            #endif
            if newPhase == .active {
                activateAfterNavigationSettles()
            } else {
                activationTask?.cancel()
                isReady = false
            }
        }
        .onDisappear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationHomeView onDisappear")
            #endif
            activationTask?.cancel()
        }
    }

    private func activateAfterNavigationSettles() {
        #if DEBUG
        DebugPerf.mark("DeferredDictationHomeView activateAfterNavigationSettles requested")
        DebugPerf.watchMainThread("DeferredDictationHomeView activation")
        #endif
        activationTask?.cancel()
        guard !isReady else { return }
        guard canActivate else { return }

        activationTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            guard canActivate else { return }
            #if DEBUG
            DebugPerf.mark("DeferredDictationHomeView showing DictationHomeView")
            #endif
            isReady = true
        }
    }
}

struct DictationHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettingsStore.self) private var appSettingsStore

    @State private var previewSession: DictationSessionProjection?
    @State private var activeRoute: DictationRoute?
    @State private var editingRoute: DictationEditRoute?
    @State private var snapshot: DictationHomeSnapshot = .empty
    @State private var snapshotRefreshTask: Task<Void, Never>?
    @State private var snapshotRefreshTaskID = UUID()
    @State private var serverRefreshError: String?
    @State private var isSnapshotLoaded = false
    @State private var deleteErrorMessage: String?
    @State private var isViewVisible = false
    @State private var isSnapshotRefreshInFlight = false
    @State private var needsSnapshotRefreshAfterCurrent = false
    @State private var isCompletedSectionExpanded = false

    private struct DictationHomeSnapshot {
        let todayAndOverdue: [DictationSessionProjection]
        let upcoming: [DictationSessionProjection]
        let completed: [DictationSessionProjection]
        let entriesBySessionID: [UUID: [DictationEntryProjection]]

        var isEmpty: Bool {
            todayAndOverdue.isEmpty && upcoming.isEmpty && completed.isEmpty
        }

        func entries(for session: DictationSessionProjection) -> [DictationEntryProjection] {
            entriesBySessionID[session.id] ?? []
        }

        var todayAndOverdueEntryCount: Int {
            todayAndOverdue.reduce(into: 0) { partialResult, session in
                partialResult += entriesBySessionID[session.id]?.count ?? 0
            }
        }

        static var empty: DictationHomeSnapshot {
            DictationHomeSnapshot(todayAndOverdue: [], upcoming: [], completed: [], entriesBySessionID: [:])
        }

        static func make(
            sessions: [DictationSessionProjection],
            entries: [DictationEntryProjection],
            referenceDate: Date = .now
        ) -> DictationHomeSnapshot {
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: referenceDate)
            let entriesBySessionID = Dictionary(grouping: entries, by: \.sessionID)
                .mapValues { sessionEntries in
                    sessionEntries.sorted { $0.sortOrder < $1.sortOrder }
                }

            let todayAndOverdue = sessions
                .filter { !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart }
                .sorted { $0.scheduledDate < $1.scheduledDate }
            let upcoming = sessions
                .filter { !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) > todayStart }
                .sorted { $0.scheduledDate < $1.scheduledDate }
            let completed = sessions
                .filter(\.isReviewed)

            return DictationHomeSnapshot(
                todayAndOverdue: todayAndOverdue,
                upcoming: upcoming,
                completed: completed,
                entriesBySessionID: entriesBySessionID
            )
        }
    }

    private var canRenderLiveContent: Bool {
        scenePhase == .active && isViewVisible
    }
    
    var body: some View {
        List {
            if !isSnapshotLoaded {
                statusSection(
                    title: canRenderLiveContent ? "正在加载听写安排..." : "正在恢复听写内容...",
                    debugLabel: canRenderLiveContent ? "loading" : "recovery"
                )
            } else {
                if !canRenderLiveContent {
                    statusSection(title: "正在恢复听写内容...", debugLabel: "recovery")
                }

                if snapshot.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("还没有听写记录", systemImage: "text.book.closed")
                        } description: {
                            Text("先设置要听写的内容并指定好日期。")
                        } actions: {
                            NavigationLink {
                                AddDictationSessionView()
                            } label: {
                                Label("新增听写计划", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    overviewSection

                    let todaySessions = snapshot.todayAndOverdue
                    if !todaySessions.isEmpty {
                        Section {
                            ForEach(todaySessions) { session in
                                sessionRow(for: session, entries: snapshot.entries(for: session))
                            }
                        } header: {
                            sectionHeader(title: "今日及待办", detail: "\(snapshot.todayAndOverdueEntryCount) 条")
                        }
                    }

                    let upcomingSessions = snapshot.upcoming
                    if !upcomingSessions.isEmpty {
                        Section {
                            ForEach(upcomingSessions) { session in
                                sessionRow(for: session, entries: snapshot.entries(for: session))
                            }
                        } header: {
                            sectionHeader(title: "未来计划", detail: "\(upcomingSessions.count) 组")
                        }
                    }

                    let completedSessions = snapshot.completed
                    if !completedSessions.isEmpty {
                        let visibleCompletedSessions = isCompletedSectionExpanded
                            ? completedSessions
                            : Array(completedSessions.prefix(10))

                        Section {
                            ForEach(visibleCompletedSessions) { session in
                                sessionRow(for: session, entries: snapshot.entries(for: session))
                            }
                        } header: {
                            if completedSessions.count > 10 {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isCompletedSectionExpanded.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("已完成")
                                        Text("\(completedSessions.count) 组")
                                            .foregroundStyle(.tertiary)
                                        Spacer()
                                        Text(isCompletedSectionExpanded ? "收起" : "查看全部")
                                            .font(.caption2.weight(.medium))
                                        Image(systemName: isCompletedSectionExpanded ? "chevron.up" : "chevron.down")
                                            .font(.caption2.weight(.semibold))
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            } else {
                                sectionHeader(title: "已完成", detail: "\(completedSessions.count) 组")
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable {
            serverRefreshError = nil
            let succeeded = await ServerSyncCoordinator.shared.refreshFromServer(
                modelContext: modelContext,
                settingsStore: appSettingsStore
            )
            if !succeeded, !Task.isCancelled {
                serverRefreshError = ServerSyncCoordinator.shared.lastErrorDescription ?? "本次服务器刷新未完成，请稍后重试。"
            }
            needsSnapshotRefreshAfterCurrent = false
            scheduleSnapshotRefresh(delay: 0)
            await snapshotRefreshTask?.value
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("听写安排")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AddDictationSessionView()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增听写计划")
            }
        }
        .onAppear {
            isViewVisible = true
            #if DEBUG
            DebugPerf.mark("DictationHomeView onAppear")
            #endif
            requestSnapshotRefresh(
                reason: "onAppear",
                delay: isSnapshotLoaded ? 0.02 : 0
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG
            DebugPerf.mark("DictationHomeView scenePhase=\(newPhase)")
            #endif
            if newPhase == .active {
                if isViewVisible {
                    requestSnapshotRefresh(
                        reason: "scenePhase active",
                        delay: isSnapshotLoaded ? 0.08 : 0.12
                    )
                }
            } else {
                snapshotRefreshTask?.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDataDidChange)) { _ in
            #if DEBUG
            DebugPerf.mark("DictationHomeView received appDataDidMutate visible=\(isViewVisible)")
            #endif
            requestSnapshotRefresh(reason: "appDataDidMutate")
        }
        .sheet(item: $previewSession) { session in
            DictationProjectionPreviewView(
                session: session,
                entries: snapshot.entries(for: session),
                onStartSession: {
                    activeRoute = DictationRoute(sessionID: session.id, title: session.title, kind: .session)
                },
                onEditSession: {
                    previewSession = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        editingRoute = DictationEditRoute(id: session.id, title: session.title)
                    }
                }
            )
        }
        .navigationDestination(item: $activeRoute) { route in
            DeferredDictationDestinationView(route: route)
        }
        .sheet(item: $editingRoute) { route in
            NavigationStack {
                DeferredDictationEditView(sessionID: route.id, title: route.title)
            }
        }
        .serverRefreshError($serverRefreshError)
        .alert("删除失败", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .onDisappear {
            isViewVisible = false
            #if DEBUG
            DebugPerf.mark("DictationHomeView onDisappear")
            #endif
            snapshotRefreshTask?.cancel()
        }
    }

    private func statusSection(title: String, debugLabel: String) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .onAppear {
                #if DEBUG
                DebugPerf.mark("DictationHomeView status section appear \(debugLabel)")
                #endif
            }
        }
    }

    private var overviewSection: some View {
        Section {
            HStack(spacing: 8) {
                overviewMetric(
                    icon: "text.book.closed.fill",
                    title: "今日待听写",
                    value: snapshot.todayAndOverdueEntryCount,
                    tint: .blue
                )
                overviewMetric(
                    icon: "calendar.badge.clock",
                    title: "未来计划",
                    value: snapshot.upcoming.count,
                    tint: .indigo
                )
                overviewMetric(
                    icon: "checkmark.circle.fill",
                    title: "已完成",
                    value: snapshot.completed.count,
                    tint: .green
                )
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .listRowBackground(Color.clear)
        }
    }

    private func overviewMetric(icon: String, title: String, value: Int, tint: Color) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.1), in: Circle())

                Text("\(value)")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .center)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.1), lineWidth: 1)
        }
    }

    private func sectionHeader(title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.tertiary)
        }
    }

    private func requestSnapshotRefresh(reason: String, delay: TimeInterval = 0.08) {
        #if DEBUG
        DebugPerf.mark("DictationHomeView requestSnapshotRefresh reason=\(reason) delay=\(delay)")
        #endif
        guard canRenderLiveContent else { return }
        if isSnapshotRefreshInFlight {
            needsSnapshotRefreshAfterCurrent = true
            #if DEBUG
            DebugPerf.mark("DictationHomeView refresh queued reason=\(reason)")
            #endif
            return
        }
        scheduleSnapshotRefresh(delay: delay)
    }

    private func scheduleSnapshotRefresh(delay: TimeInterval = 0.08) {
        #if DEBUG
        DebugPerf.mark("DictationHomeView scheduleSnapshotRefresh delay=\(delay)")
        #endif
        snapshotRefreshTask?.cancel()
        guard canRenderLiveContent else { return }

        let container = modelContext.container
        let taskID = UUID()
        snapshotRefreshTaskID = taskID
        snapshotRefreshTask = Task(priority: .utility) {
            defer {
                if snapshotRefreshTaskID == taskID {
                    isSnapshotRefreshInFlight = false
                    let needsRefresh = needsSnapshotRefreshAfterCurrent
                    needsSnapshotRefreshAfterCurrent = false
                    if needsRefresh, canRenderLiveContent, !Task.isCancelled {
                        requestSnapshotRefresh(reason: "coalesced", delay: 0.02)
                    }
                }
            }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard canRenderLiveContent else { return }
            await MainActor.run {
                isSnapshotRefreshInFlight = true
            }

            #if DEBUG
            DebugPerf.mark("DictationHomeView snapshot fetch begin")
            #endif
            let refreshedSnapshot = await Task.detached(priority: .utility) {
                PersistentStoreAccessGate.withAccess {
                #if DEBUG
                DebugPerf.mark("DictationHomeView background fetch begin")
                #endif
                let backgroundContext = ModelContext(container)
                let sessionModels = (try? backgroundContext.fetch(FetchDescriptor<DictationSession>())) ?? []
                let entryModels = (try? backgroundContext.fetch(FetchDescriptor<DictationEntry>())) ?? []
                let sessions = sessionModels
                    .map(DictationSessionProjection.init)
                    .sorted { $0.createdAt > $1.createdAt }
                let entries = entryModels.map(DictationEntryProjection.init)
                #if DEBUG
                DebugPerf.mark("DictationHomeView background fetch end sessions=\(sessions.count) entries=\(entries.count)")
                #endif
                return DictationHomeSnapshot.make(sessions: sessions, entries: entries)
                }
            }.value

            guard !Task.isCancelled else { return }
            guard canRenderLiveContent else { return }
            snapshot = refreshedSnapshot
            isSnapshotLoaded = true
            isSnapshotRefreshInFlight = false
            #if DEBUG
            DebugPerf.mark("DictationHomeView snapshot applied empty=\(refreshedSnapshot.isEmpty)")
            #endif
        }
    }

    private func sessionRow(for session: DictationSessionProjection, entries: [DictationEntryProjection]) -> some View {
        let routeKind: DictationRoute.Kind = (session.isReviewed || session.isFinished) ? .review : .session
        let tint = statusColor(for: session)

        return HStack(spacing: 10) {
            Button {
                #if DEBUG
                DebugPerf.mark("DictationHomeView session row tap title=\(session.title) kind=\(routeKind)")
                DebugPerf.watchMainThread("DictationHomeView session row tap")
                #endif
                activeRoute = DictationRoute(sessionID: session.id, title: session.title, kind: routeKind)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: session.isReviewed ? "checkmark" : "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                        .background(tint.opacity(0.09), in: Circle())

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(session.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            Text(statusText(for: session))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(tint.opacity(0.09), in: Capsule())
                        }

                        HStack(spacing: 10) {
                            Label("\(entries.count) 条", systemImage: "list.number")
                            Label(
                                session.scheduledDate.formatted(date: .abbreviated, time: .omitted),
                                systemImage: "calendar"
                            )
                            Spacer(minLength: 0)
                            Text(session.type.displayName)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if !session.isFinished && !session.isReviewed {
                Button {
                    #if DEBUG
                    DebugPerf.mark("DictationHomeView preview tap title=\(session.title)")
                    DebugPerf.watchMainThread("DictationHomeView preview tap")
                    #endif
                    previewSession = session
                } label: {
                    Image(systemName: "eye")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.08), in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("预习 \(session.title)")
            }
        }
        .padding(.vertical, 5)
        .iOS17SafeSwipeActions {
            Button(role: .destructive) {
                deleteSession(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
            
            if !session.isFinished && !session.isReviewed {
                Button {
                    editingRoute = DictationEditRoute(id: session.id, title: session.title)
                } label: {
                    Label("修改", systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
    }

    private func deleteSession(_ session: DictationSessionProjection) {
        let sessionID = session.id
        let container = modelContext.container

        Task.detached(priority: .utility) {
            let backgroundContext = ModelContext(container)

            do {
                try PersistentStoreAccessGate.withAccess {
                let sessionDescriptor = FetchDescriptor<DictationSession>(
                    predicate: #Predicate<DictationSession> { $0.id == sessionID }
                )
                guard let session = try backgroundContext.fetch(sessionDescriptor).first else { return }

                let entryDescriptor = FetchDescriptor<DictationEntry>(
                    predicate: #Predicate<DictationEntry> { $0.sessionID == sessionID }
                )
                for entry in try backgroundContext.fetch(entryDescriptor) {
                    SyncDeletionStore.delete(entry, in: backgroundContext)
                }

                SyncDeletionStore.delete(session, in: backgroundContext)
                try backgroundContext.save()

                }
                await MainActor.run {
                    AICoachSignals.post("deleted", id: sessionID)
                    AppDataChangeCenter.post()
                }
            } catch {
                await MainActor.run {
                    deleteErrorMessage = "听写计划没有删除成功，请稍后再试。\(error.localizedDescription)"
                }
            }
        }
    }

    private func statusText(for session: DictationSessionProjection) -> String {
        if session.isReviewed {
            return "已判定"
        }
        if session.isFinished {
            return "待判定"
        }
        
        let calendar = Calendar.current
        if calendar.startOfDay(for: session.scheduledDate) < calendar.startOfDay(for: .now) {
            return "逾期"
        }
        if calendar.startOfDay(for: session.scheduledDate) > calendar.startOfDay(for: .now) {
            return "未开始"
        }
        return "进行中"
    }

    private func statusColor(for session: DictationSessionProjection) -> Color {
        if session.isReviewed {
            return .green
        }
        if session.isFinished {
            return .orange
        }
        
        let calendar = Calendar.current
        if calendar.startOfDay(for: session.scheduledDate) < calendar.startOfDay(for: .now) {
            return .red
        }
        if calendar.startOfDay(for: session.scheduledDate) > calendar.startOfDay(for: .now) {
            return .gray
        }
        return .blue
    }
}

struct DictationPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = DictationSpeaker()
    
    let session: DictationSession
    let entries: [DictationEntry]
    var onStartSession: () -> Void
    var onEditSession: (() -> Void)? = nil
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.title)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        
                        Text("共 \(entries.count) 条内容 · \(session.type.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    
                    VStack(spacing: 12) {
                        ForEach(entries.indices, id: \.self) { index in
                            let entry = entries[index]
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("\(index + 1)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.blue)
                                            .frame(width: 22, height: 22)
                                            .background(Color.blue.opacity(0.1), in: Circle())
                                        
                                        TypeBadge(type: entry.type)
                                        
                                        Spacer()
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.content)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                            .foregroundStyle(.primary)
                                        
                                        if !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(entry.prompt)
                                                .font(.headline.weight(.medium))
                                                .foregroundStyle(.blue)
                                        }

                                        if let phonetic = phoneticText(for: entry) {
                                            Text(phonetic)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                
                                Spacer()
                                
                                Button {
                                    speaker.speak(content: entry.content, type: entry.type, prompt: entry.prompt)
                                } label: {
                                    Image(systemName: "speaker.wave.2.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(.secondary.opacity(0.1), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .navigationTitle(session.type.isRecitation ? "背诵预习" : "听写预习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                if let onEditAction = onEditSession {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("修改") {
                            dismiss()
                            onEditAction()
                        }
                    }
                }
            }
            .onDisappear {
                #if DEBUG
                DebugPerf.mark("DictationPreviewView onDisappear title=\(session.title)")
                #endif
                speaker.stop()
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Button {
                        #if DEBUG
                        DebugPerf.mark("DictationPreviewView start session title=\(session.title)")
                        DebugPerf.watchMainThread("DictationPreviewView start session")
                        #endif
                        dismiss()
                        onStartSession()
                    } label: {
                        Text(session.type.isRecitation ? "开始背诵" : "开始听写")
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                    .padding()
                }
                .background(.bar)
            }
        }
    }

    private func phoneticText(for entry: DictationEntry) -> String? {
        guard entry.type == .englishWord,
              let gloss = EnglishGlossService.shared.lookup(text: entry.content),
              !gloss.displayPhonetic.isEmpty else {
            return nil
        }
        return gloss.displayPhonetic
    }
}

private struct DictationProjectionPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = DictationSpeaker()

    let session: DictationSessionProjection
    let entries: [DictationEntryProjection]
    var onStartSession: () -> Void
    var onEditSession: (() -> Void)? = nil

    private var startButtonTitle: String {
        let activity = session.type.isRecitation ? "背诵" : "听写"
        guard session.currentEntryIndex > 0, !entries.isEmpty else { return "开始\(activity)" }
        return "继续\(activity) · 第 \(min(session.currentEntryIndex + 1, entries.count))/\(entries.count) 条"
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.title)
                            .font(.system(.title2, design: .rounded, weight: .bold))

                        Text("共 \(entries.count) 条内容 · \(session.type.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                    VStack(spacing: 12) {
                        ForEach(entries.indices, id: \.self) { index in
                            let entry = entries[index]
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("\(index + 1)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.blue)
                                            .frame(width: 22, height: 22)
                                            .background(Color.blue.opacity(0.1), in: Circle())

                                        TypeBadge(type: entry.type)

                                        Spacer()
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.content)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                            .foregroundStyle(.primary)

                                        if !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(entry.prompt)
                                                .font(.headline.weight(.medium))
                                                .foregroundStyle(.blue)
                                        }

                                        if let phonetic = phoneticText(for: entry) {
                                            Text(phonetic)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                Spacer()

                                Button {
                                    speaker.speak(content: entry.content, type: entry.type, prompt: entry.prompt)
                                } label: {
                                    Image(systemName: "speaker.wave.2.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(.secondary.opacity(0.1), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .navigationTitle(session.type.isRecitation ? "背诵预习" : "听写预习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                if let onEditAction = onEditSession {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("修改") {
                            dismiss()
                            onEditAction()
                        }
                    }
                }
            }
            .onDisappear {
                #if DEBUG
                DebugPerf.mark("DictationProjectionPreviewView onDisappear title=\(session.title)")
                #endif
                speaker.stop()
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Button {
                        #if DEBUG
                        DebugPerf.mark("DictationProjectionPreviewView start session title=\(session.title)")
                        DebugPerf.watchMainThread("DictationProjectionPreviewView start session")
                        #endif
                        dismiss()
                        onStartSession()
                    } label: {
                        Text(startButtonTitle)
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                    .padding()
                }
                .background(.bar)
            }
        }
    }

    private func phoneticText(for entry: DictationEntryProjection) -> String? {
        guard entry.type == .englishWord,
              let gloss = EnglishGlossService.shared.lookup(text: entry.content),
              !gloss.displayPhonetic.isEmpty else {
            return nil
        }
        return gloss.displayPhonetic
    }
}

private struct DeferredDictationDestinationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    let route: DictationRoute

    @State private var session: DictationSession?
    @State private var entries: [DictationEntry] = []
    @State private var loadTask: Task<Void, Never>?
    @State private var loadFailed = false

    private var canLoad: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active
    }

    var body: some View {
        Group {
            if let session {
                switch route.kind {
                case .session:
                    DictationSessionView(session: session, entries: entries)
                case .review:
                    DictationReviewView(session: session, entries: entries)
                }
            } else if loadFailed {
                ContentUnavailableView("听写记录不存在", systemImage: "exclamationmark.triangle")
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开 \(route.title)...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationDestinationView onAppear title=\(route.title) kind=\(route.kind)")
            DebugPerf.watchMainThread("DeferredDictationDestinationView onAppear")
            #endif
            loadAfterNavigationSettles()
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG
            DebugPerf.mark("DeferredDictationDestinationView scenePhase=\(newPhase)")
            #endif
            if newPhase == .active {
                loadAfterNavigationSettles()
            } else {
                loadTask?.cancel()
            }
        }
        .onDisappear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationDestinationView onDisappear title=\(route.title)")
            #endif
            loadTask?.cancel()
        }
    }

    private func loadAfterNavigationSettles() {
        #if DEBUG
        DebugPerf.mark("DeferredDictationDestinationView loadAfterNavigationSettles requested title=\(route.title)")
        DebugPerf.watchMainThread("DeferredDictationDestinationView load \(route.title)")
        #endif
        loadTask?.cancel()
        guard session == nil else { return }
        guard canLoad else { return }

        loadTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            guard canLoad else { return }

            do {
                #if DEBUG
                DebugPerf.mark("DeferredDictationDestinationView main fetch begin title=\(route.title)")
                #endif
                let sessionID = route.sessionID
                var sessionDescriptor = FetchDescriptor<DictationSession>(
                    predicate: #Predicate<DictationSession> { $0.id == sessionID }
                )
                sessionDescriptor.fetchLimit = 1

                let entryDescriptor = FetchDescriptor<DictationEntry>(
                    predicate: #Predicate<DictationEntry> { $0.sessionID == sessionID },
                    sortBy: [SortDescriptor(\.sortOrder)]
                )

                session = try modelContext.fetch(sessionDescriptor).first
                entries = try modelContext.fetch(entryDescriptor)
                loadFailed = session == nil
                #if DEBUG
                DebugPerf.mark("DeferredDictationDestinationView main fetch end title=\(route.title) entries=\(entries.count) failed=\(loadFailed)")
                #endif
            } catch {
                #if DEBUG
                DebugPerf.mark("DeferredDictationDestinationView main fetch error title=\(route.title) error=\(error.localizedDescription)")
                #endif
                loadFailed = true
            }
        }
    }
}

private struct DeferredDictationEditView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    let sessionID: UUID
    let title: String

    @State private var session: DictationSession?
    @State private var entries: [DictationEntry] = []
    @State private var loadTask: Task<Void, Never>?
    @State private var loadFailed = false

    private var canLoad: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active
    }

    var body: some View {
        Group {
            if let session {
                AddDictationSessionView(editingSession: session, existingEntries: entries)
            } else if loadFailed {
                ContentUnavailableView("听写记录不存在", systemImage: "exclamationmark.triangle")
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开 \(title)...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .onAppear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationEditView onAppear title=\(title)")
            DebugPerf.watchMainThread("DeferredDictationEditView onAppear")
            #endif
            loadAfterSheetSettles()
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG
            DebugPerf.mark("DeferredDictationEditView scenePhase=\(newPhase)")
            #endif
            if newPhase == .active {
                loadAfterSheetSettles()
            } else {
                loadTask?.cancel()
            }
        }
        .onDisappear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationEditView onDisappear title=\(title)")
            #endif
            loadTask?.cancel()
        }
    }

    private func loadAfterSheetSettles() {
        #if DEBUG
        DebugPerf.mark("DeferredDictationEditView loadAfterSheetSettles requested title=\(title)")
        DebugPerf.watchMainThread("DeferredDictationEditView load \(title)")
        #endif
        loadTask?.cancel()
        guard session == nil else { return }
        guard canLoad else { return }

        loadTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            guard canLoad else { return }

            do {
                #if DEBUG
                DebugPerf.mark("DeferredDictationEditView main fetch begin title=\(title)")
                #endif
                var sessionDescriptor = FetchDescriptor<DictationSession>(
                    predicate: #Predicate<DictationSession> { $0.id == sessionID }
                )
                sessionDescriptor.fetchLimit = 1

                let entryDescriptor = FetchDescriptor<DictationEntry>(
                    predicate: #Predicate<DictationEntry> { $0.sessionID == sessionID },
                    sortBy: [SortDescriptor(\.sortOrder)]
                )

                session = try modelContext.fetch(sessionDescriptor).first
                entries = try modelContext.fetch(entryDescriptor)
                loadFailed = session == nil
                #if DEBUG
                DebugPerf.mark("DeferredDictationEditView main fetch end title=\(title) entries=\(entries.count) failed=\(loadFailed)")
                #endif
            } catch {
                #if DEBUG
                DebugPerf.mark("DeferredDictationEditView main fetch error title=\(title) error=\(error.localizedDescription)")
                #endif
                loadFailed = true
            }
        }
    }
}
