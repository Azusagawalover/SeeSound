import Foundation
import XCTest
@testable import SeeSoundData

final class CampusTests:XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    @MainActor func testJourneyPauseAndResumeSurviveRestart() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:WorkroomStore(directory:root))
        let journey = CampusJourney.studentCardExample();try service.putJourney(journey)
        try service.changeJourney(journey.id) { $0.resumeStage = .communicate;$0.stage = .paused }
        let next = WorkroomService(store:WorkroomStore(directory:root))
        XCTAssertEqual(next.campus.journeys.first?.stage,.paused)
        XCTAssertEqual(next.campus.journeys.first?.resumeStage,.communicate)
        XCTAssertEqual(next.campus.journeys.first?.revision,2)
    }
    @MainActor func testCounterpartNeedsSelfCheckAndEditedFactLosesBothConfirmations() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:WorkroomStore(directory:root)),journey = CampusJourney.studentCardExample(),fact = journey.facts[0]
        try service.putJourney(journey)
        XCTAssertThrowsError(try service.confirmJourneyFact(journey.id,factID:fact.id,revision:1,counterpart:true))
        try service.confirmJourneyFact(journey.id,factID:fact.id,revision:1,counterpart:false)
        try service.confirmJourneyFact(journey.id,factID:fact.id,revision:1,counterpart:true)
        try service.changeJourney(journey.id) { $0.facts[0].revise(value:"学生服务中心",quote:fact.quote) }
        let current = try XCTUnwrap(service.campus.journeys.first?.facts.first)
        XCTAssertNil(current.userConfirmedAt);XCTAssertNil(current.counterpartRecordedAt)
        XCTAssertThrowsError(try service.confirmJourneyFact(journey.id,factID:fact.id,revision:1,counterpart:false))
    }
    func testNewSourceVersionInvalidatesOnlyItsOwnFactsAndRetainsEvidence() throws {
        var journey = CampusJourney.studentCardExample()
        journey.facts[0].userConfirmedAt = Date();journey.facts[0].counterpartRecordedAt = Date()
        var independent = WorkroomDraft();independent.origin = .demonstration;independent.text = "时间待定";let other = CaseDocument(draft:independent)
        try journey.attach(other);journey.facts.append(.init(kind:.time,value:"待定",sourceID:other.id,quote:"时间待定",userConfirmedAt:Date()))
        var changed = journey.documents[0];changed.id = UUID();changed.revision += 1;changed.text = "地点：服务中心二楼"
        try journey.attach(changed);try journey.validate()
        XCTAssertTrue(journey.facts[0].superseded);XCTAssertNil(journey.facts[0].userConfirmedAt);XCTAssertNil(journey.facts[0].counterpartRecordedAt)
        XCTAssertTrue(journey.facts.last!.isConfirmed);XCTAssertEqual(journey.documents.count,3)
        XCTAssertTrue(journey.departure(cases:[]).contains("旧版依据"))
    }
    func testEvidenceCannotBeInventedOrMixDemoWithPersonalSource() throws {
        var journey = CampusJourney.studentCardExample();journey.facts[0].quote = "这个地点原文没有"
        XCTAssertThrowsError(try journey.validate())
        var draft = WorkroomDraft();draft.text = "真实材料";XCTAssertThrowsError(try journey.attach(CaseDocument(draft:draft)))
    }
    @MainActor func testStaleJourneyEditorCannotOverwriteNewerState() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:WorkroomStore(directory:root)),journey = CampusJourney.studentCardExample()
        try service.putJourney(journey);let digest = try journey.fingerprint()
        try service.changeJourney(journey.id) { $0.stage = .check }
        XCTAssertThrowsError(try service.putJourney(journey,baseline:digest))
        XCTAssertEqual(service.campus.journeys.first?.stage,.check)
    }
    @MainActor func testSplitRequiresConsentAndRejectsWholeBatchWhenOnePartIsInvalid() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:WorkroomStore(directory:root))
        var draft = WorkroomDraft();draft.text = "缴费通知\n费用：10元\n\n领取材料\n地点：服务中心";try service.use(draft)
        var preview = try NoticeSplitPreview.make(draft);let selected = Set(preview.parts.map(\.id));XCTAssertEqual(selected.count,2)
        XCTAssertThrowsError(try service.createSplitCases(preview,selected:selected,confirmed:false))
        preview.parts[1].title = ""
        XCTAssertThrowsError(try service.createSplitCases(preview,selected:selected,confirmed:true));XCTAssertTrue(service.cases.isEmpty)
        XCTAssertTrue(try WorkroomStore(directory:root).load().cases.isEmpty)
    }
    @MainActor func testSplitPersistsSelectedOnlyAndRefusesReplayOrStaleDraft() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:WorkroomStore(directory:root))
        var draft = WorkroomDraft();draft.text = "缴费\n费用：10元\n\n领卡\n地点：服务中心";try service.use(draft)
        let preview = try NoticeSplitPreview.make(draft),selected = Set([preview.parts[0].id])
        let ids = try service.createSplitCases(preview,selected:selected,confirmed:true)
        XCTAssertEqual(ids.count,1);XCTAssertEqual(try WorkroomStore(directory:root).load().cases.count,1)
        XCTAssertNil(service.cases.first?.reminderAt);XCTAssertEqual(service.cases.first?.documents.first?.text,draft.text)
        XCTAssertThrowsError(try service.createSplitCases(preview,selected:selected,confirmed:true))
        try service.edit(title:draft.title,text:draft.text+"补充")
        XCTAssertThrowsError(try service.createSplitCases(preview,selected:Set([preview.parts[1].id]),confirmed:true))
        XCTAssertEqual(service.cases.count,1)
    }
    @MainActor func testOutcomeAndFollowUpCaseSaveTogetherAndReminderIsOptIn() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:WorkroomStore(directory:root)),journey = CampusJourney(title:"补办")
        try service.putJourney(journey)
        try service.recordJourneyOutcome(journey.id,fingerprint:journey.fingerprint(),note:"还需证件照",nextAction:"带证件照到窗口",reminder:nil,finish:false)
        XCTAssertEqual(service.cases.count,1);XCTAssertNil(service.cases[0].reminderAt)
        let archive = try WorkroomStore(directory:root).load();XCTAssertEqual(archive.enhancements?.campus?.journeys.first?.caseIDs,[service.cases[0].id])
        XCTAssertThrowsError(try service.recordJourneyOutcome(journey.id,fingerprint:journey.fingerprint(),note:"过时结果",nextAction:"",reminder:nil,finish:true))
        XCTAssertEqual(service.campus.journeys[0].outcomes.count,1)
    }
    @MainActor func testDemoCannotScheduleRealReminderAndInvalidOutcomeCreatesNothing() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:WorkroomStore(directory:root)),journey = CampusJourney.studentCardExample();try service.putJourney(journey)
        XCTAssertThrowsError(try service.recordJourneyOutcome(journey.id,fingerprint:journey.fingerprint(),note:"示例结果",nextAction:"取卡",reminder:Date().addingTimeInterval(3600),finish:false))
        XCTAssertTrue(service.cases.isEmpty);XCTAssertTrue(service.campus.journeys[0].outcomes.isEmpty)
    }
    @MainActor func testRecoveryIsOptInAndNeverSilentlyRestoredAfterRestart() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:WorkroomStore(directory:root));var item = WorkroomCase();item.title = "未完成编辑"
        try service.captureRecovery(item,baseline:nil,saveLocally:false);XCTAssertTrue(service.campus.recoveries.isEmpty)
        try service.updateEnhancements { var ledger = CampusLedger();ledger.recoverEdits = true;$0.campus = ledger }
        try service.captureRecovery(item,baseline:nil,saveLocally:false)
        let next = WorkroomService(store:WorkroomStore(directory:root));XCTAssertEqual(next.campus.recoveries.count,1);XCTAssertTrue(next.cases.isEmpty)
        try next.restoreRecovery(next.campus.recoveries[0]);XCTAssertEqual(next.cases.count,1);XCTAssertTrue(next.savedCaseIDs.isEmpty)
        XCTAssertTrue(try WorkroomStore(directory:root).load().cases.isEmpty)
    }
    @MainActor func testRecoveryCannotOverwriteDifferentCaseVersion() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:WorkroomStore(directory:root));var item = WorkroomCase();item.title = "原事务";try service.putCase(item,saveLocally:true)
        try service.updateEnhancements { var ledger = CampusLedger();ledger.recoverEdits = true;$0.campus = ledger }
        let old = try item.reviewFingerprint();var edit = item;edit.title = "旧编辑";try service.captureRecovery(edit,baseline:old,saveLocally:true)
        item.title = "已在别处更新";try service.putCase(item,saveLocally:true)
        XCTAssertThrowsError(try service.restoreRecovery(service.campus.recoveries[0]));XCTAssertEqual(service.cases[0].title,item.title)
    }
    func testJourneyHandoffIncludesDependenciesButNoUnrelatedJourneyOrRecovery() throws {
        var source = LibrarySnapshot(),journey = CampusJourney.studentCardExample(),extra = WorkroomEnhancements(),ledger = CampusLedger()
        var project = WorkroomCase();project.title = "关联事务";project.demonstration = true;journey.caseIDs = [project.id]
        var other = WorkroomCase();other.title = "不关联的私密事务";source.workroom.cases = [project,other]
        ledger.journeys = [journey,CampusJourney(title:"私密旅程")];ledger.recoverEdits = true;ledger.recoveries = [.init(item:other,baseline:nil,saveLocally:false)];extra.campus = ledger;source.workroom.enhancements = extra
        let handoff = try source.handoff(journeyID:journey.id)
        XCTAssertEqual(handoff.workroom.cases.map(\.id),[project.id]);XCTAssertEqual(handoff.workroom.enhancements?.campus?.journeys.count,1)
        XCTAssertTrue(handoff.workroom.enhancements!.campus!.recoveries.isEmpty)
        let data = try LibraryCryptography.seal(.init(snapshot:source),password:"fixture-pass")
        let imported = try LibraryCryptography.open(data,password:"fixture-pass")
        XCTAssertTrue(imported.snapshot.workroom.enhancements!.campus!.recoveries.isEmpty)
    }
    func testSelectedCaseExportDoesNotLeakJourneyConversations() throws {
        var source = LibrarySnapshot(),extra = WorkroomEnhancements(),ledger = CampusLedger();ledger.journeys = [CampusJourney.studentCardExample()];extra.campus = ledger;source.workroom.enhancements = extra
        var selection = LibraryExportSelection();selection.cases = false
        XCTAssertTrue(try selection.apply(to:source).workroom.enhancements!.campus!.journeys.isEmpty)
    }
    func testMergeRetainsJourneyAndDoesNotImportRecoveryOptIn() throws {
        var incoming = LibrarySnapshot(),extra = WorkroomEnhancements(),ledger = CampusLedger();ledger.journeys = [CampusJourney.studentCardExample()];extra.campus = ledger;incoming.workroom.enhancements = extra
        let preview = try LibraryMerge.preview(local:LibrarySnapshot(),package:.init(snapshot:incoming),options:.init())
        XCTAssertEqual(preview.target.workroom.enhancements?.campus?.journeys.count,1)
        XCTAssertFalse(preview.target.workroom.enhancements!.campus!.recoverEdits)
    }
    func testEvidenceLocationHandlesChineseAndMultilineQuotesWithoutGuessing() throws {
        var draft = WorkroomDraft();draft.text = "前文\n地点：学生中心\n材料：校园卡";let source = CaseDocument(draft:draft)
        XCTAssertEqual(try EvidenceLocation.locate(quote:"地点：学生中心\n材料",in:source).firstLine,1)
        XCTAssertThrowsError(try EvidenceLocation.locate(quote:"另一句话",in:source))
    }
    func testManualAndAutomaticRedactionPreserveOriginalAndHideSelectedIdentifiers() {
        let original = "张同学 13812345678 abc@example.com 学号20260001"
        let result = ShareRedaction.apply(original,terms:["张同学","20260001"],identifiers:true)
        XCTAssertFalse(result.contains("13812345678"));XCTAssertFalse(result.contains("abc@example.com"));XCTAssertFalse(result.contains("张同学"));XCTAssertTrue(original.contains("13812345678"))
    }
    func testWatchInvalidationIsVersionAndTimeScoped() throws {
        let now = Date(),item = WatchAgendaItem(id:UUID(),kind:.project,title:"办事",next:"检查材料",fingerprint:String(repeating:"a",count:64),demonstration:false,completed:false)
        let notice = WatchVersionNotice(date:now,fingerprints:[item.id.uuidString:String(repeating:"b",count:64)]);try notice.validate(now:now)
        XCTAssertTrue(notice.invalidates(item,snapshotDate:now.addingTimeInterval(-1)))
        XCTAssertFalse(notice.invalidates(item,snapshotDate:now.addingTimeInterval(1)))
        XCTAssertFalse(WatchVersionNotice(date:now,fingerprints:[:]).invalidates(item,snapshotDate:now))
    }
    func testLinkedTaskChangeInvalidatesWatchCaseFingerprint() throws {
        var item = WorkroomCase(),task = RoutineItem();task.title = "关联待办";item.links = [.init(id:task.id,kind:.routine,snapshot:task.title)]
        let before = try item.watchSummary(routines:[task]);task.completedAt = Date()
        XCTAssertNotEqual(before.fingerprint,try item.watchSummary(routines:[task]).fingerprint)
    }
    func testChangeImpactUsesActualOldEvidenceAndPreservesCompletion() throws {
        let journey = CampusJourney.studentCardExample(),source = journey.documents[0]
        var item = WorkroomCase();item.demonstration = true;item.sources = [source]
        item.arrangements = [.init(kind:.place,value:"学生服务中心一楼",documentID:source.id,quote:"地点：学生服务中心一楼")]
        item.steps = [.init(title:"到学生服务中心一楼领卡",done:true),.init(title:"带证件照")]
        let changes = [CaseChangeCandidate(kind:.place,value:"服务中心二楼",quote:"地点：服务中心二楼")]
        let affected = CaseUpdateComparison.affectedRows(item:item,changes:changes)
        XCTAssertEqual(affected.map(\.id),[item.steps[0].id]);XCTAssertTrue(item.steps[0].done)
    }
    func testOldArchiveDecodesWithoutCampusData() throws {
        let encoded = try JSONEncoder().encode(WorkroomArchive());let archive = try JSONDecoder().decode(WorkroomArchive.self,from:encoded);try archive.validate()
        XCTAssertNil(archive.enhancements?.campus)
    }
    @MainActor func testLinkedCaseChangeInvalidatesSourceMatchedConfirmationAtomically() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:WorkroomStore(directory:root));var journey = CampusJourney.studentCardExample()
        journey.facts[0].userConfirmedAt = Date();journey.facts[0].counterpartRecordedAt = Date()
        var item = WorkroomCase();item.demonstration = true;item.sources = journey.documents
        item.arrangements = [.init(kind:.place,value:journey.facts[0].value,documentID:journey.documents[0].id,quote:journey.facts[0].quote)]
        try service.putJourney(journey);try service.putCase(item,saveLocally:true);try service.linkCaseToJourney(item.id,journeyID:journey.id)
        var draft = WorkroomDraft();draft.origin = .demonstration;draft.text = "地点：服务中心二楼";let source = CaseDocument(draft:draft)
        item.sources?.append(source);item.arrangements = [.init(kind:.place,value:"服务中心二楼",documentID:source.id,quote:source.text)]
        try service.putCase(item,saveLocally:true)
        let updated = service.campus.journeys[0]
        XCTAssertTrue(updated.facts[0].superseded);XCTAssertNil(updated.facts[0].userConfirmedAt);XCTAssertNil(updated.facts[0].counterpartRecordedAt)
        XCTAssertFalse(updated.changedCases(service.cases).isEmpty)
        XCTAssertThrowsError(try service.confirmJourneyFact(journey.id,factID:journey.facts[1].id,revision:1,counterpart:false))
        let disk = try WorkroomStore(directory:root).load();XCTAssertEqual(disk.cases[0].confirmedFacts[0].value,"服务中心二楼");XCTAssertTrue(disk.enhancements!.campus!.journeys[0].facts[0].superseded)
        try service.acknowledgeJourneyCases(journey.id);XCTAssertTrue(service.campus.journeys[0].changedCases(service.cases).isEmpty)
        XCTAssertTrue(service.campus.journeys[0].facts[0].superseded)
    }
    func testCompletionTicksDoNotRequireJourneyArrangementReview() throws {
        var item = WorkroomCase();item.materials = [.init(title:"学生证")]
        var journey = CampusJourney(title:"办事");journey.caseIDs = [item.id];journey.caseVersions = [item.id.uuidString:try item.journeyVersion()]
        item.materials[0].done = true;XCTAssertTrue(journey.changedCases([item]).isEmpty)
        item.dueAt = Date().addingTimeInterval(1000);XCTAssertFalse(journey.changedCases([item]).isEmpty)
    }
    func testWatchSeenAppliesOnlyToSameVersionIncludingLinkedTasks() throws {
        var item = WorkroomCase();item.materials = [.init(title:"学生证")]
        item.watchSeenVersion = try item.watchViewVersion(routines:[]);item.watchSeenAt = Date()
        XCTAssertTrue(try item.watchSummary(routines:[]).seen)
        item.materials[0].done = true;XCTAssertFalse(try item.watchSummary(routines:[]).seen)
        item.watchSeenVersion = nil;XCTAssertFalse(try item.watchSummary(routines:[]).seen)
    }
    func testRemovingVisualReferencesDoesNotInvalidateJourneyCaseInformationVersion() throws {
        var snapshot = LibrarySnapshot(),draft = WorkroomDraft();draft.text = "材料：学生证";draft.visualID = UUID()
        var item = WorkroomCase();item.sources = [CaseDocument(draft:draft)];snapshot.workroom.cases = [item]
        var journey = CampusJourney(title:"办事");journey.caseIDs = [item.id];journey.caseVersions = [item.id.uuidString:try item.journeyVersion()]
        var extra = WorkroomEnhancements();var ledger = CampusLedger();ledger.journeys = [journey];extra.campus = ledger;snapshot.workroom.enhancements = extra
        let moved = snapshot.withoutLocalVisualReferences();XCTAssertTrue(moved.workroom.enhancements!.campus!.journeys[0].changedCases(moved.workroom.cases).isEmpty)
    }

    func testSettingsDeselectionKeepsJourneyButDoesNotExportItsListPreferences() throws {
        var snapshot = LibrarySnapshot(),extra = WorkroomEnhancements(),ledger = CampusLedger()
        ledger.journeys = [CampusJourney(title:"办事")];ledger.listOptions.sort = .due;ledger.caseFilter = .archived;ledger.includeDemo = false;extra.campus = ledger;snapshot.workroom.enhancements = extra
        var choice = LibraryExportSelection();choice.settings = false
        let exported = try choice.apply(to:snapshot).workroom.enhancements!.campus!
        XCTAssertEqual(exported.journeys.count,1);XCTAssertEqual(exported.listOptions,.init());XCTAssertNil(exported.caseFilter);XCTAssertNil(exported.includeDemo)
    }

}
