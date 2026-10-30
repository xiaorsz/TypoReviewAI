import CryptoKit
import Foundation
import Security

enum DailySummaryAISettings {
    static let isEnabledKey = "dailySummaryAI.isEnabled"
    static let modelKey = "dailySummaryAI.deepSeekModel"
    static let defaultModel = DeepSeekSummaryModel.flash.rawValue
}

enum DeepSeekSummaryModel: String, CaseIterable, Identifiable {
    case flash = "deepseek-v4-flash"
    case pro = "deepseek-v4-pro"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flash:
            return "DeepSeek V4 Flash"
        case .pro:
            return "DeepSeek V4 Pro"
        }
    }
}

struct DailySummaryInput: Codable, Equatable {
    struct Metrics: Codable, Equatable {
        let reviewCompleted: Int
        let reviewCorrect: Int
        let reviewWrong: Int
        let reviewAccuracyText: String
        let dictationReviewedEntries: Int
        let tasksCompleted: Int
        let tasksPending: Int
        let pointsEarnedToday: Int
        let currentStreak: Int
    }

    struct Highlights: Codable, Equatable {
        let completedTaskTitles: [String]
        let wrongReviewSamples: [String]
    }

    let date: String
    let locale: String
    let tone: String
    let childName: String
    let metrics: Metrics
    let highlights: Highlights

    var hasActivity: Bool {
        metrics.reviewCompleted > 0 ||
        metrics.dictationReviewedEntries > 0 ||
        metrics.tasksCompleted > 0
    }

    func stableHash() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return "\(date)-fallback"
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func localFallbackResult() -> DailySummaryResult {
        let name = childName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "小朋友" : childName

        guard hasActivity else {
            return DailySummaryResult(
                title: "今天还没有完成记录",
                message: "先从一小组复习、听写或任务开始吧。每一次开始，都在让自己慢慢变得更厉害。",
                highlights: [],
                tomorrowFocus: "今天先完成一个小目标就很好。"
            )
        }

        var highlights: [String] = []
        if metrics.reviewCompleted > 0 {
            highlights.append("完成 \(metrics.reviewCompleted) 次复习")
        }
        if metrics.dictationReviewedEntries > 0 {
            highlights.append("听写判定 \(metrics.dictationReviewedEntries) 条")
        }
        if metrics.tasksCompleted > 0 {
            highlights.append("任务完成 \(metrics.tasksCompleted) 项")
        }
        if metrics.pointsEarnedToday > 0 {
            highlights.append("获得 \(metrics.pointsEarnedToday) 积分")
        }

        let message: String
        if metrics.reviewCompleted > 0 {
            if metrics.reviewWrong > 0 {
                message = "\(name) 今天完成得很扎实，复习正确率 \(metrics.reviewAccuracyText)。错题不可怕，每次订正都在进步。"
            } else {
                message = "\(name) 今天完成得很扎实，复习正确率 \(metrics.reviewAccuracyText)。今天的认真，正在成为成长的底气。"
            }
        } else if metrics.dictationReviewedEntries > 0 {
            message = "\(name) 今天完成了听写判定，也认真记下了练习结果。一点点积累，也会带来很大的进步。"
        } else {
            message = "\(name) 今天的任务有推进，稳定完成比一次做很多更重要。每个小小的完成，都值得点赞。"
        }

        let focus: String
        if metrics.reviewWrong > 0 {
            focus = "明天重点回看今天答错的 \(metrics.reviewWrong) 个内容。"
        } else {
            focus = "明天继续按计划少量复习，保持手感。"
        }

        return DailySummaryResult(
            title: "今日小结",
            message: message,
            highlights: highlights,
            tomorrowFocus: focus
        )
    }

