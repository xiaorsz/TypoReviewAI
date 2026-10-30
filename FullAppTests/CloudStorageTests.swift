import XCTest
import SwiftData
@testable import CoachLab

@MainActor final class CloudStorageTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coach-cloud-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func defaults() -> UserDefaults {
        let name = "coach-cloud-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testCloudConfigurationUsesOwnPrivateContainerAndExistingStoreURL() throws {
        let url = try temporaryDirectory().appendingPathComponent("coach-full.store")
        let configuration = CloudStorageConfiguration.cloudConfiguration(schema: Schema([ReviewItem.self]), storeURL: url)
        XCTAssertEqual(configuration.cloudKitContainerIdentifier, "iCloud.cc.xiaorsz.dictation-coach-lab")
        XCTAssertEqual(configuration.url, url)
    }
    func testMigrationBackupCanReopenRealLocalDatabaseWithoutChangingSource() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("coach-full.store")
        let schema = Schema([ReviewItem.self])
        let id = UUID()
        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let item = ReviewItem(id: id, type: .phrase, content: "保留本机数据", prompt: "")
            container.mainContext.insert(item); try container.mainContext.save()
        }
        let backup = try XCTUnwrap(CloudStorageConfiguration.backupLocalStoreIfNeeded(at: url, defaults: defaults()))
        let restored = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema,
            url: backup.appendingPathComponent(url.lastPathComponent), cloudKitDatabase: .none)])
        let records = try restored.mainContext.fetch(FetchDescriptor<ReviewItem>())
        XCTAssertEqual(records.map(\.id), [id])
        XCTAssertEqual(records.first?.content, "保留本机数据")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testBackupIncludesSQLiteSidecarsAndDoesNotMarkCloudEnabledEarly() throws {
        let url = try temporaryDirectory().appendingPathComponent("coach-full.store")
        let preferences = defaults()
        for suffix in ["", "-wal", "-shm"] { try Data("preserve\(suffix)".utf8).write(to: URL(fileURLWithPath: url.path + suffix)) }
        let backup = try XCTUnwrap(CloudStorageConfiguration.backupLocalStoreIfNeeded(at: url, defaults: preferences))
        for suffix in ["", "-wal", "-shm"] {
            let expected = Data("preserve\(suffix)".utf8)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + suffix)), expected)
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(url.lastPathComponent + suffix)), expected)
        }
        XCTAssertFalse(preferences.bool(forKey: CloudStorageConfiguration.migrationKey))
        preferences.set(true, forKey: CloudStorageConfiguration.migrationKey)
        XCTAssertNil(try CloudStorageConfiguration.backupLocalStoreIfNeeded(at: url, defaults: preferences))
    }
    func testBackupFailureLeavesWorkingFilesAndMigrationStateUntouched() throws {
        let root = try temporaryDirectory(), preferences = defaults()
        let url = root.appendingPathComponent("coach-full.store")
        let original = Data("working-store".utf8)
        try original.write(to: url)
        try Data("blocking-file".utf8).write(to: root.appendingPathComponent("CloudMigrationBackups"))
        XCTAssertThrowsError(try CloudStorageConfiguration.backupLocalStoreIfNeeded(at: url, defaults: preferences))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(preferences.bool(forKey: CloudStorageConfiguration.migrationKey))
    }
    func testFreshInstallDoesNotRequireOrInventLocalBackup() throws {
        let root = try temporaryDirectory(), preferences = defaults()
        XCTAssertNil(try CloudStorageConfiguration.backupLocalStoreIfNeeded(at: root.appendingPathComponent("coach-full.store"), defaults: preferences))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("CloudMigrationBackups").path))
    }
}
