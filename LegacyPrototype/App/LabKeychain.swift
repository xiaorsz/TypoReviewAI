import Foundation
import Security
import CoachCore

enum LabKeychain {
    private static var service: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return "cc.xiaorsz.dictation-coach-lab.api-key.uitests" }
        #endif
        return "cc.xiaorsz.dictation-coach-lab.api-key"
    }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "deepseek", kSecAttrSynchronizable as String: false]
    }
    static func load() throws -> String {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw LabError.invalid("无法读取实验版 API Key（\(status)）。") }
        return text
    }
    static func save(_ text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 500, !value.contains(where: \.isWhitespace) else { throw LabError.invalid("请填写有效的 API Key。") }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query; attributes.forEach { addition[$0.key] = $0.value }
            let result = SecItemAdd(addition as CFDictionary, nil)
            guard result == errSecSuccess else { throw LabError.invalid("API Key 保存失败（\(result)）。") }
        } else if status != errSecSuccess { throw LabError.invalid("API Key 保存失败（\(status)）。") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LabError.invalid("API Key 清除失败（\(status)）。") }
    }
}
