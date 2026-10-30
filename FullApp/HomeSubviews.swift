import SwiftUI
import SwiftData

// MARK: - Home 子视图
// 从 HomeView.swift 拆分出的独立子视图与支撑类型：
// 每日复习记录（快照、分组、历史列表、单日详情）与复习/听写预习视图。
private struct DailyReviewRecordSnapshot: Identifiable {
    let id: UUID
    let itemID: UUID
    let reviewedAt: Date
    let reviewedAtText: String
    let itemType: ReviewItemType?
    let content: String
    let prompt: String?
    let source: String?
    let result: ReviewResult
    let resultText: String
    let resultIconName: String
    let resultColor: Color
    let modeText: String?
    let stageTransitionText: String
    let detailText: String?

    init(record: ReviewRecord, item: ReviewItem?) {
        id = record.id
        itemID = record.itemID
        reviewedAt = record.reviewedAt
        reviewedAtText = record.reviewedAt.formatted(date: .omitted, time: .shortened)
        itemType = item?.type
        content = item?.content ?? "题目已删除"

        let trimmedPrompt = item?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        prompt = trimmedPrompt.isEmpty ? nil : trimmedPrompt

        let trimmedSource = item?.source.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        source = trimmedSource.isEmpty ? nil : trimmedSource

        result = record.result
        resultText = record.resultDisplayText
        resultIconName = record.resultIconName
        resultColor = record.resultColor
        modeText = record.modeDisplayText
        stageTransitionText = record.stageTransitionText
        detailText = record.condensedDisplayDetailText
    }
}

private struct DailyReviewRecordSection: Identifiable {
    let date: Date
    let records: [DailyReviewRecordSnapshot]

    var id: Date { date }

    var title: String {
        date.formatted(.dateTime.year().month().day().weekday(.abbreviated))
    }

    var reviewedWordCount: Int {
        Set(records.map(\.itemID)).count
    }

    var totalCount: Int { records.count }

    var correctCount: Int {
        records.filter { $0.result == .correct }.count
    }

    var wrongCount: Int {
        records.filter { $0.result == .wrong }.count
    }

    var accuracyText: String {
        guard totalCount > 0 else { return "--" }
        let accuracy = Int((Double(correctCount) / Double(totalCount) * 100).rounded())
        return "\(accuracy)%"
    }

    var summaryLine: String {
        "复习词量 \(reviewedWordCount) 个 · 答对 \(correctCount) 次 · 答错 \(wrongCount) 次 · 正确率 \(accuracyText)"
    }
}

private enum DailyReviewRecordBuilder {
    static func itemsByID(from reviewItems: [ReviewItem]) -> [UUID: ReviewItem] {
        reviewItems.reduce(into: [UUID: ReviewItem]()) { result, item in
            // Imported historical data may contain duplicated UUIDs; keep the first
            // item from the reverse-sorted query so the newest copy wins.
            guard result[item.id] == nil else { return }
            result[item.id] = item
        }
    }

    static func sections(reviewRecords: [ReviewRecord], reviewItems: [ReviewItem]) -> [DailyReviewRecordSection] {
        let itemsByID = itemsByID(from: reviewItems)
        let snapshots = ReviewScheduler.canonicalReviewRecords(reviewRecords).map { record in
            DailyReviewRecordSnapshot(record: record, item: itemsByID[record.itemID])
        }

        let grouped = Dictionary(grouping: snapshots) {
            Calendar.current.startOfDay(for: $0.reviewedAt)
        }

        return grouped
            .map { date, records in
                DailyReviewRecordSection(
                    date: date,
                    records: records.sorted { $0.reviewedAt > $1.reviewedAt }
                )
            }
            .sorted { $0.date > $1.date }
    }
}

struct DailyReviewRecordHistoryView: View {
    @Query(sort: \ReviewRecord.reviewedAt, order: .reverse) private var reviewRecords: [ReviewRecord]
    @Query(sort: \ReviewItem.updatedAt, order: .reverse) private var reviewItems: [ReviewItem]

    private var sections: [DailyReviewRecordSection] {
        DailyReviewRecordBuilder.sections(
            reviewRecords: reviewRecords,
            reviewItems: reviewItems
        )
    }

