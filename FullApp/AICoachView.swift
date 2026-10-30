import SwiftUI
import SwiftData
import CoachCore

struct AICoachView: View {
    @Environment(AICoachCoordinator.self) private var coach
    @Environment(AppSettingsStore.self) private var settings
    @Environment(\.modelContext) private var context
    @Query private var dailyPlans: [ReviewDailyPlan]
    @State private var configuration = CoachCore.CoachConfiguration()
    @State private var hasLoadedConfiguration = false
    @State private var keyController = LabAPIKeyController.shared
    @State private var notice: String?
    @State private var isPreparingRun = false

    init() {
        let today = ReviewDailyPlan.dayKey(for: .now)
        var descriptor = FetchDescriptor<ReviewDailyPlan>(
            predicate: #Predicate { $0.dayKey >= today && $0.coachSubjectRawValue != "" },
            sortBy: [SortDescriptor(\.dayKey)]
        )
        descriptor.fetchLimit = 8
        _dailyPlans = Query(descriptor)
    }
    var body: some View {
        Form {
            Section {
                Label("AI 家庭复习教练", systemImage: "sparkles").font(.title3.bold())
                Text("AI 统一选择每天的复习内容和顺序，沿用原有复习间隔。听写保留为独立录入入口，判定后进入后续复习。AI 不可用时按原规则安排。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Picker("科目", selection: $configuration.subject) { ForEach(CoachCore.Subject.allCases) { Text($0.title).tag($0) } }
                    .accessibilityIdentifier("coach.subject")
                Stepper("每日复习共 \(configuration.dailyLimit) 题以内", value: $configuration.dailyLimit, in: 1...50)
                Toggle("授权 AI 安排每日复习", isOn: $configuration.isEnabled)
                    .accessibilityIdentifier("coach.authorize")
                Picker("模型", selection: $configuration.model) {
                    Text("DeepSeek Flash").tag("deepseek-flash")
                    Text("DeepSeek V4 Pro").tag("deepseek-v4-pro")
                }
                Button("保存教练设置") {
                    do {
                        try coach.saveConfiguration(configuration, context: context, settings: settings, startAutomatically: false)
                        notice = "教练设置已保存。"
                    } catch { notice = error.localizedDescription }
                }
            } header: { Text("每日复习安排") } footer: {
                Text("与设置中的每日复习题量共用一个上限，已完成的复习也计入。听写录入不占复习题量；当天已听写判定的内容不再重复复习。未授权科目按原规则安排，同样受总上限约束。")
            }
            .disabled(isPreparingRun)
            Section {
                SecureField("DeepSeek API Key", text: Binding(get: { keyController.draft }, set: { keyController.edit($0) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(keyController.isBusy || isPreparingRun)
                if keyController.operation == .loading { ProgressView("正在读取本机 Key…") }
                Button("保存 API Key") {
                    Task {
                        do {
                            try await keyController.save()
                            notice = "API Key 已独立保存在本机。"
                        } catch { notice = error.localizedDescription }
                    }
                }.disabled(keyController.isBusy || isPreparingRun)
            } header: { Text("AI 接入") } footer: {
                Text("与本实验 App 的 AI 小结共用独立的本机 Key。点击检查时也会保存当前 Key，供后续自动安排使用。启用后会向 DeepSeek 发送所选科目的题目与学习记录，调用由该 Key 账户计费。")
            }
            Section("安排与执行") {
                if isPreparingRun { ProgressView("正在保存 API Key…") }
                if coach.isRunning { ProgressView(coach.agent?.isRunning == true ? (coach.agent?.status ?? coach.status) : coach.status) }
                if let error = coach.error { Text(error).foregroundStyle(.orange) }
                Text(coach.status).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("coach.status")
                Button("检查记录并安排复习") {
                    let config = configuration
                    isPreparingRun = true
                    Task {
                        defer { isPreparingRun = false }
                        do {
                            // Persist before authorizing/running, so later
                            // automatic checks use the same Key as this run.
                            let key: String?
                            if config.isEnabled { key = try await keyController.save() }
                            else { key = nil }
                            try coach.saveConfiguration(config, context: context, settings: settings, startAutomatically: false)
                            coach.run(context: context, settings: settings, apiKey: key, manual: true)
                        } catch { notice = error.localizedDescription }
                    }
                }
                .accessibilityIdentifier("coach.run")
                .disabled(coach.isRunning || keyController.isBusy || isPreparingRun)
                Button("停止本轮安排") { coach.cancel() }.disabled(!coach.isRunning)
                Text("安排会直接显示在首页「开始今天复习」中。进入复习后，本日清单锁定，AI 只调整后续日期。")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink { DeferredDictationHomeView() } label: { Label("独立听写录入", systemImage: "text.book.closed") }
            }
            if let store = coach.store {
                Section("已保存的每日复习安排") {
                    let plans = dailyPlans
                    if plans.isEmpty { Text("暂用原规则安排。授权并成功生成后，AI 清单将替换首页的每日复习清单。") .foregroundStyle(.secondary) }
                    ForEach(plans) { plan in
                        ReviewPlanSummaryView(title: "\(plan.dayKey) · \(plan.itemIDs.count) 题",
                            subtitle: plan.startedAt == nil ? "AI 已安排" : "已开始，清单已锁定",
                            rationale: plan.coachRationale).padding(.vertical, 5)
                    }
                }
                Section {
                    NavigationLink("最近执行记录") { CoachExecutionLogView() }
                        .accessibilityIdentifier("coach.logs")
                }

            }
        }
        .navigationTitle("AI 教练").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !hasLoadedConfiguration else { return }
            configuration = coach.store?.state.configuration ?? CoachCore.CoachConfiguration()
            configuration.dailyLimit = settings.dailyLimit
            hasLoadedConfiguration = true
        }
        .task {
            do { try await keyController.loadIfNeeded() }
            catch is CancellationError { }
            catch { notice = error.localizedDescription }
        }
        .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(notice ?? "") }
    }
}

private struct CoachExecutionLogView: View {
    @Environment(AICoachCoordinator.self) private var coach
    var body: some View {
        List {
            if let logs = coach.store?.state.logs, !logs.isEmpty {
                ForEach(Array(logs.suffix(30).reversed())) { log in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(log.kind) · \(log.date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(log.message).font(.subheadline).textSelection(.enabled)
                    }
                }
            } else { Text("还没有执行记录。") }
        }
        .navigationTitle("教练执行记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}
