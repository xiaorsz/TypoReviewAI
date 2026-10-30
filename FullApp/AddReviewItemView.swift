import SwiftUI
import SwiftData

struct DeferredAddReviewItemView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReady = false
    @State private var activationTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isReady {
                AddReviewItemView()
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开新增错题...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("新增错题")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onAppear {
            #if DEBUG
            DebugPerf.mark("DeferredAddReviewItemView onAppear")
            DebugPerf.watchMainThread("DeferredAddReviewItemView activation")
            #endif
            activateAfterNavigationSettles()
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG
            DebugPerf.mark("DeferredAddReviewItemView scenePhase=\(newPhase)")
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
            DebugPerf.mark("DeferredAddReviewItemView onDisappear")
            #endif
            activationTask?.cancel()
        }
    }

    private func activateAfterNavigationSettles() {
        activationTask?.cancel()
        guard !isReady else { return }
        guard scenePhase == .active else { return }

        activationTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            guard scenePhase == .active else { return }
            #if DEBUG
            DebugPerf.mark("DeferredAddReviewItemView showing AddReviewItemView")
            #endif
            isReady = true
        }
    }
}

struct AddReviewItemView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let scheduler = ReviewScheduler()
    private let existingItem: ReviewItem?
    @Query(sort: \ReviewItem.updatedAt, order: .reverse) private var reviewItems: [ReviewItem]
    @Query private var reviewRecords: [ReviewRecord]
    @State private var type: ReviewItemType?
    @State private var content = ""
    @State private var prompt = ""
    @State private var note = ""
    @State private var source = ""
    @State private var showSaveToast = false
    @State private var showTypePickerAttention = false
    @State private var isTypeManuallyChosen: Bool
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    init(item: ReviewItem? = nil) {
        self.existingItem = item
        let recordItemID = item?.id ?? UUID()
        _reviewRecords = Query(
            filter: #Predicate<ReviewRecord> { record in
                record.itemID == recordItemID
            },
            sort: [SortDescriptor(\ReviewRecord.reviewedAt, order: .reverse)]
        )
        _type = State(initialValue: item?.type)
        _content = State(initialValue: item?.content ?? "")
        _prompt = State(initialValue: item?.prompt ?? "")
        _note = State(initialValue: item?.note ?? "")
        _source = State(initialValue: item?.source ?? "")
        _isTypeManuallyChosen = State(initialValue: item != nil)
    }

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var contentView: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700

            ScrollView {
                VStack(spacing: 20) {
                    introCard

                    VStack(spacing: 18) {
                        typePicker
                        inputCard
                        if existingItem != nil {
                            reviewRecordsCard(isWide: isWide)
                        }
                        tipsCard
                    }
                    .frame(maxWidth: isWide ? 780 : .infinity)
                }
                .padding(isWide ? 32 : 20)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: content) { _, newValue in
            guard !isTypeManuallyChosen else { return }
            type = ReviewItemTypeInference.infer(from: newValue)
        }
        .toast("已保存 ✓", isPresented: $showSaveToast, duration: 0.8)
        .navigationTitle(existingItem == nil ? "新增错题" : "题目详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            DebugPerf.mark("AddReviewItemView onAppear existing=\(existingItem != nil)")
            DebugPerf.watchMainThread("AddReviewItemView first frame")
            #endif
        }
        .onDisappear {
            #if DEBUG
            DebugPerf.mark("AddReviewItemView onDisappear existing=\(existingItem != nil)")
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if existingItem == nil {
                    NavigationLink {
                        BatchAddReviewItemsView()
                    } label: {
                        Text("批量录入")
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(existingItem == nil ? "保存" : "完成") {
                    Task {
                        await save()
                    }
                }
                .fontWeight(.semibold)
                .disabled(!canSave || isSaving)
            }
        }
        .alert("保存失败", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
        .overlay {
            if isSaving {
                ZStack {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(existingItem == nil ? "正在保存错题..." : "正在保存修改...")
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }

    var body: some View {
        contentView
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(existingItem == nil ? "录入新错题" : "题目详情")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text(existingItem == nil ? "录入后会从明天开始进入正式复习。" : "可以修改题目内容，也可以查看这道题历次复习情况。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [.mint.opacity(0.85), .cyan.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var typePicker: some View {
        HStack {
            Text("题目类型")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("类型", selection: Binding(
                get: { type },
                set: { newValue in
                    type = newValue
                    isTypeManuallyChosen = true
                }
            )) {
                Text("词句").tag(Optional(ReviewItemType.phrase))
                Text("英语").tag(Optional(ReviewItemType.englishWord))
                Text("背诵").tag(Optional(ReviewItemType.englishSentence))
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.orange.opacity(showTypePickerAttention ? 0.18 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(showTypePickerAttention ? Color.orange : .clear, lineWidth: 2)
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section 1: Core Content
            VStack(alignment: .leading, spacing: 10) {
                Label("核心内容", systemImage: "star.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                
                TextField(contentLabel, text: $content)
                    .font(.title2.weight(.medium))
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            // Section 2: Source
            VStack(alignment: .leading, spacing: 10) {
                Label("来源 (例如: 语文作业)", systemImage: "tag.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.purple)
                
                TextField("输入错题来源", text: $source)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            Divider()

            // Section 3: Meta info
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField(promptLabel, text: $prompt)
                        .textFieldStyle(.plain)
                }
                
                HStack(spacing: 12) {
                    Image(systemName: "note.text")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField("备注记录重点或心得", text: $note)
                        .textFieldStyle(.plain)
                }
            }
            .font(.subheadline)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .bottom) {
            if existingItem == nil {
                Button {
                    Task {
                        await save(keepOpen: true)
                    }
                } label: {
                    Label("保存并继续录入下一条", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                }
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .padding(20)
                .offset(y: 80)
            }
        }
        .padding(.bottom, existingItem == nil ? 80 : 0)
    }

    private var tipsCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text(exampleText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func reviewRecordsCard(isWide: Bool) -> some View {
        let snapshots = reviewRecordSnapshots
        let columns = isWide
            ? Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
            : Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("复习记录")
                        .font(.headline)
                    Text(snapshots.isEmpty ? "还没有复习记录" : "共 \(snapshots.count) 次复习")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            LazyVGrid(columns: columns, spacing: 12) {
                StatGridCard(icon: "clock.arrow.circlepath", title: "总次数", value: "\(snapshots.count)", tint: .blue)
                StatGridCard(icon: "hand.thumbsup", title: "答对", value: "\(snapshots.filter { $0.result == .correct }.count)", tint: .green)
                StatGridCard(icon: "hand.thumbsdown", title: "答错", value: "\(snapshots.filter { $0.result == .wrong }.count)", tint: .red)
                StatGridCard(
                    icon: "calendar",
                    title: "最近一次",
                    value: snapshots.first?.reviewedAtDateText ?? "--",
                    tint: .orange
                )
            }

            if snapshots.isEmpty {
                ContentUnavailableView(
                    "还没有复习记录",
                    systemImage: "clock.badge.xmark",
                    description: Text("做过一次正式复习后，这里就会开始累计显示每次结果。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 12) {
                    ForEach(snapshots) { snapshot in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: snapshot.resultIconName)
                                    .font(.title3)
                                    .foregroundStyle(snapshot.resultColor)

                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Text(snapshot.reviewedAtText)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer(minLength: 8)
                                        Text(snapshot.resultText)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(snapshot.resultColor)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(snapshot.resultColor.opacity(0.12), in: Capsule())

                                        if let modeText = snapshot.modeText {
                                            Text(modeText)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                        }
                                    }

                                    Text(snapshot.stageTransitionText)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    Text(snapshot.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)

                                    if let note = snapshot.noteText {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("备注")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Text(note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var reviewRecordSnapshots: [ReviewRecordDisplaySnapshot] {
        ReviewScheduler.canonicalReviewRecords(reviewRecords)
            .map(ReviewRecordDisplaySnapshot.init)
    }

    private var contentLabel: String {
        switch type {
        case .phrase?:
            "正确词句，例如 欢迎 / 在家休息"
        case .englishWord?:
            "正确英语，例如 apple / good morning"
        case .englishSentence?:
            "要背诵的英语句子"
        default:
            "先选择题目类型"
        }
    }

    private var promptLabel: String {
        switch type {
        case .phrase?:
            "题目提示，可选，例如 根据意思写词句: 高兴地接待别人"
        case .englishWord?:
            "题目提示，可选，例如 看中文写英语: 苹果"
        case .englishSentence?:
            "中文意思或背诵提示，可选"
        default:
            "题目提示，可选"
        }
    }

    private var exampleText: String {
        switch type {
        case .phrase?:
            "如果要练词句填空，可补全提示；如果不填，复习时会直接朗读词句。"
        case .englishWord?:
            "英语单词可以直接按听写来播报；如果想要中文释义出题，再补提示。"
        case .englishSentence?:
            "可以先看着读几遍，再隐藏文字背诵。背出来算对，没背出来算错。"
        default:
            "请先选择题目类型，再录入内容。"
        }
    }

    private func save(keepOpen: Bool = false) async {
        #if DEBUG
        DebugPerf.mark("AddReviewItemView save tapped keepOpen=\(keepOpen)")
        DebugPerf.watchMainThread("AddReviewItemView save")
        #endif

        guard !isSaving else { return }
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }
        guard let selectedType = type else {
            flashTypePickerAttention()
            return
        }
        isSaving = true
        saveErrorMessage = nil

        let enteredPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPrompt: String
        if selectedType == .englishWord, enteredPrompt.isEmpty,
           let gloss = EnglishGlossService.shared.lookup(text: trimmedContent) {
            resolvedPrompt = gloss.translation
        } else {
            resolvedPrompt = enteredPrompt
        }

        let context = PendingReviewItemSaveContext(
            type: selectedType,
            content: trimmedContent,
            prompt: resolvedPrompt,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source.trimmingCharacters(in: .whitespacesAndNewlines),
            keepOpen: keepOpen
        )

        persist(context: context)
    }

    private func flashTypePickerAttention() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showTypePickerAttention = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showTypePickerAttention = false
                }
            }
        }
    }

    private func persist(context: PendingReviewItemSaveContext) {
        let sanitizedContent = ReviewContentIdentity.displayContent(context.content)
        let duplicateItem = reviewItems.first {
            $0.persistentModelID != existingItem?.persistentModelID &&
            ReviewContentIdentity.isSameContent($0, type: context.type, content: sanitizedContent)
        }

        if let existingItem {
            #if DEBUG
            DebugPerf.mark("AddReviewItemView updating existing item")
            #endif
            let targetItem = duplicateItem ?? existingItem
            targetItem.type = context.type
            targetItem.content = sanitizedContent
            targetItem.prompt = context.prompt
            targetItem.note = context.note
            targetItem.source = context.source
            targetItem.updatedAt = .now

            if let duplicateItem, duplicateItem.persistentModelID != existingItem.persistentModelID {
                for record in reviewRecords {
                    record.itemID = duplicateItem.id
                }
                SyncDeletionStore.delete(existingItem, in: modelContext)
            }
        } else {
            #if DEBUG
            DebugPerf.mark("AddReviewItemView inserting new ReviewItem")
            #endif
            if let duplicateItem {
                duplicateItem.prompt = context.prompt
                duplicateItem.note = context.note
                duplicateItem.source = context.source
                duplicateItem.updatedAt = .now
            } else {
                modelContext.insert(
                    ReviewItem(
                        type: context.type,
                        content: sanitizedContent,
                        prompt: context.prompt,
                        note: context.note,
                        source: context.source,
                        stage: 0,
                        nextReviewAt: scheduler.nextDayStart()
                    )
                )
            }
        }

        AppDataChangeCenter.post()

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        isSaving = false

        if context.keepOpen {
            withAnimation {
                showSaveToast = true
                content = ""
                prompt = ""
                // Keep source and note usually for continuous entry from same source
            }
        } else {
            withAnimation {
                showSaveToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                #if DEBUG
                DebugPerf.mark("AddReviewItemView delayed dismiss")
                #endif
                dismiss()
            }
        }
    }

}

private struct PendingReviewItemSaveContext {
    let type: ReviewItemType
    let content: String
    let prompt: String
    let note: String
    let source: String
    let keepOpen: Bool
}

private struct ReviewRecordDisplaySnapshot: Identifiable {
    let id: UUID
    let reviewedAtDateText: String
    let reviewedAtText: String
    let result: ReviewResult
    let resultText: String
    let resultIconName: String
    let resultColor: Color
    let modeText: String?
    let stageTransitionText: String
    let detail: String
    let noteText: String?

    init(_ record: ReviewRecord) {
        id = record.id
        reviewedAtDateText = record.reviewedAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        reviewedAtText = record.reviewedAt.formatted(date: .abbreviated, time: .shortened)
        result = record.result
        resultText = record.resultDisplayText
        resultIconName = record.resultIconName
        resultColor = record.resultColor
        modeText = record.modeDisplayText
        stageTransitionText = record.stageTransitionText
        detail = record.displayDetailText

        noteText = record.userVisibleNoteText
    }
}
