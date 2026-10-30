import XCTest
import CloudKit
@testable import CoachLab

@MainActor final class CloudSyncDiagnosticTests: XCTestCase {
    func testProbeDefinitionsCoverEveryPersistedModelAndNewAIPlanFields() throws {
        let records = SyncStatusStore.cloudKitDiagnosticProbeRecords(zoneID: CKRecordZone.ID(zoneName: "local-test"))
        let expected = Set([
            "CD_ReviewItem", "CD_ReviewRecord", "CD_SyncDeletion", "CD_ReviewDailyPlan",
            "CD_TaskItem", "CD_TaskCompletion", "CD_TaskSubitem", "CD_TaskExecutionRecord",
            "CD_TaskSubitemExecutionRecord", "CD_AppSettings", "CD_DictationSession",
            "CD_DictationEntry", "CD_ScheduleItem", "CD_MediaAsset", "CD_PointLedgerEntry",
            "CD_PointRewardState", "CD_CalculationRound"
        ])
        XCTAssertEqual(Set(records.map(\.recordType)), expected)
        XCTAssertEqual(records.count, expected.count)
        let plan = try XCTUnwrap(records.first { $0.recordType == "CD_ReviewDailyPlan" })
        XCTAssertNotNil(plan["CD_coachSubjectRawValue"])
        XCTAssertNotNil(plan["CD_coachRationale"])
        XCTAssertNotNil(plan["CD_startedAt"])
        let deletion = try XCTUnwrap(records.first { $0.recordType == "CD_SyncDeletion" })
        XCTAssertEqual(deletion["CD_entityType"] as? String, "__cloudkit_probe__")
        XCTAssertNotNil(deletion["CD_recordID"])
        let calculation = try XCTUnwrap(records.first { $0.recordType == "CD_CalculationRound" })
        XCTAssertNotNil(calculation["CD_submittedAt"])
        XCTAssertNotNil(calculation["CD_durationSeconds"])
    }

    func testZoneFailureDoesNotClaimARecordSchemaDiagnosis() {
        let error = NSError(domain: CKError.errorDomain, code: CKError.Code.serverRejectedRequest.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Failed to modify some record zones"])
        let account = SyncStatusStore.cloudKitDirectFailure(stage: .account, error: error)
        let zone = SyncStatusStore.cloudKitDirectFailure(stage: .zones, error: error)
        let model = SyncStatusStore.cloudKitDirectFailure(stage: .models, error: error)
        XCTAssertTrue(account.contains("账户检查失败"))
        XCTAssertFalse(account.contains("账户可用"))
        XCTAssertTrue(zone.contains("账户可用，但同步区域访问失败"))
        XCTAssertTrue(zone.contains("尚未执行模型写入测试"))
        XCTAssertFalse(zone.contains("Schema 是否已部署完整"))
        XCTAssertTrue(model.contains("账户和同步区域检查通过"))
        XCTAssertTrue(zone.contains("CKErrorDomain 15"))
    }

    func testErrorDetailsExposeKnownReasonsAndNestedErrorsWithoutCredentialsOrUserInfoDump() {
        let inner = NSError(domain: "CKInternalErrorDomain", code: 1011, userInfo: [
            NSLocalizedDescriptionKey: "Failed to modify some record zones",
            NSLocalizedFailureReasonErrorKey: "Container is unavailable; api_key=FAKE_SECRET_API_KEY",
            "ServerDescription": "Zone operation rejected. Authorization: Bearer FAKE_BEARER_VALUE",
            "NSDebugDescription": "request rejected; token=FAKE_TOKEN_VALUE",
            "arbitrary-private-data": "MUST_NOT_DUMP_USER_INFO"
        ])
        let error = NSError(domain: CKError.errorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "Partial failure sk-FAKE_SECRET_123456",
            CKErrorRetryAfterKey: 5,
            CKPartialErrorsByItemIDKey: ["test-zone": inner]
        ])
        let text = SyncStatusStore.deepErrorDescription(error)
        XCTAssertTrue(text.contains("失败原因"))
        XCTAssertTrue(text.contains("服务器说明"))
        XCTAssertTrue(text.contains("CKInternalErrorDomain 1011"))
        XCTAssertTrue(text.contains("重试等待: 5秒"))
        XCTAssertTrue(text.contains("test-zone"))
        for secret in ["FAKE_SECRET_API_KEY", "FAKE_BEARER_VALUE", "FAKE_TOKEN_VALUE", "sk-FAKE_SECRET_123456", "MUST_NOT_DUMP_USER_INFO"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    func testProbeSummaryDistinguishesWriteChecksFromCompletedSynchronization() {
        let passed = SyncStatusStore.CloudKitWriteProbeResult(label: "计划", recordType: "CD_ReviewDailyPlan", succeeded: true, detail: "")
        let failed = SyncStatusStore.CloudKitWriteProbeResult(label: "计划", recordType: "CD_ReviewDailyPlan", succeeded: false, detail: "server rejected request")
        let success = SyncStatusStore.cloudKitDirectTestSummary(accountStatus: .available,
            coreResults: [passed], taskResults: [], pointsResults: [])
        XCTAssertTrue(success.contains("1 类模型的测试字段写入成功"))
        XCTAssertTrue(success.contains("仍需查看同步事件"))
        XCTAssertFalse(success.contains("全部 SwiftData 模型"))
        let failure = SyncStatusStore.cloudKitDirectTestSummary(accountStatus: .available,
            coreResults: [failed], taskResults: [], pointsResults: [])
        XCTAssertTrue(failure.contains("若明确提示记录类型或字段缺失"))
        XCTAssertFalse(failure.contains("优先检查 Production"))
    }

    func testRetryDelayAcceptsIntegerAndFractionalNumbersAndRejectsInvalidValues() {
        for (value, expected) in [(NSNumber(value: 5), "5秒"), (NSNumber(value: 2.25), "3秒")] {
            let error = NSError(domain: CKError.errorDomain, code: CKError.Code.requestRateLimited.rawValue,
                userInfo: [CKErrorRetryAfterKey: value])
            XCTAssertTrue(SyncStatusStore.deepErrorDescription(error).contains("重试等待: \(expected)"))
        }
        for value in [NSNumber(value: -1), NSNumber(value: Double.infinity), NSNumber(value: Double.nan)] {
            let error = NSError(domain: CKError.errorDomain, code: CKError.Code.requestRateLimited.rawValue,
                userInfo: [CKErrorRetryAfterKey: value])
            XCTAssertFalse(SyncStatusStore.deepErrorDescription(error).contains("重试等待:"))
        }
    }

    func testBuildLabelReportsCompileConfigurationWithoutClaimingPushEntitlements() {
        let store = SyncStatusStore()
        store.configure(cloudKitEnabled: false)
        #if DEBUG
        XCTAssertEqual(store.buildConfiguration, "Debug 构建")
        #else
        XCTAssertEqual(store.buildConfiguration, "Release 构建")
        #endif
    }
}
