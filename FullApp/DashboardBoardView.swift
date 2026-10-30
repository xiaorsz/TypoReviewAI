import SwiftUI
import SwiftData
import AVFoundation
import AVKit
import UIKit
import Combine

struct DashboardBoardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(MediaLibraryStore.self) private var mediaLibraryStore
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var boardNow = Date.now
    @State private var playbackCoordinator = MediaPlaybackCoordinator()
    @StateObject private var taskReminderSpeaker = BoardTaskReminderSpeaker()
    @State private var lastBoardInteractionAt = Date.now
    @State private var isExitButtonVisible = false
    @State private var boardSnapshot: BoardSnapshot?
    @State private var boardDataSource: BoardDataSource?
    @State private var boardReadError: String?
    @State private var remindedTaskReminderSlots: Set<String> = []
    @State private var remindedTaskReminderDay = Calendar.current.startOfDay(for: Date.now)
    @State private var shouldResumePlaybackAfterTaskReminder = false
    @State private var minimizedFullscreenVideoAssetID: UUID?

    private struct BoardSnapshot {
        let childName: String
        let dueItems: [ReviewItem]
        let pendingDictationCount: Int
        let pendingDictationBoardItems: [BoardTextItem]
        let boardTaskItems: [TodayTaskDisplayItem]
        let totalPendingTaskCount: Int
        let recentPlans: [RecentPlanProjection]
        let todaySchedules: [ScheduleItem]
        let todayHeadline: String
        let boardSettings: AppSettings?
        let enabledMediaAssets: [MediaLibraryAsset]
    }

    private struct BoardTaskSnapshot {
        let todayPendingItems: [TodayTaskDisplayItem]
        let historicalPendingItems: [TodayTaskDisplayItem]
        let historicalPendingTotalCount: Int
        let todayCompletedItems: [TodayTaskDisplayItem]
        let todayPendingTotalCount: Int

        var boardTaskItems: [TodayTaskDisplayItem] {
            todayPendingItems + historicalPendingItems + todayCompletedItems
        }

        var totalPendingTaskCount: Int {
            todayPendingTotalCount + historicalPendingTotalCount
        }
    }

    private func makeBoardSnapshot(from source: BoardDataSource, at date: Date = Date.now) -> BoardSnapshot {
        let allTasks = source.tasks
        let taskExecutionRecords = source.executions
        let taskSubitems = source.subtasks
        let childName = appSettingsStore.childName.isEmpty ? "小朋友" : appSettingsStore.childName
        let calendar = Calendar.current
        let dueItems = BoardLearningSupport.pendingReviewItems(
            items: source.reviewItems,
            records: source.reviewRecords,
            dailyPlans: source.reviewDailyPlans,
            dailyLimit: appSettingsStore.dailyLimit,
            on: date,
            calendar: calendar,
            sessions: source.sessions, entries: source.entriesBySession.values.flatMap { $0 }
        )
        let pendingDictationSessions = BoardLearningSupport.pendingDictationSessions(
            source.sessions, on: date, calendar: calendar
        )
        let pendingDictationBoardItems = pendingDictationSessions
            .flatMap { source.entriesBySession[$0.id] ?? [] }
            .sorted {
                if $0.sessionID == $1.sessionID {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.sessionID.uuidString < $1.sessionID.uuidString
            }
            .map { entry in
                BoardTextItem(id: entry.id, text: entry.content, detail: "")
            }
        let taskSnapshot = boardTaskSnapshot(from: source, on: date)
        let recentPlans = RecentPlanSupport.visibleProjections(
            from: TaskDedupSupport.deduplicatedTasks(allTasks).map(TaskProjection.init),
            executions: taskExecutionRecords.map(TaskExecutionRecordProjection.init),
            subtasks: taskSubitems.map(TaskSubitemProjection.init),
            on: date,
            includeCompletedToday: false,
            calendar: calendar
        )
        let todaySchedules = todaySchedules(source.schedules, on: date)
        let boardSettings = appSettingsStore.modelRepresentation
        let enabledMediaAssets = enabledPlaylist()

        var parts: [String] = []
        if taskSnapshot.todayPendingTotalCount > 0 {
            parts.append("\(taskSnapshot.todayPendingTotalCount) 项今日待办")
        }
        if taskSnapshot.historicalPendingTotalCount > 0 {
            parts.append("\(taskSnapshot.historicalPendingTotalCount) 次历史待办")
        }
        if !dueItems.isEmpty {
            parts.append("\(dueItems.count) 项复习")
        }
        if !pendingDictationBoardItems.isEmpty {
            parts.append("\(pendingDictationBoardItems.count) 条听写")
        }
        if !recentPlans.isEmpty {
            parts.append("\(recentPlans.count) 项近期计划")
        }

        return BoardSnapshot(
            childName: childName,
            dueItems: dueItems,
            pendingDictationCount: pendingDictationBoardItems.count,
            pendingDictationBoardItems: pendingDictationBoardItems,
            boardTaskItems: taskSnapshot.boardTaskItems,
            totalPendingTaskCount: taskSnapshot.totalPendingTaskCount,
            recentPlans: recentPlans,
            todaySchedules: todaySchedules,
            todayHeadline: parts.isEmpty ? "\(childName) 今天都完成了" : "\(childName) 今天还有 \(parts.joined(separator: "、"))",
            boardSettings: boardSettings,
            enabledMediaAssets: enabledMediaAssets
        )
    }

    private func boardTaskSnapshot(from source: BoardDataSource, on date: Date) -> BoardTaskSnapshot {
        let allTasks = source.tasks
        let taskExecutionRecords = source.executions
        let taskSubitems = source.subtasks
        let calendar = Calendar.current
        let autoArchivedCompletedAtByTaskID = Dictionary(
            taskExecutionRecords.compactMap { record -> (UUID, Date)? in
                guard record.status == .completed,
                      let completedAt = record.completedAt,
                      calendar.isDate(completedAt, inSameDayAs: date) else {
                    return nil
                }
                return (record.taskID, completedAt)
            },
            uniquingKeysWith: max
        )
        let visibleTasks = allTasks.filter { task in
            guard task.isArchived else { return true }
            guard task.recurrence.kind == .once,
                  let completedAt = autoArchivedCompletedAtByTaskID[task.id] else {
                return false
            }
            return task.updatedAt <= completedAt
        }
        let deduplicatedVisibleTasks = TaskDedupSupport.deduplicatedTasks(visibleTasks)
        let taskProjections = deduplicatedVisibleTasks.map(TaskProjection.init)
        let taskProjectionResults = TodayTaskProjectionBuilder.build(
            from: taskProjections,
            executions: taskExecutionRecords.map(TaskExecutionRecordProjection.init),
            subtasks: taskSubitems.map(TaskSubitemProjection.init),
            on: date
        )
        let tasksByID = Dictionary(
            deduplicatedVisibleTasks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let taskItems = TaskDedupSupport.deduplicatedDisplayItems(
            taskProjectionResults.compactMap { projection in
                tasksByID[projection.taskID].map { task in
                    TodayTaskDisplayItem(
                        task: task,
                        section: projection.section,
                        occurrenceDate: projection.occurrenceDate,
                        isCompleted: projection.isCompleted,
                        pendingOccurrenceCount: projection.pendingOccurrenceCount,
                        historicalPendingCount: projection.historicalPendingCount,
                        totalPendingOccurrenceCount: projection.totalPendingOccurrenceCount,
                        overdueOriginText: projection.overdueOriginText,
                        totalSubtaskCount: projection.totalSubtaskCount,
                        completedSubtaskCount: projection.completedSubtaskCount
                    )
                }
            },
            title: { $0.task.title },
            taskID: { $0.task.id },
            section: { $0.section },
            occurrenceDate: { $0.occurrenceDate },
            sortKey: { item in
                TaskDisplayDedupSortKey(
                    unskippablePriority: item.task.skipPolicy == .unskippable ? 1 : 0,
                    totalSubtaskCount: item.totalSubtaskCount,
                    completedSubtaskCount: item.completedSubtaskCount,
                    createdAt: item.task.createdAt,
                    stableID: item.task.id.uuidString
                )
            }
        )
        let todayPendingItems = taskItems.filter { $0.section == .todayPending }
        let historicalPendingItems = taskItems
            .filter { $0.section == .historicalPending }
            .sorted { lhs, rhs in
                if lhs.occurrenceDate == rhs.occurrenceDate {
                    return lhs.task.createdAt < rhs.task.createdAt
                }
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
        let orderedTaskItems = todayPendingItems + historicalPendingItems + taskItems.filter { $0.section == .todayDone }
        let taskSections = TodayTaskSectionSnapshotBuilder.build(
            from: orderedTaskItems,
            taskID: { $0.task.id },
            section: { $0.section },
            collapseTodayDone: false
        )

        return BoardTaskSnapshot(
            todayPendingItems: taskSections.todayPendingItems,
            historicalPendingItems: taskSections.historicalPendingItems,
            historicalPendingTotalCount: taskSections.historicalPendingTotalCount,
            todayCompletedItems: taskSections.todayDoneItems,
            todayPendingTotalCount: todayPendingItems.count
        )
    }

    private func todaySchedules(_ allSchedules: [ScheduleItem], on date: Date) -> [ScheduleItem] {
        allSchedules
            .filter { $0.shouldAppear(on: date) && !$0.hasEnded(on: date, reference: date) }
            .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
    }

    private func enabledPlaylist() -> [MediaLibraryAsset] {
        mediaLibraryStore.mediaAssets
            .filter(\.isIncludedInPlaylist)
            .sorted { lhs, rhs in
                if lhs.playlistOrder == rhs.playlistOrder {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.playlistOrder > rhs.playlistOrder
            }
    }

    private func mediaAutoplayStatusText(for snapshot: BoardSnapshot) -> String {
        guard let boardSettings = snapshot.boardSettings else { return "未配置" }
        guard boardSettings.boardAutoplayEnabled else { return "已关闭" }
        guard boardSettings.hasValidBoardAutoplayWindow else { return "未配置时间段" }
        guard !snapshot.enabledMediaAssets.isEmpty else { return "播放列表为空" }

        if let manualStatusText = playbackCoordinator.boardManualStatusText {
            return manualStatusText
        }

        if playbackCoordinator.isManuallyPaused {
            return "已暂停"
        }

        if playbackCoordinator.isPlaying {
            return "正在播放"
        }

        if playbackCoordinator.isWaitingForDownload {
            return "等待下载"
        }

        if let blockedReason = boardSettings.boardAutoplayBlockedReason(on: boardNow) {
            return blockedReason
        }

        if boardSettings.isBoardAutoplayActive(on: boardNow) {
            return "准备播放"
        }

        if let window = boardSettings.nextBoardAutoplayWindow(on: boardNow), boardNow < window.start {
            return "等待开始"
        }

        return "今日已结束"
    }

    private var boardMediaPreviewHeight: CGFloat {
        240
    }

    private let boardTopAnchorID = "board-top-anchor"
    private let boardInactivityReturnInterval: TimeInterval = 30
    private let boardOverlayVisibilityInterval: TimeInterval = 8

    private var canRenderLiveContent: Bool {
        scenePhase != .background
    }

    var body: some View {
        Group {
            if canRenderLiveContent, let boardSnapshot {
                boardActiveView(boardSnapshot)
            } else if canRenderLiveContent {
                boardLoadingView
            } else {
                Color.clear
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, ServerSyncCoordinator.shared.isEnabled else { return }
            await BoardSyncPolling.run { isFirstCheck in
                let coordinator = ServerSyncCoordinator.shared
                let succeeded: Bool
                if isFirstCheck {
                    succeeded = await coordinator.refreshFromServer(modelContext: modelContext, settingsStore: appSettingsStore)
                } else {
                    succeeded = await coordinator.checkForServerUpdates(modelContext: modelContext, settingsStore: appSettingsStore)
                }
                guard !Task.isCancelled, scenePhase == .active else { return }
                if succeeded { refreshBoardSnapshot(reason: "server polling completed") }
            }
        }
        .onAppear {
            refreshBoardSnapshot(reason: "onAppear")
            reinforceIdleTimerOverrideIfNeeded()
            lastBoardInteractionAt = .now
            isExitButtonVisible = false
            syncBoardPlayback(for: boardNow)
        }
        .onDisappear {
            shouldResumePlaybackAfterTaskReminder = false
            taskReminderSpeaker.stop()
            playbackCoordinator.stop()
        }
        .onReceive(boardSnapshotRefreshTimer) { _ in
            guard canRenderLiveContent else { return }
            refreshBoardSnapshot(reason: "snapshot timer")
        }
        .onReceive(boardPlaybackTimer) {
            guard canRenderLiveContent else { return }
            reinforceIdleTimerOverrideIfNeeded()
            checkTaskReminderIfNeeded(at: $0)
            guard !taskReminderSpeaker.isSpeaking else { return }
            syncBoardPlayback(for: $0)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refreshBoardSnapshot(reason: "scenePhase active")
                reinforceIdleTimerOverrideIfNeeded()
                lastBoardInteractionAt = .now
                isExitButtonVisible = false
                if !taskReminderSpeaker.isSpeaking && !shouldResumePlaybackAfterTaskReminder {
                    syncBoardPlayback(for: boardNow)
                }
            } else if newPhase == .background {
                shouldResumePlaybackAfterTaskReminder = false
                taskReminderSpeaker.stop()
                playbackCoordinator.stop()
            }
        }
        .onChange(of: playbackCoordinator.currentAsset?.id) { _, _ in
            minimizedFullscreenVideoAssetID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDataDidChange)) { _ in
            guard canRenderLiveContent else { return }
            refreshBoardSnapshot(reason: "appDataDidChange")
        }
    }

    private var boardLoadingView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.12, blue: 0.22),
                    Color(red: 0.04, green: 0.33, blue: 0.47),
                    Color(red: 0.05, green: 0.52, blue: 0.48)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ProgressView()
                .tint(.white)
        }
    }

    private func boardActiveView(_ snapshot: BoardSnapshot) -> some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.12, blue: 0.22),
                            Color(red: 0.04, green: 0.33, blue: 0.47),
                            Color(red: 0.05, green: 0.52, blue: 0.48)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 28) {
                            Color.clear
                                .frame(height: 1)
                                .id(boardTopAnchorID)

                            boardHeader(snapshot)
                            boardStats(snapshot)
                            boardContent(snapshot)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, boardTopInset(for: proxy))
                        .padding(.horizontal, 36)
                        .padding(.bottom, 28)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture().onChanged { _ in
                                recordBoardInteraction()
                            }
                        )
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                recordBoardInteraction()
                            }
                        )
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onReceive(boardInactivityTimer) { _ in
                        guard canRenderLiveContent else { return }
                        autoReturnBoardToTopIfNeeded(using: scrollProxy)
                    }

                    if isExitButtonVisible {
                        exitBoardButton
                            .padding(.top, topOverlayPadding(for: proxy))
                            .padding(.trailing, 28)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }

                    if shouldShowFullscreenBoardVideo {
                        boardFullscreenVideoPlayer(proxy: proxy)
                            .transition(.opacity)
                            .zIndex(10)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: shouldShowFullscreenBoardVideo)
            }
        }
    }

    private var shouldShowFullscreenBoardVideo: Bool {
        guard let currentAsset = playbackCoordinator.currentAsset,
              currentAsset.mediaType == .video else {
            return false
        }
        return minimizedFullscreenVideoAssetID != currentAsset.id
    }

    private func boardFullscreenVideoPlayer(proxy: GeometryProxy) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            VideoPlayer(player: playbackCoordinator.player)
                .ignoresSafeArea()

            Button {
                recordBoardInteraction()
                minimizedFullscreenVideoAssetID = playbackCoordinator.currentAsset?.id
            } label: {
                Label("返回看板", systemImage: "rectangle.compress.vertical")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, topOverlayPadding(for: proxy))
            .padding(.trailing, 24)
            .accessibilityLabel("返回看板，视频继续播放")
        }
    }

    private func boardHeader(_ snapshot: BoardSnapshot) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("听写复习看板")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Button {
                        recordBoardInteraction()
                        playbackCoordinator.toggleManualPlayback(
                            playlist: snapshot.enabledMediaAssets,
                            option: snapshot.boardSettings?.boardManualPlaybackOption ?? .untilPlaylistEnds
                        )
                    } label: {
                        Image(systemName: boardPlaybackControlIconName)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .disabled(snapshot.enabledMediaAssets.isEmpty && playbackCoordinator.currentAsset == nil)
                    .opacity((snapshot.enabledMediaAssets.isEmpty && playbackCoordinator.currentAsset == nil) ? 0.45 : 1)
                    .accessibilityLabel(boardPlaybackControlAccessibilityLabel)
                }

                Text(snapshot.todayHeadline)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))

                if let message = boardReadError ?? ServerSyncCoordinator.shared.lastErrorDescription {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .lineLimit(2)
                } else if ServerSyncCoordinator.shared.isEnabled {
                    Text("看板自动同步中 · 每 60 秒检查更新")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(context.date.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.top, -12)
        }
    }

    private func boardStats(_ snapshot: BoardSnapshot) -> some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 18
            let unitWidth = max((proxy.size.width - spacing * 3) / 4, 0)
            let hasSchedule = snapshot.todaySchedules.first != nil

            HStack(spacing: spacing) {
                BoardStatCard(title: "待办任务", value: "\(snapshot.totalPendingTaskCount)", tint: .orange)
                    .frame(width: unitWidth)

                BoardStatCard(title: "待复习", value: "\(snapshot.dueItems.count)", tint: .blue)
                    .frame(width: unitWidth)

                if hasSchedule {
                    BoardScheduleStatCard(schedule: snapshot.todaySchedules.first, tint: .green)
                        .frame(width: unitWidth * 2 + spacing)
                } else {
                    BoardStatCard(title: "待听写", value: "\(snapshot.pendingDictationCount)", tint: .teal)
                        .frame(width: unitWidth)

                    BoardScheduleStatCard(schedule: nil, tint: .green)
                        .frame(width: unitWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 112)
    }

    private func boardContent(_ snapshot: BoardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if shouldShowBoardMediaPanel {
                boardMediaPanel(snapshot)
            }

            boardRecentPlansBanner(snapshot)

            HStack(alignment: .top, spacing: 18) {
                boardTaskColumn(snapshot)

                boardColumn(
                    title: "待复习",
                    icon: "book.closed.fill",
                    items: snapshot.dueItems,
                    emptyTitle: "今天没有待复习",
                    itemText: { item in
                        let prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        return prompt.isEmpty ? item.content : "\(item.content) · \(prompt)"
                    }
                )

                boardColumn(
                    title: "待听写",
                    icon: "text.book.closed.fill",
                    items: snapshot.pendingDictationBoardItems,
                    emptyTitle: "今天没有待听写",
                    itemText: { item in
                        item.text
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func boardRecentPlansBanner(_ snapshot: BoardSnapshot) -> some View {
        if !snapshot.recentPlans.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("近期计划", systemImage: "calendar.badge.exclamationmark")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    if snapshot.recentPlans.count > 3 {
                        Text("还有 \(snapshot.recentPlans.count - 3) 项")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.78))
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(snapshot.recentPlans.prefix(3))) { plan in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(plan.task.title)
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            HStack(spacing: 7) {
                                Text("截止 \(plan.deadline.formatted(.dateTime.month().day()))")
                                Text("·")
                                Text(plan.deadlineState.statusText)
                                    .fontWeight(.bold)
                                    .foregroundStyle(boardRecentPlanTint(plan.deadlineState))
                            }
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)
                        .background(
                            boardRecentPlanTint(plan.deadlineState).opacity(0.17),
                            in: RoundedRectangle(cornerRadius: 20)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(boardRecentPlanTint(plan.deadlineState).opacity(0.3), lineWidth: 1)
                        }
                    }
                }
            }
            .padding(20)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 26))
        }
    }

    private func boardRecentPlanTint(_ state: RecentPlanDeadlineState) -> Color {
        switch state.kind {
        case .overdue:
            return .red
        case .dueToday:
            return .orange
        case .upcoming:
            return state.dayCount <= 7 ? .orange : .blue
        }
    }

    private var shouldShowBoardMediaPanel: Bool {
        playbackCoordinator.isPlaying
            || playbackCoordinator.isWaitingForDownload
            || playbackCoordinator.currentAsset != nil
            || playbackCoordinator.isBoardManualSession
    }

    private var boardPlaybackControlIconName: String {
        if playbackCoordinator.isWaitingForDownload {
            return "stop.fill"
        }
        return playbackCoordinator.isPlaying ? "pause.fill" : "play.fill"
    }

    private var boardPlaybackControlAccessibilityLabel: String {
        if playbackCoordinator.isWaitingForDownload {
            return "停止准备晨读资源播放"
        }
        return playbackCoordinator.isPlaying ? "暂停晨读资源播放" : "开始晨读资源播放"
    }

    private func boardMediaPanel(_ snapshot: BoardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    Image(systemName: "music.note.tv")
                    Text("晨读自动播放")
                    Text(snapshot.boardSettings?.boardAutoplayTimeSummary ?? "07:00 - 07:30")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

                Spacer()

                HStack(spacing: 10) {
                    if playbackCoordinator.isPlaying {
                        Button {
                            recordBoardInteraction()
                            withAnimation(.easeInOut(duration: 0.24)) {
                                playbackCoordinator.stopBoardPlaybackByUser()
                            }
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.red.opacity(0.55), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("停止晨读资源播放")
                    }

                    Text(mediaAutoplayStatusText(for: snapshot))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }

            if snapshot.enabledMediaAssets.isEmpty {
                Label("播放列表还没有资源，请到资源库里导入音频或视频。", systemImage: "tray")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.vertical, 12)
            } else if playbackCoordinator.isWaitingForDownload {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        playbackCoordinator.pendingAssetTitle.map { "“\($0)” 正在从 iCloud 下载" } ?? "资源正在从 iCloud 下载",
                        systemImage: "icloud.and.arrow.down"
                    )
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))

                    Text("文件下载完成后，看板会继续自动播放。")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.vertical, 12)
            } else {
                GeometryReader { proxy in
                    let spacing: CGFloat = 18
                    let panelContentHeight = boardMediaPanelContentHeight(for: snapshot)
                    let previewHeight = boardMediaPreviewBodyHeight(for: panelContentHeight)
                    let queueWidth = boardMediaQueueWidth(for: proxy.size.width)
                    let previewWidth = max(proxy.size.width - queueWidth - spacing, 0)

                    HStack(alignment: .top, spacing: spacing) {
                        boardMediaPreviewCard(previewHeight: previewHeight)
                            .frame(width: previewWidth, alignment: .topLeading)

                        boardMediaQueueCard(snapshot)
                            .frame(width: queueWidth, alignment: .topLeading)
                    }
                }
                .frame(height: boardMediaPanelContentHeight(for: snapshot))
            }
        }
        .padding(22)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
    }

    private func boardMediaQueueWidth(for panelWidth: CGFloat) -> CGFloat {
        let preferredWidth = panelWidth * 0.36
        let compactMaximum = max(panelWidth * 0.42, 0)
        return min(max(preferredWidth, 460), min(620, compactMaximum))
    }

    private func boardMediaPanelContentHeight(for snapshot: BoardSnapshot) -> CGFloat {
        let visibleRowCount = min(snapshot.enabledMediaAssets.count, 6)
        let rowHeight: CGFloat = 54
        let rowSpacing: CGFloat = 10
        let headerHeight: CGFloat = 22
        let sectionSpacing: CGFloat = 14
        let footerHeight: CGFloat = snapshot.enabledMediaAssets.count > 6 ? 17 + sectionSpacing : 0
        let queueListHeight = CGFloat(visibleRowCount) * rowHeight + CGFloat(max(visibleRowCount - 1, 0)) * rowSpacing
        let queueHeight = headerHeight + sectionSpacing + queueListHeight + footerHeight
        let previewHeight = headerHeight + sectionSpacing + boardMediaPreviewHeight

        return max(queueHeight, previewHeight)
    }

    private func boardMediaPreviewBodyHeight(for panelContentHeight: CGFloat) -> CGFloat {
        let headerHeight: CGFloat = 22
        let sectionSpacing: CGFloat = 14
        return max(panelContentHeight - headerHeight - sectionSpacing, boardMediaPreviewHeight)
    }

    private func boardMediaPreviewCard(previewHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("当前资源")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

            if let currentAsset = playbackCoordinator.currentAsset {
                if currentAsset.mediaType == .video {
                    VideoPlayer(player: playbackCoordinator.player)
                        .frame(height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 58))
                            .foregroundStyle(.white.opacity(0.92))

                        Text(currentAsset.title)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text("正在播放音频")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .padding(20)
                    .background(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.55), Color.cyan.opacity(0.36)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 24)
                    )
                    .frame(maxWidth: .infinity, minHeight: previewHeight, maxHeight: previewHeight)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "clock.badge")
                        .font(.system(size: 52))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("到时间后会从第一条资源开始播放")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text("只有看板保持打开时才会触发自动播放。")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, minHeight: previewHeight, maxHeight: previewHeight)
                .padding(20)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func boardMediaQueueCard(_ snapshot: BoardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("播放列表")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(snapshot.enabledMediaAssets.prefix(6))) { asset in
                    HStack(spacing: 12) {
                        Image(systemName: asset.mediaType.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(asset.title)
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                Text(asset.mediaType.rawValue)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.82))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.white.opacity(0.12), in: Capsule())
                            }
                        }

                        Spacer()

                        if asset.id == playbackCoordinator.currentAsset?.id {
                            Text("播放中")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white.opacity(asset.id == playbackCoordinator.currentAsset?.id ? 0.18 : 0.1), in: RoundedRectangle(cornerRadius: 18))
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture {
                        playbackCoordinator.play(
                            asset: asset,
                            within: snapshot.enabledMediaAssets,
                            boardManualOption: snapshot.boardSettings?.boardManualPlaybackOption ?? .untilPlaylistEnds
                        )
                    }
                }
            }

            if snapshot.enabledMediaAssets.count > 6 {
                Text("还有 \(snapshot.enabledMediaAssets.count - 6) 条资源未展示")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func boardTaskColumn(_ snapshot: BoardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                Text("待办任务")
            }
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(.white)

            if snapshot.boardTaskItems.isEmpty {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("今天没有任务")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(24)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(snapshot.boardTaskItems.prefix(10))) { item in
                        boardTaskRow(item)
                    }

                    if snapshot.boardTaskItems.count > 10 {
                        Text("还有 \(snapshot.boardTaskItems.count - 10) 项未展示")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.leading, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func boardColumn<Item: Identifiable>(
        title: String,
        icon: String,
        items: [Item],
        emptyTitle: String,
        itemText: @escaping (Item) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(.white)

            if items.isEmpty {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.25))
                    Text(emptyTitle)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(24)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(items.prefix(10))) { item in
                        Text(itemText(item))
                            .font(.system(size: 24, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 20))
                    }

                    if items.count > 10 {
                        Text("还有 \(items.count - 10) 项未展示")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.leading, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func boardTaskRow(_ item: TodayTaskDisplayItem) -> some View {
        let isDone = item.isCompleted
        let statusText: String? = switch item.section {
        case .todayDone:
            "已完成"
        case .historicalPending:
            item.overdueOriginText
        case .upcomingPending:
            "未来一周"
        case .todayPending:
            nil
        }

        return HStack(spacing: 14) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isDone ? Color.green.opacity(0.95) : .white.opacity(0.72))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.task.title)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(isDone ? .white.opacity(0.68) : .white)
                    .strikethrough(isDone, color: .white.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let statusText {
                    Text(statusText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(isDone ? Color.green.opacity(0.95) : Color.orange.opacity(0.95))
                        .lineLimit(1)
                }

                if item.historicalPendingCount > 0 {
                    Text("历史 \(item.historicalPendingCount) 次")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.orange.opacity(0.95))
                        .lineLimit(1)
                }

                if let progressText = item.subtaskProgressText {
                    Text(progressText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(isDone ? Color.green.opacity(0.95) : Color.blue.opacity(0.95))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            (isDone ? Color.green.opacity(0.15) : Color.white.opacity(0.13)),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay {
            if isDone {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.green.opacity(0.22), lineWidth: 1)
            }
        }
    }

    private func boardTopInset(for proxy: GeometryProxy) -> CGFloat {
        let isLandscape = isLandscapeBoardLayout(fallbackSize: proxy.size)
        let safeTop = isLandscape ? min(proxy.safeAreaInsets.top, 6) : max(proxy.safeAreaInsets.top, 8)
        return max(safeTop - 18, 0)
    }

    private func isLandscapeBoardLayout(fallbackSize: CGSize) -> Bool {
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        if let activeScene {
            return activeScene.interfaceOrientation.isLandscape
        }
        return fallbackSize.width > fallbackSize.height
    }

    private func topOverlayPadding(for proxy: GeometryProxy) -> CGFloat {
        let isLandscape = isLandscapeBoardLayout(fallbackSize: proxy.size)
        let safeTop = isLandscape ? min(proxy.safeAreaInsets.top, 8) : max(proxy.safeAreaInsets.top, 12)
        return safeTop + 10
    }

    private var exitBoardButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.22), in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private let boardSnapshotRefreshTimer: Publishers.Autoconnect<Timer.TimerPublisher> = {
        Timer.publish(every: 600, on: .main, in: .common)
            .autoconnect()
    }()

    private let boardPlaybackTimer: Publishers.Autoconnect<Timer.TimerPublisher> = {
        Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
    }()

    private let boardInactivityTimer: Publishers.Autoconnect<Timer.TimerPublisher> = {
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
    }()

    @MainActor
    private func reinforceIdleTimerOverrideIfNeeded() {
        DashboardBoardWakeCoordinator.shared.reinforceIfNeeded()
    }

    private func refreshBoardSnapshot(reason: String) {
        let now = Date.now
        boardNow = now
        do {
            try PersistentStoreAccessGate.withAccess {
                let source = try BoardDataSource.load(from: modelContext.container)
                let snapshot = makeBoardSnapshot(from: source, at: now)
                boardDataSource = source
                boardSnapshot = snapshot
            }
            boardReadError = nil
        } catch {
            // Keep the last valid snapshot instead of displaying empty counts.
            boardReadError = "看板数据读取失败，请重新打开看板重试。"
        }
        #if DEBUG
        DebugPerf.mark("DashboardBoardView refreshBoardSnapshot reason=\(reason)")
        #endif
    }

    private func syncBoardPlayback(for date: Date) {
        playbackCoordinator.sync(
            now: date,
            settings: appSettingsStore.modelRepresentation,
            playlist: enabledPlaylist()
        )
    }

    private func checkTaskReminderIfNeeded(at date: Date) {
        guard scenePhase == .active,
              let boardSnapshot,
              let slotID = taskReminderSlotID(for: date),
              !remindedTaskReminderSlots.contains(slotID),
              !taskReminderSpeaker.isSpeaking else {
            return
        }

        resetTaskReminderSlotsIfNeeded(for: date)
        guard !remindedTaskReminderSlots.contains(slotID) else { return }

        let reminderText = taskReminderText(for: boardSnapshot)
        remindedTaskReminderSlots.insert(slotID)

        let shouldResumePlayback = playbackCoordinator.isPlaying
        if shouldResumePlayback {
            playbackCoordinator.pauseForTemporaryInterruption()
        }
        shouldResumePlaybackAfterTaskReminder = shouldResumePlayback

        taskReminderSpeaker.speak(reminderText) {
            if shouldResumePlaybackAfterTaskReminder, scenePhase == .active, canRenderLiveContent {
                playbackCoordinator.resumeAfterTemporaryInterruption()
            }
            shouldResumePlaybackAfterTaskReminder = false
        }
    }

    private func resetTaskReminderSlotsIfNeeded(for date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard day != remindedTaskReminderDay else { return }
        remindedTaskReminderDay = day
        remindedTaskReminderSlots.removeAll()
    }

    private func taskReminderSlotID(for date: Date) -> String? {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute else {
            return nil
        }

        let isReminderMinute = minute == 0 || minute == 30
        let isReminderHour = (17...20).contains(hour) || (hour == 21 && minute == 0)
        guard isReminderMinute, isReminderHour else { return nil }

        return String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
    }

    private func taskReminderText(for snapshot: BoardSnapshot) -> String {
        let todayPendingTasks = snapshot.boardTaskItems
            .filter { $0.section == .todayPending && !$0.isCompleted }
        let displayedTaskCount = min(todayPendingTasks.count, 5)
        let pendingTaskTitles = todayPendingTasks
            .prefix(5)
            .map { $0.task.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.isEmpty ? "未命名任务" : $0 }

        var parts: [String] = []
        if todayPendingTasks.count > 0 {
            var taskText = "今天还有 \(todayPendingTasks.count) 项任务待完成"
            if !pendingTaskTitles.isEmpty {
                taskText += "，分别是：" + pendingTaskTitles.joined(separator: "，")
            }

            let hiddenTaskCount = max(todayPendingTasks.count - displayedTaskCount, 0)
            if hiddenTaskCount > 0 {
                taskText += "，还有 \(hiddenTaskCount) 项未播报"
            }
            parts.append(taskText)
        }

        if snapshot.pendingDictationCount > 0 {
            parts.append("还有 \(snapshot.pendingDictationCount) 条待听写")
        }

        let urgentRecentPlans = snapshot.recentPlans.filter(\.isVoiceReminderEligible)
        if !urgentRecentPlans.isEmpty {
            let spokenPlans = urgentRecentPlans.prefix(3).map { plan in
                "\(plan.task.title)，\(plan.deadlineState.statusText)"
            }
            var recentPlanText = "近期计划提醒：" + spokenPlans.joined(separator: "；")
            if urgentRecentPlans.count > 3 {
                recentPlanText += "；还有 \(urgentRecentPlans.count - 3) 项未播报"
            }
            parts.append(recentPlanText)
        }

        if parts.isEmpty {
            return "今天的任务都完成了。"
        }

        return parts.joined(separator: "；") + "。"
    }

    private func recordBoardInteraction() {
        lastBoardInteractionAt = .now
        if !isExitButtonVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExitButtonVisible = true
            }
        }
    }

    private func autoReturnBoardToTopIfNeeded(using scrollProxy: ScrollViewProxy) {
        if isExitButtonVisible, Date.now.timeIntervalSince(lastBoardInteractionAt) >= boardOverlayVisibilityInterval {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExitButtonVisible = false
            }
        }

        guard Date.now.timeIntervalSince(lastBoardInteractionAt) >= boardInactivityReturnInterval else { return }

        withAnimation(.easeInOut(duration: 0.35)) {
            scrollProxy.scrollTo(boardTopAnchorID, anchor: .top)
        }
        lastBoardInteractionAt = .now
    }

}

