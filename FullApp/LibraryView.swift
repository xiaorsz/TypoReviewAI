import SwiftUI
import SwiftData

private struct LibraryItemProjection: Identifiable, Hashable, @unchecked Sendable {
    let id: UUID
    let type: ReviewItemType
    let content: String
    let prompt: String
    let source: String
    let stage: Int
    let nextReviewAt: Date
    let lastReviewedAt: Date?
    let consecutiveWrongCount: Int
    let isPriority: Bool
    let reviewTrackRawValue: String
    let dictationFollowUpStep: Int
    let isDictationPass: Bool
    let createdAt: Date
    let updatedAt: Date

    init(_ item: ReviewItem) {
        id = item.id
        type = item.type
        content = item.content
        prompt = item.prompt
        source = item.source
        stage = item.stage
        nextReviewAt = item.nextReviewAt
        lastReviewedAt = item.lastReviewedAt
        consecutiveWrongCount = item.consecutiveWrongCount
        isPriority = item.isPriority
        reviewTrackRawValue = item.reviewTrackRawValue
        dictationFollowUpStep = item.dictationFollowUpStep
        isDictationPass = item.isDictationPass
        createdAt = item.createdAt
        updatedAt = item.updatedAt
    }

    var reviewTrack: ReviewTrack {
        if let track = ReviewTrack(rawValue: reviewTrackRawValue) {
            if track == .standard, isDictationPass, dictationFollowUpStep == 0 {
                return .dictationFollowUp
            }
            return track
        }
        return isDictationPass ? .dictationFollowUp : .standard
    }

    var resolvedDictationFollowUpStep: Int {
        if reviewTrack == .dictationFollowUp {
            return (1...2).contains(dictationFollowUpStep) ? dictationFollowUpStep : 1
        }
        if isDictationPass {
            return stage >= 5 ? 2 : 1
        }
        return 0
    }

    var isMastered: Bool {
        ReviewScheduler.isMastered(
            stage: stage,
            consecutiveWrongCount: consecutiveWrongCount
        ) && nextReviewAt == .distantFuture
    }
}

private struct LibraryViewSnapshot: @unchecked Sendable {
    let filterCounts: [LibraryFilter: Int]
    let stageFilterCounts: [LibraryStageFilter: Int]
    let filteredItems: [LibraryItemProjection]
    let displayedItems: [LibraryItemProjection]

    static let empty = LibraryViewSnapshot(
        filterCounts: [:],
        stageFilterCounts: [:],
        filteredItems: [],
        displayedItems: []
    )
}

