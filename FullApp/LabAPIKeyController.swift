import Foundation
import Observation

/// One editor for the Key shared by the coach and daily summary. Keychain work
/// stays off the main actor; conflicting actions cannot overtake each other.
@MainActor @Observable final class LabAPIKeyController {
    enum Operation: Equatable { case idle, loading, saving, clearing, testing }
    enum Failure: LocalizedError {
        case busy, invalidKey
        var errorDescription: String? {
            switch self {
            case .busy: return "正在处理 API Key，请稍后再试。"
            case .invalidKey: return "请先填写有效的 DeepSeek API Key；删除已保存的 Key 请点「清空」。"
            }
        }
    }

    static let shared = LabAPIKeyController(
        load: { try await Task.detached(priority: .utility) { try LabKeychain.load() }.value },
        save: { key in try await Task.detached(priority: .utility) { try LabKeychain.save(key) }.value },
        delete: { try await Task.detached(priority: .utility) { try LabKeychain.delete() }.value }
    )

    private(set) var draft = ""
    private(set) var hasLoaded = false
    private(set) var operation = Operation.idle
    var isBusy: Bool { operation != .idle }

    private let loadKey: @Sendable () async throws -> String
    private let saveKey: @Sendable (String) async throws -> Void
    private let deleteKey: @Sendable () async throws -> Void

    init(load: @escaping @Sendable () async throws -> String,
         save: @escaping @Sendable (String) async throws -> Void,
         delete: @escaping @Sendable () async throws -> Void) {
        loadKey = load; saveKey = save; deleteKey = delete
    }

    func edit(_ value: String) {
        guard !isBusy else { return }
        draft = value
    }

    func loadIfNeeded() async throws {
        guard !hasLoaded, !isBusy else { return }
        operation = .loading
        defer { operation = .idle }
        let value = try await loadKey()
        try Task.checkCancellation()
        draft = value; hasLoaded = true
    }

    @discardableResult func save() async throws -> String {
        try requireIdle()
        let key = try validatedDraft()
        operation = .saving
        defer { operation = .idle }
        try await saveKey(key)
        draft = key; hasLoaded = true
        return key
    }

    func clear() async throws {
        try requireIdle()
        operation = .clearing
        defer { operation = .idle }
        try await deleteKey()
        draft = ""; hasLoaded = true
    }

    func testConnection(using request: @Sendable (String) async throws -> String) async throws -> String {
        try requireIdle()
        let key = try validatedDraft()
        operation = .testing
        defer { operation = .idle }
        try await saveKey(key)
        draft = key; hasLoaded = true
        // The response never restores a captured draft. Clear/edit/save are
        // blocked until this request finishes, including in the other screen.
        return try await request(key)
    }

    private func requireIdle() throws {
        guard !isBusy else { throw Failure.busy }
    }

    private func validatedDraft() throws -> String {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 500, !key.contains(where: \.isWhitespace) else {
            throw Failure.invalidKey
        }
        return key
    }
}
