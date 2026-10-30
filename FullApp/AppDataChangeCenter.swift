import Foundation

/// Serializes destructive full-store replacement with background SwiftData
/// snapshots. SwiftData model objects become invalid as soon as another context
/// deletes their backing rows, so readers must finish materializing immutable
/// projections before a server restore begins.
enum PersistentStoreAccessGate {
    private static let lock = NSRecursiveLock()

    static func withAccess<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

extension Notification.Name {
    /// Posted after persisted app data changes and read models should refresh.
    static let appDataDidChange = Notification.Name("appDataDidMutate")
}

enum AppDataChangeCenter {
    enum Source: String {
        case local
        case server
    }

    private static let sourceKey = "changeSource"

    static func requiresUpload(_ notification: Notification) -> Bool {
        notification.userInfo?[sourceKey] as? String != Source.server.rawValue
    }

    static func post(source: Source = .local, using center: NotificationCenter = .default) {
        let userInfo = [sourceKey: source.rawValue]
        if Thread.isMainThread {
            center.post(name: .appDataDidChange, object: nil, userInfo: userInfo)
        } else {
            DispatchQueue.main.async {
                center.post(name: .appDataDidChange, object: nil, userInfo: userInfo)
            }
        }
    }
}
