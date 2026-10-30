import Foundation
import SwiftData

@Model
final class TaskSubitem {
    var id: UUID = UUID()
    var parentTaskID: UUID = UUID()
    var taskExecutionIDRawValue: String = ""
    var title: String = ""
    var note: String = ""
    var detail: String = ""
    var statusRawValue: String = TaskExecutionStatus.pending.rawValue
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var completedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        parentTaskID: UUID,
        taskExecutionID: UUID? = nil,
        title: String,
        note: String = "",
        detail: String = "",
        status: TaskExecutionStatus = .pending,
        sortOrder: Int = 0,
        isArchived: Bool = false,
        completedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.parentTaskID = parentTaskID
        self.taskExecutionIDRawValue = taskExecutionID?.uuidString ?? ""
        self.title = title
        self.note = note
        self.detail = detail
        self.statusRawValue = status.rawValue
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var taskExecutionID: UUID? {
        get { UUID(uuidString: taskExecutionIDRawValue) }
        set { taskExecutionIDRawValue = newValue?.uuidString ?? "" }
    }

    var status: TaskExecutionStatus {
        get { TaskExecutionStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }
}

enum TaskExecutionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending = "待处理"
    case completed = "已完成"
    case skipped = "已跳过"

    var id: String { rawValue }
}

@Model
final class TaskExecutionRecord {
    var id: UUID = UUID()
    var taskID: UUID = UUID()
    var occurrenceDate: Date = Date()
    var detail: String = ""
    var statusRawValue: String = TaskExecutionStatus.pending.rawValue
    var completedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        taskID: UUID,
        occurrenceDate: Date,
        detail: String = "",
        status: TaskExecutionStatus = .pending,
        completedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.taskID = taskID
        self.occurrenceDate = occurrenceDate
        self.detail = detail
        self.statusRawValue = status.rawValue
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var status: TaskExecutionStatus {
        get { TaskExecutionStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }
}

@Model
final class TaskSubitemExecutionRecord {
    var id: UUID = UUID()
    var taskExecutionID: UUID = UUID()
    var subtaskID: UUID = UUID()
    var detail: String = ""
    var statusRawValue: String = TaskExecutionStatus.pending.rawValue
    var completedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        taskExecutionID: UUID,
        subtaskID: UUID,
        detail: String = "",
        status: TaskExecutionStatus = .pending,
        completedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.taskExecutionID = taskExecutionID
        self.subtaskID = subtaskID
        self.detail = detail
        self.statusRawValue = status.rawValue
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var status: TaskExecutionStatus {
        get { TaskExecutionStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }
}