    static func dateKey(for date: Date = .now, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

struct DailySummaryResult: Codable, Equatable {
    let title: String
    let message: String
    let highlights: [String]
    let tomorrowFocus: String

    var displayText: String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMessage.isEmpty {
            return trimmedMessage
        }
        return tomorrowFocus.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LearningSessionSummaryInput: Codable, Equatable {
    enum SessionKind: String, Codable {
        case review
        case dictation

        var title: String {
            switch self {
            case .review:
                return "复习"
            case .dictation:
                return "听写"
            }
        }
    }

    struct Metrics: Codable, Equatable {
        let totalCount: Int
        let correctCount: Int
        let wrongCount: Int
        let accuracyText: String
    }

    struct Samples: Codable, Equatable {
        let wrongItems: [String]
        let correctItems: [String]
    }

    let kind: SessionKind
    let title: String
    let date: String
    let childName: String
    let metrics: Metrics
    let samples: Samples

    func stableHash() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return "\(date)-\(kind.rawValue)-fallback"
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func localFallbackResult() -> LearningSessionSummaryResult {
        let kindTitle = kind.title
        let title = metrics.wrongCount == 0 ? "\(kindTitle)完成得很稳" : "\(kindTitle)已完成"
        let message: String
        if metrics.totalCount == 0 {
            message = "这次还没有可总结的记录。"
        } else if metrics.wrongCount == 0 {
            message = "这次 \(kindTitle) 共完成 \(metrics.totalCount) 条，全部正确，正确率 \(metrics.accuracyText)。"
        } else {
            message = "这次 \(kindTitle) 共完成 \(metrics.totalCount) 条，答错 \(metrics.wrongCount) 条，正确率 \(metrics.accuracyText)。"
        }

        let suggestions: [String]
        if kind == .dictation {
            suggestions = metrics.wrongCount == 0
                ? ["这次没有错项，保持当前听写节奏。", "可以把全对内容快速朗读一遍。"]
                : ["把本次错项单独读准，再遮住重写。", "对照错项找偏旁、字形或拼写差异。"]
        } else {
            suggestions = metrics.wrongCount == 0
                ? ["这次没有错项，按系统节奏继续即可。", "可以用听写方式抽查一小组。"]
                : ["把本次错项先看提示，再独立复述。", "对照错项补一句自己的记忆提示。"]
        }

        return LearningSessionSummaryResult(
            title: title,
            message: message,
            suggestions: suggestions
        )
    }
}

struct LearningSessionSummaryResult: Codable, Equatable {
    let title: String
    let message: String
    let suggestions: [String]

    var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum DailySummaryCache {
    private static let prefix = "dailySummaryAI.cache.v3.learning-and-tasks"

    private struct Entry: Codable {
        let result: DailySummaryResult
        let createdAt: Date
    }

    static func load(inputHash: String, model: String) -> DailySummaryResult? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(inputHash: inputHash, model: model)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return entry.result
    }

    static func save(_ result: DailySummaryResult, inputHash: String, model: String) {
        let entry = Entry(result: result, createdAt: .now)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(inputHash: inputHash, model: model))
    }

    private static func cacheKey(inputHash: String, model: String) -> String {
        "\(prefix).\(model).\(inputHash)"
    }
}

enum LearningSessionSummaryCache {
    private static let prefix = "learningSessionSummaryAI.cache.v1"

    private struct Entry: Codable {
        let result: LearningSessionSummaryResult
        let createdAt: Date
    }

    static func load(inputHash: String, model: String) -> LearningSessionSummaryResult? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(inputHash: inputHash, model: model)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return entry.result
    }

    static func save(_ result: LearningSessionSummaryResult, inputHash: String, model: String) {
        let entry = Entry(result: result, createdAt: .now)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(inputHash: inputHash, model: model))
    }

    private static func cacheKey(inputHash: String, model: String) -> String {
        "\(prefix).\(model).\(inputHash)"
    }
}

enum DeepSeekAPIKeyStore {
    static func loadAPIKey() throws -> String { try LabKeychain.load() }
    static func saveAPIKey(_ key: String) throws {
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try LabKeychain.delete() }
        else { try LabKeychain.save(key) }
    }
    static func deleteAPIKey() { try? LabKeychain.delete() }
}

