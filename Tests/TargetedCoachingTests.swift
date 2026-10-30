import XCTest
@testable import CoachCore

final class TargetedCoachingTests: XCTestCase {
    private let now = Codec.date("2026-10-30")!.addingTimeInterval(12 * 3600)
    private func record(_ item: ReviewItem, days: Int, correct: Bool = false, mode: String = "scheduled") -> ReviewRecord {
        var record = ReviewRecord(itemID: item.id, correct: correct, oldStage: 2, newStage: correct ? 3 : 0,
                                  now: Calendar.current.date(byAdding: .day, value: days, to: now)!)
        record.modeRawValue = mode; return record
    }
    private func fixture() throws -> (ReviewItem, [ReviewRecord], RepeatedErrorFinding) {
        let item = ReviewItem(type: "单词", content: "Portugal", now: now)
        let records = [record(item, days: -4), record(item, days: -3), record(item, days: -1)]
        let finding = try XCTUnwrap(TargetedCoaching.findings(items: [item], records: records, subject: .english, now: now).first)
        return (item, records, finding)
    }
    private var validJSON: String {
        """
        {"strategy":"先辨析写法，再在语境中回忆。只有对错记录，具体错因尚不确定。","exercises":[{"kind":"choice","prompt":"选出正确写法。","answer":"Portugal","choices":["Portugal","Portugla","Protugal"]},{"kind":"cloze","prompt":"Lisbon is the capital of ____.","answer":"Portugal","choices":[]}]}
        """
    }

    func testAnalysisRequiresThreeRealErrorsAcrossTwoDaysAndHonorsScopeAndWindow() throws {
        let (item, records, _) = try fixture()
        var sameDay = records
        for i in sameDay.indices { sameDay[i].reviewedAt = now.addingTimeInterval(-Double(i + 1)) }
        XCTAssertTrue(TargetedCoaching.findings(items: [item], records: sameDay, subject: .english, now: now).isEmpty)
        XCTAssertTrue(TargetedCoaching.findings(items: [item], records: Array(records.prefix(2)), subject: .english, now: now).isEmpty)
        XCTAssertTrue(TargetedCoaching.findings(items: [item], records: records, subject: .chinese, now: now).isEmpty)
        let outside = [record(item, days: -31), record(item, days: -40), record(item, days: 1)]
        XCTAssertTrue(TargetedCoaching.findings(items: [item], records: outside, subject: .all, now: now).isEmpty)
        XCTAssertEqual(TargetedCoaching.findings(items: [item], records: records + records, subject: .english, now: now).first?.wrong.count, 3)
    }

    func testDuplicateContentIsOneFindingAndTwoLaterCorrectDaysStopPromotingIt() throws {
        let (item, records, _) = try fixture()
        let duplicate = ReviewItem(type: "单词", content: item.content, now: now)
        let extra = record(duplicate, days: -2)
        let findings = TargetedCoaching.findings(items: [duplicate, item], records: records + [extra], subject: .all, now: now)
        XCTAssertEqual(findings.count, 1); XCTAssertEqual(findings.first?.wrong.count, 4)
        let later = records + [record(item, days: 1, correct: true), record(item, days: 2, correct: true)]
        XCTAssertTrue(TargetedCoaching.findings(items: [item], records: later, subject: .english, now: now.addingTimeInterval(3 * 86400)).isEmpty)
    }

    func testValidatedAIQuestionsUseCanonicalAnswerAndRejectMalformedOrLeakingQuestions() throws {
        let (_, _, finding) = try fixture()
        let draft = try TargetedCoaching.aiDraft(validJSON, finding: finding, observation: .unknown, mistake: "", now: now)
        XCTAssertTrue(draft.isAIGenerated); XCTAssertEqual(draft.exercises.count, 2)
        XCTAssertEqual(Set(draft.exercises.map(\.answer)), ["Portugal"])
        for bad in [validJSON.replacingOccurrences(of: "\"answer\":\"Portugal\"", with: "\"answer\":\"portugal\""),
                    validJSON.replacingOccurrences(of: "Lisbon is the capital of ____.", with: "Portugal is ____.") ,
                    validJSON.replacingOccurrences(of: "Protugal", with: "Portugla"), "not json"] {
            XCTAssertThrowsError(try TargetedCoaching.aiDraft(bad, finding: finding, observation: .unknown, mistake: "", now: now))
        }
    }

