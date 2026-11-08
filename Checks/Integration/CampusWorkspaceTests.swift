import Foundation
import XCTest
@testable import SeeSoundData

final class CampusWorkspaceTests:XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    @MainActor func testAnswerFactNeedsConsentExactValueAndKeepsUnconfirmedManualSource() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url))
        var journey = try CampusScenario.counter.makeJourney(title:"窗口咨询",questions:["在哪里办理？"],date:nil)
        journey.questions[0].answer = "请到学生服务中心二楼。"
        try studio.putJourney(journey)
        let questionID = journey.questions[0].id,baseline = try journey.fingerprint()
        XCTAssertThrowsError(try studio.makeJourneyAnswerFact(journey.id,questionID:questionID,kind:.place,value:"学生服务中心二楼",baseline:baseline,consent:false))
        XCTAssertThrowsError(try studio.makeJourneyAnswerFact(journey.id,questionID:questionID,kind:.place,value:"图书馆三楼",baseline:baseline,consent:true))
        let factID = try studio.makeJourneyAnswerFact(journey.id,questionID:questionID,kind:.place,value:"学生服务中心二楼",baseline:baseline,consent:true)
        let current = try XCTUnwrap(studio.campus.journeys.first)
        XCTAssertEqual(current.documents.count,1);XCTAssertEqual(current.documents[0].origin,.typed)
        XCTAssertTrue(current.documents[0].text.contains("非逐字录音"))
        let fact = try XCTUnwrap(current.facts.first)
        XCTAssertEqual(fact.id,factID);XCTAssertEqual(fact.quote,journey.questions[0].answer)
        XCTAssertNil(fact.userConfirmedAt);XCTAssertNil(fact.counterpartRecordedAt)
        XCTAssertEqual(try studio.makeJourneyAnswerFact(journey.id,questionID:questionID,kind:.place,value:fact.value,baseline:current.fingerprint(),consent:true),factID)
        XCTAssertEqual(try studio.campus.journeys[0].fingerprint(),try current.fingerprint())
        let restored = WorkroomService(store:WorkroomStore(directory:url))
        XCTAssertEqual(restored.campus.journeys[0],current)
    }
    @MainActor func testAnswerEditInvalidatesDependentCardsAndNewSnapshotRetainsOldEvidence() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url))
        var journey = try CampusScenario.counter.makeJourney(title:"模拟窗口",questions:["在哪里办理？"],date:nil)
        journey.demonstration = true;journey.questions[0].answer = "学生服务中心二楼"
        try studio.putJourney(journey)
        let questionID = journey.questions[0].id
        let factID = try studio.makeJourneyAnswerFact(journey.id,questionID:questionID,kind:.place,value:"学生服务中心二楼",baseline:journey.fingerprint(),consent:true)
        try studio.confirmJourneyFact(journey.id,factID:factID,revision:1,counterpart:false)
        try studio.confirmJourneyFact(journey.id,factID:factID,revision:1,counterpart:true)
        try studio.changeJourney(journey.id) { $0.questions[0].answer = "学生服务中心三楼" }
        var current = studio.campus.journeys[0]
        XCTAssertTrue(current.facts[0].superseded);XCTAssertNil(current.facts[0].userConfirmedAt);XCTAssertNil(current.facts[0].counterpartRecordedAt)
        XCTAssertEqual(current.documents.count,1)
        XCTAssertThrowsError(try studio.confirmJourneyFact(journey.id,factID:factID,revision:1,counterpart:false))
        let updatedID = try studio.makeJourneyAnswerFact(journey.id,questionID:questionID,kind:.place,value:"学生服务中心三楼",baseline:current.fingerprint(),consent:true)
        current = studio.campus.journeys[0]
        XCTAssertNotEqual(updatedID,factID);XCTAssertEqual(current.documents.map(\.revision),[1,2])
        XCTAssertTrue(current.documents.allSatisfy(\.demonstration));XCTAssertTrue(current.documents[0].text.contains("二楼"))
        XCTAssertTrue(current.facts[0].superseded);XCTAssertFalse(current.facts[1].isConfirmed)
        try current.validate()
    }
    @MainActor func testStaleAnswerPreviewAndCapacityFailureDoNotPartiallySave() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url))
        var journey = try CampusScenario.counter.makeJourney(title:"窗口",questions:["需要什么材料？"],date:nil)
        journey.questions[0].answer = "校园卡";try studio.putJourney(journey)
        let baseline = try journey.fingerprint(),questionID = journey.questions[0].id
        try studio.changeJourney(journey.id) { $0.questions[0].answer = "校园卡和照片" }
        XCTAssertThrowsError(try studio.makeJourneyAnswerFact(journey.id,questionID:questionID,kind:.material,value:"校园卡",baseline:baseline,consent:true))
        XCTAssertTrue(studio.campus.journeys[0].documents.isEmpty);XCTAssertTrue(studio.campus.journeys[0].facts.isEmpty)
        try studio.changeJourney(journey.id) { item in
            for i in 0..<12 { var draft = WorkroomDraft();draft.title = "材料\(i)";draft.text = "第\(i)份已存材料";try item.attach(CaseDocument(draft:draft)) }
        }
        let full = studio.campus.journeys[0]
        XCTAssertThrowsError(try studio.makeJourneyAnswerFact(journey.id,questionID:questionID,kind:.material,value:"校园卡",baseline:full.fingerprint(),consent:true))
        XCTAssertEqual(studio.campus.journeys[0],full)
    }
    @MainActor func testRemovingQuestionInvalidatesOnlyItsDependentAnswerCards() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url))
        var journey = CampusJourney.studentCardExample()
        journey.questions[0].answer = "学生服务中心一楼";try studio.putJourney(journey)
        let factID = try studio.makeJourneyAnswerFact(journey.id,questionID:journey.questions[0].id,kind:.place,value:"学生服务中心一楼",baseline:journey.fingerprint(),consent:true)
        try studio.confirmJourneyFact(journey.id,factID:factID,revision:1,counterpart:false)
        try studio.confirmJourneyFact(journey.id,factID:journey.facts[0].id,revision:1,counterpart:false)
        try studio.changeJourney(journey.id) { $0.questions.removeFirst() }
        let current = studio.campus.journeys[0]
        XCTAssertTrue(try XCTUnwrap(current.facts.first{$0.id == factID}).superseded)
        XCTAssertTrue(try XCTUnwrap(current.facts.first{$0.id == journey.facts[0].id}).isConfirmed)
    }
    func testScenarioOnlyCreatesQuestionsAndExplicitUserDate() throws {
        let date = Date().addingTimeInterval(3600)
        for scenario in CampusScenario.allCases {
            let journey = try scenario.makeJourney(title:scenario.title,questions:scenario.questions,date:date)
            XCTAssertEqual(journey.questions.count,3);XCTAssertTrue(journey.facts.isEmpty);XCTAssertTrue(journey.documents.isEmpty)
            XCTAssertEqual(journey.plan?.plannedAt,date);XCTAssertEqual(journey.plan?.scenario,scenario)
        }
    }
    func testLegacyJourneyAndLedgerDecodeWithoutNewFields() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(CampusJourney.studentCardExample())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);json.removeValue(forKey:"plan")
        let old = try JSONDecoder().decode(CampusJourney.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(old.plan);try old.validate()
        var ledger = CampusLedger();ledger.journeys = [old]
        let roundtrip = try JSONDecoder().decode(CampusLedger.self,from:encoder.encode(ledger));XCTAssertNil(roundtrip.workspace)
    }
    func testInvalidPlanDateAndInventedQuestionEvidenceAreRejected() throws {
        var journey = CampusJourney.studentCardExample();journey.plan = JourneyPlan(plannedAt:Date(timeIntervalSince1970:.infinity))
        XCTAssertThrowsError(try journey.validate())
        journey.plan = JourneyPlan(questionEvidence:[.init(questionID:journey.questions[0].id,excerptID:UUID(),quote:"不存在",answer:"捏造")])
        XCTAssertThrowsError(try journey.validate())
        var personal = CampusJourney(title:"普通旅程")
        personal.plan = JourneyPlan(presentationID:"campus-040")
        XCTAssertThrowsError(try personal.validate())
    }
    @MainActor func testBookmarkAndFavoritesPersistWithoutChangingJourneyVersion() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url)),journey = CampusJourney.studentCardExample()
        try studio.putJourney(journey);let before = try journey.fingerprint()
        try studio.rememberJourney(journey.id,section:.confirmation,targetID:journey.facts[0].id)
        try studio.updateCampusWorkspace { $0.favoriteJourneyIDs = [journey.id];$0.favoriteScenarios = [.certificate] }
        let restored = WorkroomService(store:WorkroomStore(directory:url))
        XCTAssertEqual(restored.campusWorkspace.bookmarks[0].targetID,journey.facts[0].id)
        XCTAssertEqual(restored.campusWorkspace.favoriteJourneyIDs,[journey.id])
        XCTAssertEqual(try restored.campus.journeys[0].fingerprint(),before)
    }
    @MainActor func testJourneyDeletionRemovesLocalReadingAndWatchState() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url)),journey = CampusJourney.studentCardExample()
        try studio.putJourney(journey);try studio.rememberJourney(journey.id,section:.questions)
        try studio.updateCampusWorkspace { $0.favoriteJourneyIDs = [journey.id];$0.watchSeenVersions[journey.id.uuidString] = String(repeating:"a",count:64) }
        try studio.removeJourney(journey.id);XCTAssertTrue(studio.campusWorkspace.bookmarks.isEmpty);XCTAssertTrue(studio.campusWorkspace.favoriteJourneyIDs.isEmpty);XCTAssertTrue(studio.campusWorkspace.watchSeenVersions.isEmpty)
    }
    func testDuplicateNormalizationPreservesDifferentContentAndOrigin() throws {
        var journey = CampusJourney.studentCardExample()
        var draft = WorkroomDraft();draft.origin = .demonstration;draft.text = journey.documents[0].text.replacingOccurrences(of:"\n",with:"  ")
        XCTAssertEqual(JourneyMaterialAnalysis.duplicates(CaseDocument(draft:draft),in:journey).count,1)
        draft.text += "新增材料";XCTAssertTrue(JourneyMaterialAnalysis.duplicates(CaseDocument(draft:draft),in:journey).isEmpty)
        draft.origin = .typed;XCTAssertThrowsError(try journey.attach(CaseDocument(draft:draft)))
    }
    @MainActor func testDuplicateSourceRequiresExplicitKeepAndStalePreviewCannotWrite() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url)),journey = CampusJourney.studentCardExample()
        try studio.putJourney(journey);var source = journey.documents[0];source.id = UUID();source.draftID = UUID()
        let baseline = try journey.fingerprint()
        XCTAssertThrowsError(try studio.attachJourneySource(source,to:journey.id,baseline:baseline,allowDuplicate:false))
        try studio.attachJourneySource(source,to:journey.id,baseline:baseline,allowDuplicate:true)
        XCTAssertEqual(studio.campus.journeys[0].documents.count,2)
        source.id = UUID();source.draftID = UUID()
        XCTAssertThrowsError(try studio.attachJourneySource(source,to:journey.id,baseline:baseline,allowDuplicate:true))
    }
    func testConflictOnlyUsesLatestVersionOfEachMaterial() throws {
        var journey = CampusJourney.studentCardExample(),replacement = journey.documents[0]
        replacement.id = UUID();replacement.revision = 2;replacement.text = "地点：学生服务中心二楼\n费用：10元"
        try journey.attach(replacement);XCTAssertTrue(JourneyMaterialAnalysis.conflicts(journey).isEmpty)
        var different = WorkroomDraft();different.origin = .demonstration;different.text = "地点：图书馆三楼\n费用：20元";try journey.attach(CaseDocument(draft:different))
        XCTAssertEqual(Set(JourneyMaterialAnalysis.conflicts(journey).map(\.kind)),[.place,.amount])
        let history = try XCTUnwrap(JourneyRevisionDelta.history(journey).first{$0.after.id == replacement.id})
        XCTAssertEqual(history.before?.revision,1);XCTAssertTrue(history.added.contains("地点：学生服务中心二楼"))
    }
    @MainActor func testConflictResolutionDoesNotSilentlyRewriteFactsAndNewSourceReopensIt() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url));var journey = CampusJourney.studentCardExample()
        var draft = WorkroomDraft();draft.origin = .demonstration;draft.text = "地点：图书馆二楼";let source = CaseDocument(draft:draft);try journey.attach(source);try studio.putJourney(journey)
        let conflict = try XCTUnwrap(JourneyMaterialAnalysis.conflicts(journey).first)
        try studio.resolveJourneyConflict(journey.id,key:conflict.id,sourceID:source.id,note:"现场核对采用这份",baseline:journey.fingerprint())
        var current = studio.campus.journeys[0];XCTAssertEqual(current.facts[0].value,journey.facts[0].value)
        XCTAssertFalse(CampusOverview.attention([current],cases:[]).contains{$0.section == .materials})
        var updated = source;updated.id = UUID();updated.revision += 1;updated.text = "地点：图书馆五楼";try current.attach(updated)
        XCTAssertTrue(CampusOverview.attention([current],cases:[]).contains{$0.section == .materials})
    }
    @MainActor func testQuestionEvidenceRequiresConsentExactQuoteAndCurrentVersion() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url));var journey = CampusJourney.studentCardExample()
        let excerpt = JourneyConversation(title:"窗口",text:"请在二楼提交材料。");journey.conversations = [excerpt];try studio.putJourney(journey)
        let baseline = try journey.fingerprint(),question = journey.questions[0].id
        XCTAssertThrowsError(try studio.linkJourneyAnswer(journey.id,questionID:question,excerptID:excerpt.id,quote:"请在二楼",answer:"二楼",baseline:baseline,consent:false))
        XCTAssertThrowsError(try studio.linkJourneyAnswer(journey.id,questionID:question,excerptID:excerpt.id,quote:"三楼",answer:"三楼",baseline:baseline,consent:true))
        try studio.linkJourneyAnswer(journey.id,questionID:question,excerptID:excerpt.id,quote:"请在二楼",answer:"二楼提交",baseline:baseline,consent:true)
        XCTAssertEqual(studio.campus.journeys[0].questions[0].answer,"二楼提交")
        XCTAssertEqual(studio.campus.journeys[0].plan?.questionEvidence.count,1)
        XCTAssertThrowsError(try studio.linkJourneyAnswer(journey.id,questionID:question,excerptID:excerpt.id,quote:"请在二楼",answer:"旧窗口",baseline:baseline,consent:true))
    }
    @MainActor func testExcerptSaveNeverMixesDemonstrationAndPersonal() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url)),journey = CampusJourney(title:"真实旅程")
        try studio.putJourney(journey)
        XCTAssertThrowsError(try studio.addJourneyExcerpt(journey.id,text:"演示",title:"示例",demonstration:true,consent:true))
        XCTAssertThrowsError(try studio.addJourneyExcerpt(journey.id,text:"普通",title:"文字",demonstration:false,consent:false))
        XCTAssertTrue(studio.campus.journeys[0].conversations.isEmpty)
    }
    func testSearchKeepsJourneyChildrenSeparateAndProvidesParentRoute() throws {
        var journey = CampusJourney.studentCardExample();journey.questions[0].answer = "到窗口";journey.conversations = [.init(title:"窗口回答",text:"窗口在一楼")]
        let hits = WorkroomSearch.hits(query:"窗口",events:[],conversations:[],cards:[],routines:[],drafts:[],cases:[],journeys:[journey])
        XCTAssertTrue(hits.contains{$0.kind == .question});XCTAssertTrue(hits.contains{$0.kind == .excerpt})
        XCTAssertTrue(hits.allSatisfy{$0.parentJourneyID == journey.id && $0.demonstration});XCTAssertEqual(Set(hits.map(\.id)).count,hits.count)
    }
    func testSearchDistinguishesSharedSourceAndFactIDsAcrossJourneys() {
        let first = CampusJourney.studentCardExample()
        var second = first;second.id = UUID();second.title = "另一段办理旅程"
        let hits = WorkroomSearch.hits(query:"学生服务中心",events:[],conversations:[],cards:[],routines:[],drafts:[],cases:[],journeys:[first,second])
        let sources = hits.filter{$0.kind == .journeySource}
        let facts = hits.filter{$0.kind == .journeyFact}
        XCTAssertEqual(sources.count,2);XCTAssertEqual(facts.count,2)
        XCTAssertEqual(Set(sources.compactMap(\.parentJourneyID)),[first.id,second.id])
        XCTAssertEqual(Set(hits.map(\.id)).count,hits.count)
    }
    func testScheduleUsesExplicitUserPlanAndExcludesFinishedJourney() throws {
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let now = Date(timeIntervalSince1970:1_790_000_000)
        var a = CampusJourney(title:"计划");a.plan = JourneyPlan(plannedAt:now)
        var b = a;b.id = UUID();b.stage = .finished
        XCTAssertEqual(CampusOverview.scheduled([a,b,CampusJourney(title:"没安排")],on:now,week:false,calendar:calendar).map(\.id),[a.id])
    }
    func testScheduleUsesHalfOpenDayAndWeekBoundaries() throws {
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let now = Date(timeIntervalSince1970:1_790_000_000)
        for week in [false,true] {
            let interval = try XCTUnwrap(calendar.dateInterval(of:week ? .weekOfYear : .day,for:now))
            var first = CampusJourney(title:"本期起点");first.plan = JourneyPlan(plannedAt:interval.start)
            var next = CampusJourney(title:"下一期起点");next.plan = JourneyPlan(plannedAt:interval.end)
            XCTAssertEqual(CampusOverview.scheduled([first,next],on:now,week:week,calendar:calendar).map(\.id),[first.id])
        }
    }
    func testAttentionIDsAreScopedToParentJourney() {
        var first = CampusJourney.studentCardExample();first.facts[0].superseded = true
        var second = first;second.id = UUID()
        let rows = CampusOverview.attention([first,second],cases:[])
        XCTAssertEqual(rows.count,2);XCTAssertEqual(Set(rows.map(\.id)).count,2)
        XCTAssertEqual(Set(rows.map(\.journeyID)),[first.id,second.id])
    }
    func testWatchJourneyContainsOnlySummaryAndContentChangesInvalidateIt() throws {
        var journey = CampusJourney.studentCardExample();journey.facts[0].userConfirmedAt = Date()
        let before = try journey.watchJourneySummary();XCTAssertEqual(before.kind,.journey);XCTAssertTrue(before.next.contains("地点"))
        XCTAssertFalse(before.next.contains("费用：10"));XCTAssertNil(WatchAgendaActionPolicy.rejection(item:before,fingerprint:before.fingerprint,action:.seen))
        XCTAssertNotNil(WatchAgendaActionPolicy.rejection(item:before,fingerprint:before.fingerprint,action:.complete))
        journey.questions[0].answer = "已向窗口确认"
        XCTAssertNotEqual(before.fingerprint,try journey.watchJourneySummary().fingerprint)
    }
    func testLocalReadingAndWatchReceiptStateDoesNotEnterEncryptedExport() throws {
        var snapshot = LibrarySnapshot(),extra = WorkroomEnhancements(),ledger = CampusLedger()
        let journey = CampusJourney.studentCardExample();ledger.journeys = [journey]
        ledger.workspace = CampusWorkspaceState(favoriteJourneyIDs:[journey.id],bookmarks:[.init(journeyID:journey.id,section:.confirmation,targetID:journey.facts[0].id)])
        extra.campus = ledger;snapshot.workroom.enhancements = extra
        let data = try LibraryCryptography.seal(.init(snapshot:snapshot),password:"fixture-040")
        let restored = try LibraryCryptography.open(data,password:"fixture-040")
        XCTAssertNil(restored.snapshot.workroom.enhancements?.campus?.workspace)
    }
    func testIncomingJourneyDifferenceRespectsKeepLocalChoice() throws {
        var local = LibrarySnapshot(),incoming = LibrarySnapshot(),extra = WorkroomEnhancements(),ledger = CampusLedger()
        var journey = CampusJourney.studentCardExample();ledger.journeys = [journey];extra.campus = ledger;local.workroom.enhancements = extra
        journey.title = "改过标题";ledger.journeys = [journey];extra.campus = ledger;incoming.workroom.enhancements = extra
        let diff = LibraryJourneyDifference.make(local:local,package:.init(snapshot:incoming),preferIncoming:false)
        XCTAssertEqual(diff.count,1);XCTAssertFalse(diff[0].appliesIncoming);XCTAssertTrue(diff[0].summary[0].contains("标题"))
    }
    @MainActor func testPresentationResetOnlyTouchesItsOwnMarkedJourney() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let studio = WorkroomService(store:WorkroomStore(directory:url)),personal = CampusJourney(title:"保留我的旅程"),otherDemo = CampusJourney.studentCardExample()
        try studio.putJourney(personal);try studio.putJourney(otherDemo)
        let first = try studio.startCampusPresentation(reset:false)
        XCTAssertEqual(first,try studio.startCampusPresentation(reset:false))
        try studio.rememberJourney(first,section:.confirmation)
        try studio.updateCampusWorkspace {
            $0.favoriteJourneyIDs = [first,personal.id]
            $0.bookmarks.append(.init(journeyID:personal.id,section:.questions))
            $0.watchSeenVersions[first.uuidString] = String(repeating:"a",count:64)
            $0.watchSeenVersions[personal.id.uuidString] = String(repeating:"b",count:64)
        }
        XCTAssertNotEqual(first,try studio.startCampusPresentation(reset:true))
        XCTAssertTrue(studio.campus.journeys.contains{$0.id == personal.id});XCTAssertTrue(studio.campus.journeys.contains{$0.id == otherDemo.id})
        XCTAssertEqual(studio.campus.journeys.filter{$0.plan?.presentationID == "campus-040"}.count,1)
        XCTAssertEqual(studio.campusWorkspace.favoriteJourneyIDs,[personal.id])
        XCTAssertEqual(studio.campusWorkspace.bookmarks.map(\.journeyID),[personal.id])
        XCTAssertEqual(studio.campusWorkspace.watchSeenVersions,[personal.id.uuidString:String(repeating:"b",count:64)])
    }
    func testCharacterMetricPreservesDigitsAndCountsInsertionsAndSubstitutions() {
        XCTAssertEqual(CharacterEvaluation.compare(reference:"时间：09:30。",observed:"时间 09:30")?.edits,0)
        XCTAssertEqual(CharacterEvaluation.compare(reference:"二楼12元",observed:"三楼13元")?.edits,2)
        XCTAssertEqual(CharacterEvaluation.compare(reference:"提交",observed:"请提交")?.edits,1)
        XCTAssertNil(CharacterEvaluation.compare(reference:"",observed:"结果"))
        XCTAssertNil(CharacterEvaluation.compare(reference:String(repeating:"字",count:1501),observed:"结果"))
    }
    func testEvaluationRecordStoreRoundtripPreservesRawOutputAndManualCorrectionSeparately() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let store = CampusEvaluationStore(directory:url);var record = CampusEvaluationRecord(sampleID:"notice",title:"公告",kind:.ocr,model:"Vision",reference:"二楼",observed:"三楼",elapsed:0.4)
        record.correction = "二楼";record.reviewed = true;try store.save([record])
        let loaded = try XCTUnwrap(store.load().first);XCTAssertEqual(loaded.observed,"三楼");XCTAssertEqual(loaded.correction,"二楼");XCTAssertEqual(loaded.score?.edits,1)
    }
    func testEvaluationStoreRejectsCorruptionAndInvalidDurations() throws {
        let url = root();defer { try? FileManager.default.removeItem(at:url) }
        let store = CampusEvaluationStore(directory:url);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        try Data("broken".utf8).write(to:url.appendingPathComponent("records.json"));XCTAssertThrowsError(try store.load())
        let record = CampusEvaluationRecord(sampleID:"test",title:"测",kind:.speech,model:"Base",reference:"参考",observed:"",elapsed:-1)
        XCTAssertThrowsError(try store.save([record]));XCTAssertEqual(try String(contentsOf:url.appendingPathComponent("records.json")),"broken")
    }
}