    var body: some View {
        // 同一轮渲染只整理一次历史；明细直接复用这份值类型快照。
        let sections = self.sections
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700

            ScrollView(showsIndicators: false) {
                if sections.isEmpty {
                    ContentUnavailableView(
                        "还没有复习记录",
                        systemImage: "calendar.badge.clock",
                        description: Text("做过一次正式复习后，这里会按日期自动整理每天的复习情况。")
                    )
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height * 0.7)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(sections) { section in
                            NavigationLink {
                                DailyReviewRecordDayDetailView(section: section)
                            } label: {
                                HStack(alignment: .center, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(section.title)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                            .foregroundStyle(.primary)

                                        Text(section.summaryLine)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    Spacer(minLength: 12)

                                    Image(systemName: "chevron.right")
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(isWide ? 32 : 20)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }
}

private struct DailyReviewRecordDayDetailView: View {
    // 只渲染所选日期的快照，不在导航过程中再次读取和归并整库历史。
    let section: DailyReviewRecordSection

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: isWide ? 4 : 2
            )

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.system(.title3, design: .rounded, weight: .bold))
                            Text("当天共复习 \(section.reviewedWordCount) 个词")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        LazyVGrid(columns: columns, spacing: 12) {
                            StatGridCard(icon: "character.book.closed", title: "复习词量", value: "\(section.reviewedWordCount)", tint: .blue)
                            StatGridCard(icon: "hand.thumbsup", title: "答对", value: "\(section.correctCount)", tint: .green)
                            StatGridCard(icon: "hand.thumbsdown", title: "答错", value: "\(section.wrongCount)", tint: .red)
                            StatGridCard(icon: "percent", title: "正确率", value: section.accuracyText, tint: .orange)
                        }

                        LazyVStack(spacing: 12) {
                            ForEach(section.records) { record in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: record.resultIconName)
                                            .font(.title3)
                                            .foregroundStyle(record.resultColor)

                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(spacing: 8) {
                                                Text(record.reviewedAtText)
                                                    .font(.subheadline.weight(.semibold))

                                                Spacer(minLength: 8)

                                                Text(record.resultText)
                                                    .font(.caption.weight(.bold))
                                                    .foregroundStyle(record.resultColor)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(record.resultColor.opacity(0.12), in: Capsule())

                                                if let modeText = record.modeText {
                                                    Text(modeText)
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(.secondary)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(Color.secondary.opacity(0.12), in: Capsule())
                                                }
                                            }

                                            HStack(spacing: 8) {
                                                if let itemType = record.itemType {
                                                    TypeBadge(type: itemType)
                                                }

                                                Text(record.content)
                                                    .font(.headline)
                                                    .foregroundStyle(.primary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }

                                            Text(record.stageTransitionText)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)

                                            if let detailText = record.detailText {
                                                Text(detailText)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.primary)
                                            }

                                            if let prompt = record.prompt {
                                                Text(prompt)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            if let source = record.source {
                                                Label(source, systemImage: "bookmark.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                }
                .padding(isWide ? 24 : 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationTitle(section.date.formatted(.dateTime.month().day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Home Dictation Preview

struct HomeDictationPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = DictationSpeaker()

    let session: HomeDictationSessionProjection
    let entries: [HomeDictationEntryProjection]
    var onStartSession: () -> Void

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
            }
            .onDisappear {
                speaker.stop()
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Button {
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

    private func phoneticText(for entry: HomeDictationEntryProjection) -> String? {
        guard entry.type == .englishWord,
              let gloss = EnglishGlossService.shared.lookup(text: entry.content),
              !gloss.displayPhonetic.isEmpty else {
            return nil
        }
        return gloss.displayPhonetic
    }
}

// MARK: - Review Preview View

struct ReviewPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = DictationSpeaker()
    
    let items: [HomeReviewItemProjection]
    var onStartReview: () -> Void
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("今日待复习")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        
                        Text("共 \(items.count) 项错题内容")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    
                    VStack(spacing: 12) {
                        ForEach(items.indices, id: \.self) { index in
                            let item = items[index]
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("\(index + 1)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.orange)
                                            .frame(width: 22, height: 22)
                                            .background(Color.orange.opacity(0.1), in: Circle())
                                        
                                        TypeBadge(type: item.type)
                                        
                                        Spacer()
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.content)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                            .foregroundStyle(.primary)
                                        
                                        if !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(item.prompt)
                                                .font(.headline.weight(.medium))
                                                .foregroundStyle(.orange)
                                        }

                                        if let phonetic = phoneticText(for: item) {
                                            Text(phonetic)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                
                                Spacer()
                                
                                Button {
                                    speaker.speak(content: item.content, type: item.type, prompt: item.prompt)
                                } label: {
                                    Image(systemName: "speaker.wave.2.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.orange.opacity(0.6))
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
            .navigationTitle("复习预习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .onDisappear {
                speaker.stop()
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Button {
                        dismiss()
                        onStartReview()
                    } label: {
                        Text("开始复习")
                    }
                    .buttonStyle(ResultButtonStyle(color: .orange))
                    .padding()
                }
                .background(.bar)
            }
        }
    }

    private func phoneticText(for item: HomeReviewItemProjection) -> String? {
        guard item.type == .englishWord,
              let gloss = EnglishGlossService.shared.lookup(text: item.content),
              !gloss.displayPhonetic.isEmpty else {
            return nil
        }
        return gloss.displayPhonetic
    }
}

private struct SyncStatusIconView: View {
    let isRefreshing: Bool

    var body: some View {
        Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "icloud")
            .symbolVariant(isRefreshing ? .circle : .none)
    }
}

// 加载完成后的内容分流；空数组是已加载的空状态，不能进入练习页面。
struct HomeReviewSessionContent: View {
    let items: [ReviewItem]
    let style: ReviewInteractionStyle

    var body: some View {
        if items.isEmpty {
            ReviewEmptyStateView()
        } else if style == .batch {
            BatchReviewSessionView(items: items)
        } else {
            ReviewSessionView(items: items)
        }
    }
}
