import Foundation
import CryptoKit
import SwiftData

enum CalculationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case multiplication = "竖式乘法"
    case division = "竖式除法"
    case mixed = "混合运算"
    case numberSense = "简便计算"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .multiplication: return "multiply"
        case .division: return "divide"
        case .mixed: return "function"
        case .numberSense: return "lightbulb.fill"
        }
    }
}

enum CalculationAnswerMode: String, Codable, Hashable, Sendable {
    case integer
    case quotientAndRemainder
}

struct CalculationQuestion: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let kind: CalculationKind
    let templateID: String
    let expression: String
    let answerMode: CalculationAnswerMode
    let expectedValue: Int
    let expectedRemainder: Int?
    let hint: String
    let fingerprint: String

    var standardAnswerText: String {
        if answerMode == .quotientAndRemainder {
            return "商 \(expectedValue)，余数 \(expectedRemainder ?? 0)"
        }
        return "\(expectedValue)"
    }
}

struct CalculationAnswer: Codable, Hashable, Sendable {
    let questionID: UUID
    var value: String
    var remainder: String
    var isCorrect: Bool?

    init(
        questionID: UUID,
        value: String = "",
        remainder: String = "",
        isCorrect: Bool? = nil
    ) {
        self.questionID = questionID
        self.value = value
        self.remainder = remainder
        self.isCorrect = isCorrect
    }
}

@Model
final class CalculationRound {
    var id: UUID = UUID()
    var dayKey: String = ""
    var roundIndex: Int = 0
    var generatorVersion: Int = CalculationGenerator.currentVersion
    var questionsRawValue: String = "[]"
    var answersRawValue: String = "[]"
    var correctCount: Int = 0
    var startedAt: Date = Date()
    var submittedAt: Date?
    var durationSeconds: Double = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        dayKey: String,
        roundIndex: Int,
        generatorVersion: Int = CalculationGenerator.currentVersion,
        questions: [CalculationQuestion],
        answers: [CalculationAnswer] = [],
        correctCount: Int = 0,
        startedAt: Date = .now,
        submittedAt: Date? = nil,
        durationSeconds: Double = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.dayKey = dayKey
        self.roundIndex = roundIndex
        self.generatorVersion = generatorVersion
        questionsRawValue = Self.encode(questions)
        answersRawValue = Self.encode(answers)
        self.correctCount = correctCount
        self.startedAt = startedAt
        self.submittedAt = submittedAt
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var questions: [CalculationQuestion] {
        get { Self.decode([CalculationQuestion].self, from: questionsRawValue) ?? [] }
        set {
            questionsRawValue = Self.encode(newValue)
            updatedAt = .now
        }
    }

    var answers: [CalculationAnswer] {
        get { Self.decode([CalculationAnswer].self, from: answersRawValue) ?? [] }
        set {
            answersRawValue = Self.encode(newValue)
            updatedAt = .now
        }
    }

    var isSubmitted: Bool { submittedAt != nil }

    var isPerfect: Bool {
        isSubmitted && !questions.isEmpty && correctCount == questions.count
    }

    var accuracyPercent: Int {
        guard isSubmitted, !questions.isEmpty else { return 0 }
        return Int((Double(correctCount) / Double(questions.count) * 100).rounded())
    }

    static func dayKey(for date: Date = .now, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: String) -> T? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum CalculationAnswerEvaluator {
    static func isComplete(_ answer: CalculationAnswer, for question: CalculationQuestion) -> Bool {
        guard normalizedInteger(answer.value) != nil else { return false }
        if question.answerMode == .quotientAndRemainder {
            return normalizedInteger(answer.remainder) != nil
        }
        return true
    }

    static func isCorrect(_ answer: CalculationAnswer, for question: CalculationQuestion) -> Bool {
        guard normalizedInteger(answer.value) == question.expectedValue else { return false }
        if question.answerMode == .quotientAndRemainder {
            return normalizedInteger(answer.remainder) == question.expectedRemainder
        }
        return true
    }

    static func normalizedInteger(_ text: String) -> Int? {
        var normalized = ""
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            switch character {
            case "０"..."９":
                let scalars = character.unicodeScalars
                guard let value = scalars.first?.value else { return nil }
                normalized.append(String(value - 0xFF10))
            case "−", "－":
                normalized.append("-")
            case ",", "，", " ":
                continue
            default:
                normalized.append(character)
            }
        }
        return Int(normalized)
    }
}

enum CalculationGenerator {
    static let currentVersion = 2

