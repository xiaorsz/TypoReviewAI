import XCTest

final class CoachLabUITests: XCTestCase {
    @MainActor func testReviewPlanCardShowsCompactSummaryAndExpandableTruthfulDetails() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-coach-summary"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 20))
        let details = app.buttons["coach.plan.details"]
        for _ in 0..<6 where !details.isHittable { app.swipeUp() }
        XCTAssertTrue(details.isHittable)
        XCTAssertTrue(app.staticTexts["今日 · 待复习 5 题"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "分页")).firstMatch.exists)
        saveScreenshot(app, "07-复习安排摘要")
        details.tap()
        for _ in 0..<3 where !app.staticTexts["需要重新检查"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["需要重新检查"].exists)
        XCTAssertTrue(app.staticTexts["5. Portugal"].exists)
        saveScreenshot(app, "08-复习安排详情")
    }

    @MainActor func testCoachConfigurationDraftSurvivesExecutionLogNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 20))
        selectTab("设置", in: app)
        app.buttons["AI 家庭复习教练"].tap()
        XCTAssertTrue(app.navigationBars["AI 教练"].waitForExistence(timeout: 10))
        let authorization = app.switches["coach.authorize"]
        XCTAssertTrue(authorization.waitForExistence(timeout: 10))
        for _ in 0..<3 where !authorization.isHittable { app.swipeUp() }
        XCTAssertEqual(authorization.value as? String, "0")
        // SwiftUI exposes the whole labelled row as the switch. Tap the
        // trailing control rather than the centre of its text accessibility frame.
        authorization.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        saveScreenshot(app, "06-教练授权草稿")
        let switchedOn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: authorization)
        XCTAssertEqual(XCTWaiter.wait(for: [switchedOn], timeout: 5), .completed)
        let logs = app.buttons["coach.logs"]
        for _ in 0..<5 where !logs.isHittable { app.swipeUp() }
        XCTAssertTrue(logs.isHittable)
        logs.tap()
        XCTAssertTrue(app.navigationBars["教练执行记录"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<5 where !authorization.isHittable { app.swipeDown() }
        XCTAssertEqual(authorization.value as? String, "1", "往返执行记录不应丢失未保存的授权草稿")
        authorization.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let run = app.buttons["coach.run"]
        for _ in 0..<5 where !run.isHittable { app.swipeUp() }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: run)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        run.tap()
        XCTAssertTrue(app.staticTexts["coach.status"].label.contains("授权"))
    }

    @MainActor func testSettingsEntryScrollAndDeferredPreferences() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 20))
        selectTab("设置", in: app)
        XCTAssertTrue(app.textFields["输入名字"].waitForExistence(timeout: 10))
        // The heavy editors are absent from the root and still reachable.
        XCTAssertFalse(app.datePickers["开始时间"].exists)
        XCTAssertFalse(app.secureTextFields["DeepSeek API Key"].exists)
        let reading = app.buttons["晨读与看板"].firstMatch
        for _ in 0..<4 where !reading.isHittable { app.swipeUp() }
        XCTAssertTrue(reading.exists); reading.tap()
        XCTAssertTrue(app.navigationBars["晨读与看板"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["晨读自动播放"].exists)
        saveScreenshot(app, "04-晨读偏好")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let ai = app.buttons["AI 小结与 API Key"].firstMatch
        XCTAssertTrue(ai.waitForExistence(timeout: 10)); ai.tap()
        XCTAssertTrue(app.navigationBars["AI 小结与 API Key"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["启用 AI 今日小结"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<4 where !app.buttons["开源许可"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["开源许可"].isHittable)
        saveScreenshot(app, "05-设置滚动")
        selectTab("首页", in: app)
        selectTab("设置", in: app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
    }

    @MainActor func testFullApplicationKeepsOriginalTabsAndAddsCoach() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "计算，")).firstMatch.exists)
        // Check the whole loaded home, including the former calculation card.
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "每日计算，")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["每日计算"].exists)
        XCTAssertFalse(app.buttons["开始计算"].exists)
        XCTAssertFalse(app.buttons["继续补练"].exists)
        for _ in 0..<3 { app.swipeDown() }
        saveScreenshot(app, "01-完整首页")
        selectTab("题库", in: app)
        XCTAssertTrue(app.navigationBars["题库"].waitForExistence(timeout: 10))
        selectTab("听写", in: app)
        XCTAssertTrue(app.buttons["新增听写计划"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["新增听写计划"].firstMatch.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        for _ in 0..<3 where !editor.isHittable { app.swipeUp() }
        editor.tap(); editor.typeText("辨别 | biàn bié\n认真 | 做事不马虎")
        app.buttons["保存计划"].tap()
        XCTAssertTrue(app.buttons["新增听写计划"].firstMatch.waitForExistence(timeout: 10))
        saveScreenshot(app, "02-完整听写列表")
        selectTab("待办", in: app)
        XCTAssertTrue(app.navigationBars["任务管理"].waitForExistence(timeout: 10))
        selectTab("设置", in: app)
        XCTAssertTrue(app.buttons["AI 家庭复习教练"].waitForExistence(timeout: 10))
        app.buttons["AI 家庭复习教练"].tap()
        XCTAssertTrue(app.navigationBars["AI 教练"].waitForExistence(timeout: 10))
        let run = app.buttons["coach.run"]
        for _ in 0..<4 where !run.isHittable { app.swipeUp() }
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: run)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        run.tap()
        let status = app.staticTexts["coach.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("授权"), "未授权时点击也必须有明确反馈")
        for _ in 0..<4 where !app.buttons["独立听写录入"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["独立听写录入"].exists)
        saveScreenshot(app, "03-AI教练")
        app.terminate()
    }
    @MainActor private func saveScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func selectTab(_ title: String, in app: XCUIApplication) {
        let tab = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
    }
}