private struct BoardTextItem: Identifiable {
    let id: UUID
    let text: String
    let detail: String
}

@MainActor
private final class BoardTaskReminderSpeaker: NSObject, ObservableObject {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingUtteranceCount = 0
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, onFinish: @escaping () -> Void) {
        stop()

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            onFinish()
            return
        }

        self.onFinish = onFinish
        let utterances = SpeechUtteranceBuilder.utterances(content: trimmedText, type: .phrase)
        guard !utterances.isEmpty else {
            finishSpeaking()
            return
        }

        pendingUtteranceCount = utterances.count
        isSpeaking = true
        SpeechAudioSession.activate()
        utterances.forEach { synthesizer.speak($0) }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        SpeechAudioSession.deactivate()
        pendingUtteranceCount = 0
        isSpeaking = false
        onFinish = nil
    }

    private func finishSpeaking() {
        pendingUtteranceCount = 0
        SpeechAudioSession.deactivate()
        isSpeaking = false
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}

extension BoardTaskReminderSpeaker: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        pendingUtteranceCount = max(pendingUtteranceCount - 1, 0)
        if pendingUtteranceCount == 0 {
            finishSpeaking()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        pendingUtteranceCount = 0
        SpeechAudioSession.deactivate()
        isSpeaking = false
        onFinish = nil
    }
}