    static func generateInitialRound(dayKey: String) -> [CalculationQuestion] {
        generate(
            dayKey: dayKey,
            roundIndex: 0,
            kinds: [.multiplication, .division, .mixed, .mixed, .numberSense],
            variants: [0, 0, 0, 1, 0]
        )
    }

    static func generateRetryRound(
        dayKey: String,
        roundIndex: Int,
        wrongKinds: [CalculationKind]
    ) -> [CalculationQuestion] {
        var seen = Set<CalculationKind>()
        let preferred = wrongKinds.filter { seen.insert($0).inserted }
        let source = preferred.isEmpty ? CalculationKind.allCases : preferred
        let kinds = (0..<3).map { source[($0 + max(roundIndex - 1, 0)) % source.count] }
        return generate(
            dayKey: dayKey,
            roundIndex: roundIndex,
            kinds: kinds,
            variants: Array(0..<kinds.count)
        )
    }

    static func roundID(dayKey: String, roundIndex: Int) -> UUID {
        deterministicUUID(for: "daily-calculation|v\(currentVersion)|\(dayKey)|round|\(roundIndex)")
    }

    private static func generate(
        dayKey: String,
        roundIndex: Int,
        kinds: [CalculationKind],
        variants: [Int]
    ) -> [CalculationQuestion] {
        var random = SeededCalculationRandom(seedText: "v\(currentVersion)|\(dayKey)|\(roundIndex)")
        var fingerprints = Set<String>()
        var questions: [CalculationQuestion] = []

        for (position, kind) in kinds.enumerated() {
            var attempt = 0
            var question: CalculationQuestion
            repeat {
                question = makeQuestion(
                    kind: kind,
                    variant: (variants.indices.contains(position) ? variants[position] : position) + attempt,
                    position: position,
                    dayKey: dayKey,
                    roundIndex: roundIndex,
                    random: &random
                )
                attempt += 1
            } while fingerprints.contains(question.fingerprint) && attempt < 30
            fingerprints.insert(question.fingerprint)
            questions.append(question)
        }
        return questions
    }

    private static func makeQuestion(
        kind: CalculationKind,
        variant: Int,
        position: Int,
        dayKey: String,
        roundIndex: Int,
        random: inout SeededCalculationRandom
    ) -> CalculationQuestion {
        let draft: QuestionDraft
        let dayRotation = Int(stableHash(dayKey) % 24)
        switch kind {
        case .multiplication:
            draft = multiplication(variant: variant + dayRotation, random: &random)
        case .division:
            draft = division(dayKey: dayKey, roundIndex: roundIndex, variant: variant, random: &random)
        case .mixed:
            draft = mixed(
                grouped: variant % 2 == 1,
                variant: variant / 2 + dayRotation,
                random: &random
            )
        case .numberSense:
            draft = numberSense(variant: variant + dayRotation, random: &random)
        }

        let fingerprint = "\(kind.rawValue)|\(draft.expression)"
        return CalculationQuestion(
            id: deterministicUUID(
                for: "daily-calculation|v\(currentVersion)|\(dayKey)|\(roundIndex)|\(position)|\(fingerprint)"
            ),
            kind: kind,
            templateID: draft.templateID,
            expression: draft.expression,
            answerMode: draft.answerMode,
            expectedValue: draft.expectedValue,
            expectedRemainder: draft.expectedRemainder,
            hint: draft.hint,
            fingerprint: fingerprint
        )
    }

    private static func multiplication(
        variant: Int,
        random: inout SeededCalculationRandom
    ) -> QuestionDraft {
        let lhs: Int
        let rhs: Int
        switch variant % 4 {
        case 0:
            lhs = random.int(120...989)
            rhs = random.int(12...89)
        case 1:
            lhs = random.int(20...98) * 10
            rhs = random.int(12...89)
        case 2:
            lhs = [198, 199, 298, 299, 398, 399, 498, 499][random.int(0...7)]
            rhs = random.int(12...79)
        default:
            lhs = random.int(101...899)
            rhs = [25, 32, 48, 64, 75, 88][random.int(0...5)]
        }
        return QuestionDraft(
            templateID: "multiplication-\(variant % 4)",
            expression: "\(lhs) × \(rhs)",
            expectedValue: lhs * rhs,
            hint: "可以先估算积的位数，再用竖式计算并检查进位。"
        )
    }