struct DeepSeekSummaryClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiError(String)
        case emptyContent
        case invalidSummary(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "请先填写 DeepSeek API Key。"
            case .invalidResponse:
                return "DeepSeek 返回异常。"
            case .apiError(let message):
                return message
            case .emptyContent:
                return "DeepSeek 没有返回小结内容。"
            case .invalidSummary(let detail):
                return "DeepSeek 返回的小结格式不正确：\(detail)"
            case .timedOut:
                return "DeepSeek 连接超时，请稍后重试，或切换网络后再试。"
            }
        }
    }

    private static let requestTimeout: TimeInterval = 45
    private static let maxAttempts = 2

    let apiKey: String
    let model: String

    func testConnection() async throws -> String {
        let chatResponse = try await performChatRequest(
            DeepSeekChatRequest(
                model: model,
                messages: [
                    DeepSeekMessage(role: "system", content: "你只用于检查 API 连接是否可用。"),
                    DeepSeekMessage(role: "user", content: "请只回复：连接成功")
                ],
                responseFormat: nil,
                thinking: DeepSeekThinking(type: "disabled"),
                temperature: 0,
                maxTokens: 20,
                stream: false
            )
        )
        guard let content = chatResponse.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw ClientError.emptyContent
        }
        return content
    }

    func generateSummary(for input: DailySummaryInput) async throws -> DailySummaryResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        for attempt in 1...Self.maxAttempts {
            let chatResponse = try await performChatRequest(makeRequestBody(input: input))
            let choice = chatResponse.choices.first
            let content = choice?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if let result = decodeSummary(DailySummaryResult.self, from: content),
               result.isUsable {
                return result
            }

            if attempt < Self.maxAttempts {
                try await Task.sleep(nanoseconds: 400_000_000)
                continue
            }

            guard !content.isEmpty else {
                throw ClientError.emptyContent
            }
            throw ClientError.invalidSummary(failureDetail(for: choice?.finishReason))
        }

        throw ClientError.emptyContent
    }

    func generateLearningSessionSummary(for input: LearningSessionSummaryInput) async throws -> LearningSessionSummaryResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        for attempt in 1...Self.maxAttempts {
            let chatResponse = try await performChatRequest(makeLearningSessionRequestBody(input: input))
            let choice = chatResponse.choices.first
            let content = choice?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if let result = decodeSummary(LearningSessionSummaryResult.self, from: content),
               result.isUsable {
                return result
            }

            if attempt < Self.maxAttempts {
                try await Task.sleep(nanoseconds: 400_000_000)
                continue
            }

            guard !content.isEmpty else {
                throw ClientError.emptyContent
            }
            throw ClientError.invalidSummary(failureDetail(for: choice?.finishReason))
        }

        throw ClientError.emptyContent
    }

    private func performChatRequest(_ body: DeepSeekChatRequest) async throws -> DeepSeekChatResponse {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ClientError.timedOut
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(DeepSeekErrorResponse.self, from: data)
            throw ClientError.apiError(errorResponse?.error.message ?? "DeepSeek 请求失败：\(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        } catch {
            throw ClientError.apiError("DeepSeek 响应解析失败：\(error.localizedDescription)")
        }
    }

    private func decodeSummary<Result: Decodable>(_ type: Result.Type, from content: String) -> Result? {
        guard !content.isEmpty else { return nil }

        let normalizedContent = content
            .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = normalizedContent.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func failureDetail(for finishReason: String?) -> String {
        switch finishReason {
        case "length":
            return "输出被截断"
        case "content_filter":
            return "内容被过滤"
        case "insufficient_system_resource":
            return "DeepSeek 推理资源不足"
        default:
            return "JSON 字段缺失或类型不匹配"
        }
    }

    private func makeRequestBody(input: DailySummaryInput) throws -> DeepSeekChatRequest {
        let inputData = try JSONEncoder().encode(input)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"

        let systemPrompt = """
        你是一个给小学生家长看的学习助手。请只根据用户提供的 JSON 事实总结复习、听写、任务和积分，不要编造数字。
        当前应用不提供计算训练，不要提及或建议计算、口算、算术训练。
        输出必须是严格 JSON object，字段为 title、message、highlights、tomorrowFocus。
        JSON 输出格式示例：{"title":"今日小结","message":"今天完成了计划中的学习内容。每一次认真投入，都在为成长积蓄力量。","highlights":["完成复习"],"tomorrowFocus":"下一次重点回看错项。"}
        message 只总结今天已经完成的内容和当前状态，不要写“明天”，不要说今天失败了，也不要承诺今天一定还能完成。
        message 末尾加入一句简短、自然的鼓励语，类似成长型的暖心寄语；要贴合当天表现，每次可换一种表达，避免空泛说教、夸大成果或制造压力。
        有错项时强调“发现问题也是进步、订正会带来成长”；全对或完成较多时肯定认真与坚持；完成较少时鼓励从小目标和持续积累开始。
        如果 tasksCompleted 为 0 且 tasksPending 大于 0，可以温和表达“还有待办未完成”，不要写“今天没有完成任务”。
        tomorrowFocus 只写下一次可以关注什么，不要再出现“今天还能/今天可以/一起完成今天”这类表达。
        语气温和、鼓励、具体，中文简体。message 不超过 55 个汉字，tomorrowFocus 不超过 30 个汉字，highlights 最多 3 条。
        """

        let userPrompt = """
        请根据这份今日学习 JSON 生成小结：
        \(inputJSON)
        """

        return DeepSeekChatRequest(
            model: model,
            messages: [
                DeepSeekMessage(role: "system", content: systemPrompt),
                DeepSeekMessage(role: "user", content: userPrompt)
            ],
            responseFormat: DeepSeekResponseFormat(type: "json_object"),
            thinking: DeepSeekThinking(type: "disabled"),
            temperature: 0.4,
            maxTokens: 500,
            stream: false
        )
    }

    private func makeLearningSessionRequestBody(input: LearningSessionSummaryInput) throws -> DeepSeekChatRequest {
        let inputData = try JSONEncoder().encode(input)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"

        let systemPrompt = """
        你是一个给小学生家长看的学习助手。请只根据用户提供的 JSON 事实写本次练习结束小结，不要编造数字。
        输出必须是严格 JSON object，字段为 title、message、suggestions。
        JSON 输出格式示例：{"title":"本次练习已完成","message":"这次共完成 10 条，正确率 90%。","suggestions":["重新辨认本次错项","遮住答案再写一次"]}
        message 只总结本次 \(input.kind.title) 的完成情况，不要提不存在的任务、日程或历史记录。
        suggestions 给 2 到 3 条具体可执行建议，必须优先针对 samples.wrongItems 里的本次错项；不要泛泛写“下次/明天/以后”。
        若 kind 是 dictation，建议围绕本次听错内容如何立刻纠正、辨析字形/拼写/发音或提示；若 kind 是 review，建议围绕本次错项如何重新理解和记忆。
        语气温和、具体，中文简体。message 不超过 55 个汉字，每条 suggestion 不超过 24 个汉字。
        """

        let userPrompt = """
        请根据这份本次练习 JSON 生成结束小结：
        \(inputJSON)
        """

        return DeepSeekChatRequest(
            model: model,
            messages: [
                DeepSeekMessage(role: "system", content: systemPrompt),
                DeepSeekMessage(role: "user", content: userPrompt)
            ],
            responseFormat: DeepSeekResponseFormat(type: "json_object"),
            thinking: DeepSeekThinking(type: "disabled"),
            temperature: 0.35,
            maxTokens: 500,
            stream: false
        )
    }
}

private struct DeepSeekChatRequest: Encodable {
    let model: String
    let messages: [DeepSeekMessage]
    let responseFormat: DeepSeekResponseFormat?
    let thinking: DeepSeekThinking?
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case thinking
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct DeepSeekMessage: Codable {
    let role: String
    let content: String?
}

private struct DeepSeekResponseFormat: Encodable {
    let type: String
}

private struct DeepSeekThinking: Encodable {
    let type: String
}

private struct DeepSeekChatResponse: Decodable {
    struct Choice: Decodable {
        let message: DeepSeekMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]
}

private struct DeepSeekErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
