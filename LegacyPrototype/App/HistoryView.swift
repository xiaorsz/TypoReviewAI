import SwiftUI
import CoachCore

struct HistoryView: View {
    @Environment(LabStore.self) private var store
    var body: some View {
        List {
            Section { NavigationLink { CoachLogView() } label: { Label("教练执行记录", systemImage: "sparkles") } }
            Section("全部听写与判定") {
                if store.state.sessions.isEmpty { Text("完成练习后，可以在这里回看结果。") .foregroundStyle(.secondary) }
                ForEach(store.state.sessions.sorted { $0.scheduledDate > $1.scheduledDate }) { session in
                    NavigationLink { SessionDetailView(sessionID: session.id) } label: { SessionRow(session: session) }
                }
            }
            Section {
                Text("\(store.state.records.count) 条复习记录，其中包含导入的历史。实验版不计积分。") .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("练习记录")
    }
}

struct CoachLogView: View {
    @Environment(LabStore.self) private var store
    var body: some View {
        List {
            if store.state.logs.isEmpty { ContentUnavailableView("教练还没有执行记录", systemImage: "list.bullet.clipboard", description: Text("运行后会显示查询、实际保存的安排、失败原因与调用用量。")) }
            ForEach(store.state.logs.reversed()) { log in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Badge(text: log.kind, color: log.kind == "停止" || log.kind == "工具未执行" ? .orange : .indigo); Spacer(); Text(log.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Text(log.message).font(.subheadline).textSelection(.enabled)
                    Text("运行 \(log.runID.uuidString.prefix(8))").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }.padding(.vertical, 6)
            }
        }.navigationTitle("教练执行记录").navigationBarTitleDisplayMode(.inline)
    }
}