@MainActor
final class DashboardBoardWakeCoordinator {
    static let shared = DashboardBoardWakeCoordinator()

    private(set) var isActive = false
    private var previousIdleTimerDisabled = false
    private var reinforcementTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    #if DEBUG
    private var lastDiagnosticLogAt = Date.distantPast
    #endif

    private init() {}

    func activate(reason: String = "activate") {
        let application = UIApplication.shared
        if !isActive {
            previousIdleTimerDisabled = application.isIdleTimerDisabled
            isActive = true
            startReinforcement()
            startObservers()
            logDiagnostic("activate reason=\(reason) previousIdleDisabled=\(previousIdleTimerDisabled)")
        }

        application.isIdleTimerDisabled = true
        logDiagnostic("activate applied reason=\(reason)")
    }

    func deactivate(reason: String = "deactivate") {
        logDiagnostic("deactivate requested reason=\(reason)")
        reinforcementTask?.cancel()
        reinforcementTask = nil
        stopObservers()

        guard isActive else { return }
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        isActive = false
        logDiagnostic("deactivate restored reason=\(reason) restoredIdleDisabled=\(previousIdleTimerDisabled)")
    }

    func reinforceIfNeeded(reason: String = "timer") {
        guard isActive else { return }
        let application = UIApplication.shared
        if !application.isIdleTimerDisabled {
            application.isIdleTimerDisabled = true
            logDiagnostic("reinforce restored reason=\(reason)")
        } else {
            logHeartbeatIfNeeded(reason: reason)
        }
    }

