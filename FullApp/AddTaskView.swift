import SwiftUI
import SwiftData
import WidgetKit

struct AddTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var existingTask: TaskItem?

    @State private var title = ""
    @State private var note = ""
    @State private var timingMode: TaskTimingMode = .scheduled
    @State private var recurrenceKind: TaskRecurrence.Kind = .once
    @State private var selectedWeekdays: Set<Int> = []
    @State private var skipPolicy: TaskSkipPolicy = .skippable
    @State private var startDate: Date = .now
    @State private var endDate: Date = .now
    @State private var deadline: Date = .now
    @State private var hasEndDate = false
    @State private var showSaveToast = false
    @State private var persistenceErrorMessage: String?

    init(task: TaskItem? = nil) {
        self.existingTask = task
        if let task {
            _title = State(initialValue: task.title)
            _note = State(initialValue: task.note)
            _timingMode = State(initialValue: task.timingMode)
            _recurrenceKind = State(initialValue: task.recurrence.kind)
            _selectedWeekdays = State(initialValue: Set(task.recurrence.weekdays))
            _skipPolicy = State(initialValue: task.skipPolicy)
            _startDate = State(initialValue: task.startDate)
            _endDate = State(initialValue: task.endDate ?? task.startDate)
            _deadline = State(initialValue: task.deadline ?? task.startDate)
            _hasEndDate = State(initialValue: task.endDate != nil)
        }
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty
    }

    private let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                introCard
                infoCard
                timingModeCard
                if timingMode == .flexibleDeadline {
                    deadlineCard
                } else {
                    recurrenceCard
                    policyCard
                }
            }
            .padding(20)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .toast("已保存 ✓", isPresented: $showSaveToast, duration: 0.8)
        .alert("保存失败", isPresented: Binding(get: { persistenceErrorMessage != nil }, set: { if !$0 { persistenceErrorMessage = nil } })) {
            Button("知道了") { persistenceErrorMessage = nil }
        } message: {
            Text(persistenceErrorMessage ?? "发生未知错误")
        }
        .navigationTitle(existingTask == nil ? "新增任务" : "编辑任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(existingTask == nil ? "保存" : "完成") {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(existingTask == nil ? "新增任务" : "编辑任务")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text(
                timingMode == .flexibleDeadline
                    ? "设置截止日期，创建后随时都可以完成。"
                    : "任务可以设置为单次或按周期重复。"
            )
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
                        colors: [.blue.opacity(0.85), .indigo.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label("任务名称", systemImage: "star.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                
                TextField("例如：每天朗读课文 20 分钟", text: $title)
                    .font(.title2.weight(.medium))
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Label("备注 (可选)", systemImage: "tag.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.purple)
                
                TextField("补充说明", text: $note)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var timingModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("任务类型", systemImage: "square.grid.2x2")
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)

            Picker("任务类型", selection: $timingMode) {
                ForEach(TaskTimingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(existingTask != nil)

            Text(
                timingMode == .flexibleDeadline
                    ? "近期计划会在截止前一个月显示在首页、Widget 和大屏看板。"
                    : "普通任务按指定日期或重复规则出现在今日任务中。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if existingTask != nil {
                Text("任务创建后不能更改类型。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var deadlineCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("截止日期", systemImage: "calendar.badge.exclamationmark")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.orange)

            DatePicker(
                "计划截止",
                selection: $deadline,
                in: deadlineDateRange,
                displayedComponents: .date
            )
            .font(.subheadline.weight(.medium))

            Text("进入提醒期后会持续显示；截止后未完成将标记为逾期，直到完成或手动归档。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var deadlineDateRange: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: .now)
        let lowerBound = existingTask?.deadline.map {
            min(Calendar.current.startOfDay(for: $0), today)
        } ?? today
        let upperBound = Calendar.current.date(byAdding: .year, value: 20, to: today) ?? .distantFuture
        return lowerBound...upperBound
    }

    private var recurrenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("重复规则")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("重复", selection: $recurrenceKind) {
                    ForEach(TaskRecurrence.Kind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            
            if recurrenceKind == .weekly {
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Label("选择周几执行", systemImage: "calendar.badge.clock")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)

                    HStack(spacing: 8) {
                        ForEach(0..<7, id: \.self) { index in
                            let displayOrder = (index + 1) % 7 + 1 // Display Mon first
                            let actualWeekday = displayOrder
                            let label = weekdayNames[actualWeekday - 1]

                            Button {
                                if selectedWeekdays.contains(actualWeekday) {
                                    selectedWeekdays.remove(actualWeekday)
                                } else {
                                    selectedWeekdays.insert(actualWeekday)
                                }
                            } label: {
                                Text(label)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        selectedWeekdays.contains(actualWeekday)
                                            ? Color.accentColor
                                            : Color(uiColor: .secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .foregroundStyle(selectedWeekdays.contains(actualWeekday) ? .white : .primary)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var policyCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("过期处理")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("跳过策略", selection: $skipPolicy) {
                    ForEach(TaskSkipPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            
            Text(skipPolicy == .skippable
                 ? "提示：过期未完成就自动作废，不再出现。"
                 : "提示：过期未完成会累积到当天，直到手动完成。")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if recurrenceKind == .once {
                    DatePicker("生效日期", selection: $startDate, displayedComponents: .date)
                        .font(.subheadline.weight(.medium))
                } else {
                    Label("生效范围", systemImage: "calendar")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)

                    DatePicker("开始日期", selection: $startDate, displayedComponents: .date)
                        .font(.subheadline.weight(.medium))

                    Toggle("设置结束日期", isOn: $hasEndDate.animation())
                        .font(.subheadline.weight(.medium))

                    if hasEndDate {
                        DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: .date)
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .onChange(of: startDate) { _, newStartDate in
            if endDate < newStartDate {
                endDate = newStartDate
            }
        }
    }

    private func save() {
        let actionID = String(UUID().uuidString.prefix(6))
        let targetTitle = trimmedTitle
        let recurrence: TaskRecurrence
        if timingMode == .flexibleDeadline {
            recurrence = .once
        } else {
            switch recurrenceKind {
            case .once:
                recurrence = .once
            case .daily:
                recurrence = .daily
            case .weekly:
                recurrence = .weekly(Array(selectedWeekdays))
            }
        }
        let resolvedSkipPolicy: TaskSkipPolicy = timingMode == .flexibleDeadline ? .unskippable : skipPolicy
        let resolvedDeadline = timingMode == .flexibleDeadline
            ? Calendar.current.startOfDay(for: deadline)
            : nil

        #if DEBUG
        DebugPerf.mark(
            "AddTaskView save begin id=\(actionID) existing=\(existingTask != nil) title=\(targetTitle) recurrence=\(recurrence.kind.rawValue) start=\(debugDateLabel(startDate)) end=\(debugDateLabel(recurrenceKind == .once ? nil : (hasEndDate ? endDate : nil))) hasEnd=\(hasEndDate)"
        )
        #endif

        if let duplicateTask = duplicateTask(withTitle: targetTitle) {
            #if DEBUG
            DebugPerf.mark(
                "AddTaskView save duplicate title blocked id=\(actionID) title=\(targetTitle) duplicateTaskID=\(duplicateTask.id.uuidString.prefix(6))"
            )
            #endif
            persistenceErrorMessage = "任务名称“\(targetTitle)”已经存在，请换一个标题。"
            return
        }

        let savedTask: TaskItem

        if let existingTask {
            existingTask.title = targetTitle
            existingTask.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            existingTask.recurrence = recurrence
            existingTask.skipPolicy = resolvedSkipPolicy
            existingTask.timingMode = timingMode
            if timingMode == .scheduled {
                existingTask.startDate = startDate
            }
            existingTask.endDate = timingMode == .scheduled && recurrenceKind != .once && hasEndDate
                ? endDate
                : nil
            existingTask.deadline = resolvedDeadline
            if recurrence.kind == .once, existingTask.pauseStartedAt != nil {
                existingTask.resume(on: .now)
            }
            existingTask.updatedAt = .now
            savedTask = existingTask
        } else {
            let task = TaskItem(
                title: targetTitle,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                recurrence: recurrence,
                skipPolicy: resolvedSkipPolicy,
                timingMode: timingMode,
                startDate: timingMode == .flexibleDeadline
                    ? Calendar.current.startOfDay(for: .now)
                    : startDate,
                endDate: timingMode == .scheduled && recurrenceKind != .once && hasEndDate
                    ? endDate
                    : nil,
                deadline: resolvedDeadline
            )
            modelContext.insert(task)
            savedTask = task
        }

        do {
            try ensureTodayExecutionRecordIfNeeded(for: savedTask)
            try modelContext.save()
            #if DEBUG
            let taskID = savedTask.id
            let persistedTask = try? modelContext.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate<TaskItem> { $0.id == taskID })).first
            let persistedExecutions = (try? modelContext.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate<TaskExecutionRecord> { $0.taskID == taskID }))) ?? []
            let today = TaskExecutionSupport.day(for: .now)
            let todayExecution = persistedExecutions.first { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: today) }
            DebugPerf.mark(
                "AddTaskView save success id=\(actionID) taskID=\(taskID.uuidString.prefix(6)) archived=\(persistedTask?.isArchived ?? savedTask.isArchived) start=\(debugDateLabel(persistedTask?.startDate ?? savedTask.startDate)) end=\(debugDateLabel(persistedTask?.endDate ?? savedTask.endDate)) executions=\(persistedExecutions.count) todayExecution=\(todayExecution != nil) todayStatus=\(todayExecution?.status.rawValue ?? "nil")"
            )
            #endif
            WidgetCenter.shared.reloadAllTimelinesInBackground()
            AppDataChangeCenter.post()
        } catch {
            #if DEBUG
            DebugPerf.mark("AddTaskView save failed id=\(actionID) error=\(error.localizedDescription)")
            #endif
            persistenceErrorMessage = error.localizedDescription
            return
        }

        withAnimation {
            showSaveToast = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dismiss()
        }
    }

    private func ensureTodayExecutionRecordIfNeeded(for task: TaskItem) throws {
        guard task.timingMode == .scheduled else { return }
        let today = TaskExecutionSupport.day(for: .now)
        let isScheduledToday = task.scheduledOccurrenceDates(upTo: today).contains {
            Calendar.current.isDate($0, inSameDayAs: today)
        }
        #if DEBUG
        DebugPerf.mark(
            "AddTaskView ensureTodayRecord taskID=\(task.id.uuidString.prefix(6)) scheduledToday=\(isScheduledToday) start=\(debugDateLabel(task.startDate)) end=\(debugDateLabel(task.endDate)) archived=\(task.isArchived)"
        )
        #endif
        guard isScheduledToday else { return }

        let taskID = task.id
        let descriptor = FetchDescriptor<TaskExecutionRecord>(
            predicate: #Predicate<TaskExecutionRecord> { $0.taskID == taskID }
        )
        let existingExecutions = try modelContext.fetch(descriptor)
        let record = TaskExecutionSupport.ensureExecutionRecord(
            for: task,
            occurrenceDate: today,
            existingExecutions: existingExecutions,
            modelContext: modelContext
        )
        #if DEBUG
        DebugPerf.mark(
            "AddTaskView ensured today record taskID=\(taskID.uuidString.prefix(6)) existingExecutions=\(existingExecutions.count) recordID=\(record.id.uuidString.prefix(6)) status=\(record.status.rawValue) occurrence=\(debugDateLabel(record.occurrenceDate))"
        )
        #endif
    }

    private func duplicateTask(withTitle title: String) -> TaskItem? {
        let normalizedTargetTitle = normalizedTaskTitle(title)
        guard !normalizedTargetTitle.isEmpty else { return nil }

        let allTasks = (try? modelContext.fetch(FetchDescriptor<TaskItem>())) ?? []
        return allTasks.first { task in
            if let existingTask, task.id == existingTask.id {
                return false
            }
            return normalizedTaskTitle(task.title) == normalizedTargetTitle
        }
    }

    private func normalizedTaskTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private func debugDateLabel(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return date.formatted(.dateTime.year().month().day().hour().minute().second())
    }
}
