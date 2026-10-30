import Foundation
import SwiftData

enum CloudStorageConfiguration {
    static let containerIdentifier = "iCloud.cc.xiaorsz.dictation-coach-lab"
    static let migrationKey = "coachLab.privateCloudKit.enabled.v1"

    static var isTestRuntime: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static func cloudConfiguration(schema: Schema, storeURL: URL) -> ModelConfiguration {
        ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .private(containerIdentifier))
    }

    /// Called before opening the persistent store. The main file and SQLite sidecars are
    /// copied together, while the store is closed. Never delete/move the working files.
    @discardableResult
    static func backupLocalStoreIfNeeded(at storeURL: URL, defaults: UserDefaults = .standard) throws -> URL? {
        let manager = FileManager.default
        guard !defaults.bool(forKey: migrationKey), manager.fileExists(atPath: storeURL.path) else { return nil }
        let destination = storeURL.deletingLastPathComponent()
            .appendingPathComponent("CloudMigrationBackups", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: storeURL.path + suffix)
                if manager.fileExists(atPath: source.path) {
                    try manager.copyItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
                }
            }
            return destination
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }
}
