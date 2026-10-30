import Foundation
import Security

struct ServerAPIConfiguration: Sendable {
    static let urlInfoKey = "TypoReviewServerURL"

    let baseURL: URL
    let token: String

    // The full experiment deliberately has no production sync route.
    static var serverURL: URL? { nil }
    static var current: ServerAPIConfiguration? { nil }

}

enum LabSyncCredentialStore {
    private static let service = "cc.xiaorsz.dictation-coach-lab.server-sync"
    private static let tokenAccount = "device-token"
    private static let pairingCodeAccount = "pairing-code"

    static func loadToken() throws -> String {
        try loadValue(account: tokenAccount)
    }

    static func saveToken(_ token: String) throws {
        try saveValue(token, account: tokenAccount)
    }

    static func loadPairingCode() throws -> String {
        try loadValue(account: pairingCodeAccount)
    }

    static func savePairingCode(_ code: String) throws {
        try saveValue(code, account: pairingCodeAccount)
    }

    private static func loadValue(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw ServerAPIError.notConfigured
        }
        return token
    }

    private static func saveValue(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var inserted = query
            attributes.forEach { inserted[$0.key] = $0.value }
            let status = SecItemAdd(inserted as CFDictionary, nil)
            guard status == errSecSuccess else { throw ServerAPIError.notConfigured }
        } else if updateStatus != errSecSuccess {
            throw ServerAPIError.notConfigured
        }
    }
}

enum ServerAPIError: LocalizedError {
    case notConfigured
    case invalidResponse
    case rejected(statusCode: Int, message: String)
    case pinnedCertificateUnavailable
    case pinnedCertificateRejected

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "服务器同步尚未配置。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .rejected(let statusCode, let message):
            return "服务器拒绝了请求（HTTP \(statusCode)）：\(message)"
        case .pinnedCertificateUnavailable:
            return "App 中缺少服务器 CA 证书。"
        case .pinnedCertificateRejected:
            return "服务器证书与 App 固定的证书不一致。"
        }
    }
}