    private static func division(
        dayKey: String,
        roundIndex: Int,
        variant: Int,
        random: inout SeededCalculationRandom
    ) -> QuestionDraft {
        let cycle = stableHash(dayKey) + UInt64(max(0, roundIndex + variant))
        let wantsRemainder = cycle % 2 == 1
        var divisor = 0
        var quotient = 0
        var remainder = 0
        var dividend = 0

        repeat {
            divisor = random.int(11...89)
            quotient = random.int(2...49)
            remainder = wantsRemainder ? random.int(1...(divisor - 1)) : 0
            dividend = divisor * quotient + remainder
        } while dividend < 100 || dividend > 999

        return QuestionDraft(
            templateID: wantsRemainder ? "division-remainder" : "division-exact",
            expression: "\(dividend) ÷ \(divisor)",
            answerMode: wantsRemainder ? .quotientAndRemainder : .integer,
            expectedValue: quotient,
            expectedRemainder: wantsRemainder ? remainder : nil,
            hint: wantsRemainder
                ? "用“商 × 除数 + 余数 = 被除数”验算，余数必须小于除数。"
                : "可以用“商 × 除数 = 被除数”验算。"
        )
    }

    private static func mixed(
        grouped: Bool,
        variant: Int,
        random: inout SeededCalculationRandom
    ) -> QuestionDraft {
        let expression: IntegerExpression
        let templateID: String

        if grouped {
            switch variant % 4 {
            case 0:
                let a = random.int(120...360)
                let b = random.int(20...90)
                let c = random.int(12...35)
                let d = random.int(2...(c - 1))
                expression = .multiply(.add(.value(a), .value(b)), .subtract(.value(c), .value(d)))
                templateID = "mixed-grouped-product"
            case 1:
                let b = random.int(24...80)
                let c = random.int(2...(b - 1))
                let d = random.int(2...8)
                let denominator = (b - c) * d
                let quotient = random.int(5...35)
                expression = .divide(
                    .value(denominator * quotient),
                    .multiply(.subtract(.value(b), .value(c)), .value(d))
                )
                templateID = "mixed-nested-division"
            case 2:
                let b = random.int(80...180)
                let c = random.int(20...(b - 1))
                let d = random.int(2...6)
                let product = (b - c) * d
                let a = product + random.int(80...500)
                expression = .subtract(.value(a), .multiply(.subtract(.value(b), .value(c)), .value(d)))
                templateID = "mixed-grouped-subtraction"
            default:
                let b = random.int(12...30)
                let c = random.int(3...9)
                let d = random.int(3...12)
                let result = random.int(10...60)
                let a = result * d + b * c
                expression = .divide(.subtract(.value(a), .multiply(.value(b), .value(c))), .value(d))
                templateID = "mixed-grouped-exact"
            }
        } else {
            switch variant % 3 {
            case 0:
                let a = random.int(80...360)
                let b = random.int(12...45)
                let c = random.int(3...12)
                let d = random.int(10...min(120, a + b * c))
                expression = .subtract(.add(.value(a), .multiply(.value(b), .value(c))), .value(d))
                templateID = "mixed-precedence"
            case 1:
                let divisor = random.int(3...12)
                let quotient = random.int(12...60)
                let multiplier = random.int(2...8)
                let tail = random.int(10...90)
                expression = .add(
                    .multiply(.divide(.value(divisor * quotient), .value(divisor)), .value(multiplier)),
                    .value(tail)
                )
                templateID = "mixed-left-to-right"
            default:
                let a = random.int(300...900)
                let b = random.int(8...25)
                let c = random.int(3...9)
                let divisor = random.int(3...12)
                let quotient = random.int(2...12)
                expression = .subtract(
                    .add(.value(a), .multiply(.value(b), .value(c))),
                    .divide(.value(divisor * quotient), .value(divisor))
                )
                templateID = "mixed-four-operations"
            }
        }

        let answer = expression.evaluate()
        precondition(answer != nil && answer! >= 0)
        return QuestionDraft(
            templateID: templateID,
            expression: expression.rendered(),
            expectedValue: answer!,
            hint: grouped
                ? "先算括号里面，再按先乘除、后加减的顺序计算。"
                : "没有括号时先乘除、后加减，同级运算从左往右。"
        )
    }