    func testApprovalAndIdempotentSubmissionPreserveCaseAndKeepPracticeSeparate() throws {
        let (_, records, finding) = try fixture()
        var draft = try TargetedCoaching.aiDraft(validJSON, finding: finding, observation: .spelling, mistake: "portugal", now: now)
        let first = draft.exercises[0]
        XCTAssertThrowsError(try draft.answer(exerciseID: first.id, response: "Portugal", parentJudgment: nil, revealed: false, now: now))
        draft.approve(now: now)
        try draft.answer(exerciseID: first.id, response: "portugal", parentJudgment: nil, revealed: false, now: now)
        XCTAssertFalse(draft.attempts[0].correct)
        XCTAssertThrowsError(try draft.answer(exerciseID: first.id, response: "Portugal", parentJudgment: nil, revealed: false, now: now))
        try draft.answer(exerciseID: draft.exercises[1].id, response: "Portugal", parentJudgment: nil, revealed: false, now: now)
        XCTAssertEqual(draft.completedAt, now); XCTAssertEqual(records.count, 3)
        XCTAssertEqual(draft.attempts.count, 2)
    }

    func testVerificationIgnoresSameDayRetriesFutureRecordsAndRequiresTwoDifferentDays() throws {
        let (item, records, finding) = try fixture()
        var draft = TargetedCoaching.localDraft(finding, observation: .unknown, mistake: "", now: now)
        draft.approve(now: now)
        try draft.answer(exerciseID: draft.exercises[0].id, response: "", parentJudgment: true, revealed: true, now: now)
        XCTAssertFalse(draft.isAIGenerated)
        let sameDay = ReviewRecord(itemID: item.id, correct: true, oldStage: 0, newStage: 1, now: now.addingTimeInterval(60))
        let retry = record(item, days: 1, correct: true, mode: "retry")
        let first = record(item, days: 1, correct: true)
        let otherSameDay = record(item, days: 1, correct: true)
        let second = record(item, days: 2, correct: true, mode: "dictation")
        func report(_ additions: [ReviewRecord], _ days: Int = 3) -> CoachingVerificationReport {
            TargetedCoaching.verification(draft, items: [item], records: records + additions,
                                         now: now.addingTimeInterval(Double(days) * 86400))
        }
        XCTAssertEqual(report([sameDay, retry]).state, .awaiting)
        XCTAssertEqual(report([first, otherSameDay]).state, .oneCorrect)
        XCTAssertEqual(report([first, second, second]).state, .improving)
        XCTAssertEqual(report([first, second], 1).state, .oneCorrect)
        let wrong = record(item, days: 3)
        XCTAssertEqual(report([first, second, wrong]).state, .needsPractice)
        XCTAssertEqual(report([first, second]).state, .improving, "撤销后续错判后，重新计算实际结果")
        XCTAssertEqual(report([first]).evidence.map(\.id), [first.id])
    }

    func testRemovedOrEditedSourceInvalidatesOldInterventionIncludingCapitalizationEdits() throws {
        let (item, records, finding) = try fixture()
        let draft = TargetedCoaching.localDraft(finding, observation: .unknown, mistake: "", now: now)
        XCTAssertTrue(TargetedCoaching.sourceIsValid(draft, items: [item], records: records))
        XCTAssertEqual(TargetedCoaching.verification(draft, items: [item], records: Array(records.dropLast()), now: now).state, .invalidated)
        var edited = item; edited.content = "portugal"
        XCTAssertFalse(TargetedCoaching.sourceIsValid(draft, items: [edited], records: records))
        var corrected = records; corrected[0].resultRawValue = "correct"
        XCTAssertFalse(TargetedCoaching.sourceIsValid(draft, items: [item], records: corrected))
    }

    func testDraftAndPartialAttemptsSurviveSerializationWithEvidenceIDs() throws {
        let (_, _, finding) = try fixture()
        var draft = try TargetedCoaching.aiDraft(validJSON, finding: finding, observation: .unknown, mistake: "", now: now)
        draft.approve(now: now)
        try draft.answer(exerciseID: draft.exercises[0].id, response: "Portugal", parentJudgment: nil, revealed: false, now: now)
        var state = TargetedCoachingState(datasetID: UUID()); state.interventions = [draft]
        let restored = try TargetedCoachingState.decoder().decode(TargetedCoachingState.self, from: TargetedCoachingState.encoder().encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.interventions[0].baseline.map(\.id), finding.evidence.map(\.id))
        XCTAssertNil(restored.interventions[0].completedAt)
    }

