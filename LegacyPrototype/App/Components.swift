import SwiftUI
import CoachCore

enum LabStyle {
    static let ink = Color(red: 0.12, green: 0.16, blue: 0.29)
    static let teal = Color(red: 0.05, green: 0.43, blue: 0.43)
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct Badge: View {
    let text: String
    var color: Color = .indigo
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5).background(color.opacity(0.09), in: Capsule())
    }
}

struct SessionRow: View {
    @Environment(LabStore.self) private var store
    let session: DictationSession
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(session.title).font(.headline)
                Spacer()
                if session.cancelledAt != nil { Badge(text: "已取消", color: .secondary) }
                else if session.reviewedAt != nil { Badge(text: "已判定", color: LabStyle.teal) }
                else { Badge(text: session.startedAt == nil ? "待练习" : "进行中") }
            }
            Text("\(session.scheduledDate.formatted(date: .abbreviated, time: .omitted)) · \(store.entries(for: session.id).count) 题 · \(store.state.plans.contains { $0.sessionID == session.id } ? "AI 教练" : "原有听写／手动练习")")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

struct SessionDetailView: View {
    @Environment(LabStore.self) private var store
    @Environment(CoachAgent.self) private var agent
    let sessionID: UUID
    @State private var showPractice = false
    @State private var error: String?
    @State private var confirmCancel = false
    private var session: DictationSession? { store.state.sessions.first { $0.id == sessionID } }
    var body: some View {
        List {
            if let session {
                Section {
                    SessionRow(session: session)
                    if let plan = store.state.plans.first(where: { $0.sessionID == sessionID }) {
                        Label("教练的选题依据", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                        Text(plan.rationale).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section("练习内容") {
                    ForEach(store.entries(for: sessionID)) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.content)
                                if !entry.prompt.isEmpty { Text(entry.prompt).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if entry.resultRawValue != "未判定" { Badge(text: entry.resultRawValue, color: entry.resultRawValue == "正确" ? LabStyle.teal : .orange) }
                        }
                    }
                }
                if session.reviewedAt == nil && session.cancelledAt == nil {
                    Section {
                        Button(session.startedAt == nil ? "开始听写" : "继续练习／判定") {
                            do { try store.begin(sessionID); showPractice = true } catch { self.error = error.localizedDescription }
                        }
                        .disabled(Calendar.current.startOfDay(for: session.scheduledDate) > Calendar.current.startOfDay(for: .now) || store.entries(for: sessionID).isEmpty)
                        if session.isUntouched && store.state.plans.contains(where: { $0.sessionID == sessionID }) {
                            Button("取消这组 AI 计划", role: .destructive) { confirmCancel = true }
                        }
                    } footer: { Text("孩子在纸上书写，家长确认对错。未来的计划到日期后可开始。") }
                }
                if session.reviewedAt != nil {
                    Section("后续安排") {
                        if agent.isRunning { ProgressView("教练正在结合结果调整…") }
                        if let message = agent.lastError { Text(message).foregroundStyle(.orange) }
                        let followUps = store.state.sessions.filter { candidate in candidate.id != sessionID && candidate.cancelledAt == nil && candidate.scheduledDate > Calendar.current.startOfDay(for: .now) && store.state.plans.contains { plan in plan.sessionID == candidate.id } }
                        ForEach(followUps.sorted { $0.scheduledDate < $1.scheduledDate }) { next in
                            NavigationLink { SessionDetailView(sessionID: next.id) } label: { SessionRow(session: next) }
                        }
                        if followUps.isEmpty && !agent.isRunning { Text("尚未保存后续 AI 计划。启用教练后，可处理本次新判定。") .foregroundStyle(.secondary) }
                        if store.state.pendingFeedbackSessionIDs.contains(sessionID) {
                            Button("处理本次判定／重试") { agent.start(apiKey: (try? LabKeychain.load()) ?? "") }
                                .disabled(agent.isRunning || !store.state.configuration.isEnabled)
                        }
                    }
                }
            } else { Text("这组练习已不存在。") }
        }
        .navigationTitle("听写计划").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPractice) { NavigationStack { PracticeView(sessionID: sessionID) }.environment(store).environment(agent) }
        .confirmationDialog("取消这组尚未开始的计划？", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("取消计划", role: .destructive) {
                do { try store.cancel(sessionID) } catch { self.error = error.localizedDescription }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}