struct LibraryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    @State private var stageFilter: LibraryStageFilter = .all
    @State private var displayedItemLimit = 50
    @State private var editingItemID: UUID?
    @State private var viewSnapshot: LibraryViewSnapshot = .empty
    @State private var snapshotRefreshTask: Task<Void, Never>?
    @State private var isSnapshotLoaded = false
    @State private var isViewVisible = false
    @State private var saveErrorMessage: String?

    var body: some View {
        let snapshot = viewSnapshot

        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(LibraryFilter.allCases) { item in
                                filterButton(item, count: snapshot.filterCounts[item, default: 0])
                            }
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(LibraryStageFilter.options) { item in
                                stageFilterButton(item, count: snapshot.stageFilterCounts[item, default: 0])
                            }
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 6, trailing: 0))
            }

            if !isSnapshotLoaded {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在整理题库...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else if snapshot.filteredItems.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyIcon)
                } description: {
                    Text(emptyDescription)
                } actions: {
                    HStack {
                        NavigationLink {
                            AddReviewItemView()
                        } label: {
                            Text("单条录入")
                        }
                        .buttonStyle(.borderedProminent)

                        NavigationLink {
                            BatchAddReviewItemsView()
                        } label: {
                            Text("批量录入")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                ForEach(snapshot.displayedItems) { item in
                    NavigationLink {
                        LibraryReviewItemEditor(itemID: item.id)
                    } label: {
                        libraryRow(item)
                    }
                    .iOS17SafeSwipeActions {
                        Button(role: .destructive) {
                            delete(item)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }

                        Button {
                            togglePriority(item)
                        } label: {
                            Label(
                                item.isPriority ? "取消重点" : "设为重点",
                                systemImage: item.isPriority ? "star.slash" : "star.fill"
                            )
                        }
                        .tint(.orange)

                        Button {
                            editingItemID = item.id
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }

                paginationFooter(snapshot: snapshot)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .alert("保存失败", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "这次操作没有保存成功，请再试一次。")
        }
        .searchable(text: $searchText, prompt: "搜索词句或英语")
        .onChange(of: searchText) { _, _ in
            displayedItemLimit = 50
            requestSnapshotRefresh(reason: "search", delay: 0.12)
        }
        .onChange(of: filter) { _, _ in
            requestSnapshotRefresh(reason: "filter", delay: 0.02)
        }
        .onChange(of: stageFilter) { _, _ in
            requestSnapshotRefresh(reason: "stage filter", delay: 0.02)
        }
        .onChange(of: displayedItemLimit) { _, _ in
            requestSnapshotRefresh(reason: "pagination", delay: 0)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active, isViewVisible {
                requestSnapshotRefresh(reason: "scene active", delay: 0.08)
            } else {
                snapshotRefreshTask?.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDataDidChange)) { _ in
            requestSnapshotRefresh(reason: "app data changed", delay: 0.08)
        }
        .onAppear {
            isViewVisible = true
            requestSnapshotRefresh(reason: "onAppear", delay: isSnapshotLoaded ? 0.08 : 0.12)
        }
        .onDisappear {
            isViewVisible = false
            snapshotRefreshTask?.cancel()
        }
        .navigationTitle("题库")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $editingItemID) { itemID in
            LibraryReviewItemEditor(itemID: itemID)
        }
        .toolbar {
            Menu("新增", systemImage: "plus") {
                NavigationLink {
                    AddReviewItemView()
                } label: {
                    Label("单条录入", systemImage: "square.and.pencil")
                }

                NavigationLink {
                    BatchAddReviewItemsView()
                } label: {
                    Label("批量录入", systemImage: "text.badge.plus")
                }
            }
        }
    }

    private func requestSnapshotRefresh(reason: String, delay: TimeInterval) {
        #if DEBUG
        DebugPerf.mark("LibraryView requestSnapshotRefresh reason=\(reason) delay=\(delay)")
        #endif
        snapshotRefreshTask?.cancel()
        guard isViewVisible, scenePhase == .active else { return }

        let container = modelContext.container
        let requestedFilter = filter
        let requestedStageFilter = stageFilter
        let requestedSearchText = searchText
        let requestedLimit = displayedItemLimit

        snapshotRefreshTask = Task(priority: .utility) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            let refreshedSnapshot = await Task.detached(priority: .utility) {
                PersistentStoreAccessGate.withAccess {
                    let backgroundContext = ModelContext(container)
                    let descriptor = FetchDescriptor<ReviewItem>(
                        sortBy: [SortDescriptor(\ReviewItem.updatedAt, order: .reverse)]
                    )
                    let items = ((try? backgroundContext.fetch(descriptor)) ?? [])
                        .map(LibraryItemProjection.init)

                    return Self.makeViewSnapshot(
                        from: items,
                        filter: requestedFilter,
                        stageFilter: requestedStageFilter,
                        searchText: requestedSearchText,
                        displayedItemLimit: requestedLimit
                    )
                }
            }.value

            guard !Task.isCancelled, isViewVisible, scenePhase == .active else { return }
            viewSnapshot = refreshedSnapshot
            isSnapshotLoaded = true
        }
    }

    nonisolated private static func makeViewSnapshot(
        from items: [LibraryItemProjection],
        filter: LibraryFilter,
        stageFilter: LibraryStageFilter,
        searchText: String,
        displayedItemLimit: Int,
        referenceDate: Date = .now
    ) -> LibraryViewSnapshot {
        let canonicalItems = canonicalItems(from: items)
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        var filterCounts = Dictionary(
            uniqueKeysWithValues: LibraryFilter.allCases.map { ($0, 0) }
        )
        var stageFilterCounts = Dictionary(
            uniqueKeysWithValues: LibraryStageFilter.options.map { ($0, 0) }
        )
        var scopedItems: [LibraryItemProjection] = []
        scopedItems.reserveCapacity(canonicalItems.count)

        for item in canonicalItems {
            for candidateFilter in LibraryFilter.allCases
            where matches(item, filter: candidateFilter, referenceDate: referenceDate) {
                filterCounts[candidateFilter, default: 0] += 1
            }

            guard matches(item, filter: filter, referenceDate: referenceDate) else { continue }

            for candidateStage in LibraryStageFilter.options
            where matches(item, stageFilter: candidateStage) {
                stageFilterCounts[candidateStage, default: 0] += 1
            }

            guard matches(item, stageFilter: stageFilter) else { continue }
            scopedItems.append(item)
        }

        let filteredItems: [LibraryItemProjection]
        if searchText.isEmpty {
            filteredItems = scopedItems
        } else {
            filteredItems = scopedItems.filter {
                $0.content.localizedCaseInsensitiveContains(searchText) ||
                $0.prompt.localizedCaseInsensitiveContains(searchText) ||
                $0.source.localizedCaseInsensitiveContains(searchText)
            }
        }

        return LibraryViewSnapshot(
            filterCounts: filterCounts,
            stageFilterCounts: stageFilterCounts,
            filteredItems: filteredItems,
            displayedItems: Array(filteredItems.prefix(displayedItemLimit))
        )
    }

    nonisolated private static func canonicalItems(
        from items: [LibraryItemProjection]
    ) -> [LibraryItemProjection] {
        var canonicalByKey: [String: LibraryItemProjection] = [:]

        for item in items {
            let itemKey = ReviewContentIdentity.key(type: item.type, content: item.content)
            guard !itemKey.hasSuffix("|") else { continue }

            if let current = canonicalByKey[itemKey] {
                if isPreferred(item, over: current) {
                    canonicalByKey[itemKey] = item
                }
            } else {
                canonicalByKey[itemKey] = item
            }
        }

        return Array(canonicalByKey.values)
    }

    nonisolated private static func isPreferred(
        _ candidate: LibraryItemProjection,
        over current: LibraryItemProjection
    ) -> Bool {
        let candidateFinished = candidate.nextReviewAt == .distantFuture
        let currentFinished = current.nextReviewAt == .distantFuture
        if candidateFinished != currentFinished {
            return candidateFinished
        }
        if candidate.stage != current.stage {
            return candidate.stage > current.stage
        }
        if candidate.consecutiveWrongCount != current.consecutiveWrongCount {
            return candidate.consecutiveWrongCount < current.consecutiveWrongCount
        }
        if candidate.nextReviewAt != current.nextReviewAt {
            return candidate.nextReviewAt > current.nextReviewAt
        }

        let candidateReviewedAt = candidate.lastReviewedAt ?? .distantPast
        let currentReviewedAt = current.lastReviewedAt ?? .distantPast
        if candidateReviewedAt != currentReviewedAt {
            return candidateReviewedAt > currentReviewedAt
        }
        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }
        return candidate.createdAt < current.createdAt
    }

    nonisolated private static func matches(
        _ item: LibraryItemProjection,
        filter: LibraryFilter,
        referenceDate: Date
    ) -> Bool {
        switch filter {
        case .all:
            return true
        case .due:
            return ReviewScheduler.isDue(item.nextReviewAt, on: referenceDate)
        case .priority:
            return item.isPriority
        case .mastered:
            return item.isMastered
        }
    }

    private func filterButton(_ item: LibraryFilter, count: Int) -> some View {
        let isSelected = filter == item

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                filter = item
                displayedItemLimit = 50
            }
        } label: {
            HStack(spacing: 5) {
                Text(item.rawValue)
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                isSelected ? item.tint : Color(uiColor: .secondarySystemGroupedBackground),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isSelected ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    nonisolated private static func matches(
        _ item: LibraryItemProjection,
        stageFilter: LibraryStageFilter
    ) -> Bool {
        switch stageFilter {
        case .all:
            return true
        case let .stage(stage):
            return item.reviewTrack != .dictationFollowUp && !item.isDictationPass && item.stage == stage
        case .dictationFollowUp:
            return item.reviewTrack == .dictationFollowUp || item.isDictationPass
        }
    }

    private func stageFilterButton(_ item: LibraryStageFilter, count: Int) -> some View {
        let isSelected = stageFilter == item

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                stageFilter = item
                displayedItemLimit = 50
            }
        } label: {
            HStack(spacing: 5) {
                Text(item.title)
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.indigo : Color(uiColor: .secondarySystemGroupedBackground),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isSelected ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func paginationFooter(snapshot: LibraryViewSnapshot) -> some View {
        if snapshot.filteredItems.count > 50 {
            Section {
                VStack(spacing: 8) {
                    Text("已显示 \(snapshot.displayedItems.count) / 共 \(snapshot.filteredItems.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if snapshot.displayedItems.count < snapshot.filteredItems.count {
                        Button {
                            displayedItemLimit += 50
                        } label: {
                            Label("再加载 50 条", systemImage: "arrow.down.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private func libraryRow(_ item: LibraryItemProjection) -> some View {
        let status = statusBadge(for: item)

        return HStack(alignment: .top, spacing: 12) {
            Text(typeLabel(for: item.type))
                .font(.system(size: item.type == .englishWord ? 10 : 13, weight: .bold, design: .rounded))
                .foregroundStyle(typeColor(for: item.type))
                .frame(width: 36, height: 36)
                .background(typeColor(for: item.type).opacity(0.09), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.content)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    Text(status.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(status.tint)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(status.tint.opacity(0.09), in: Capsule())
                }

                Text(subtitle(for: item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if !item.source.isEmpty || item.isPriority {
                    HStack(spacing: 8) {
                        if !item.source.isEmpty {
                            Label(item.source, systemImage: "bookmark")
                                .lineLimit(1)
                        }

                        if item.isPriority {
                            priorityBadge
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func subtitle(for item: LibraryItemProjection) -> String {
        if item.reviewTrack == .dictationFollowUp {
            guard item.dictationFollowUpStep > 0 else {
                return "听写通过后的跟进复习"
            }
            switch item.resolvedDictationFollowUpStep {
            case 1:
                return "听写通过后，第3天复习"
            case 2:
                return "听写通过后，第7天复习"
            default:
                return "听写通过后的跟进复习"
            }
        }

        let prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            return prompt
        }

        return "听写模式：直接朗读 \(item.type.displayName)"
    }

    private var priorityBadge: some View {
        Label("重点", systemImage: "star.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.08), in: Capsule())
    }

    private func statusBadge(for item: LibraryItemProjection) -> (title: String, tint: Color) {
        if item.isMastered {
            return ("已掌握", .green)
        }

        if ReviewScheduler.isDue(item.nextReviewAt) {
            let calendar = Calendar.current
            let reviewDay = ReviewScheduler.normalizedReviewDate(item.nextReviewAt, calendar: calendar)
            let today = calendar.startOfDay(for: .now)
            return reviewDay < today ? ("已逾期", .red) : ("今日待复习", .orange)
        }

        if item.reviewTrack == .dictationFollowUp {
            guard item.dictationFollowUpStep > 0 else {
                return ("听写跟进", .blue)
            }
            switch item.resolvedDictationFollowUpStep {
            case 1:
                return ("第3天", .blue)
            case 2:
                return ("第7天", .teal)
            default:
                return ("听写跟进", .blue)
            }
        }

        if item.isDictationPass {
            return ("听写跟进", .blue)
        }

        return (item.stage.reviewStageDisplayText, item.stage.stageColor)
    }

    private func typeLabel(for type: ReviewItemType) -> String {
        switch type {
        case .chineseCharacter:
            return "字"
        case .phrase:
            return "词"
        case .englishWord:
            return "EN"
        case .englishSentence:
            return "背"
        }
    }

    private func typeColor(for type: ReviewItemType) -> Color {
        switch type {
        case .chineseCharacter:
            return .orange
        case .phrase:
            return .blue
        case .englishWord:
            return .purple
        case .englishSentence:
            return .teal
        }
    }

    private func togglePriority(_ item: LibraryItemProjection) {
        guard let persistedItem = fetchReviewItem(id: item.id) else { return }
        persistedItem.isPriority.toggle()
        persistedItem.updatedAt = .now

        do {
            try modelContext.save()
            AppDataChangeCenter.post()
        } catch {
            // 保存失败时回滚本次改动，界面维持原状态，并提示用户操作未生效。
            modelContext.rollback()
            saveErrorMessage = "设为重点没有保存成功，请再试一次。\(error.localizedDescription)"
        }
    }

    private func delete(_ item: LibraryItemProjection) {
        guard let persistedItem = fetchReviewItem(id: item.id) else { return }
        SyncDeletionStore.delete(persistedItem, in: modelContext)

        do {
            try modelContext.save()
            AppDataChangeCenter.post()
        } catch {
            // 保存失败时回滚删除（含同步墓碑），恢复条目，并提示用户操作未生效。
            modelContext.rollback()
            saveErrorMessage = "删除没有保存成功，请再试一次。\(error.localizedDescription)"
        }
    }

    private func fetchReviewItem(id: UUID) -> ReviewItem? {
        var descriptor = FetchDescriptor<ReviewItem>(
            predicate: #Predicate<ReviewItem> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private var emptyIcon: String {
        if stageFilter != .all {
            return "line.3.horizontal.decrease.circle"
        }

        switch filter {
        case .all: return "tray"
        case .due: return "clock.badge.checkmark"
        case .priority: return "exclamationmark.triangle"
        case .mastered: return "star.circle"
        }
    }

    private var emptyTitle: String {
        if stageFilter != .all {
            return "当前筛选下没有内容"
        }

        switch filter {
        case .all:
            return "题库还是空的"
        case .due:
            return "暂时没有待复习内容"
        case .priority:
            return "暂时没有重点复习内容"
        case .mastered:
            return "还没有已掌握内容"
        }
    }

    private var emptyDescription: String {
        if stageFilter != .all {
            return "“\(filter.rawValue)”中暂时没有“\(stageFilter.title)”的题目，可以切换其他阶段查看。"
        }

        switch filter {
        case .all:
            return "先录入今天写错的内容，后面就会按遗忘曲线自动安排复习。"
        case .due:
            return "今天到期的内容已经练完，或者还没到下一次复习日期。"
        case .priority:
            return "目前没有连续出错较多、需要重点盯住的内容。"
        case .mastered:
            return "再坚持复习几轮，掌握稳定后会出现在这里。"
        }
    }
}

private struct LibraryReviewItemEditor: View {
    @Environment(\.modelContext) private var modelContext
    @State private var item: ReviewItem?
    @State private var hasFinishedLoading = false

    let itemID: UUID

    var body: some View {
        Group {
            if let item {
                AddReviewItemView(item: item)
            } else if hasFinishedLoading {
                ContentUnavailableView("内容不存在", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView("正在打开...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: itemID) {
            var descriptor = FetchDescriptor<ReviewItem>(
                predicate: #Predicate<ReviewItem> { $0.id == itemID }
            )
            descriptor.fetchLimit = 1
            item = try? modelContext.fetch(descriptor).first
            hasFinishedLoading = true
        }
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case due = "待复习"
    case priority = "重点复习"
    case mastered = "已掌握"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .all: return .blue
        case .due: return .orange
        case .priority: return .orange
        case .mastered: return .green
        }
    }
}

private enum LibraryStageFilter: Hashable, Identifiable, Sendable {
    case all
    case stage(Int)
    case dictationFollowUp

    static let options: [LibraryStageFilter] = [
        .all,
        .stage(0),
        .stage(1),
        .stage(2),
        .stage(3),
        .stage(4),
        .stage(5),
        .stage(6),
        .stage(7),
        .dictationFollowUp
    ]

    var id: String {
        switch self {
        case .all:
            return "all"
        case let .stage(stage):
            return "stage-\(stage)"
        case .dictationFollowUp:
            return "dictation-follow-up"
        }
    }

    var title: String {
        switch self {
        case .all:
            return "全部阶段"
        case let .stage(stage):
            return stage.reviewStageDisplayText
        case .dictationFollowUp:
            return "听写跟进"
        }
    }
}
