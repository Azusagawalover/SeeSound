import XCTest
import UIKit

/// Exercises real on-device OCR and local rules. Does not call the network or seed OCR results.
final class WorkflowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(largeText: Bool = false) {
        app.launchArguments = ["--skip-intro", "--page", "experience", "--reset-experience", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["完整体验"].waitForExistence(timeout: 15), app.debugDescription)
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func scroll(_ up: Bool, x: CGFloat = 0.5) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: up ? 0.74 : 0.33))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: up ? 0.33 : 0.74))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @discardableResult private func reveal(_ target: XCUIElement, up: Bool = true, attempts: Int = 18, content: Bool = true, menu: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let top = app.frame.minY + 115
        var bottom = app.frame.maxY - 45
        if app.tabBars.firstMatch.exists && app.tabBars.firstMatch.isHittable { bottom = min(bottom, app.tabBars.firstMatch.frame.minY - 8) }
        for id in ["workroom.acceptImport", "workroom.reviewNext", "workroom.prepare", "workroom.create"] {
            let footer = app.buttons[id]
            if footer.exists && footer.isHittable { bottom = min(bottom, footer.frame.minY - 8) }
        }
        if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY - 8) }
        func ready() -> Bool {
            guard target.exists && (target.isHittable || menu) else { return false }
            return !content || (target.frame.midY >= top && target.frame.midY <= bottom)
        }
        if ready() { return target }
        for _ in 0..<attempts {
            var direction = up
            if target.exists, target.frame.height > 0 { direction = target.frame.midY >= top }
            let x = target.exists && target.frame.width > 0 ? min(0.8, max(0.2, (target.frame.midX-app.frame.minX)/app.frame.width)) : 0.5
            scroll(direction, x: x)
            if ready() { return target }
        }
        XCTFail("Control was not reachable: \(target)\n\(app.debugDescription)", file: file, line: line)
        return target
    }

    private func tap(_ id: String, up: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let fixed = ["workroom.acceptImport", "workroom.reviewNext", "workroom.prepare", "workroom.create", "notice.restore", "case.delete.confirm"]
        let menu = id.hasPrefix("case.rowTools.") || id == "case.checklistTools"
        let target = reveal(element(id), up: up, content: !fixed.contains(id), menu: menu, file: file, line: line)
        XCTAssertTrue(target.isEnabled, "Disabled control: \(id)", file: file, line: line)
        // SwiftUI List exposes a Menu wrapper and its inner button separately on iOS 17.
        if menu {
            let inner = target.buttons.firstMatch
            let control = inner.exists ? inner : target
            control.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        } else { target.tap() }
    }

    private func turnOn(_ id: String) {
        let control = reveal(app.switches[id])
        if control.value as? String != "1" {
            let nativeSwitch = control.switches.firstMatch
            (nativeSwitch.exists ? nativeSwitch : control).tap()
            let changed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","1"),object:control)
            XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:5),.completed,"Switch did not turn on: \(id)")
        }
        XCTAssertEqual(app.switches[id].value as? String, "1")
    }

    private func shot(_ name: String) {
        let screenshot = UIDevice.current.userInterfaceIdiom == .pad ? XCUIScreen.main.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNotificationToCompletedCaseAndRecovery() {
        launch()
        tap("experience.start")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "读取完成")).firstMatch.waitForExistence(timeout: 30))
        tap("workroom.acceptImport")
        tap("workroom.reviewNext")
        tap("workroom.offline")
        tap("workroom.prepare")
        turnOn("prepared.acknowledged")
        turnOn("prepared.save")
        tap("workroom.create")
        tap("workroom.openCreated", up: false)
        XCTAssertTrue(element("case.state").waitForExistence(timeout: 8))
        shot("01-case-next-action")

        tap("case.arrangements")
        tap("case.sources")
        tap("source.add.内置体验 · 补充通知")
        tap("source.compare.内置体验 · 补充通知", up: false)
        for kind in ["time", "place", "amount"] {
            let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "change." + kind + ".")).firstMatch
            reveal(candidate).tap()
        }
        tap("change.material.报名凭证")
        turnOn("change.acknowledged")
        tap("change.apply")
        let result = reveal(element("change.status"))
        XCTAssertTrue(result.label.contains("已按你的选择更新事务"), result.label)
        shot("02-confirmed-notification-change")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["case.closeSources"].tap()
        reveal(element("case.primary"), up: false)
        tap("case.checklist.material.学生证")
        tap("case.checklist.material.报名凭证")
        tap("case.checklist.step.确认报名")
        XCTAssertEqual(element("case.checklist.step.确认报名").value as? String, "已处理")
        let completion = reveal(element("case.primary"), up: false)
        XCTAssertTrue(completion.label.contains("确认完成事务"), completion.label)
        completion.tap()
        XCTAssertEqual(reveal(element("case.state"), up: false).label, "已完成")
        shot("03-case-completed")
        tap("case.delete")
        tap("case.delete.confirm")
        XCTAssertTrue(app.buttons["notice.restore"].waitForExistence(timeout: 8))
        tap("notice.restore")
        tap("workroom.openCreated", up: false)
        XCTAssertEqual(reveal(element("case.state"), up: false).label, "已完成")
        XCTAssertEqual(reveal(element("case.checklist.material.学生证")).value as? String, "已处理")
        shot("04-restored-completed-case")
    }

    func testOriginalImageZoomAndEditableComparison() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        launch()
        tap("experience.start")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "读取完成")).firstMatch.waitForExistence(timeout: 30))
        reveal(app.buttons["原图与识字逐行对照"]).tap()
        XCTAssertTrue(app.navigationBars["原图对照"].waitForExistence(timeout: 5), app.debugDescription)
        tap("compare.zoomIn")
        XCTAssertEqual(element("compare.zoom").label, "1.5×")
        let editor = reveal(app.textViews["compare.editor"])
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertGreaterThan(editor.frame.minX, element("compare.zoomIn").frame.maxX)
            XCTAssertLessThanOrEqual(editor.frame.maxX, app.frame.maxX)
            XCTAssertGreaterThan(editor.frame.width, app.frame.width * 0.25)
        }
        editor.tap()
        editor.typeText("\nchecked019")
        if app.buttons["keyboard.dismiss"].exists { app.buttons["keyboard.dismiss"].tap() }
        shot("05-original-comparison-edit-and-zoom")
        let line = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@", "compare.line.")).firstMatch
        reveal(line).tap()
        tap("compare.returnToLine", up: false)
        XCTAssertTrue(line.isHittable)
        app.buttons["返回核对"].tap()
        tap("workroom.acceptImport")
        XCTAssertTrue(app.textViews["材料原文"].value as? String != nil)
        XCTAssertTrue((app.textViews["材料原文"].value as? String)?.contains("checked019") == true,app.debugDescription)
    }

    func testLargestTextKeepsPrimaryActionReachable() {
        launch(largeText: true)
        tap("experience.quickCase")
        XCTAssertTrue(app.navigationBars["事务详情"].waitForExistence(timeout: 8))
        reveal(element("case.primary"))
        shot("06-largest-text-next-action")
        tap("case.primary")
        let firstMaterial = element("case.checklist.material.学生证")
        XCTAssertTrue(firstMaterial.isHittable)
        firstMaterial.tap()
        XCTAssertEqual(firstMaterial.value as? String, "已处理")
        shot("07-largest-text-checklist")
    }
    func testFocusSkipUndoAndExplicitCompletion() {
        launch()
        tap("experience.quickCase")
        tap("case.focus")
        XCTAssertEqual(element("focus.title").label,"学生证")
        shot("24-focus-current-item")
        tap("focus.complete")
        XCTAssertEqual(element("focus.title").label,"确认报名")
        tap("checklist.undo")
        XCTAssertEqual(reveal(element("focus.title"),up:false).label,"学生证")
        tap("focus.skip")
        XCTAssertEqual(element("focus.title").label,"确认报名")
        tap("focus.complete")
        tap("focus.resetSkipped")
        XCTAssertEqual(reveal(element("focus.title"),up:false).label,"学生证")
        tap("focus.complete")
        shot("20-focus-ready-to-finish")
        tap("focus.finish")
        app.buttons["focus.close"].tap()
        XCTAssertEqual(reveal(element("case.state"),up:false).label,"已完成")
    }

    func testChecklistRenameOrderBatchAndUndo() {
        launch()
        tap("experience.quickCase")
        let newMaterial = reveal(element("case.addMaterialText"))
        newMaterial.tap();newMaterial.typeText("Receipt")
        if app.buttons["keyboard.dismiss"].exists { app.buttons["keyboard.dismiss"].tap() }
        tap("case.addMaterial")
        tap("case.rowTools.学生证",up:false)
        app.buttons["case.rename.学生证"].tap()
        let name = app.textViews["checklist.name"].exists ? app.textViews["checklist.name"] : app.textFields["checklist.name"]
        XCTAssertTrue(name.waitForExistence(timeout:5));name.tap();name.typeText("2")
        let renamed = name.value as! String
        if app.buttons["keyboard.dismiss"].exists { app.buttons["keyboard.dismiss"].tap() }
        app.buttons["checklist.saveName"].tap()
        XCTAssertTrue(reveal(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","名称由你修改")).firstMatch).exists)
        tap("case.checklistTools",up:false)
        app.buttons["调整材料顺序"].tap()
        let down = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","order.down.")).firstMatch
        reveal(down).tap();app.buttons["order.apply"].tap()
        XCTAssertTrue(reveal(element("case.primary"),up:false).label.contains("Receipt"))
        tap("checklist.undo")
        XCTAssertTrue(reveal(element("case.primary"),up:false).label.contains(renamed))
        turnOn("case.onlyRemaining")
        tap("case.checklistTools")
        app.buttons["case.batch"].tap()
        tap("batch.selectReady")
        tap("batch.preview")
        turnOn("batch.acknowledged")
        shot("21-batch-preview")
        tap("batch.apply")
        XCTAssertTrue(reveal(app.staticTexts["没有未处理材料"]).exists)
        tap("checklist.undo",up:false)
        XCTAssertTrue(reveal(element("case.primary"),up:false).label.contains(renamed))
        shot("22-checklist-restored-after-undo")
    }

    func testUnsavedEditorAndListSortControls() {
        launch()
        tap("experience.quickCase")
        reveal(app.buttons["编辑与提醒"]).tap()
        let title = app.textFields["caseEditor.title"]
        XCTAssertTrue(title.waitForExistence(timeout:5));title.tap();title.typeText("X")
        if app.buttons["keyboard.dismiss"].exists { app.buttons["keyboard.dismiss"].tap() }
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["放弃修改"].waitForExistence(timeout:3))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue((title.value as? String)?.contains("X") == true)
        app.navigationBars.buttons["取消"].tap();app.buttons["放弃修改"].tap()
        app.navigationBars.buttons["关闭"].tap()
        app.tabBars.buttons["办事"].tap()
        app.buttons["cases.options"].tap()
        app.buttons["cases.sort"].tap();app.buttons["截止时间先后"].tap()
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(reveal(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","截止时间先后")).firstMatch).exists)
        shot("23-list-sort")
        tap("cases.clearOptions")
        XCTAssertFalse(app.buttons["cases.clearOptions"].exists)
    }

    func testFocusLargestText() {
        launch(largeText:true)
        tap("experience.quickCase")
        tap("case.focus")
        tap("focus.complete")
        XCTAssertEqual(reveal(element("focus.title"),up:false).label,"确认报名")
        shot("25-focus-largest-text")
        app.buttons["focus.close"].tap()
    }

    private func launchCampus(largeText:Bool = false) {
        app.launchArguments = ["--skip-intro","--page","campus","--reset-campus-examples","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch();XCTAssertTrue(app.navigationBars["校园办事"].waitForExistence(timeout:15))
    }
    func testCampusJourneyConfirmationDepartureAndOutcome() {
        launchCampus();tap("journey.example")
        XCTAssertTrue(app.navigationBars["办事旅程"].waitForExistence(timeout:8),app.debugDescription)
        tap("journey.pause");XCTAssertTrue(app.buttons["继续这段旅程"].exists);tap("journey.pause")
        shot("30-campus-journey")
        reveal(app.staticTexts["学生服务中心一楼"].firstMatch).tap()
        XCTAssertTrue(app.navigationBars["信息确认"].waitForExistence(timeout:8));tap("journey.confirmSelf")
        tap("journey.confirmPartner");let accept = app.buttons["journey.confirmPartner.accept"];XCTAssertTrue(accept.waitForExistence(timeout:5));accept.tap()
        XCTAssertTrue(app.buttons["用户已记录对方确认"].waitForExistence(timeout:5),app.debugDescription);shot("31-two-way-confirmation")
        app.navigationBars.buttons.element(boundBy:0).tap()
        tap("journey.departure");XCTAssertTrue(app.navigationBars["随身办事单"].waitForExistence(timeout:8));shot("32-departure")
        app.navigationBars.buttons["关闭"].tap()
        tap("journey.outcome");let note = app.textViews["journey.result"];XCTAssertTrue(note.waitForExistence(timeout:8));reveal(note).tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout:3) { note.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.3)).tap() }
        note.typeText("窗口已核对材料，等待领取。")
        if app.buttons["收起键盘"].exists { app.buttons["收起键盘"].tap() }
        tap("journey.resultSave")
        XCTAssertTrue(app.navigationBars["办事旅程"].waitForExistence(timeout:8))
        XCTAssertTrue(reveal(app.staticTexts["窗口已核对材料，等待领取。"]).exists)
        shot("33-journey-outcome")
    }
    func testCampusLargestTextAndEvidenceNavigation() {
        launchCampus(largeText:true);tap("journey.example")
        tap("journey.sources");XCTAssertTrue(app.navigationBars["旅程材料"].waitForExistence(timeout:8))
        reveal(app.buttons.matching(NSPredicate(format:"label CONTAINS %@","补办说明")).firstMatch).tap()
        XCTAssertTrue(app.navigationBars["核对依据"].waitForExistence(timeout:8));tap("evidence.jump")
        shot("34-campus-evidence-largest-text")
    }
    func testPANNsPublicRecordingActuallyRunsInApp() {
        app.launchArguments = ["--skip-intro","--page","lab","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch();XCTAssertTrue(app.navigationBars["环境声音实验"].waitForExistence(timeout:15))
        reveal(app.buttons["在本机分析这段录音"]).tap()
        let status = app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","本段公开录音分析完成")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout:90),app.debugDescription)
        shot("35-panns-live-inference")
    }
    func testWhisperBaseWithSyntheticSpeech() {
        app.launchArguments = ["--skip-intro","--page","offline","--speech-fixture","-SeeSound.speechModel","base","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch();XCTAssertTrue(app.navigationBars["音频文件转写"].waitForExistence(timeout:15))
        let cached = app.buttons["准备内置 Base 模型"]
        XCTAssertTrue(cached.waitForExistence(timeout:8));reveal(cached).tap()
        let fixture = element("speech.fixture")
        let ready = NSPredicate(format:"enabled == true")
        expectation(for:ready,evaluatedWith:fixture);waitForExpectations(timeout:180)
        reveal(fixture).tap()
        expectation(for:ready,evaluatedWith:fixture);waitForExpectations(timeout:120)
        let result = reveal(app.staticTexts["speech.result"])
        XCTAssertTrue(result.label.lowercased().contains("student"),result.label)
        shot("36-whisper-base-synthetic")
    }

    func testPairedWatchSnapshotAndVersionChange() throws {
        guard ProcessInfo.processInfo.environment["SEESOUND_WATCH_INTEGRATION"] == "1" else { throw XCTSkip("Enable only with the paired Watch simulator running.") }
        launch();tap("experience.quickCase")
        app.navigationBars.buttons["关闭"].tap();app.terminate()
        app.launchArguments = ["--skip-intro","--page","continuity","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch();XCTAssertTrue(app.navigationBars["设备接力"].waitForExistence(timeout:15))
        reveal(app.buttons["激活并刷新连接"]).tap()
        XCTAssertTrue(app.staticTexts["当前可通信"].waitForExistence(timeout:20),app.debugDescription)
        let selected = app.switches.matching(NSPredicate(format:"label CONTAINS %@","内置体验 · 校园读书会")).firstMatch
        reveal(selected)
        let knob = selected.switches.firstMatch
        XCTAssertTrue(knob.exists,app.debugDescription);knob.tap()
        XCTAssertEqual(selected.value as? String,"1",app.debugDescription)
        reveal(app.buttons["发送所选摘要（1 项）"]).tap()
        let received = app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","手表 App 已接收摘要")).firstMatch
        XCTAssertTrue(received.waitForExistence(timeout:15),app.debugDescription);shot("37-watch-delivery-receipt")
        app.tabBars.buttons["办事"].tap()
        reveal(app.staticTexts["内置体验 · 校园读书会"].firstMatch).tap()
        reveal(app.buttons["编辑与提醒"]).tap()
        let title = app.textFields["caseEditor.title"];XCTAssertTrue(title.waitForExistence(timeout:5));title.tap();title.typeText("W")
        if app.buttons["keyboard.dismiss"].exists { app.buttons["keyboard.dismiss"].tap() }
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["事务详情"].waitForExistence(timeout:8));shot("38-phone-changed-summary")
    }

    func testCampusScenarioWizardCreatesExplicitPlan() {
        launchCampus();tap("campus.scenarios");tap("scenario.clinic")
        let title = app.textFields["wizard.title"];XCTAssertTrue(title.waitForExistence(timeout:5));title.tap();title.typeText(" · 界面验证")
        if app.buttons["keyboard.dismiss"].exists { app.buttons["keyboard.dismiss"].tap() }
        tap("wizard.next");tap("wizard.next");shot("40-scenario-preview")
        turnOn("wizard.consent");tap("wizard.next")
        XCTAssertTrue(app.navigationBars["办事旅程"].waitForExistence(timeout:8),app.debugDescription)
        XCTAssertTrue(reveal(app.staticTexts["应该到哪个窗口或科室？"]).exists)
        let addFact = reveal(app.buttons["journey.addFact"]);XCTAssertFalse(addFact.isEnabled)
        shot("41-scenario-journey")
    }
    func testPairedWatchJourneySnapshotAndVersionChange() throws {
        guard ProcessInfo.processInfo.environment["SEESOUND_WATCH_INTEGRATION"] == "1" else { throw XCTSkip("Enable only with the paired Watch simulator running.") }
        launchCampus();tap("journey.example")
        reveal(app.staticTexts["学生服务中心一楼"].firstMatch).tap();tap("journey.confirmSelf")
        app.terminate()
        app.launchArguments = ["--skip-intro","--page","continuity","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch();XCTAssertTrue(app.navigationBars["设备接力"].waitForExistence(timeout:15))
        reveal(app.buttons["激活并刷新连接"]).tap()
        // The actual remote receipt below is the delivery contract, even when simulator installation metadata lags.
        _ = app.staticTexts["当前可通信"].waitForExistence(timeout:8)
        let selected = app.switches.matching(NSPredicate(format:"label CONTAINS %@","补办学生证 · 示例")).firstMatch
        reveal(selected);let knob = selected.switches.firstMatch
        XCTAssertTrue(knob.exists,app.debugDescription);knob.tap();XCTAssertEqual(selected.value as? String,"1")
        reveal(app.buttons["发送所选摘要（1 项）"]).tap()
        let received = app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","手表 App 已接收摘要")).firstMatch
        XCTAssertTrue(received.waitForExistence(timeout:15),app.debugDescription);shot("48-watch-journey-receipt")
        let retryRow = app.cells.containing(.staticText,identifier:"上次传递与重试").firstMatch
        reveal(retryRow,up:false).buttons.firstMatch.tap()
        reveal(app.buttons["重新发送上次所选的当前摘要"]).tap()
        XCTAssertTrue(received.waitForExistence(timeout:15),app.debugDescription);shot("49-watch-manual-retry")
        app.navigationBars["设备接力"].buttons["沟通"].tap()
        XCTAssertTrue(app.navigationBars["沟通"].waitForExistence(timeout:8))
        tap("home.journey",up:false)
        XCTAssertTrue(app.navigationBars["校园办事"].waitForExistence(timeout:8));tap("journey.example")
        XCTAssertTrue(app.navigationBars["办事旅程"].waitForExistence(timeout:8));tap("journey.pause")
        XCTAssertTrue(app.buttons["继续这段旅程"].waitForExistence(timeout:5));shot("50-watch-journey-changed")
    }
    func testCampusPresentationShowsRealSourceInvalidation() {
        launchCampus();tap("campus.presentation")
        XCTAssertTrue(app.navigationBars["作品演示"].waitForExistence(timeout:5))
        tap("presentation.reset");tap("presentation.reset.confirm")
        XCTAssertTrue(reveal(element("presentation.step"),up:false).label.hasPrefix("第 1 / 7"))
        tap("presentation.next");tap("presentation.next")
        XCTAssertTrue(reveal(element("presentation.step"),up:false).label.hasPrefix("第 3 / 7"))
        reveal(app.buttons["准备一段模拟窗口回答"]).tap()
        tap("presentation.next")
        reveal(app.buttons["逐张展示并实际核对"]).tap()
        XCTAssertTrue(element("carousel.position").label.hasPrefix("第 1 /"))
        tap("carousel.next");XCTAssertTrue(element("carousel.position").label.hasPrefix("第 2 /"))
        tap("carousel.previous");XCTAssertTrue(element("carousel.position").label.hasPrefix("第 1 /"))
        tap("journey.confirmSelf");shot("42-presentation-confirmation")
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(app.navigationBars["作品演示"].waitForExistence(timeout:5))
        tap("presentation.next");tap("presentation.next")
        reveal(app.buttons["加入明确标注的模拟改期通知"]).tap()
        reveal(app.buttons["查看受影响的信息与来源"]).tap()
        XCTAssertTrue(app.navigationBars["变更处理"].waitForExistence(timeout:5))
        XCTAssertTrue(reveal(app.staticTexts["地点需要重新核对"]).exists,app.debugDescription)
        shot("43-material-change-center")
    }
    func testChineseNoticeEvaluationActuallyRunsOCR() {
        launchCampus();tap("campus.evaluation")
        for (id,expected) in [("notice-counter","学生服务中心"),("notice-activity","校园读书会"),("notice-update","证件照")] {
            tap("evaluation.sample."+id);tap("evaluation.run")
            let output = app.staticTexts["evaluation.output"]
            XCTAssertTrue(output.waitForExistence(timeout:60),app.debugDescription)
            XCTAssertTrue(output.label.contains(expected),output.label)
            attachEvaluation(id,output:output.label)
            reveal(output);shot("44-chinese-"+id)
            app.navigationBars.buttons.element(boundBy:0).tap()
        }
    }
    func testChineseFleursEvaluationActuallyRunsWhisper() {
        launchCampus();tap("campus.evaluation")
        for id in ["fleurs-zh-1","fleurs-zh-2"] {
            tap("evaluation.sample."+id);tap("evaluation.run")
            let output = app.staticTexts["evaluation.output"]
            XCTAssertTrue(output.waitForExistence(timeout:180),app.debugDescription)
            XCTAssertTrue(output.label.unicodeScalars.contains{(0x4e00...0x9fff).contains(Int($0.value))},output.label)
            attachEvaluation(id,output:output.label)
            reveal(output);shot("45-chinese-"+id)
            app.navigationBars.buttons.element(boundBy:0).tap()
        }
    }

    private func attachEvaluation(_ id:String,output:String) {
        let metric = reveal(app.staticTexts["evaluation.score"])
        let report = ["sample_id":id,"output":output,"metric":metric.label]
        let data = try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        let attachment = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
        attachment.name = "evaluation-"+id;attachment.lifetime = .keepAlways;add(attachment)
    }
    func testCampusDeskAndResume() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        launchCampus();tap("journey.example")
        XCTAssertTrue(app.navigationBars["办事旅程"].waitForExistence(timeout:8),app.debugDescription)
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(app.navigationBars["校园办事"].waitForExistence(timeout:8),app.debugDescription)
        tap("campus.desk")
        XCTAssertTrue(app.navigationBars["联动工作台"].waitForExistence(timeout:5))
        if UIDevice.current.userInterfaceIdiom == .pad { XCTAssertTrue(element("desk.columns").exists,app.debugDescription) }
        let source = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","desk.source.")).firstMatch
        reveal(source).tap();shot("46-linked-workbench")
        reveal(app.staticTexts["学生服务中心一楼"].firstMatch).tap()
        XCTAssertTrue(app.navigationBars["信息确认"].waitForExistence(timeout:5))
    }
    func testJourneySearchOpensSpecificCardAndResume() {
        launchCampus();tap("journey.example")
        XCTAssertTrue(app.navigationBars["办事旅程"].waitForExistence(timeout:8),app.debugDescription)
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(app.navigationBars["校园办事"].waitForExistence(timeout:8),app.debugDescription)
        tap("campus.search")
        let demo = app.switches["包含演示材料"];reveal(demo)
        if demo.value as? String != "1" { let inner = demo.switches.firstMatch;if inner.exists { inner.tap() } else { demo.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap() } }
        XCTAssertEqual(demo.value as? String,"1")
        let field = reveal(app.searchFields.firstMatch,up:false);field.tap();field.typeText("学生服务中心\n")
        let hit = app.staticTexts["地点：学生服务中心一楼"].firstMatch
        reveal(hit).tap();XCTAssertTrue(app.navigationBars["信息确认"].waitForExistence(timeout:5))
        shot("47-journey-search-specific-card")
        app.navigationBars["信息确认"].buttons["全局搜索"].tap()
        XCTAssertTrue(app.navigationBars["全局搜索"].waitForExistence(timeout:8),app.debugDescription)
        let cancelSearch = app.navigationBars["全局搜索"].buttons["取消"]
        if cancelSearch.exists { cancelSearch.tap() }
        XCTAssertTrue(app.navigationBars["全局搜索"].buttons["校园办事"].waitForExistence(timeout:8),app.debugDescription)
        app.navigationBars["全局搜索"].buttons["校园办事"].tap()
        XCTAssertTrue(app.navigationBars["校园办事"].waitForExistence(timeout:8),app.debugDescription)
        tap("campus.resume",up:false);XCTAssertTrue(app.navigationBars["信息确认"].waitForExistence(timeout:5),app.debugDescription)
    }

    func testVisualHomeJourneyAndTabs() {
        app.launchArguments = ["--skip-intro","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch();XCTAssertTrue(app.navigationBars["沟通"].waitForExistence(timeout:15))
        XCTAssertTrue(element("home.journey").waitForExistence(timeout:8))
        shot("60-home-design")
        XCTAssertTrue(reveal(element("home.journey")).isHittable)
        tap("home.journey");XCTAssertTrue(app.navigationBars["校园办事"].waitForExistence(timeout:8));shot("61-campus-design")
        tap("campus.scenarios");XCTAssertTrue(app.navigationBars["场景开始"].waitForExistence(timeout:8));shot("62-scenarios-design")
        app.navigationBars["场景开始"].buttons["校园办事"].tap()
        XCTAssertTrue(app.navigationBars["校园办事"].waitForExistence(timeout:8));tap("journey.example",up:false)
        XCTAssertTrue(app.navigationBars["办事旅程"].waitForExistence(timeout:8));shot("63-journey-design")
        reveal(app.staticTexts["学生服务中心一楼"].firstMatch).tap()
        XCTAssertTrue(app.navigationBars["信息确认"].waitForExistence(timeout:8));XCTAssertTrue(element("journey.confirmSelf").exists);shot("64-confirmation-design")
        app.tabBars.buttons["办事"].tap();XCTAssertTrue(app.navigationBars["事务清单"].waitForExistence(timeout:8));shot("65-cases-design")
        app.tabBars.buttons["提醒"].tap();XCTAssertTrue(app.navigationBars["提醒"].waitForExistence(timeout:8));shot("66-events-design")
        app.tabBars.buttons["我的"].tap();XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout:8),app.debugDescription);shot("67-preferences-design")
    }

    func testHearingFocusedHomeAndQuickReplies() {
        app.launchArguments = ["--skip-intro","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch();XCTAssertTrue(app.navigationBars["沟通"].waitForExistence(timeout:15))
        for id in ["home.captureStatus", "home.watchStatus"] {
            XCTAssertTrue(element(id).waitForExistence(timeout:8), app.debugDescription)
            XCTAssertTrue(reveal(element(id)).isHittable)
        }

        tap("home.communication",up:false)
        XCTAssertTrue(app.navigationBars["面对面沟通"].waitForExistence(timeout:8))
        XCTAssertTrue(app.staticTexts["最新文字"].exists)
        XCTAssertTrue(app.buttons["开始字幕"].exists)
        let quickReply = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@", "conversation.quickReply.")).firstMatch
        reveal(quickReply)
        let phrase = quickReply.label
        XCTAssertFalse(phrase.isEmpty)
        quickReply.tap()
        let reply = element("conversation.reply")
        XCTAssertTrue(reply.waitForExistence(timeout:5))
        XCTAssertEqual(reply.value as? String, phrase)
        XCTAssertTrue(reply.isHittable)

        app.navigationBars["面对面沟通"].buttons["沟通"].tap()
        XCTAssertTrue(app.navigationBars["沟通"].waitForExistence(timeout:8))
        tap("home.showCard",up:false)
        XCTAssertTrue(app.navigationBars["面对面沟通"].waitForExistence(timeout:8))
        XCTAssertTrue(reply.waitForExistence(timeout:5))
        XCTAssertEqual(reply.value as? String, phrase)
        shot("72-quick-reply-draft")

        let readingPanel = app.buttons["conversation.panel.reading"]
        if readingPanel.exists { tap("conversation.panel.reading",up:false) }
        tap("conversation.freeze",up:false)
        XCTAssertEqual(app.buttons["conversation.freeze"].label, "回到最新")
        tap("conversation.quickReply." + phrase)
        XCTAssertTrue(reply.waitForExistence(timeout:5))
        XCTAssertEqual(reply.value as? String, phrase)
        XCTAssertTrue(reply.isHittable)
        let displayReply = app.buttons["显示回应"]
        XCTAssertTrue(displayReply.isHittable)
        displayReply.tap()
        XCTAssertTrue(app.staticTexts["最新文字"].waitForExistence(timeout:5))
        if readingPanel.exists { XCTAssertTrue(readingPanel.isSelected) }
        XCTAssertEqual(app.buttons["conversation.freeze"].label, "固定画面")
        let latest = app.staticTexts["conversation.latestText"]
        XCTAssertTrue(latest.waitForExistence(timeout:5))
        XCTAssertEqual(latest.label, phrase)
        XCTAssertTrue(latest.isHittable)
        shot("73-displayed-quick-reply")

        app.navigationBars["面对面沟通"].buttons["沟通"].tap()
        tap("home.alerts",up:false)
        XCTAssertTrue(app.navigationBars["声音关注"].waitForExistence(timeout:8))
        XCTAssertTrue(reveal(app.buttons["开始声音识别"]).exists)
        XCTAssertFalse(app.buttons["停止声音识别"].exists)

        reveal(app.buttons["加入一条演示事件"]).tap()
        app.tabBars.buttons["提醒"].tap()
        XCTAssertTrue(app.navigationBars["提醒"].waitForExistence(timeout:8))
        XCTAssertTrue(element("alerts.status").waitForExistence(timeout:8))
        let acknowledgment = app.buttons.matching(NSPredicate(format:"label == %@ AND identifier BEGINSWITH %@", "敲门提醒界面演示，我已看到", "alerts.confirm.")).firstMatch
        reveal(acknowledgment)
        let confirmationID = acknowledgment.identifier
        let eventID = confirmationID.replacingOccurrences(of:"alerts.confirm.",with:"alerts.event.",options:.anchored)
        let exactAcknowledgment = app.buttons[confirmationID]
        exactAcknowledgment.tap()
        let removed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:exactAcknowledgment)
        XCTAssertEqual(XCTWaiter.wait(for:[removed],timeout:5),.completed)
        let event = element(eventID)
        XCTAssertTrue(event.waitForExistence(timeout:5))
        XCTAssertTrue(reveal(event).label.contains("已确认看到"),event.label)
        shot("74-hearing-alert-seen")
    }

    func testVisualCommunicationAndMaterialTools() {
        app.launchArguments = ["--skip-intro","--page","captions","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch();XCTAssertTrue(app.navigationBars["面对面沟通"].waitForExistence(timeout:15));shot("68-conversation-design")
        app.terminate();app.launchArguments = ["--skip-intro","--page","workroom","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch();XCTAssertTrue(app.navigationBars["文字工作室"].waitForExistence(timeout:15));shot("69-workroom-design")
    }

    func testJournalLargestTextHome() {
        app.launchArguments = ["--skip-intro","-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch();XCTAssertTrue(app.navigationBars["沟通"].waitForExistence(timeout:15))
        tap("home.journey");XCTAssertTrue(app.navigationBars["校园办事"].waitForExistence(timeout:8))
        shot("70-journal-largest-text-campus")
        tap("journey.new");XCTAssertTrue(app.navigationBars["开始办事"].waitForExistence(timeout:8))
        XCTAssertTrue(element("journey.title").exists);shot("71-journal-largest-text-new")
    }

}
