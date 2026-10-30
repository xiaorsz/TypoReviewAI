import SwiftUI
import CoachCore

struct LearningHubView: View {
    @Environment(LabStore.self) private var store
    @State private var adding = false
    @State private var activeID: UUID?
    @State private var error: String?
    @State private var selectedType: ContentType?
    private var review: DictationSession? { store.state.sessions.first { $0.isFormalReview && $0.reviewedAt == nil && $0.cancelledAt == nil } }
    private var pending: [DictationSession] {
        store.state.sessions.filter { !$0.isFormalReview && $0.reviewedAt == nil && $0.cancelledAt == nil && (selectedType == nil || $0.typeRawValue == selectedType!.rawValue) }.sorted { $0.scheduledDate < $1.scheduledDate }
    }
    private var today: [DictationSession] { pending.filter { Calendar.current.startOfDay(for: $0.scheduledDate) <= Calendar.current.startOfDay(for: .now) } }
    private var future: [DictationSession] { pending.filter { Calendar.current.startOfDay(for: $0.scheduledDate) > Calendar.current.startOfDay(for: .now) } }
    var body: some View {
        List {
            Section {
                HStack {
                    stat("到期题目", value: store.dueItems().count)
                    Spacer()
                    stat("今日已练", value: store.state.records.filter { Calendar.current.isDateInToday($0.reviewedAt) }.count)
                    Spacer()
                    stat("重点题目", value: store.state.items.filter(\.isPriority).count)
                }.padding(.vertical, 8)
                if let review {
                    NavigationLink { SessionDetailView(sessionID: review.id) } label: { Label("继续本轮复习", systemImage: "arrow.clockwise") }
                } else {
                    Button("逐题复习到期内容") { startReview(.sequential) }.disabled(store.dueItems().isEmpty)
                    Button("连续听写后统一判卷") { startReview(.batch) }.disabled(store.dueItems().isEmpty)
                }
                Text("每日正式复习最多 \(store.state.practicePreferences.reviewDailyLimit) 题，优先安排重点与较早到期内容。") .font(.caption).foregroundStyle(.secondary)
            } header: { Text("按遗忘曲线复习") }
            Section {
                Picker("计划类型", selection: $selectedType) {
                    Text("全部").tag(Optional<ContentType>.none)
                    ForEach(ContentType.allCases) { Text($0.title).tag(Optional($0)) }
                }
                Button { adding = true } label: { Label("新增听写／背诵计划", systemImage: "plus.circle") }
            }
            Section("今天与逾期听写（\(today.count)）") {
                if today.isEmpty { Text("没有待完成的听写计划。") .foregroundStyle(.secondary) }
                ForEach(today) { session in NavigationLink { SessionDetailView(sessionID: session.id) } label: { SessionRow(session: session) } }
            }
            if !future.isEmpty {
                Section("后续安排") {
                    ForEach(future) { session in NavigationLink { SessionDetailView(sessionID: session.id) } label: { SessionRow(session: session) } }
                }
            }
            Section {
                NavigationLink { HistoryView() } label: { Label("全部听写与复习记录", systemImage: "clock.arrow.circlepath") }
            }
        }
        .navigationTitle("听写复习")
        .toolbar { Button { adding = true } label: { Label("新增计划", systemImage: "plus") } }
        .sheet(isPresented: $adding) { NavigationStack { DictationEditorView() }.environment(store) }
        .navigationDestination(isPresented: Binding(get: { activeID != nil }, set: { if !$0 { activeID = nil } })) {
            if let activeID { SessionDetailView(sessionID: activeID) }
        }
        .alert("无法开始", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(error ?? "") }
    }
    private func stat(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text("\(value)").font(.title2.bold()).foregroundStyle(.indigo); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func startReview(_ style: GradingStyle) {
        do { activeID = try store.createFormalReview(style: style) } catch { self.error = error.localizedDescription }
    }
}

struct DictationEditorView: View {
    @Environment(LabStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var sessionID: UUID?
    @State private var title = ""
    @State private var type: ContentType = .phrase
    @State private var date = Date()
    @State private var source = ""
    @State private var text = ""
    @State private var shuffle = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                TextField("计划标题（可选）", text: $title)
                Picker("内容类型", selection: $type) { ForEach(ContentType.allCases) { Text($0.title).tag($0) } }
                DatePicker("计划日期", selection: $date, displayedComponents: .date)
                TextField("默认来源（教材／单元）", text: $source)
                Toggle("保存时打乱顺序", isOn: $shuffle)
            }
            Section {
                TextEditor(text: $text).frame(minHeight: 230).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("dictation.lines")
                if let rows = try? ParsedLearningLine.parse(text) { Text("共 \(rows.count) 条").font(.caption).foregroundStyle(.secondary) }
                PasteButton(payloadType: String.self) { values in text = values.joined(separator: "\n") }
            } header: { Text("批量录入") } footer: { Text("每行一条，格式：内容 | 提示或释义 | 来源。后两项可省略。英语单词未填写释义时，优先使用离线词典补全。背诵可整句录入。") }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .navigationTitle(sessionID == nil ? "新增听写计划" : "编辑听写计划").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存计划") {
                    do {
                        let rows = try ParsedLearningLine.parse(text).map { row -> ParsedLearningLine in
                            var row = row
                            if row.source.isEmpty { row.source = source }
                            if type == .word && row.prompt.isEmpty { row.prompt = EnglishGlossService.shared.lookup(text: row.content)?.translation ?? "" }
                            return row
                        }
                        _ = try store.saveDictation(id: sessionID, title: title, type: type, date: date, rows: rows, shuffle: shuffle)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            guard let sessionID, let session = store.state.sessions.first(where: { $0.id == sessionID }) else { return }
            title = session.title; date = session.scheduledDate; type = ContentType(rawValue: session.typeRawValue) ?? .phrase
            text = store.entries(for: sessionID).map { ParsedLearningLine(content: $0.content, prompt: $0.prompt, source: $0.source).serialized }.joined(separator: "\n")
        }
    }
}

struct BulkItemView: View {
    @Environment(LabStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var type: ContentType = .phrase
    @State private var text = ""
    @State private var source = ""
    @State private var message: String?
    @State private var completed = false
    var body: some View {
        Form {
            Picker("内容类型", selection: $type) { ForEach(ContentType.allCases) { Text($0.title).tag($0) } }
            TextField("默认来源（可选）", text: $source)
            Section {
                TextEditor(text: $text).frame(minHeight: 260).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("library.batch-lines")
                PasteButton(payloadType: String.self) { text = $0.joined(separator: "\n") }
            } header: { Text("每行：内容 | 提示 | 来源") }
        }
        .navigationTitle("批量录入题库").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("导入题库") {
                do {
                    let rows = try ParsedLearningLine.parse(text).map { row -> ParsedLearningLine in
                        var row = row; if row.source.isEmpty { row.source = source }
                        if type == .word && row.prompt.isEmpty { row.prompt = EnglishGlossService.shared.lookup(text: row.content)?.translation ?? "" }
                        return row
                    }
                    let count = try store.addItems(type: type, rows: rows)
                    completed = true; message = "新增 \(count) 条，已有的重复内容跳过 \(rows.count - count) 条。"
                } catch { completed = false; message = error.localizedDescription }
            }.disabled(text.isEmpty) }
        }
        .alert(completed ? "录入完成" : "未能录入", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了") { if completed { dismiss() } }
        } message: { Text(message ?? "") }
    }
}
