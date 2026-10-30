import XCTest
@testable import CoachLab

private actor FakeLabKeyStorage {
    enum Failure: Error { case unavailable }
    private(set) var value: String
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    private var remainingSaveFailures: Int
    init(_ value: String = "", saveFailures: Int = 0) {
        self.value = value; remainingSaveFailures = saveFailures
    }
    func load() -> String { value }
    func save(_ key: String) throws {
        saveCount += 1
        if remainingSaveFailures > 0 {
            remainingSaveFailures -= 1
            throw Failure.unavailable
        }
        value = key
    }
    func delete() { deleteCount += 1; value = "" }
}

private actor LabKeyOperationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters = []
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() {
        released = true; continuation?.resume(); continuation = nil
    }
}

@MainActor final class LabAPIKeyControllerTests: XCTestCase {
    private func controller(_ storage: FakeLabKeyStorage) -> LabAPIKeyController {
        LabAPIKeyController(load: { await storage.load() },
                            save: { try await storage.save($0) },
                            delete: { await storage.delete() })
    }

    func testSavingForImmediateUseMakesNormalizedKeyAvailableToLaterAutomaticRead() async throws {
        let storage = FakeLabKeyStorage()
        let editor = controller(storage)
        try await editor.loadIfNeeded()
        editor.edit("  test-key-for-coach\n")
        let keyForImmediateRun = try await editor.save()
        let keyForAutomaticRun = await storage.load()
        XCTAssertEqual(keyForImmediateRun, "test-key-for-coach")
        XCTAssertEqual(keyForAutomaticRun, keyForImmediateRun)
        XCTAssertEqual(editor.draft, keyForAutomaticRun)
        XCTAssertFalse(editor.isBusy)
    }

    func testInFlightSaveCannotBeOvertakenByClearSaveOrDraftEdit() async throws {
        let storage = FakeLabKeyStorage()
        let gate = LabKeyOperationGate()
        let editor = LabAPIKeyController(load: { await storage.load() }, save: { key in
            await gate.suspend()
            try await storage.save(key)
        }, delete: { await storage.delete() })
        editor.edit("test-key-first")
        let saving = Task { try await editor.save() }
        await gate.waitUntilEntered()
        XCTAssertEqual(editor.operation, .saving)
        editor.edit("test-key-later")
        do { try await editor.clear(); XCTFail("Clear must not overtake an in-flight save") }
        catch LabAPIKeyController.Failure.busy { }
        do { try await editor.save(); XCTFail("A second save must not start") }
        catch LabAPIKeyController.Failure.busy { }
        await gate.release()
        _ = try await saving.value
        let value = await storage.load()
        let deleteCount = await storage.deleteCount
        XCTAssertEqual(value, "test-key-first")
        XCTAssertEqual(editor.draft, value)
        XCTAssertEqual(deleteCount, 0)
        try await editor.clear()
        let cleared = await storage.load()
        XCTAssertEqual(cleared, "")
    }

    func testConnectionBlocksConflictingActionsAndClearDoesNotRestoreTestedKey() async throws {
        let storage = FakeLabKeyStorage()
        let gate = LabKeyOperationGate()
        let editor = controller(storage)
        editor.edit("test-key-for-connection")
        let testing = Task {
            try await editor.testConnection { key in
                XCTAssertEqual(key, "test-key-for-connection")
                await gate.suspend()
                return "连接正常"
            }
        }
        await gate.waitUntilEntered()
        XCTAssertEqual(editor.operation, .testing)
        let savedBeforeResponse = await storage.load()
        XCTAssertEqual(savedBeforeResponse, "test-key-for-connection")
        do { try await editor.clear(); XCTFail("Clear must wait until the connection test finishes") }
        catch LabAPIKeyController.Failure.busy { }
        editor.edit("replacement-during-test")
        XCTAssertEqual(editor.draft, "test-key-for-connection")
        await gate.release()
        let response = try await testing.value
        XCTAssertEqual(response, "连接正常")
        try await editor.clear()
        XCTAssertEqual(editor.draft, "")
        let persisted = await storage.load()
        XCTAssertEqual(persisted, "")
        XCTAssertFalse(editor.isBusy)
    }

    func testFailedSavePreservesDraftAndReleasesBusyStateForRetry() async throws {
        let storage = FakeLabKeyStorage("previous-test-key", saveFailures: 1)
        let editor = controller(storage)
        try await editor.loadIfNeeded()
        editor.edit("replacement-test-key")
        do { try await editor.save(); XCTFail("Expected injected storage failure") }
        catch FakeLabKeyStorage.Failure.unavailable { }
        XCTAssertFalse(editor.isBusy)
        XCTAssertEqual(editor.draft, "replacement-test-key")
        let unchanged = await storage.load()
        XCTAssertEqual(unchanged, "previous-test-key")
        try await editor.save()
        let retried = await storage.load()
        XCTAssertEqual(retried, "replacement-test-key")
    }

    func testInvalidDraftDoesNotReplaceSavedKey() async throws {
        let storage = FakeLabKeyStorage("previous-test-key")
        let editor = controller(storage)
        editor.edit("bad key with spaces")
        do { try await editor.save(); XCTFail("Invalid draft must not be persisted") }
        catch LabAPIKeyController.Failure.invalidKey { }
        let saveCount = await storage.saveCount
        let value = await storage.load()
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(value, "previous-test-key")
    }
}