    private func startReinforcement() {
        reinforcementTask?.cancel()
        reinforcementTask = Task { @MainActor in
            while !Task.isCancelled {
                reinforceIfNeeded(reason: "timer")
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func startObservers() {
        stopObservers()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.logDiagnostic("notification willResignActive")
                    self?.reinforceIfNeeded(reason: "willResignActive")
                }
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.logDiagnostic("notification didBecomeActive")
                    self?.reinforceIfNeeded(reason: "didBecomeActive")
                }
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.logDiagnostic("notification didEnterBackground")
                    #if DEBUG
                    DebugPerf.flushRecentEvents()
                    #endif
                }
            },
            center.addObserver(
                forName: UIScene.willDeactivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.logDiagnostic("notification sceneWillDeactivate")
                    self?.reinforceIfNeeded(reason: "sceneWillDeactivate")
                }
            },
            center.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.logDiagnostic("notification sceneDidActivate")
                    self?.reinforceIfNeeded(reason: "sceneDidActivate")
                }
            }
        ]
    }

    private func stopObservers() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    private func logHeartbeatIfNeeded(reason: String) {
        #if DEBUG
        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticLogAt) >= 60 else { return }
        lastDiagnosticLogAt = now
        logDiagnostic("heartbeat reason=\(reason)")
        #endif
    }

    private func logDiagnostic(_ message: String) {
        #if DEBUG
        DebugPerf.mark(
            "DashboardBoardWake \(message) active=\(isActive) idleDisabled=\(UIApplication.shared.isIdleTimerDisabled) appState=\(applicationStateDescription()) scenes=\(sceneStateDescription())"
        )
        #endif
    }

    #if DEBUG
    private func applicationStateDescription() -> String {
        switch UIApplication.shared.applicationState {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    private func sceneStateDescription() -> String {
        UIApplication.shared.connectedScenes
            .compactMap { scene -> String? in
                guard scene.session.role == .windowApplication else { return nil }
                switch scene.activationState {
                case .foregroundActive:
                    return "foregroundActive"
                case .foregroundInactive:
                    return "foregroundInactive"
                case .background:
                    return "background"
                case .unattached:
                    return "unattached"
                @unknown default:
                    return "unknown"
                }
            }
            .joined(separator: ",")
    }
    #endif
}

private struct BoardStatCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Text(value)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(tint.opacity(0.32), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct BoardScheduleStatCard: View {
    let schedule: ScheduleItem?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日日程")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            if let schedule {
                Text(schedule.title)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(schedule.timeRangeText(on: .now))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            } else {
                Text("0")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(tint.opacity(0.32), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

/// The board shows today's unfinished review plan and due, unsubmitted dictations.
@MainActor
enum BoardLearningSupport {
    static func pendingReviewItems(
        items: [ReviewItem],
        records: [ReviewRecord],
        dailyPlans: [ReviewDailyPlan],
        dailyLimit: Int,
        on date: Date,
        calendar: Calendar = .current,
        sessions: [DictationSession] = [], entries: [DictationEntry] = []
    ) -> [ReviewItem] {
        let dayKey = ReviewDailyPlan.dayKey(for: date, calendar: calendar)
        let dailyPlan = ReviewDailyPlan.preferred(from: dailyPlans.filter { $0.dayKey == dayKey })
        let selection = DailyReviewPlanner.select(
            items: items.map(HomeReviewItemProjection.init), records: records.map(HomeReviewRecordProjection.init),
            sessions: sessions.map(HomeDictationSessionProjection.init), entries: entries.map(HomeDictationEntryProjection.init),
            existingIDs: dailyPlan?.itemIDs ?? [],
            fixedSelection: dailyPlan?.isCoachSelection == true || dailyPlan?.startedAt != nil,
            dailyLimit: dailyLimit, on: date, calendar: calendar
        )
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selection.pending.compactMap { byID[$0.id] }
    }

    static func pendingDictationSessions(
        _ sessions: [DictationSession],
        on date: Date,
        calendar: Calendar = .current
    ) -> [DictationSession] {
        sessions.filter {
            !$0.isFinished && !$0.isReviewed
                && calendar.startOfDay(for: $0.scheduledDate) <= calendar.startOfDay(for: date)
        }
        .sorted {
            if $0.scheduledDate != $1.scheduledDate { return $0.scheduledDate < $1.scheduledDate }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

/// Models stay on the main actor and retain their fresh read context for display.
/// Existing @Query instances can still contain the generation preceding a server
/// merge when its notification arrives.
@MainActor
struct BoardDataSource {
    let context: ModelContext
    let reviewItems: [ReviewItem]
    let reviewRecords: [ReviewRecord]
    let reviewDailyPlans: [ReviewDailyPlan]
    let sessions: [DictationSession]
    let entriesBySession: [UUID: [DictationEntry]]
    let tasks: [TaskItem]
    let subtasks: [TaskSubitem]
    let executions: [TaskExecutionRecord]
    let schedules: [ScheduleItem]

    static func load(from container: ModelContainer) throws -> BoardDataSource {
        try PersistentStoreAccessGate.withAccess {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return BoardDataSource(
                context: context,
                reviewItems: try context.fetch(FetchDescriptor<ReviewItem>()),
                reviewRecords: try context.fetch(FetchDescriptor<ReviewRecord>()),
                reviewDailyPlans: try context.fetch(FetchDescriptor<ReviewDailyPlan>()),
                sessions: try context.fetch(FetchDescriptor<DictationSession>()),
                entriesBySession: Dictionary(grouping: try context.fetch(FetchDescriptor<DictationEntry>()), by: \.sessionID),
                tasks: try context.fetch(FetchDescriptor<TaskItem>()),
                subtasks: try context.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { !$0.isArchived })),
                executions: try context.fetch(FetchDescriptor<TaskExecutionRecord>()),
                schedules: try context.fetch(FetchDescriptor<ScheduleItem>(predicate: #Predicate { !$0.isArchived }))
            )
        }
    }
}

@MainActor
enum BoardSyncPolling {
    static func run(
        intervalNanoseconds: UInt64 = 60_000_000_000,
        check: (_ isFirstCheck: Bool) async -> Void
    ) async {
        var isFirstCheck = true
        while !Task.isCancelled {
            await check(isFirstCheck)
            isFirstCheck = false
            do { try await Task.sleep(nanoseconds: intervalNanoseconds) } catch { return }
        }
    }
}