    private static func numberSense(
        variant: Int,
        random: inout SeededCalculationRandom
    ) -> QuestionDraft {
        let expression: IntegerExpression
        let hint: String
        let templateID: String

        switch variant % 8 {
        case 0:
            let value = random.int(120...880)
            expression = .multiply(.value(value), .value(99))
            templateID = "sense-times-99"
            hint = "把 99 看成 100 − 1，会更容易口算和验算。"
        case 1:
            let value = random.int(120...880)
            expression = .multiply(.value(value), .value(101))
            templateID = "sense-times-101"
            hint = "把 101 看成 100 + 1，利用乘法分配律。"
        case 2:
            let multiple = random.int(3...24) * 4
            expression = .multiply(.value(25), .value(multiple))
            templateID = "sense-25-pair"
            hint = "先找出 25 × 4 = 100，再计算剩余部分。"
        case 3:
            let multiple = random.int(2...15) * 8
            expression = .multiply(.value(125), .value(multiple))
            templateID = "sense-125-pair"
            hint = "先找出 125 × 8 = 1000，再计算剩余部分。"
        case 4:
            let common = random.int(12...86)
            let lhs = random.int(60...98)
            let rhs = random.int(12...(lhs - 1))
            expression = .subtract(.multiply(.value(lhs), .value(common)), .multiply(.value(rhs), .value(common)))
            templateID = "sense-common-factor"
            hint = "两个乘法里有相同因数，可以先算另两个数的差。"
        case 5:
            let common = random.int(12...86)
            let lhs = random.int(12...70)
            expression = .add(
                .multiply(.value(lhs), .value(common)),
                .multiply(.value(100 - lhs), .value(common))
            )
            templateID = "sense-make-100"
            hint = "提取相同因数后，观察另外两个数能否凑成 100。"
        case 6:
            let first = random.int(120...680)
            let gap = random.int(1...9)
            let nearHundred = random.int(2...6) * 100 - gap
            expression = .add(.add(.value(first), .value(nearHundred)), .value(gap))
            templateID = "sense-round-to-hundred"
            hint = "把最后一个数和接近整百的数放在一起，先凑成整百。"
        default:
            let divisor = [4, 5, 8, 10, 20, 25][random.int(0...5)]
            let quotient = random.int(3...24)
            let factor = random.int(12...86)
            expression = .divide(
                .multiply(.value(factor), .value(divisor * quotient)),
                .value(divisor)
            )
            templateID = "sense-multiply-divide-cancel"
            hint = "先观察乘数里有没有除数的倍数，约简后再乘。"
        }

        return QuestionDraft(
            templateID: templateID,
            expression: expression.rendered(),
            expectedValue: expression.evaluate()!,
            hint: hint
        )
    }

