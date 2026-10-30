import SwiftData
import XCTest
@testable import CoachLab

@MainActor
final class DailyCalculationTests: XCTestCase {
    func testInitialRoundIsDeterministicAndHasExpectedComposition() {
        let first = CalculationGenerator.generateInitialRound(dayKey: "2026-08-17")
        let second = CalculationGenerator.generateInitialRound(dayKey: "2026-08-17")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(first.map(\.kind), [
            .multiplication, .division, .mixed, .mixed, .numberSense,
        ])
        XCTAssertEqual(Set(first.map(\.fingerprint)).count, first.count)
    }

    func testGeneratedQuestionsStayWithinIntegerRules() throws {
        for offset in 0..<366 {
            let dayKey = String(format: "2026-%03d", offset)
            let questions = CalculationGenerator.generateInitialRound(dayKey: dayKey)
                + CalculationGenerator.generateRetryRound(
                    dayKey: dayKey,
                    roundIndex: 1,
                    wrongKinds: CalculationKind.allCases
                )

            for question in questions {
                XCTAssertGreaterThanOrEqual(question.expectedValue, 0, question.expression)
                if question.kind == .division {
                    let parts = question.expression.components(separatedBy: " ÷ ")
                    XCTAssertEqual(parts.count, 2)
                    let dividend = try XCTUnwrap(Int(parts[0]))
                    let divisor = try XCTUnwrap(Int(parts[1]))
                    let remainder = question.expectedRemainder ?? 0
                    XCTAssertGreaterThan(divisor, 0)
                    XCTAssertGreaterThanOrEqual(remainder, 0)
                    XCTAssertLessThan(remainder, divisor)
                    XCTAssertEqual(dividend, divisor * question.expectedValue + remainder)
                }
            }
        }
    }

    func testDailyRotationCoversCalculationTemplates() {
        var multiplicationTemplates = Set<String>()
        var numberSenseTemplates = Set<String>()
        var divisionModes = Set<CalculationAnswerMode>()
        var expressionsByPosition = Array(repeating: Set<String>(), count: 5)

        for day in 1...60 {
            let questions = CalculationGenerator.generateInitialRound(
                dayKey: String(format: "2026-09-%02d", day)
            )
            multiplicationTemplates.insert(questions[0].templateID)
            divisionModes.insert(questions[1].answerMode)
            numberSenseTemplates.insert(questions[4].templateID)
            if day <= 30 {
                for index in questions.indices {
                    expressionsByPosition[index].insert(questions[index].expression)
                }
            }
        }

        XCTAssertEqual(multiplicationTemplates.count, 4)
        XCTAssertEqual(divisionModes, [.integer, .quotientAndRemainder])
        XCTAssertEqual(numberSenseTemplates.count, 8)
        XCTAssertTrue(expressionsByPosition.allSatisfy { $0.count >= 28 })
    }

    func testAnswerEvaluatorSupportsFullwidthDigitsAndRemainders() {
        let question = CalculationGenerator.generateInitialRound(dayKey: "2026-08-17")
            .first { $0.kind == .division }!
        let correct = CalculationAnswer(
            questionID: question.id,
            value: fullwidth(question.expectedValue),
            remainder: fullwidth(question.expectedRemainder ?? 0)
        )

        XCTAssertTrue(CalculationAnswerEvaluator.isComplete(correct, for: question))
        XCTAssertTrue(CalculationAnswerEvaluator.isCorrect(correct, for: question))

        var wrong = correct
        wrong.value = "\(question.expectedValue + 1)"
        XCTAssertFalse(CalculationAnswerEvaluator.isCorrect(wrong, for: question))
    }

    func testRetryRoundHasThreeQuestionsAndTargetsWrongKinds() {
        let questions = CalculationGenerator.generateRetryRound(
            dayKey: "2026-08-17",
            roundIndex: 2,
            wrongKinds: [.division, .numberSense]
        )

        XCTAssertEqual(questions.count, 3)
        XCTAssertTrue(questions.allSatisfy { [.division, .numberSense].contains($0.kind) })
        XCTAssertEqual(Set(questions.map(\.fingerprint)).count, 3)
    }

    func testWrongRoundThenPerfectRetryAwardsOnlyOnce() throws {
        let container = try ModelContainer(
            for: CalculationRound.self,
            PointLedgerEntry.self,
            PointRewardState.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_776_600_000)
        let firstRound = try CalculationSessionService.ensureInitialRound(
            referenceDate: start,
            in: context
        )
        var firstAnswers = correctAnswers(for: firstRound)
        firstAnswers[0].value = "-1"

        let judged = try CalculationSessionService.submit(
            answers: firstAnswers,
            for: firstRound,
            at: start.addingTimeInterval(60),
            in: context
        )
        XCTAssertEqual(judged.filter { $0.isCorrect == true }.count, 4)
        XCTAssertFalse(firstRound.isPerfect)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PointLedgerEntry>()).isEmpty)

        let retry = try CalculationSessionService.createRetryRound(
            after: firstRound,
            at: start.addingTimeInterval(70),
            in: context
        )
        XCTAssertEqual(retry.questions.count, 3)
        _ = try CalculationSessionService.submit(
            answers: correctAnswers(for: retry),
            for: retry,
            at: start.addingTimeInterval(120),
            in: context
        )
        _ = try CalculationSessionService.submit(
            answers: correctAnswers(for: retry),
            for: retry,
            at: start.addingTimeInterval(150),
            in: context
        )

        let rewards = try context.fetch(FetchDescriptor<PointLedgerEntry>())
            .filter { $0.sourceType == .dailyCalculation }
        XCTAssertTrue(retry.isPerfect)
        XCTAssertEqual(rewards.count, 1)
        XCTAssertEqual(rewards.first?.amount, 5)
    }

    private func correctAnswers(for round: CalculationRound) -> [CalculationAnswer] {
        round.questions.map { question in
            CalculationAnswer(
                questionID: question.id,
                value: "\(question.expectedValue)",
                remainder: question.expectedRemainder.map(String.init) ?? ""
            )
        }
    }

    private func fullwidth(_ value: Int) -> String {
        String(value).map { character in
            guard let digit = character.wholeNumberValue,
                  let scalar = UnicodeScalar(0xFF10 + digit) else {
                return String(character)
            }
            return String(Character(scalar))
        }.joined()
    }
}
