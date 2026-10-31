import XCTest

final class CoachLabUITests: XCTestCase {
    @MainActor func testWordLessonsFiveThenTwoWithIndependentScreenAnswers() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-targeted"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 20))
        let entry = app.buttons["targeted.home"]
        for _ in 0..<6 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.isHittable); entry.tap()
        XCTAssertTrue(app.navigationBars["AI 词语讲解"].waitForExistence(timeout: 10))
        let start = app.buttons["targeted.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        XCTAssertTrue(app.navigationBars["词语学习"].waitForExistence(timeout: 10))
        let basic = app.buttons["targeted.basic"]
        XCTAssertTrue(basic.waitForExistence(timeout: 10)); basic.tap()
        var words = Set<String>()
        for groupSize in [5, 2] {
            for index in 0..<groupSize {
                let wordLabel = app.staticTexts["targeted.word"]
                XCTAssertTrue(wordLabel.waitForExistence(timeout: 10))
                let word = wordLabel.label
                XCTAssertTrue(words.insert(word).inserted, "同一天不能重复推荐")
                XCTAssertTrue(app.staticTexts["第 \(index + 1) / \(groupSize) 个词"].exists)
                XCTAssertTrue(app.staticTexts["是什么意思"].exists)
                if words.count == 1 { saveScreenshot(app, "14-孩子自主词语讲解") }
                let attempt = app.buttons["targeted.try"]
                for _ in 0..<3 where !attempt.isHittable { app.swipeUp() }
                attempt.tap()
                let input = app.textFields["targeted.answer"]
                XCTAssertTrue(input.waitForExistence(timeout: 10))
                XCTAssertFalse(wordLabel.isHittable, "进入作答后隐藏讲解和答案")
                XCTAssertFalse(app.buttons["targeted.submit"].isEnabled)
                input.tap(); input.typeText(word)
                let submit = app.buttons["targeted.submit"]
                XCTAssertTrue(submit.isHittable); submit.tap()
                XCTAssertTrue(app.staticTexts["答对了！"].waitForExistence(timeout: 10))
                if words.count == 1 { saveScreenshot(app, "15-屏幕作答自动反馈") }
                app.buttons["targeted.next"].tap()
            }
            XCTAssertTrue(app.staticTexts["这一组学完了"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["完成 \(groupSize) 个词，本次答对 \(groupSize) 个。"].exists)
            if groupSize == 5 {
                saveScreenshot(app, "16-完成五个再学五个")
                let more = app.buttons["targeted.more"]
                XCTAssertTrue(more.isHittable); more.tap()
            } else {
                XCTAssertFalse(app.buttons["targeted.more"].exists)
                XCTAssertTrue(app.staticTexts["今天没有更多新词了，休息一下吧。"].exists)
            }
        }
        XCTAssertEqual(words.count, 7)
        app.buttons["targeted.finish"].tap()
        XCTAssertTrue(app.buttons["学习记录"].waitForExistence(timeout: 5)); app.buttons["学习记录"].tap()
        XCTAssertTrue(app.staticTexts["等待隔日验证"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["targeted.approve"].exists)
    }

    @MainActor func testClassroomMeaningStructureAndWrongAnswerFeedback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-targeted", "--ui-testing-targeted-rich"]
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["targeted.home"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20)); entry.tap()
        let start = app.buttons["targeted.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        saveScreenshot(app, "20-词语小课堂入口"); start.tap()
        let word = app.staticTexts["targeted.word"]
        XCTAssertTrue(word.waitForExistence(timeout: 10)); XCTAssertEqual(word.label, "辨别")
        let progress = app.staticTexts["第 1 / 5 个词"]
        XCTAssertLessThan(word.frame.minY - progress.frame.maxY, 100, "顶部进度与朗读状态合并，词语应紧随其后")
        let wordSpeech = app.buttons["targeted.speech.word"]
        XCTAssertGreaterThanOrEqual(wordSpeech.frame.width, 43.5, "44 点触控区域允许坐标换算的小数误差")
        XCTAssertLessThanOrEqual(wordSpeech.frame.minX - word.frame.maxX, 16, "朗读按钮应紧邻词语")
        XCTAssertFalse(app.staticTexts["点喇叭，听听怎么读"].exists)
        let memory = app.staticTexts["targeted.soundMemory"]
        for _ in 0..<4 where !memory.isHittable { app.swipeUp() }
        XCTAssertTrue(memory.isHittable)
        XCTAssertTrue(app.staticTexts["组成与记忆"].exists)
        XCTAssertTrue(app.staticTexts["按读音记"].exists)
        XCTAssertEqual(app.staticTexts["targeted.pronunciation"].label, "biàn bié")
        saveScreenshot(app, "21-词义与记忆便签")
        let example = app.staticTexts["放进句子里"]
        for _ in 0..<5 where !example.isHittable { app.swipeUp() }
        XCTAssertTrue(example.isHittable)
        let sentence = app.staticTexts["targeted.example.text"]
        let sentenceSpeech = app.buttons["targeted.speech.example"]
        // Glyph bounds vary with line wrapping and Dynamic Type. Verify that
        // the control sits to the paragraph's right, without overlapping text,
        // and alongside its first line rather than beside the section heading.
        XCTAssertGreaterThan(sentenceSpeech.frame.midX, sentence.frame.midX)
        XCTAssertGreaterThanOrEqual(sentenceSpeech.frame.minX, sentence.frame.maxX - 1, "朗读控件不能遮住例句")
        XCTAssertLessThan(abs(sentenceSpeech.frame.minY - sentence.frame.minY), sentenceSpeech.frame.height / 2, "例句播放／暂停应位于句子第一行旁")
        saveScreenshot(app, "22-结构与例句")
        let attempt = app.buttons["targeted.try"]
        XCTAssertTrue(attempt.isHittable); attempt.tap()
        let input = app.textFields["targeted.answer"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); XCTAssertFalse(word.isHittable)
        XCTAssertFalse(memory.exists, "进入作答后读音与音节记忆提示也应隐藏")
        input.tap(); input.typeText("分辨")
        saveScreenshot(app, "23-独立作答与键盘")
        app.buttons["targeted.back"].tap()
        XCTAssertTrue(word.waitForExistence(timeout: 5)); XCTAssertEqual(word.label, "辨别")
        XCTAssertFalse(app.textFields["targeted.answer"].exists)
        saveScreenshot(app, "26-作答返回讲解")
        app.buttons["targeted.try"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "分辨")
        app.buttons["targeted.submit"].tap()
        XCTAssertTrue(app.staticTexts["再记一记这个词"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["你刚才写的是：分辨"].exists)
        saveScreenshot(app, "24-温和的错误反馈")
        app.buttons["targeted.back"].tap()
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["targeted.try"].exists, "已提交的词只回看，不重新作答")
        app.buttons["targeted.result"].tap()
        XCTAssertTrue(app.staticTexts["你刚才写的是：分辨"].waitForExistence(timeout: 5))
        app.buttons["targeted.next"].tap()
        XCTAssertTrue(app.staticTexts["第 2 / 5 个词"].waitForExistence(timeout: 5))
        app.buttons["targeted.back"].tap()
        XCTAssertTrue(word.waitForExistence(timeout: 5)); XCTAssertEqual(word.label, "辨别")
        saveScreenshot(app, "27-返回上个词且保留结果")
        app.buttons["targeted.close"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["词语学习"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        app.buttons["targeted.start"].tap()
        XCTAssertTrue(app.staticTexts["第 2 / 5 个词"].waitForExistence(timeout: 5), "退出再进继续未完成的词")
        app.buttons["targeted.back"].tap()
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        app.buttons["targeted.back"].tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["词语学习"])
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["AI 词语讲解"].waitForExistence(timeout: 5), "第一个词的讲解页返回列表")
        let history = app.buttons["学习记录"]
        for _ in 0..<4 where !history.isHittable { app.swipeUp() }
        XCTAssertTrue(history.isHittable); history.tap()
        XCTAssertTrue(app.navigationBars["学习记录"].waitForExistence(timeout: 5), app.debugDescription)
        saveScreenshot(app, "25-学习记录")
        XCTAssertTrue(app.staticTexts["等待隔日验证"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor func testLessonReadAloudPausesResumesAndStopsWhenAnswering() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-targeted", "--ui-testing-targeted-rich", "--ui-testing-targeted-speech"]
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["targeted.home"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20)); entry.tap()
        let start = app.buttons["targeted.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        let word = app.buttons["targeted.speech.word"]
        XCTAssertTrue(word.waitForExistence(timeout: 10)); word.tap()
        let example = app.buttons["targeted.speech.example"]
        for _ in 0..<5 where !example.isHittable { app.swipeUp() }
        XCTAssertTrue(example.isHittable); example.tap()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "正在朗读"), object: example)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 5), .completed, app.debugDescription)
        example.tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已暂停"), object: example)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        saveScreenshot(app, "28-词语和例句朗读")
        example.tap()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "正在朗读"), object: example)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed)
        app.buttons["targeted.try"].tap()
        XCTAssertTrue(app.textFields["targeted.answer"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["targeted.speech.word"].exists)
        XCTAssertFalse(app.buttons["targeted.speech.example"].exists)
        XCTAssertFalse(app.buttons["targeted.speech.stop"].exists, "进入作答须停止朗读，不能继续读标准答案")
        app.buttons["targeted.back"].tap()
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        XCTAssertEqual(example.value as? String, "未朗读")
        app.buttons["targeted.close"].tap()
        XCTAssertTrue(app.navigationBars["AI 词语讲解"].waitForExistence(timeout: 5))
    }

    @MainActor func testLessonSpeechKeepsContentAndButtonFramesStable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-targeted", "--ui-testing-targeted-rich", "--ui-testing-targeted-speech"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["targeted.home"].waitForExistence(timeout: 20))
        app.buttons["targeted.home"].tap()
        XCTAssertTrue(app.buttons["targeted.start"].waitForExistence(timeout: 10))
        app.buttons["targeted.start"].tap()
        let word = app.buttons["targeted.speech.word"]
        XCTAssertTrue(word.waitForExistence(timeout: 10))
        let example = app.buttons["targeted.speech.example"]
        let bottom = app.buttons["targeted.try"]
        for _ in 0..<5 where !example.isHittable || example.frame.maxY > bottom.frame.minY - 12 { app.swipeUp() }
        XCTAssertTrue(example.isHittable)
        let initial = example.frame
        func assertFrame(_ element: XCUIElement, equals frame: CGRect, _ message: String) {
            let actual = element.frame
            XCTAssertEqual(actual.minX, frame.minX, accuracy: 1, message)
            XCTAssertEqual(actual.minY, frame.minY, accuracy: 1, message)
            XCTAssertEqual(actual.width, frame.width, accuracy: 1, message)
            XCTAssertEqual(actual.height, frame.height, accuracy: 1, message)
        }
        func waitForValue(_ value: String) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: example)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        }
        example.tap(); waitForValue("正在朗读")
        assertFrame(example, equals: initial, "开始朗读不能推移内容或改变按钮尺寸")
        example.tap(); waitForValue("已暂停")
        assertFrame(example, equals: initial, "暂停朗读不能推移内容或改变按钮尺寸")
        example.tap(); waitForValue("正在朗读")
        assertFrame(example, equals: initial, "继续朗读不能推移内容或改变按钮尺寸")
        // Pause while scrolling back to the stop control so natural completion
        // cannot race the idle-layout assertion.
        example.tap(); waitForValue("已暂停")
        let stop = app.buttons["targeted.speech.stop"]
        for _ in 0..<5 where !stop.isHittable { app.swipeDown() }
        XCTAssertTrue(stop.isHittable, app.debugDescription)
        let beforeStop = word.frame
        stop.tap(); waitForValue("未朗读")
        assertFrame(word, equals: beforeStop, "停止朗读不能让讲解卡片跳动")
        saveScreenshot(app, "29-朗读停止后布局稳定")
    }

    @MainActor func testHomeRemovesPlanCardAndKeepsLearningAndCoachRoutes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-targeted"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 20))
        let words = app.buttons["targeted.home"]
        XCTAssertTrue(words.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["coach.plan.summary"].exists)
        XCTAssertFalse(app.buttons["coach.plan.details"].exists)
        XCTAssertFalse(app.buttons["coach.plan.recheck"].exists)
        XCTAssertFalse(app.buttons["home.sync.check"].exists)
        XCTAssertFalse(app.buttons["home.sync.details"].exists)
        for _ in 0..<4 where !words.isHittable { app.swipeUp() }
        saveScreenshot(app, "17-首页移除独立安排卡")
        words.tap()
        XCTAssertTrue(app.navigationBars["AI 词语讲解"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["targeted.start"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["每组推荐 5 个重点词，学完还可以再学 5 个。"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let preview = app.buttons["home.review.preview"]
        for _ in 0..<12 where !preview.isHittable { app.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        XCTAssertFalse(app.buttons["coach.plan.details"].exists)
        saveScreenshot(app, "18-保留原位置的复习入口")
        preview.tap()
        XCTAssertTrue(app.navigationBars["复习预习"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["共 7 项错题内容"].exists)
        app.buttons["关闭"].tap()
        let start = app.buttons["home.review.start"]
        XCTAssertTrue(start.isHittable); start.tap()
        XCTAssertTrue(app.staticTexts["第 1 / 7 题"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        selectTab("设置", in: app)
        app.buttons["AI 家庭复习教练"].tap()
        XCTAssertTrue(app.navigationBars["AI 教练"].waitForExistence(timeout: 10))
        let savedPlans = app.staticTexts["暂用原规则安排。授权并成功生成后，AI 清单将替换首页的每日复习清单。"]
        for _ in 0..<6 where !savedPlans.isHittable { app.swipeUp() }
        XCTAssertTrue(savedPlans.exists)
        let logs = app.buttons["coach.logs"]
        for _ in 0..<4 where !logs.isHittable { app.swipeUp() }
        XCTAssertTrue(logs.isHittable); logs.tap()
        XCTAssertTrue(app.navigationBars["教练执行记录"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let syncDetails = app.buttons["iCloud 同步诊断"]
        for _ in 0..<5 where !syncDetails.isHittable { app.swipeUp() }
        XCTAssertTrue(syncDetails.isHittable); syncDetails.tap()
        XCTAssertTrue(app.navigationBars["同步诊断信息"].waitForExistence(timeout: 5))
        let automaticCheck = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "题库 7 条，记录 21 条")).firstMatch
        XCTAssertTrue(automaticCheck.waitForExistence(timeout: 5), "自动状态检查仍应完成，打开预习与复习不应增加判定记录")
        saveScreenshot(app, "19-设置同步诊断保持正常")
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
