import SwiftUI
import SwiftData
import WidgetKit

struct AddScheduleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var existingSchedule: ScheduleItem?

    @State private var title = ""
    @State private var note = ""
    @State private var startTime: Date = {
        let calendar = Calendar.current
        let now = Date.now
        // Round up to next hour
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        let nextHour = calendar.date(from: components)!.addingTimeInterval(3600)
        return nextHour
    }()
    @State private var endTime: Date = {
        let calendar = Calendar.current
        let now = Date.now
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        let nextHour = calendar.date(from: components)!.addingTimeInterval(7200)
        return nextHour
    }()
    @State private var repeatRule: ScheduleRepeatRule = .once
    @State private var selectedWeekdays: Set<Int> = []
    @State private var effectiveStartDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var effectiveEndDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var hasEffectiveEndDate = false
    @State private var showSaveToast = false
    @State private var activePicker: ActivePicker?

    init(schedule: ScheduleItem? = nil) {
        self.existingSchedule = schedule
        if let schedule {
            _title = State(initialValue: schedule.title)
            _note = State(initialValue: schedule.note)
            _startTime = State(initialValue: schedule.startTime)
            _endTime = State(initialValue: schedule.endTime)
            _repeatRule = State(initialValue: schedule.repeatRule)
            _selectedWeekdays = State(initialValue: Set(schedule.weekdays))
            _effectiveStartDate = State(initialValue: schedule.effectiveStartDate)
            _effectiveEndDate = State(initialValue: schedule.effectiveEndDate ?? schedule.effectiveStartDate)
            _hasEffectiveEndDate = State(initialValue: schedule.effectiveEndDate != nil)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                introCard
                infoCard
                timeCard
                recurrenceCard
                if repeatRule != .once {
                    effectiveRangeCard
                }
            }
            .padding(20)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .toast("已保存 ✓", isPresented: $showSaveToast, duration: 0.8)
        .navigationTitle(existingSchedule == nil ? "新增日程" : "编辑日程")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activePicker) { picker in
            pickerSheet(for: picker)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(existingSchedule == nil ? "保存" : "完成") {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(existingSchedule == nil ? "新增日程" : "编辑日程")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text("设置日程的时间段、重复规则和生效范围。")
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
                        colors: [.indigo.opacity(0.85), .purple.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label("日程名称", systemImage: "calendar.badge.clock")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.indigo)
                
                TextField("例如：英语网课", text: $title)
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

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("时间设置", systemImage: "clock.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.indigo)

            if repeatRule == .once {
                pickerRow(title: "开始时间", value: dateTimeText(startTime)) {
                    activePicker = .startTime
                }

                pickerRow(title: "结束时间", value: dateTimeText(endTime)) {
                    activePicker = .endTime
                }
            } else {
                DatePicker("开始时间", selection: $startTime, displayedComponents: timePickerComponents)
                    .font(.subheadline.weight(.medium))

                DatePicker("结束时间", selection: $endTime, in: startTime..., displayedComponents: timePickerComponents)
                    .font(.subheadline.weight(.medium))
            }

            if repeatRule != .once {
                Text("重复日程只使用这里的时间，生效日期范围请在下方设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if endTime <= startTime {
                Label("结束时间需要晚于开始时间", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .onChange(of: startTime) { _, newStart in
            if endTime <= newStart {
                endTime = newStart.addingTimeInterval(3600)
            }
            if repeatRule != .once {
                effectiveStartDate = Calendar.current.startOfDay(for: newStart)
            }
        }
    }

    private var recurrenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("重复规则")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("重复", selection: $repeatRule) {
                    ForEach(ScheduleRepeatRule.allCases) { rule in
                        Text(rule.rawValue).tag(rule)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            
            if repeatRule == .weekly {
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Label("选择周几执行", systemImage: "calendar.badge.clock")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.indigo)

                    HStack(spacing: 8) {
                        ForEach(0..<7, id: \.self) { index in
                            let displayOrder = (index + 1) % 7 + 1
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
                                            ? Color.indigo
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
        .onChange(of: repeatRule) { _, newRule in
            if newRule != .once {
                let startDay = Calendar.current.startOfDay(for: startTime)
                effectiveStartDate = startDay
                if effectiveEndDate < startDay {
                    effectiveEndDate = startDay
                }
            }
        }
    }

    private var effectiveRangeCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("生效范围", systemImage: "calendar")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.indigo)

            Text("重复日程只会在这个日期范围内出现。")
                .font(.caption)
                .foregroundStyle(.secondary)

            pickerRow(title: "开始日期", value: dateText(effectiveStartDate)) {
                activePicker = .effectiveStartDate
            }

            Toggle("设置结束日期", isOn: $hasEffectiveEndDate.animation())
                .font(.subheadline.weight(.medium))

            if hasEffectiveEndDate {
                pickerRow(title: "结束日期", value: dateText(effectiveEndDate)) {
                    activePicker = .effectiveEndDate
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .onChange(of: effectiveStartDate) { _, newStartDate in
            if effectiveEndDate < newStartDate {
                effectiveEndDate = newStartDate
            }
        }
    }

    private var timePickerComponents: DatePickerComponents {
        repeatRule == .once ? [.date, .hourAndMinute] : .hourAndMinute
    }

    private func save() {
        let weekdaysList = Array(selectedWeekdays)
        let normalizedStartTime = normalizedScheduleDate(from: startTime, on: effectiveStartDate)
        let normalizedEndTime = normalizedScheduleDate(from: endTime, on: effectiveStartDate)
        let normalizedEffectiveStartDate = Calendar.current.startOfDay(for: effectiveStartDate)
        let normalizedEffectiveEndDate = hasEffectiveEndDate ? Calendar.current.startOfDay(for: effectiveEndDate) : nil

        if let existingSchedule {
            existingSchedule.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            existingSchedule.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            existingSchedule.startTime = repeatRule == .once ? startTime : normalizedStartTime
            existingSchedule.endTime = repeatRule == .once ? endTime : normalizedEndTime
            existingSchedule.repeatRule = repeatRule
            existingSchedule.weekdays = weekdaysList
            existingSchedule.effectiveStartDate = repeatRule == .once ? Calendar.current.startOfDay(for: startTime) : normalizedEffectiveStartDate
            existingSchedule.effectiveEndDate = repeatRule == .once ? nil : normalizedEffectiveEndDate
            existingSchedule.updatedAt = .now
        } else {
            let schedule = ScheduleItem(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: repeatRule == .once ? startTime : normalizedStartTime,
                endTime: repeatRule == .once ? endTime : normalizedEndTime,
                repeatRule: repeatRule,
                weekdays: weekdaysList,
                effectiveStartDate: repeatRule == .once ? Calendar.current.startOfDay(for: startTime) : normalizedEffectiveStartDate,
                effectiveEndDate: repeatRule == .once ? nil : normalizedEffectiveEndDate
            )
            modelContext.insert(schedule)
        }

        withAnimation {
            showSaveToast = true
        }
        
        Task { @MainActor in
            try? modelContext.save()
            WidgetCenter.shared.reloadAllTimelinesInBackground()
            AppDataChangeCenter.post()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dismiss()
        }
    }

    private func normalizedScheduleDate(from time: Date, on day: Date) -> Date {
        let calendar = Calendar.current
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: time)

        var components = DateComponents()
        components.year = dayComponents.year
        components.month = dayComponents.month
        components.day = dayComponents.day
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = timeComponents.second

        return calendar.date(from: components) ?? time
    }

    private func pickerRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func dateText(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private func dateTimeText(_ date: Date) -> String {
        Self.dateTimeFormatter.string(from: date)
    }

    @ViewBuilder
    private func pickerSheet(for picker: ActivePicker) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                switch picker {
                case .startTime:
                    DatePicker(
                        "开始时间",
                        selection: $startTime,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)

                    DatePicker(
                        "",
                        selection: $startTime,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.wheel)
                case .endTime:
                    DatePicker(
                        "结束时间",
                        selection: $endTime,
                        in: startTime...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)

                    DatePicker(
                        "",
                        selection: $endTime,
                        in: startTime...,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.wheel)
                case .effectiveStartDate:
                    DatePicker(
                        "开始日期",
                        selection: $effectiveStartDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                case .effectiveEndDate:
                    DatePicker(
                        "结束日期",
                        selection: $effectiveEndDate,
                        in: effectiveStartDate...,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                }
            }
            .padding(20)
            }
            .navigationTitle(picker.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        activePicker = nil
                    }
                }
            }
        }
        .presentationDetents([.large], selection: .constant(.large))
    }

    private enum ActivePicker: Int, Identifiable {
        case startTime
        case endTime
        case effectiveStartDate
        case effectiveEndDate

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .startTime:
                return "开始时间"
            case .endTime:
                return "结束时间"
            case .effectiveStartDate:
                return "开始日期"
            case .effectiveEndDate:
                return "结束日期"
            }
        }

    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()
}