private final class ServerPinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let certificate: SecCertificate?

    override init() {
        if let url = Bundle.main.url(forResource: "TypoReviewServerCA", withExtension: "crt"),
           let data = try? Data(contentsOf: url) {
            certificate = Self.makeCertificate(from: data)
        } else {
            certificate = nil
        }
        super.init()
    }

    private static func makeCertificate(from data: Data) -> SecCertificate? {
        if let certificate = SecCertificateCreateWithData(nil, data as CFData) {
            return certificate
        }
        guard let pem = String(data: data, encoding: .utf8) else { return nil }
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // The shared HTTPS gateway uses a publicly trusted certificate. Keep
        // accepting the bundled private CA as a fallback for the legacy
        // :18443 endpoint while devices transition to the standard :443 URL.
        var systemTrustError: CFError?
        if SecTrustEvaluateWithError(trust, &systemTrustError) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard let certificate else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

struct ServerImportResponse: Decodable, Sendable {
    let ok: Bool
    let changed: [String: Int]
    let ignoredMediaAssets: Int
    let ignoredDuplicatePointEntries: Int
}

struct ServerDailyPlan: Codable, Sendable {
    struct Item: Codable, Sendable {
        let itemID: UUID
        let position: Int
        let completedEventID: UUID?
        let completedAt: Date?
    }

    let id: UUID
    let day: String
    let dailyLimit: Int
    let createdAt: Date
    let updatedAt: Date
    let items: [Item]
}

struct ServerReviewSubmission: Encodable, Sendable {
    let eventID: UUID
    let itemID: UUID
    let result: String
    let modeRawValue: String
    let reviewedAt: Date
    let note: String
}

struct ServerReviewResponse: Decodable, Sendable {
    let accepted: Bool
    let idempotent: Bool
    let item: ReviewItemSnapshot?
    let record: ReviewRecordSnapshot
}

struct ServerPairingResponse: Decodable, Sendable {
    let token: String
    let accountID: UUID
    let deviceID: UUID
}

struct ServerPairingCodeResponse: Decodable, Sendable {
    let code: String
    let persistent: Bool
}

struct ServerSecretValueResponse: Decodable, Sendable {
    let value: String?
    let updatedAt: Date?
}

struct ServerDailyQuoteResponse: Decodable, Sendable {
    enum Status: String, Decodable, Sendable {
        case available
        case exhausted
    }

    struct Quote: Decodable, Sendable {
        let id: String
        let text: String
        let kind: DailyQuote.Kind
        let attribution: String
        let explanation: String
        let action: String
    }

    let date: String
    let status: Status
    let quote: Quote?

    var dailyQuote: DailyQuote? {
        guard status == .available, let quote else { return nil }
        return DailyQuote(
            id: quote.id,
            dayKey: date,
            text: quote.text,
            kind: quote.kind,
            attribution: quote.attribution,
            explanation: quote.explanation,
            action: quote.action
        )
    }
}

enum ServerJSONValue: Codable, Sendable {
    case object([String: ServerJSONValue])
    case array([ServerJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: ServerJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([ServerJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct ServerChange: Decodable, Sendable {
    let entityType: String
    let recordID: UUID
    let payload: ServerJSONValue?
    let updatedAt: Date
    let serverVersion: Int64
    let deletedAt: Date?

    func decodePayload<Value: Decodable>(_ type: Value.Type) throws -> Value {
        guard let payload else { throw ServerAPIError.invalidResponse }
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder.typoReviewISO8601.decode(type, from: data)
    }
}

struct ServerChangeBatch: Decodable, Sendable {
    let changes: [ServerChange]
    let cursor: Int64
}

struct ServerSyncManifest: Decodable, Sendable {
    let protocolVersion: Int
    let cursor: Int64
    let records: [Record]
    struct Record: Decodable, Sendable {
        let entityType: String
        let recordID: UUID
        let serverVersion: Int64
        let deleted: Bool
    }
}

protocol ServerSyncAPI: Sendable {
    func health() async throws
    func syncManifest() async throws -> ServerSyncManifest?
    func exportSnapshot() async throws -> DataBackupPayload
    func changes(after cursor: Int64, limit: Int) async throws -> ServerChangeBatch
    func dailyPlan(day: String, dailyLimit: Int) async throws -> ServerDailyPlan
    func pushMutations(_ body: Data) async throws -> ServerMutationResponse
    func deepSeekAPIKey() async throws -> ServerSecretValueResponse
    func saveDeepSeekAPIKey(_ value: String) async throws -> ServerSecretValueResponse
}

extension ServerSyncAPI {
    func syncManifest() async throws -> ServerSyncManifest? { nil }
}

actor ServerAPIClient: ServerSyncAPI {
    static let shared = ServerAPIClient()

    private let configuration: ServerAPIConfiguration?
    private let sessionDelegate: ServerPinnedCertificateDelegate
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(configuration: ServerAPIConfiguration? = .current) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 45
        sessionConfiguration.timeoutIntervalForResource = 180
        sessionConfiguration.waitsForConnectivity = true
        let sessionDelegate = ServerPinnedCertificateDelegate()
        self.sessionDelegate = sessionDelegate
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = .typoReviewISO8601
    }

    func health() async throws {
        let _: EmptyHealthResponse = try await request(path: "/health", method: "GET", authorized: false)
    }

    func dailyQuote() async throws -> ServerDailyQuoteResponse {
        try await request(
            path: "/v1/content/daily-quote",
            method: "GET",
            authorized: false,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
    }

    func pair(code: String, deviceName: String) async throws -> ServerPairingResponse {
        struct Body: Encodable {
            let code: String
            let deviceName: String
        }
        return try await request(
            path: "/v1/auth/pair",
            method: "POST",
            body: try encoder.encode(Body(code: code, deviceName: deviceName)),
            authorized: false
        )
    }

    func pairingCode() async throws -> ServerPairingCodeResponse {
        try await request(path: "/v1/auth/pairing-code", method: "GET")
    }

    func importSnapshot(_ payload: DataBackupPayload) async throws -> ServerImportResponse {
        try await request(
            path: "/v1/migration/import",
            method: "POST",
            body: try encoder.encode(payload)
        )
    }

    func exportSnapshot() async throws -> DataBackupPayload {
        try await request(path: "/v1/migration/export", method: "GET")
    }

    func changes(after cursor: Int64, limit: Int = 1_000) async throws -> ServerChangeBatch {
        try await request(
            path: "/v1/sync/changes",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "after", value: String(cursor)),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    func syncManifest() async throws -> ServerSyncManifest? {
        do {
            return try await request(path: "/v1/sync/manifest", method: "GET")
        } catch ServerAPIError.rejected(let code, _) where code == 404 {
            return nil
        }
    }

    func deepSeekAPIKey() async throws -> ServerSecretValueResponse {
        try await request(path: "/v1/secrets/deepseek-api-key", method: "GET")
    }

    func saveDeepSeekAPIKey(_ value: String) async throws -> ServerSecretValueResponse {
        struct Body: Encodable {
            let value: String
        }
        return try await request(
            path: "/v1/secrets/deepseek-api-key",
            method: "PUT",
            body: try encoder.encode(Body(value: value))
        )
    }

    func deleteDeepSeekAPIKey() async throws {
        let _: ServerSecretDeletionResponse = try await request(
            path: "/v1/secrets/deepseek-api-key",
            method: "DELETE"
        )
    }

    func dailyPlan(day: String, dailyLimit: Int) async throws -> ServerDailyPlan {
        struct Body: Encodable {
            let day: String
            let dailyLimit: Int
        }
        return try await request(
            path: "/v1/review/daily-plan",
            method: "POST",
            body: try encoder.encode(Body(day: day, dailyLimit: dailyLimit))
        )
    }

    func submitReview(_ submission: ServerReviewSubmission) async throws -> ServerReviewResponse {
        try await request(
            path: "/v1/review/submit",
            method: "POST",
            body: try encoder.encode(submission)
        )
    }

    func pushMutations(_ body: Data) async throws -> ServerMutationResponse {
        try await request(
            path: "/v1/sync/push",
            method: "POST",
            body: body
        )
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        body: Data? = nil,
        authorized: Bool = true,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        timeoutInterval: TimeInterval? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        guard let baseURL = configuration?.baseURL ?? ServerAPIConfiguration.serverURL else {
            throw ServerAPIError.notConfigured
        }
        let baseRequestURL = baseURL.appending(path: path)
        var components = URLComponents(
            url: baseRequestURL,
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw ServerAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = cachePolicy
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        if authorized {
            guard let token = configuration?.token else { throw ServerAPIError.notConfigured }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(1_024), encoding: .utf8) ?? "未知错误"
            throw ServerAPIError.rejected(statusCode: http.statusCode, message: message)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ServerAPIError.invalidResponse
        }
    }
}

private struct EmptyHealthResponse: Decodable {
    let status: String
}

struct ServerMutationResponse: Decodable, Sendable {
    let appliedMutationIDs: [UUID]
    var conflicts: [ServerMutationConflict]? = nil
}

struct ServerMutationConflict: Codable, Sendable {
    let mutationID: UUID
    let entityType: String
    let recordID: UUID
    let statusCode: Int
    let reason: ServerJSONValue
}

private struct ServerSecretDeletionResponse: Decodable {
    let deleted: Bool
}
