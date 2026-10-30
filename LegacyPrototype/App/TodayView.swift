import SwiftUI
import CoachCore

struct TodayView: View {
    @Environment(LabStore.self) private var store
    @Environment(CoachAgent.self) private var agent
    private var today: [DictationSession] {
        store.state.sessions.filter { $0.cancelledAt == nil && Calendar.current.startOfDay(for: $0.scheduledDate) <= Calendar.current.startOfDay(for: .now) && $0.reviewedAt == nil }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }
    private var upcoming: [DictationSession] {
        store.state.sessions.filter { $0.cancelledAt == nil && Calendar.current.startOfDay(for: $0.scheduledDate) > Calendar.current.startOfDay(for: .now) }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Label("听写 AI 教练", systemImage: "sparkles").font(.subheadline.weight(.semibold)); Spacer(); Text("独立实验版").font(.caption) }
                    Text(store.state.configuration.childName.isEmpty ? "每天一点，\n把易错练熟。" : "\(store.state.configuration.childName)，\n今天一起练熟一点。")
                        .font(.system(size: 32, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                    Text("根据真实学习记录选题，练完再调整。") .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: 24) {
                        metric("题库", value: "\(store.state.items.count)")
                        metric("待练习", value: "\(today.count)")
                        metric("每日上限", value: "\(store.state.configuration.dailyLimit)题")
                    }
                }
                .foregroundStyle(.white).padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [LabStyle.ink, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26))

                Panel {
                    HStack {
                        NavigationLink { LearningHubView() } label: { Label("到期复习 \(store.dueItems().count) 题", systemImage: "arrow.clockwise") }
                        Spacer()
                        NavigationLink { LearningHubView() } label: { Label("听写安排", systemImage: "calendar") }
                    }.font(.subheadline.weight(.semibold))
                }
                Panel {
                    HStack { Label("教练今日安排", systemImage: "sparkles").font(.headline); Spacer(); Badge(text: store.state.configuration.isEnabled ? "已授权" : "未启用", color: store.state.configuration.isEnabled ? LabStyle.teal : .secondary) }
                    Text("\(store.state.configuration.subject.title) · 每日最多 \(store.state.configuration.dailyLimit) 题") .font(.subheadline).foregroundStyle(.secondary)
                    if agent.isRunning { ProgressView(agent.status).font(.subheadline) }
                    else if !agent.status.isEmpty { Text(agent.status).font(.subheadline).foregroundStyle(LabStyle.teal) }
                    if let error = agent.lastError { Text(error).font(.subheadline).foregroundStyle(.orange) }
                    if store.state.items.isEmpty {
                        Text("先在设置导入原 App 的 JSON 备份，或到题库添加内容。导入的是独立副本。") .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button {
                        agent.start(apiKey: (try? LabKeychain.load()) ?? "")
                    } label: {
                        Label(agent.lastError == nil ? "检查并安排练习" : "重试教练", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent).disabled(agent.isRunning || !store.state.configuration.isEnabled || store.state.items.isEmpty)
                    if !store.state.configuration.isEnabled { Text("在设置中选择科目、保存 API Key 并授权后开始。") .font(.caption).foregroundStyle(.secondary) }
                    NavigationLink("查看教练执行记录") { CoachLogView() }.font(.subheadline)
                }
                Text("待开始与继续练习").font(.title3.bold()).padding(.top, 4)
                if today.isEmpty {
                    Panel { Label("暂时没有待练习内容", systemImage: "checkmark.circle").foregroundStyle(.secondary); Text("让教练检查安排，或从题库开始一条练习。") .font(.subheadline).foregroundStyle(.secondary) }
                }
                ForEach(today) { session in
                    NavigationLink { SessionDetailView(sessionID: session.id) } label: {
                        Panel {
                            SessionRow(session: session)
                            if let plan = store.state.plans.first(where: { $0.sessionID == session.id }) {
                                Text(plan.rationale).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Label("开始／继续", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                        }
                    }.buttonStyle(.plain)
                }
                if !upcoming.isEmpty {
                    Text("后续安排").font(.title3.bold())
                    ForEach(upcoming.prefix(7)) { session in
                        NavigationLink { SessionDetailView(sessionID: session.id) } label: { Panel { SessionRow(session: session) } }.buttonStyle(.plain)
                    }
                }
            }.padding(20).frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("今日教练").toolbar(.hidden, for: .navigationBar)
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(value).font(.title3.bold()); Text(title).font(.caption).foregroundStyle(.white.opacity(0.7)) }
    }
}
