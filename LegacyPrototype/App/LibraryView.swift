import SwiftUI
import CoachCore

struct LibraryView: View {
    @Environment(LabStore.self) private var store
    @State private var search = ""
    @State private var adding = false
    @State private var selectedSubject: Subject = .chinese
    private var items: [ReviewItem] {
        store.state.items.filter { selectedSubject.contains($0.typeRawValue) && (search.isEmpty || $0.content.localizedCaseInsensitiveContains(search) || $0.prompt.localizedCaseInsensitiveContains(search)) }
            .sorted { $0.nextReviewAt < $1.nextReviewAt }
    }
    var body: some View {
        List {
            Section {
                Picker("科目", selection: $selectedSubject) { ForEach(Subject.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            }
            if items.isEmpty {
                ContentUnavailableView("还没有这些题目", systemImage: "books.vertical", description: Text("导入备份或点右上角添加。"))
            }
            ForEach(items) { item in
                NavigationLink { ItemDetailView(itemID: item.id) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(item.content).font(.headline); Spacer(); if item.isPriority { Badge(text: "重点", color: .orange) } }
                        if !item.prompt.isEmpty { Text(item.prompt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        Text("阶段 \(item.stage) · \(item.nextReviewAt == .distantFuture ? "已掌握" : "下次 " + item.nextReviewAt.formatted(date: .abbreviated, time: .omitted))") .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
        }
        .searchable(text: $search, prompt: "搜索内容或提示")
        .navigationTitle("题库")
        .toolbar { Button { adding = true } label: { Label("添加题目", systemImage: "plus") } }
        .sheet(isPresented: $adding) { NavigationStack { AddItemView() }.environment(store) }
    }
}

struct AddItemView: View {
    @Environment(LabStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var subject: Subject = .chinese
    @State private var content = ""
    @State private var prompt = ""
    @State private var error: String?
    var body: some View {
        Form {
            Picker("科目", selection: $subject) { ForEach(Subject.allCases) { Text($0.title).tag($0) } }
            TextField("正确的字词／单词", text: $content).autocorrectionDisabled()
            TextField("提示、拼音或中文释义（可选）", text: $prompt, axis: .vertical)
            if let error { Text(error).foregroundStyle(.orange) }
        }
        .navigationTitle("添加题目").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do { try store.addItem(subject: subject, content: content, prompt: prompt); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

struct ItemDetailView: View {
    @Environment(LabStore.self) private var store
    let itemID: UUID
    @State private var practiceID: UUID?
    @State private var error: String?
    private var item: ReviewItem? { store.state.items.first { $0.id == itemID } }
    var body: some View {
        List {
            if let item {
                Section {
                    Text(item.content).font(.largeTitle.bold())
                    if !item.prompt.isEmpty { Text(item.prompt) }
                    Text("\(item.typeRawValue) · 阶段 \(item.stage) · 连续答错 \(item.consecutiveWrongCount) 次") .font(.subheadline).foregroundStyle(.secondary)
                    if !item.source.isEmpty { Text("来源：\(item.source)").font(.caption).foregroundStyle(.secondary) }
                    if !item.note.isEmpty { Text(item.note).font(.caption).foregroundStyle(.secondary) }
                    Button("听写这一条") {
                        do { practiceID = try store.createManualPractice(itemID: itemID) } catch { self.error = error.localizedDescription }
                    }
                }
                Section("学习历史") {
                    let records = store.state.records.filter { $0.itemID == itemID }.sorted { $0.reviewedAt > $1.reviewedAt }
                    if records.isEmpty { Text("还没有复习记录。") .foregroundStyle(.secondary) }
                    ForEach(records) { record in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(record.reviewedAt.formatted(date: .abbreviated, time: .shortened))
                                Text("阶段 \(record.oldStage) → \(record.newStage)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Badge(text: record.resultRawValue == "correct" ? "正确" : "错误", color: record.resultRawValue == "correct" ? LabStyle.teal : .orange)
                        }
                    }
                }
            }
        }
        .navigationTitle("题目详情").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(get: { practiceID != nil }, set: { if !$0 { practiceID = nil } })) {
            if let practiceID { SessionDetailView(sessionID: practiceID) }
        }
        .alert("未能开始练习", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(error ?? "") }
    }
}
