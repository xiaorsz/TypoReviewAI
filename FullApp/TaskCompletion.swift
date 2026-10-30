import Foundation
import SwiftData

@Model
final class TaskCompletion {
    var id: UUID = UUID()
    var taskID: UUID = UUID()
    var completedDate: Date = Date()
    var completedAt: Date = Date()

    init(
        id: UUID = UUID(),
        taskID: UUID,
        completedDate: Date,
        completedAt: Date = .now
    ) {
        self.id = id
        self.taskID = taskID
        self.completedDate = completedDate
        self.completedAt = completedAt
    }
}
