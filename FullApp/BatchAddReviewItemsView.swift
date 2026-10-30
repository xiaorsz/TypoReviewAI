import SwiftUI
import SwiftData

struct BatchAddReviewItemsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var reviewItems: [ReviewItem]

    private let scheduler = ReviewScheduler()
    @State private var type: ReviewItemType?
    @State private var rawText = ""
    @State private var defaultSource = ""
    @State private var importSummary: BatchImportSummary?
    @State private var showTypePickerAttention = false
    @State private var isTypeManuallyChosen = false

    private let resultCardAnchor = "batchImportResultCard"

    private var parsedLines: [BatchReviewLineResult] {
        rawText
            .components(separatedBy: .newlines)
            .enumerated()
            .map { index, rawLine in
                BatchReviewLineResult(lineNumber: index + 1, rawLine: rawLine)
            }
    }

    private var entries: [BatchReviewEntry] {
        parsedLines.compactMap(\.entry)
    }

    private var canImport: Bool {
        !entries.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 20) {
                        if let importSummary {
                            resultCard(summary: importSummary)
                                .id(resultCardAnchor)
                        }

                        introCard
                        configCard
                        editorCard
                        formatCard
                    }
                    .padding(isWide ? 32 : 20)
                    .frame(maxWidth: isWide ? 860 : .infinity)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: importSummary?.importedCount) { _, newValue in
                    guard newValue != nil else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scrollProxy.scrollTo(resultCardAnchor, anchor: .top)
                    }
                }
            }
        }
        .onChange(of: rawText) { _, newValue in
            guard !isTypeManuallyChosen else { return }
            type = ReviewItemTypeInference.infer(from: newValue)
        }
        .navigationTitle("批量录入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("导入") {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(!canImport)
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("批量导入错题")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text("适合把当天写错的内容整体贴进来批量录入。")
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
                        colors: [.indigo.opacity(0.85), .blue.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var configCard: some View {
        VStack(spacing: 18) {
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

            VStack(alignment: .leading, spacing: 10) {
                Label("默认来源 (可选)", systemImage: "tag.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.purple)
                
                TextField("输入这批错题共用的来源", text: $defaultSource)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(20)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Label("核心内容", systemImage: "star.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                    Text("每行一条，点右侧按钮插入分隔符")
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
            
            HStack {
                Label(editorStatusText, systemImage: "text.badge.checkmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(canImport ? .blue : .secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(canImport ? Color.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var formatCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("支持格式：每行一条，可用 | 分隔提示和来源。")
                Text("例如：`apple | 苹果 | 英语作业`")
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
            return "欢迎\n认真 | 做事不马虎\n提醒 | 让别人注意 | 语文听写"
        case .englishWord?:
            return "apple\nbanana | 香蕉\norange | 橙子 | 英语听写"
        case .englishSentence?:
            return "What would you like to eat? | 你想吃什么？ | Unit 3\nI'd like a sandwich. | 我想要一个三明治。"
        default:
            return "请先选择题目类型，再粘贴批量内容"
        }
    }

    private var editorStatusText: String {
        let validCount = entries.count
        let invalidCount = parsedLines.filter(\.isInvalid).count

        if invalidCount == 0 {
            return "可导入 \(validCount) 条"
        }

        return "可导入 \(validCount) 条，跳过 \(invalidCount) 行"
    }

    @ViewBuilder
    private func resultCard(summary: BatchImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: summary.importedCount > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(summary.importedCount > 0 ? .green : .orange)
                    .symbolEffect(.bounce, value: summary.importedCount)

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.importedCount > 0 ? "导入成功！" : "导入结果")
                        .font(.title3.weight(.bold))
                    Text("成功导入 \(summary.importedCount) 条内容")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                resultPill(title: "成功导入", value: "\(summary.importedCount)", tint: .green)
                resultPill(title: "重复跳过", value: "\(summary.duplicateLines.count)", tint: .orange)
                resultPill(title: "无效行", value: "\(summary.invalidLines.count)", tint: .red)
            }

            if !summary.duplicateLines.isEmpty {
                Text("这些内容已存在，已跳过：")
                    .font(.subheadline.weight(.semibold))
                Text(summary.duplicateLines.map(\.displayText).joined(separator: "\n"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !summary.invalidLines.isEmpty {
                Text("这些行格式无效，未导入：")
                    .font(.subheadline.weight(.semibold))
                Text(summary.invalidLines.map(\.displayText).joined(separator: "\n"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("继续录入") {
                    importSummary = nil
                    rawText = ""
                }
                .buttonStyle(.bordered)

                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func resultPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private func save() {
        guard let selectedType = type else {
            flashTypePickerAttention()
            return
        }

        let sourceFallback = defaultSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingKeys = Set(
            reviewItems.map {
                BatchImportKey(type: $0.type, content: $0.content)
            }
        )

        var importedCount = 0
        var duplicateLines: [BatchReviewLineResult] = []
        var invalidLines: [BatchReviewLineResult] = []
        var seenInThisBatch = Set<BatchImportKey>()

        for line in parsedLines {
            guard let entry = line.entry else {
                if line.isInvalid {
                    invalidLines.append(line)
                }
                continue
            }

            let key = BatchImportKey(type: selectedType, content: entry.content)
            if existingKeys.contains(key) || seenInThisBatch.contains(key) {
                duplicateLines.append(line)
                continue
            }

            modelContext.insert(
                ReviewItem(
                    type: selectedType,
                    content: ReviewContentIdentity.displayContent(entry.content),
                    prompt: entry.prompt,
                    note: "",
                    source: entry.source.isEmpty ? sourceFallback : entry.source,
                    stage: 0,
                    nextReviewAt: scheduler.nextDayStart()
                )
            )
            seenInThisBatch.insert(key)
            importedCount += 1
        }

        importSummary = BatchImportSummary(
            importedCount: importedCount,
            duplicateLines: duplicateLines,
            invalidLines: invalidLines
        )

        if importedCount > 0 {
            rawText = ""
            defaultSource = ""
            AppDataChangeCenter.post()
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

private struct BatchImportSummary {
    let importedCount: Int
    let duplicateLines: [BatchReviewLineResult]
    let invalidLines: [BatchReviewLineResult]
}

private struct BatchImportKey: Hashable {
    let type: ReviewItemType
    let content: String

    init(type: ReviewItemType, content: String) {
        self.type = type
        self.content = ReviewContentIdentity.normalizedContent(content, type: type)
    }
}

private struct BatchReviewLineResult: Identifiable {
    let id = UUID()
    let lineNumber: Int
    let rawLine: String
    let entry: BatchReviewEntry?

    init(lineNumber: Int, rawLine: String) {
        self.lineNumber = lineNumber
        self.rawLine = rawLine
        self.entry = BatchReviewEntry(rawLine: rawLine)
    }

    var isInvalid: Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && entry == nil
    }

    var displayText: String {
        let text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return "第 \(lineNumber) 行: \(text)"
    }
}

private struct BatchReviewEntry {
    let content: String
    let prompt: String
    let source: String

    init?(rawLine: String) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let first = parts.first, !first.isEmpty else { return nil }
        guard parts.count <= 3 else { return nil }

        self.content = first
        self.prompt = parts.count > 1 ? parts[1] : ""
        self.source = parts.count > 2 ? parts[2] : ""
    }
}