    private static func deterministicUUID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { result, byte in
            (result ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private struct QuestionDraft {
        let templateID: String
        let expression: String
        var answerMode: CalculationAnswerMode = .integer
        let expectedValue: Int
        var expectedRemainder: Int? = nil
        let hint: String
    }

    private struct SeededCalculationRandom: RandomNumberGenerator {
        private var state: UInt64

        init(seedText: String) {
            state = CalculationGenerator.stableHash(seedText)
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }

        mutating func int(_ range: ClosedRange<Int>) -> Int {
            guard range.lowerBound < range.upperBound else { return range.lowerBound }
            let width = UInt64(range.upperBound - range.lowerBound + 1)
            return range.lowerBound + Int(next() % width)
        }
    }

    private indirect enum IntegerExpression {
        case value(Int)
        case add(IntegerExpression, IntegerExpression)
        case subtract(IntegerExpression, IntegerExpression)
        case multiply(IntegerExpression, IntegerExpression)
        case divide(IntegerExpression, IntegerExpression)

        var precedence: Int {
            switch self {
            case .value: return 3
            case .multiply, .divide: return 2
            case .add, .subtract: return 1
            }
        }

        func evaluate() -> Int? {
            switch self {
            case .value(let value):
                return value
            case .add(let lhs, let rhs):
                guard let left = lhs.evaluate(), let right = rhs.evaluate() else { return nil }
                return left + right
            case .subtract(let lhs, let rhs):
                guard let left = lhs.evaluate(), let right = rhs.evaluate(), left >= right else { return nil }
                return left - right
            case .multiply(let lhs, let rhs):
                guard let left = lhs.evaluate(), let right = rhs.evaluate() else { return nil }
                return left * right
            case .divide(let lhs, let rhs):
                guard let left = lhs.evaluate(), let right = rhs.evaluate(), right != 0, left % right == 0 else {
                    return nil
                }
                return left / right
            }
        }

        func rendered(parentPrecedence: Int = 0, isRightOperand: Bool = false) -> String {
            let body: String
            switch self {
            case .value(let value):
                body = "\(value)"
            case .add(let lhs, let rhs):
                body = "\(lhs.rendered(parentPrecedence: precedence)) + \(rhs.rendered(parentPrecedence: precedence, isRightOperand: true))"
            case .subtract(let lhs, let rhs):
                body = "\(lhs.rendered(parentPrecedence: precedence)) − \(rhs.rendered(parentPrecedence: precedence, isRightOperand: true))"
            case .multiply(let lhs, let rhs):
                body = "\(lhs.rendered(parentPrecedence: precedence)) × \(rhs.rendered(parentPrecedence: precedence, isRightOperand: true))"
            case .divide(let lhs, let rhs):
                body = "\(lhs.rendered(parentPrecedence: precedence)) ÷ \(rhs.rendered(parentPrecedence: precedence, isRightOperand: true))"
            }

            let needsParentheses = precedence < parentPrecedence
                || (isRightOperand && precedence == parentPrecedence && {
                    switch self {
                    case .add, .subtract: return parentPrecedence == 1
                    case .multiply, .divide: return parentPrecedence == 2
                    case .value: return false
                    }
                }())
            return needsParentheses ? "(\(body))" : body
        }
    }
}

@MainActor
enum CalculationSessionService {
    static let completionRewardAmount = 5

    static func todayRounds(
        from allRounds: [CalculationRound],
        referenceDate: Date = .now
    ) -> [CalculationRound] {
        let key = CalculationRound.dayKey(for: referenceDate)
        return allRounds.filter { $0.dayKey == key }.sorted { $0.roundIndex < $1.roundIndex }
    }

    @discardableResult
    static func ensureInitialRound(
        referenceDate: Date = .now,
        in modelContext: ModelContext
    ) throws -> CalculationRound {
        let key = CalculationRound.dayKey(for: referenceDate)
        let rounds = try modelContext.fetch(FetchDescriptor<CalculationRound>())
            .filter { $0.dayKey == key }
            .sorted { $0.roundIndex < $1.roundIndex }
        if let first = rounds.first(where: { $0.roundIndex == 0 }) {
            return first
        }

        let round = CalculationRound(
            id: CalculationGenerator.roundID(dayKey: key, roundIndex: 0),
            dayKey: key,
            roundIndex: 0,
            questions: CalculationGenerator.generateInitialRound(dayKey: key),
            startedAt: referenceDate,
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
        modelContext.insert(round)
        try modelContext.save()
        AppDataChangeCenter.post()
        return round
    }

    @discardableResult
    static func createRetryRound(
        after previousRound: CalculationRound,
        at date: Date = .now,
        in modelContext: ModelContext
    ) throws -> CalculationRound {
        let nextIndex = previousRound.roundIndex + 1
        let existing = try modelContext.fetch(FetchDescriptor<CalculationRound>())
            .first { $0.dayKey == previousRound.dayKey && $0.roundIndex == nextIndex }
        if let existing { return existing }

        let answersByID = Dictionary(uniqueKeysWithValues: previousRound.answers.map { ($0.questionID, $0) })
        let wrongKinds = previousRound.questions.compactMap { question -> CalculationKind? in
            answersByID[question.id]?.isCorrect == false ? question.kind : nil
        }
        let round = CalculationRound(
            id: CalculationGenerator.roundID(dayKey: previousRound.dayKey, roundIndex: nextIndex),
            dayKey: previousRound.dayKey,
            roundIndex: nextIndex,
            questions: CalculationGenerator.generateRetryRound(
                dayKey: previousRound.dayKey,
                roundIndex: nextIndex,
                wrongKinds: wrongKinds
            ),
            startedAt: date,
            createdAt: date,
            updatedAt: date
        )
        modelContext.insert(round)
        try modelContext.save()
        AppDataChangeCenter.post()
        return round
    }

    static func saveDraft(
        answers: [CalculationAnswer],
        for round: CalculationRound,
        in modelContext: ModelContext
    ) {
        guard !round.isSubmitted else { return }
        round.answers = answers
        try? modelContext.save()
    }

    @discardableResult
    static func submit(
        answers: [CalculationAnswer],
        for round: CalculationRound,
        at date: Date = .now,
        in modelContext: ModelContext
    ) throws -> [CalculationAnswer] {
        guard !round.isSubmitted else { return round.answers }
        let questionByID = Dictionary(uniqueKeysWithValues: round.questions.map { ($0.id, $0) })
        let judged = answers.map { answer -> CalculationAnswer in
            var judged = answer
            judged.isCorrect = questionByID[answer.questionID].map {
                CalculationAnswerEvaluator.isCorrect(answer, for: $0)
            } ?? false
            return judged
        }
        round.answers = judged
        round.correctCount = judged.filter { $0.isCorrect == true }.count
        round.submittedAt = date
        round.durationSeconds = max(0, date.timeIntervalSince(round.startedAt))
        round.updatedAt = date

        if round.isPerfect {
            _ = PointLedgerService.awardDailyCalculation(
                dayKey: round.dayKey,
                completedAt: date,
                in: modelContext
            )
        }
        try modelContext.save()
        AppDataChangeCenter.post()
        return judged
    }
}
