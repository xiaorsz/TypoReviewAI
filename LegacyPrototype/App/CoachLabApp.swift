import SwiftUI
import CoachCore

@main
struct CoachLabApp: App {
    @State private var store: LabStore?
    @State private var startupError: String?

    init() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var url = support.appendingPathComponent("cc.xiaorsz.dictation-coach-lab", isDirectory: true).appendingPathComponent("lab.json")
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-test-\(UUID()).json")
                try LabKeychain.delete()
            }
            #endif
            _store = State(initialValue: try LabStore(fileURL: url))
        } catch { _startupError = State(initialValue: error.localizedDescription) }
    }
    var body: some Scene {
        WindowGroup {
            if let store { LabRoot(store: store).environment(store).tint(.indigo) }
            else {
                ContentUnavailableView("实验数据未能打开", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text((startupError ?? "未知错误") + "\n已有文件已保留，请检查设备存储后重新打开应用。"))
            }
        }
    }
}

struct LabRoot: View {
    let store: LabStore
    @State private var agent: CoachAgent
    @Environment(\.scenePhase) private var phase
    init(store: LabStore) { self.store = store; _agent = State(initialValue: CoachAgent(store: store)) }
    var body: some View {
        TabView {
            NavigationStack { TodayView() }.tabItem { Label("今日教练", systemImage: "sparkles") }
            NavigationStack { LibraryView() }.tabItem { Label("题库", systemImage: "books.vertical") }
            NavigationStack { LearningHubView() }.tabItem { Label("听写复习", systemImage: "pencil.and.list.clipboard") }
            NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .environment(agent)
        .task { startCoach() }
        .onChange(of: phase) { _, value in
            if value == .active { startCoach() } else { agent.cancel() }
        }
        .onChange(of: store.state.configuration) { _, value in
            agent.cancel()
            if value.isEnabled { startCoach() }
        }
        .onChange(of: store.state.pendingFeedbackSessionIDs) { _, _ in startPendingFeedback() }
        .onChange(of: agent.isRunning) { _, running in if !running && agent.lastError == nil { startPendingFeedback() } }
    }
    private func startCoach() {
        guard store.state.configuration.isEnabled else { return }
        agent.start(apiKey: (try? LabKeychain.load()) ?? "")
    }
    private func startPendingFeedback() {
        guard phase == .active, store.state.configuration.isEnabled,
              store.state.pendingFeedbackSessionIDs.contains(where: { id in
                  store.state.sessions.contains { $0.id == id && store.state.configuration.subject.contains($0.typeRawValue) }
              }) else { return }
        startCoach()
    }
}