    func testPersistedEvidencePreservesNativeSubsecondPrecision() throws {
        let (item, records, _) = try fixture()
        let precise = records.map { record -> ReviewRecord in
            var next = record; next.reviewedAt = record.reviewedAt.addingTimeInterval(0.123456789); return next
        }
        let finding = try XCTUnwrap(TargetedCoaching.findings(items: [item], records: precise, subject: .english, now: now).first)
        let draft = TargetedCoaching.localDraft(finding, observation: .unknown, mistake: "", now: now.addingTimeInterval(0.875))
        var state = TargetedCoachingState(datasetID: UUID()); state.interventions = [draft]
        let restored = try TargetedCoachingState.decoder().decode(TargetedCoachingState.self, from: TargetedCoachingState.encoder().encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertTrue(TargetedCoaching.sourceIsValid(restored.interventions[0], items: [item], records: precise))
    }
    private var lessonJSON: String {
        """
        {"meaning":"葡萄牙，欧洲的一个国家。","structure":"注意首字母 P 大写。","example":"Portugal is in Europe.","exampleTranslation":"葡萄牙在欧洲。","question":"Lisbon is the capital of ____.","answer":"Portugal"}
        """
    }

    func testWordLessonExplainsMeaningAndStructureThenUsesOneCanonicalInputQuestion() throws {
        let (_, _, finding) = try fixture()
        var draft = try TargetedCoaching.lessonDraft(lessonJSON, finding: finding, now: now)
        XCTAssertNotNil(draft.lesson); XCTAssertEqual(draft.exercises.count, 1)
        XCTAssertEqual(draft.lesson?.structure, "注意首字母 P 大写。")
        draft.approve(now: now)
        try draft.answer(exerciseID: draft.exercises[0].id, response: " Portugal ", parentJudgment: nil, revealed: false, now: now)
        XCTAssertTrue(draft.attempts[0].correct); XCTAssertNotNil(draft.completedAt)
        for bad in [lessonJSON.replacingOccurrences(of: "\"answer\":\"Portugal\"", with: "\"answer\":\"portugal\""),
                    lessonJSON.replacingOccurrences(of: "Lisbon is the capital of ____.", with: "Portugal is _____."),
                    lessonJSON.replacingOccurrences(of: "葡萄牙，欧洲的一个国家。", with: ""), "{}"] {
            XCTAssertThrowsError(try TargetedCoaching.lessonDraft(bad, finding: finding, now: now))
        }
        let noStructure = lessonJSON.replacingOccurrences(of: "注意首字母 P 大写。", with: "")
        XCTAssertEqual(try TargetedCoaching.lessonDraft(noStructure, finding: finding, now: now).lesson?.structure, "")
    }

    func testFiveWordGroupsThenRemainingTwoAndNoSameDayDuplicates() throws {
        var items: [ReviewItem] = [], records: [ReviewRecord] = []
        for word in ["one", "two", "three", "four", "five", "six", "seven"] {
            let item = ReviewItem(type: "单词", content: word, now: now); items.append(item)
            records += [-4, -3, -1].map { record(item, days: $0) }
        }
        let findings = TargetedCoaching.findings(items: items, records: records, subject: .english, now: now)
        var state = TargetedCoachingState(datasetID: UUID())
        let first = TargetedCoaching.recommendations(findings: findings, state: state, items: items, records: records, now: now)
        XCTAssertEqual(first.count, 5)
        var group = CoachingStudyGroup(findings: first, now: now)
        for index in group.targets.indices { group.targets[index].skipped = true }
        state.groups.append(group)
        let second = TargetedCoaching.recommendations(findings: findings, state: state, items: items, records: records, now: now)
        XCTAssertEqual(second.count, 2)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        var last = CoachingStudyGroup(findings: second, now: now)
        for index in last.targets.indices { last.targets[index].skipped = true }
        state.groups.append(last)
        XCTAssertTrue(TargetedCoaching.recommendations(findings: findings, state: state, items: items, records: records, now: now).isEmpty)
    }

    func testOldMetadataMigratesWithoutLosingDatesOrRequiringNewParentApproval() throws {
        let (_, _, finding) = try fixture()
        let draft = TargetedCoaching.localDraft(finding, observation: .unknown, mistake: "", now: now)
        var old = TargetedCoachingState(datasetID: UUID()); old.interventions = [draft]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: TargetedCoachingState.encoder().encode(old)) as? [String: Any])
        object["schemaVersion"] = 1; object.removeValue(forKey: "groups")
        let migrated = try TargetedCoachingState.decoder().decode(TargetedCoachingState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.schemaVersion, 2); XCTAssertTrue(migrated.groups.isEmpty)
        XCTAssertEqual(migrated.interventions, old.interventions)
        XCTAssertNil(migrated.interventions[0].lesson)
    }

    func testBasicLessonHasNoInventedStructureOrExampleAndRejectsMissingMeaning() throws {
        let (_, _, finding) = try fixture()
        let draft = try TargetedCoaching.basicLesson(finding, meaning: "葡萄牙", now: now)
        XCTAssertFalse(draft.isAIGenerated); XCTAssertEqual(draft.exercises.first?.kind, .cloze)
        XCTAssertEqual(draft.lesson?.meaning, "葡萄牙"); XCTAssertEqual(draft.lesson?.structure, "")
        XCTAssertEqual(draft.lesson?.example, "")
        XCTAssertThrowsError(try TargetedCoaching.basicLesson(finding, meaning: " ", now: now))
    }

}
