import SwiftUI
import SwiftData

struct AddDictationSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var type: ReviewItemType?
    @State private var title = ""
    @State private var scheduledDate: Date = .now
    @State private var defaultSource = ""
    @State private var rawText = ""
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var showTypePickerAttention = false
    @State private var isTypeManuallyChosen: Bool

    var editingSession: DictationSession?
    var existingEntries: [DictationEntry]?

    init(editingSession: DictationSession? = nil, existingEntries: [DictationEntry]? = nil) {
        self.editingSession = editingSession
        self.existingEntries = existingEntries

        if let session = editingSession {
            _type = State(initialValue: session.type)
            _title = State(initialValue: session.title)
            _scheduledDate = State(initialValue: session.scheduledDate)

            if let entriesToEdit = existingEntries {
                let text = entriesToEdit
                    .sorted { $0.sortOrder < $1.sortOrder }
                    .map { entry in
                        var line = entry.content
                        if !entry.prompt.isEmpty || !entry.source.isEmpty {
                            line += " | \(entry.prompt)"
                        }
                        if !entry.source.isEmpty {
                            line += " | \(entry.source)"
                        }
                        return line
                    }
                    .joined(separator: "\n")
                _rawText = State(initialValue: text)
            }
        }

        _isTypeManuallyChosen = State(initialValue: editingSession != nil)
    }

    private var entries: [ParsedDictationEntry] {
        rawText
            .components(separatedBy: .newlines)
            .compactMap(ParsedDictationEntry.init(rawLine:))
    }

    private var canSave: Bool {
        !entries.isEmpty
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 20) {
                introCard
                formCard
                editorCard
                formatCard
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(editingSession != nil ? "编辑听写计划" : "新增今日听写")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: rawText) { _, newValue in
            guard !isTypeManuallyChosen else { return }
            type = ReviewItemTypeInference.infer(from: newValue)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(editingSession != nil ? "完成修改" : "保存计划") {
                        Task {
                            await save()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
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
                        Text("正在生成听写计划...")
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }

    var body: some View {
        content
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editingSession != nil ? "编辑听写计划" : "新增听写计划")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text(editingSession != nil ? "修改听写内容和日期，保存后即生效。" : "录入内容并指定日期，孩子只在当天看到任务。")
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
                        colors: [.teal.opacity(0.9), .cyan.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 18) {
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

            DatePicker("计划日期", selection: $scheduledDate, displayedComponents: .date)
                .font(.subheadline.weight(.medium))

            if type?.isRecitation == true {
                Text("先看着原文读几遍，再隐藏文字背诵。背出来算对，没背出来算错，之后照常复习。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(type?.isRecitation == true ? "背诵标题" : "听写标题", systemImage: "star.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                    
                    TextField(type?.isRecitation == true ? "例如：Unit 5 句子背诵" : "例如：Unit 5 听写", text: $title)
                        .font(.title2.weight(.medium))
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Label("默认来源 (可选)", systemImage: "tag.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.purple)
                    
                    TextField("输入所有错题共用的来源", text: $defaultSource)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(type?.isRecitation == true ? "背诵内容" : "听写内容")
                        .font(.headline)
                    Text("共 \(entries.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                Button {
                    rawText += " | "
                } label: {
                    HStack(spacing: 4) {
                        Text("|")
                            .font(.system(.body, design: .monospaced, weight: .bold))
                        Text("分隔符")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }

            PlaceholderTextEditor(text: $rawText, placeholder: placeholderText, minHeight: 240)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var formatCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 6) {
                Text("支持格式：每行一条，可用 | 分隔提示和来源。")
                Text("例如：`apple | 苹果` 或 `欢迎 | 高兴地接待`")
                    .font(.caption.monospaced())
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var placeholderText: String {
        switch type {
        case .phrase?:
            return "欢迎\n认真 | 做事不马虎\n提醒 | 让别人注意 | 第三单元"
        case .englishWord?:
            return "apple\nbanana | 香蕉\norange | 橙子 | Unit 5"
        case .englishSentence?:
            return "What would you like to eat? | 你想吃什么？ | Unit 3\nI'd like a sandwich. | 我想要一个三明治。"
        default:
            return "请先选择题目类型，再录入听写内容"
        }
    }

    private func save() async {
        guard !isSaving else { return }
        guard let selectedType = type else {
            flashTypePickerAttention()
            return
        }
        isSaving = true
        saveErrorMessage = nil
        
        let now = Date()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let activityName = selectedType.isRecitation ? "背诵" : "听写"
        let sessionTitle = trimmedTitle.isEmpty ? "\(scheduledDate.formatted(date: .abbreviated, time: .omitted))\(activityName)" : trimmedTitle
        let sourceFallback = defaultSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentEntries = entries.map { entry in
            guard selectedType == .englishWord,
                  entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let gloss = EnglishGlossService.shared.lookup(text: entry.content) else {
                return entry
            }
            return entry.settingPrompt(to: gloss.translation)
        }

        let context = PendingDictationSaveContext(
            title: sessionTitle,
            scheduledDate: scheduledDate,
            type: selectedType,
            sourceFallback: sourceFallback,
            entries: currentEntries,
            createdAt: now
        )

        await persist(context: context)
    }

    private func persist(context: PendingDictationSaveContext) async {
        let session: DictationSession
        if let existing = editingSession {
            session = existing
            session.title = context.title
            session.type = context.type
            session.scheduledDate = context.scheduledDate
            session.updatedAt = context.createdAt

            if let entriesToDelete = existingEntries {
                for entry in entriesToDelete {
                    SyncDeletionStore.delete(entry, in: modelContext)
                }
            }
        } else {
            session = DictationSession(
                title: context.title,
                type: context.type,
                createdAt: context.createdAt,
                updatedAt: context.createdAt,
                scheduledDate: context.scheduledDate
            )
            modelContext.insert(session)
        }

        for (index, entry) in context.entries.enumerated() {
            modelContext.insert(
                DictationEntry(
                    sessionID: session.id,
                    sortOrder: index,
                    type: context.type,
                    content: entry.content,
                    prompt: entry.prompt,
                    note: "",
                    source: entry.source.isEmpty ? context.sourceFallback : entry.source,
                    result: .pending,
                    createdAt: context.createdAt,
                    updatedAt: context.createdAt
                )
            )
        }

        do {
            try modelContext.save()
            if editingSession != nil { AICoachSignals.post("manualEdit", id: session.id) }
            AppDataChangeCenter.post()
            isSaving = false
            dismiss()
        } catch {
            isSaving = false
            saveErrorMessage = "听写计划保存失败，请稍后再试。\(error.localizedDescription)"
        }
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

}

private struct ParsedDictationEntry {
    let content: String
    let prompt: String
    let source: String

    init?(rawLine: String) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let first = parts.first, !first.isEmpty, parts.count <= 3 else { return nil }

        self.content = first
        self.prompt = parts.count > 1 ? parts[1] : ""
        self.source = parts.count > 2 ? parts[2] : ""
    }

    init(content: String, prompt: String, source: String) {
        self.content = content
        self.prompt = prompt
        self.source = source
    }

    func settingPrompt(to prompt: String) -> ParsedDictationEntry {
        ParsedDictationEntry(content: content, prompt: prompt, source: source)
    }

    var serializedLine: String {
        var line = content
        if !prompt.isEmpty || !source.isEmpty {
            line += " | \(prompt)"
        }
        if !source.isEmpty {
            line += " | \(source)"
        }
        return line
    }
}

private struct PendingDictationSaveContext {
    let title: String
    let scheduledDate: Date
    let type: ReviewItemType
    let sourceFallback: String
    let entries: [ParsedDictationEntry]
    let createdAt: Date
}
