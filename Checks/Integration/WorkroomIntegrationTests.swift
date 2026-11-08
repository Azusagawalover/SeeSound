import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import SeeSoundData

final class WorkroomIntegrationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeeSoundWorkroomChecks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testFragmentsAreStableBoundedAndNeverSendUnselectedLongText() throws {
        var draft = WorkroomDraft(); draft.text = String(repeating: "材料", count: 2000)
        try draft.validate()
        XCTAssertEqual(draft.fragments.count, 8)
        XCTAssertEqual(draft.fragments.map(\.id), draft.fragments.map(\.id))
        XCTAssertTrue(draft.fragments.allSatisfy { $0.text.count <= 500 })
        let payload = InsightRequest(turns: Array(draft.fragments.prefix(6)))
        try payload.validate(); XCTAssertEqual(payload.turns.map(\.text).joined().count, 3000)
        XCTAssertThrowsError(try InsightRequest(turns: draft.fragments).validate())
    }
    func testRevisionHistoryPreservesOriginAndKeepsSixPreviousVersions() throws {
        var draft = WorkroomDraft.demonstrationDraft()
        let id = draft.id, oldFragment = draft.fragments[0].id
        for index in 0..<10 { draft = try draft.edited(title: draft.title, text: "演示修改 \(index)") }
        XCTAssertEqual(draft.id,id); XCTAssertTrue(draft.demonstration); XCTAssertEqual(draft.history.count,6)
        XCTAssertNotEqual(draft.fragments[0].id,oldFragment)
        let restored = try draft.edited(title: draft.title,text: draft.history[0].text)
        XCTAssertEqual(restored.revision,draft.revision+1)
        XCTAssertThrowsError(try draft.edited(title: draft.title,text: String(repeating:"字",count:12001)))
        let diff = TextComparison(old:"三点\n二楼",new:"四点\n三楼")
        XCTAssertEqual(diff.added,["四点","三楼"]); XCTAssertEqual(diff.removed,["三点","二楼"])
        XCTAssertEqual(TextComparison(old:"材料\n材料",new:"材料").removed,["材料"])
    }
    func testOfflineRulesExtractExplicitFactsWithoutInferringDatesOrActions() throws {
        let draft = WorkroomDraft.demonstrationDraft()
        let request = InsightRequest(turns:draft.fragments)
        let output = try LocalTextOrganizer.organize(request)
        XCTAssertEqual(output.provider,"LocalRules"); XCTAssertTrue(output.replies.isEmpty)
        XCTAssertTrue(output.candidates.contains { $0.kind == .amount && $0.value == "12" && $0.currency == "CNY" })
        XCTAssertTrue(output.candidates.contains { $0.kind == .place && $0.value == "图书馆二楼" })
        XCTAssertTrue(output.candidates.contains { $0.kind == .time && $0.date != nil })
        XCTAssertFalse(output.questions?.isEmpty ?? true)
        for candidate in output.candidates where candidate.kind != .task {
            let card = try candidate.makeCard(request:request,assistant:output.assistantTitle)
            XCTAssertFalse(card.reviewed); XCTAssertEqual(card.assistedBy,"本地规则"); XCTAssertEqual(card.origin,.demonstration)
        }
    }
    func testOfflineRulesRejectImpossibleDatesAndConflictingArrangements() throws {
        var draft = WorkroomDraft();draft.text="时间：2026-02-30 15:00\n地点：未定\n费用没确定"
        var output = try LocalTextOrganizer.organize(.init(turns:draft.fragments))
        XCTAssertFalse(output.candidates.contains { $0.kind == .time || $0.kind == .amount || $0.kind == .place })
        draft.text="2026-10-30 15:00，费用12元人民币，后续取消并改为别的时间。"
        output=try LocalTextOrganizer.organize(.init(turns:draft.fragments));XCTAssertTrue(output.candidates.isEmpty)
    }
    @MainActor
    func testClarificationAppendsUserAnswerAndRejectsOldQuestionAfterRevision() throws {
        let service=WorkroomService(store:WorkroomStore(directory:directory))
        try service.use(.demonstrationDraft())
        let turn=try XCTUnwrap(service.active.fragments.first)
        let question=InsightQuestion(kind:.time,question:"报名截止是何时？",sourceID:turn.id,quote:"报名截止时间待定")
        try question.validate(request:.init(turns:[turn]))
        try service.answer(question,text:"我已向组织者核对：2026-10-29 18:00。")
        XCTAssertTrue(service.active.text.contains("我的补充"));XCTAssertTrue(service.active.demonstration)
        XCTAssertThrowsError(try service.answer(question,text:"再回答"))
        XCTAssertTrue(service.drafts.isEmpty)
    }
    @MainActor
    func testDraftAndCaseSavingAreIndependentOptInAndDeletionDoesNotRemoveOtherStores() throws {
        let store=WorkroomStore(directory:directory)
        let service=WorkroomService(store:store)
        try service.use(.demonstrationDraft())
        var item=WorkroomCase();item.title="读书会";item.demonstration=true;item.steps=[.init(title:"报名")]
        try service.putCase(item,saveLocally:false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.url.path))
        try service.saveDraft()
        XCTAssertEqual(try store.load().drafts.count,1);XCTAssertTrue(try store.load().cases.isEmpty)
        try service.putCase(item,saveLocally:true)
        let reopened=WorkroomService(store:store)
        XCTAssertEqual(reopened.cases.count,1);XCTAssertTrue(reopened.active.text.isEmpty)
        item.demonstration=false;XCTAssertThrowsError(try reopened.putCase(item,saveLocally:true))
        try reopened.removeCase(item.id)
        XCTAssertEqual(try store.load().drafts.count,1);XCTAssertTrue(try store.load().cases.isEmpty)
    }
    @MainActor
    func testCorruptWorkroomCannotBeOverwrittenAndCanBeExplicitlyReset() throws {
        let store=WorkroomStore(directory:directory);let bytes=Data("broken".utf8);try bytes.write(to:store.url)
        let service=WorkroomService(store:store);XCTAssertNotNil(service.error)
        try service.use(.demonstrationDraft());XCTAssertThrowsError(try service.saveDraft())
        XCTAssertEqual(try Data(contentsOf:store.url),bytes)
        try service.reset();try service.saveDraft();XCTAssertEqual(try store.load().drafts.count,1)
    }
    func testCaseProgressDoesNotCountMissingTasksAsCompleted() throws {
        var item=WorkroomCase();item.steps=[.init(title:"报名",done:true)];item.materials=[.init(title:"学生证")]
        var routine=RoutineItem();routine.title="出发";routine.completedAt=Date()
        item.links=[.init(id:routine.id,kind:.routine,snapshot:routine.title),.init(id:UUID(),kind:.routine,snapshot:"已被删除的任务")]
        try item.validate();let progress=item.progress(routines:[routine]);XCTAssertEqual(progress.done,2);XCTAssertEqual(progress.total,4)
        XCTAssertNil(routine.sourceCardID)
        item.demonstration=true
        XCTAssertThrowsError(try item.validate())
        for index in item.links.indices { item.links[index].demonstration=true }
        XCTAssertNoThrow(try item.validate())
    }
    func testGlobalSearchUsesProvidedLocalRecordsAndDoesNotSearchEmptyQueries() throws {
        let draft=WorkroomDraft.demonstrationDraft()
        var item=WorkroomCase();item.title="参会";item.materials=[.init(title:"学生证")]
        let hits=WorkroomSearch.hits(query:"学生证",events:[],conversations:[],cards:[],routines:[],drafts:[draft],cases:[item])
        XCTAssertEqual(hits.count,2);XCTAssertEqual(Set(hits.map(\.kind)),[.draft,.project])
        XCTAssertTrue(WorkroomSearch.hits(query:" ",events:[],conversations:[],cards:[],routines:[],drafts:[draft],cases:[item]).isEmpty)
    }
    func testTranslationResultMustMatchSourceAndTargetAndPreserveRequestOrigin() throws {
        let request=TranslationRequest(text:"【演示】请写下时间。",target:.english,origin:.demonstration)
        var result=TranslationResult(version:1,provider:"DeepSeek",model:"test",sourceID:request.sourceID,target:.english,text:"[Demo] Please write down the time.")
        XCTAssertNoThrow(try result.validate(request:request))
        result.target = .japanese;XCTAssertThrowsError(try result.validate(request:request))
        result.target = .english;result.sourceID=UUID();XCTAssertThrowsError(try result.validate(request:request))
        XCTAssertThrowsError(try TranslationRequest(text:String(repeating:"字",count:1501),target:.english,origin:.typed).validate())
    }
    func testCapturedRealClarificationsAndFourTranslationsDecodeInTheApp() throws {
        struct Fixture:Decodable {
            struct QuestionCase:Decodable { var request:InsightRequest;var result:InsightResult;var status:Int }
            struct TranslationCase:Decodable { var request:TranslationRequest;var result:TranslationResult;var status:Int }
            var clarification:QuestionCase
            var translations:[TranslationCase]
        }
        let url=try XCTUnwrap(Bundle.module.url(forResource:"WorkroomLive",withExtension:"json",subdirectory:"Fixtures"))
        let fixture=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
        XCTAssertEqual(fixture.clarification.status,200)
        try fixture.clarification.result.validate(request:fixture.clarification.request)
        XCTAssertFalse(fixture.clarification.result.questions?.isEmpty ?? true)
        XCTAssertEqual(fixture.translations.count,4)
        for item in fixture.translations {
            XCTAssertEqual(item.status,200);try item.result.validate(request:item.request)
            XCTAssertTrue(item.result.text.contains("15:00"));XCTAssertTrue(item.result.text.contains("12"))
        }
    }
    func testTextAndPDFImportExtractTextWithoutNetworking() throws {
        let text=directory.appendingPathComponent("notice.txt");try "地点：图书馆\n费用12元人民币".write(to:text,atomically:true,encoding:.utf8)
        XCTAssertTrue(try WorkroomImport.file(text).contains("图书馆"))
        let pdf=directory.appendingPathComponent("notice.pdf");try makePDF(pdf,scanned:false)
        XCTAssertTrue(try WorkroomImport.file(pdf).contains("MEETING"))
        let big=directory.appendingPathComponent("big.txt");try String(repeating:"字",count:12001).write(to:big,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try WorkroomImport.file(big))
    }
    func testImageOCRAndScannedPDFRecognizeGeneratedDemoText() throws {
        let image=try demoImage(),data=NSMutableData()
        let destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let recognized = try WorkroomImport.image(data as Data)
        XCTAssertTrue(recognized.uppercased().contains("MEETING")); XCTAssertTrue(recognized.contains("图书馆"))
        let url=directory.appendingPathComponent("scanned.pdf");try makePDF(url,scanned:true)
        let scannedText = try WorkroomImport.file(url)
        XCTAssertTrue(scannedText.uppercased().contains("MEETING")); XCTAssertTrue(scannedText.contains("图书馆"))
        XCTAssertThrowsError(try WorkroomImport.image(Data([1,2,3])))
    }
    func testPDFSelectionReadsOnlyRequestedPagesAndRejectsInvalidSelections() throws {
        let url = directory.appendingPathComponent("long.pdf");var bounds = CGRect(x:0,y:0,width:1000,height:600)
        let context = try XCTUnwrap(CGContext(url as CFURL,mediaBox:&bounds,nil))
        for i in 0..<14 {
            context.beginPDFPage(nil)
            let line = NSAttributedString(string:"Demo Page \(i+1)",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,30,nil)])
            context.textPosition = CGPoint(x:50,y:300);CTLineDraw(CTLineCreateWithAttributedString(line),context);context.endPDFPage()
        };context.closePDF()
        XCTAssertThrowsError(try WorkroomImport.file(url))
        let text = try WorkroomImport.file(url,selectedPages:[13,1])
        XCTAssertTrue(text.contains("Demo Page 14"));XCTAssertTrue(text.contains("Demo Page 2"));XCTAssertFalse(text.contains("Demo Page 3"))
        XCTAssertThrowsError(try WorkroomImport.file(url,selectedPages:[]));XCTAssertThrowsError(try WorkroomImport.file(url,selectedPages:[14]));XCTAssertThrowsError(try WorkroomImport.file(url,selectedPages:[1,1]))
    }
    private func drawDemo(_ context:CGContext) {
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:1000,height:600))
        let font=CTFontCreateWithName("Helvetica" as CFString,42,nil)
        let string=NSAttributedString(string:"MEETING 2026-10-30 15:00",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
        context.textPosition=CGPoint(x:50,y:350);CTLineDraw(CTLineCreateWithAttributedString(string),context)
        let chineseFont=CTFontCreateWithName("PingFangSC-Regular" as CFString,40,nil)
        let chinese=NSAttributedString(string:"读书会通知 地点：图书馆二楼",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):chineseFont,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
        context.textPosition=CGPoint(x:50,y:250);CTLineDraw(CTLineCreateWithAttributedString(chinese),context)
    }
    private func demoImage() throws -> CGImage {
        let context=try XCTUnwrap(CGContext(data:nil,width:1000,height:600,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        drawDemo(context);return try XCTUnwrap(context.makeImage())
    }
    private func makePDF(_ url:URL,scanned:Bool) throws {
        var bounds=CGRect(x:0,y:0,width:1000,height:600)
        let context=try XCTUnwrap(CGContext(url as CFURL,mediaBox:&bounds,nil));context.beginPDFPage(nil)
        if scanned { context.draw(try demoImage(),in:bounds) } else { drawDemo(context) }
        context.endPDFPage();context.closePDF()
    }
}

final class AgendaIntegrationTests: XCTestCase {
    func testScheduledNoticesAreNeverSuppressedAsMissingEventIDs() {
        let eventID = UUID()
        XCTAssertFalse(ReminderForegroundPolicy.suppress(eventID:nil,activeEventID:nil))
        XCTAssertFalse(ReminderForegroundPolicy.suppress(eventID:nil,activeEventID:eventID))
        XCTAssertFalse(ReminderForegroundPolicy.suppress(eventID:eventID.uuidString,activeEventID:nil))
        XCTAssertTrue(ReminderForegroundPolicy.suppress(eventID:eventID.uuidString,activeEventID:eventID))
        XCTAssertFalse(ReminderForegroundPolicy.suppress(eventID:UUID().uuidString,activeEventID:eventID))
    }

    @MainActor private func settled(_ service: AppointmentReminderService) async throws {
        for _ in 0..<1000 {
            if !service.reconciling { return }
            try await Task.sleep(nanoseconds:1_000_000)
        }
        XCTFail("Reminder reconciliation did not settle")
    }
    func testLegacyRecordsDecodeWithoutAgendaFieldsAndInvalidDatesFail() throws {
        var item = WorkroomCase(); item.steps = [.init(title:"报名")]
        let raw = try JSONEncoder().encode(item)
        let restored = try JSONDecoder().decode(WorkroomCase.self,from:raw)
        XCTAssertNil(restored.reminderAt); XCTAssertNil(restored.completedAt); XCTAssertTrue(restored.isActive)
        item.reminderAt = .init(timeIntervalSince1970:.infinity)
        XCTAssertThrowsError(try item.validate())
        var routine = RoutineItem(); routine.title = "准备资料"; routine.reminderAt = .init(timeIntervalSince1970:.nan)
        XCTAssertThrowsError(try routine.validate())
        XCTAssertNil(ScheduledDestination.parse(kind:"unknown",id:UUID().uuidString))
        XCTAssertNil(ScheduledDestination.parse(kind:"project",id:"not-a-uuid"))
    }
    @MainActor func testCaseCompletionRequiresEveryStepAndLiveLinkedTaskAndArchivePreservesProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = WorkroomStore(directory:directory), service = WorkroomService(store:store)
        var task = RoutineItem();task.title = "报名"
        var item = WorkroomCase();item.materials = [.init(title:"学生证")]
        item.links = [.init(id:task.id,kind:.routine,snapshot:task.title)]
        item.dueAt = .now.addingTimeInterval(3600);item.reminderAt = .now.addingTimeInterval(1800)
        try service.putCase(item,saveLocally:true)
        XCTAssertThrowsError(try service.completeCase(item.id,completed:true,routines:[task]))
        item.materials[0].done = true;try service.putCase(item,saveLocally:true)
        XCTAssertThrowsError(try service.completeCase(item.id,completed:true,routines:[]))
        task.completedAt = .now
        try service.completeCase(item.id,completed:true,routines:[task])
        XCTAssertTrue(try XCTUnwrap(service.cases.first).isCompleted)
        try service.archiveCase(item.id,archived:true)
        let archived = try XCTUnwrap(store.load().cases.first)
        XCTAssertTrue(archived.isArchived);XCTAssertTrue(archived.materials[0].done);XCTAssertEqual(archived.reminderAt,item.reminderAt)
        try service.archiveCase(item.id,archived:false)
        try service.completeCase(item.id,completed:false,routines:[task])
        XCTAssertTrue(try XCTUnwrap(service.cases.first).isActive)
    }
    func testCaseFiltersSearchMaterialsAndRespectDemonstrationAndArchive() throws {
        let now = Date()
        var overdue = WorkroomCase();overdue.title = "读书会";overdue.dueAt = now.addingTimeInterval(-10);overdue.materials = [.init(title:"学生证")]
        var pinned = WorkroomCase();pinned.title = "排练";pinned.pinned = true
        var archive = overdue;archive.id = UUID();archive.archivedAt = now
        var demo = overdue;demo.id = UUID();demo.demonstration = true
        let all = [overdue,pinned,archive,demo]
        XCTAssertEqual(WorkroomCase.select(all,query:"",filter:.active,includeDemonstrations:false,now:now).map(\.id),[pinned.id,overdue.id])
        XCTAssertEqual(WorkroomCase.select(all,query:"学生证",filter:.overdue,includeDemonstrations:false,now:now).map(\.id),[overdue.id])
        XCTAssertEqual(WorkroomCase.select(all,query:"",filter:.archived,includeDemonstrations:false,now:now).map(\.id),[archive.id])
        XCTAssertEqual(overdue.nextAction(routines:[]),"准备：学生证")
    }
    func testPlannerRequiresExplicitFutureTimeSavedRealAndOpenRecords() {
        let now = Date()
        var plain = RoutineItem();plain.title = "只有截止时间";plain.dueAt = now.addingTimeInterval(1000)
        var eligible = plain;eligible.id = UUID();eligible.reminderAt = now.addingTimeInterval(100)
        var unsaved = eligible;unsaved.id = UUID()
        var demo = eligible;demo.id = UUID();demo.origin = .demonstration
        var done = eligible;done.id = UUID();done.completedAt = now
        var past = eligible;past.id = UUID();past.reminderAt = now.addingTimeInterval(-100)
        let tasks = [plain,eligible,unsaved,demo,done,past]
        var project = WorkroomCase();project.reminderAt = now.addingTimeInterval(200)
        var archived = project;archived.id = UUID();archived.archivedAt = now
        let notices = AgendaPlanner.notices(routines:tasks,savedRoutineIDs:Set(tasks.filter { $0.id != unsaved.id }.map(\.id)),cases:[project,archived],savedCaseIDs:[project.id,archived.id],now:now)
        XCTAssertEqual(notices.map(\.destination.recordID),[eligible.id,project.id])
        XCTAssertEqual(AgendaPlanner.limit,24)
    }
    @MainActor func testCoordinatorDeduplicatesAndRemovesCompletedDeletedAndArchivedNoticesOnly() async throws {
        let client = FakeAgendaClient(), service = AppointmentReminderService(client:client)
        client.requests["seesound-reminder-unrelated"] = .init(id:"seesound-reminder-unrelated",plannedAt:nil)
        var item = RoutineItem();item.title = "private";item.reminderAt = .now.addingTimeInterval(300)
        var project = WorkroomCase();project.reminderAt = .now.addingTimeInterval(600)
        service.update(routines:[item],savedRoutineIDs:[item.id],cases:[project],savedCaseIDs:[project.id]);try await settled(service)
        XCTAssertTrue(service.isScheduled(.routine,id:item.id));XCTAssertTrue(service.isScheduled(.project,id:project.id));XCTAssertEqual(client.addCount,2)
        service.refresh();try await settled(service);XCTAssertEqual(client.addCount,2)
        item.completedAt = .now;project.archivedAt = .now
        service.update(routines:[item],savedRoutineIDs:[item.id],cases:[project],savedCaseIDs:[project.id]);try await settled(service)
        XCTAssertTrue(service.scheduledIDs.isEmpty);XCTAssertEqual(Set(client.requests.keys),["seesound-reminder-unrelated"])
        project.archivedAt = nil
        service.update(routines:[],savedRoutineIDs:[],cases:[project],savedCaseIDs:[project.id]);try await settled(service)
        XCTAssertTrue(service.isScheduled(.project,id:project.id))
        service.update(routines:[],savedRoutineIDs:[],cases:[],savedCaseIDs:[]);try await settled(service)
        XCTAssertTrue(service.scheduledIDs.isEmpty)
    }
    @MainActor func testRescheduleReplacesTimeAndOldDeliveredNoticeAndPermissionDoesNotPromptAutomatically() async throws {
        let client = FakeAgendaClient(), service = AppointmentReminderService(client:client)
        var item = RoutineItem();item.title = "准备";item.reminderAt = .now.addingTimeInterval(300)
        service.update(routines:[item],savedRoutineIDs:[item.id],cases:[],savedCaseIDs:[]);try await settled(service)
        let id = try XCTUnwrap(service.scheduledIDs.first)
        client.shown[id] = client.requests[id]
        item.reminderAt = .now.addingTimeInterval(900)
        service.update(routines:[item],savedRoutineIDs:[item.id],cases:[],savedCaseIDs:[]);try await settled(service)
        XCTAssertEqual(client.requests[id]?.plannedAt,item.reminderAt?.timeIntervalSince1970);XCTAssertNil(client.shown[id]);XCTAssertEqual(client.promptCount,0)
        client.permission = .denied;service.refresh();try await settled(service)
        XCTAssertTrue(service.scheduledIDs.isEmpty);XCTAssertEqual(client.promptCount,0)
        await service.requestPermission();try await settled(service)
        XCTAssertEqual(client.promptCount,1);XCTAssertTrue(service.isScheduled(.routine,id:item.id))
    }
    @MainActor func testCoordinatorCleansStaleAdditionWhenItemIsDeletedDuringAwait() async throws {
        let client = FakeAgendaClient(), service = AppointmentReminderService(client:client)
        var item = RoutineItem();item.title = "准备";item.reminderAt = .now.addingTimeInterval(300)
        client.afterAdd = { service.update(routines:[],savedRoutineIDs:[],cases:[],savedCaseIDs:[]) }
        service.update(routines:[item],savedRoutineIDs:[item.id],cases:[],savedCaseIDs:[]);try await settled(service)
        XCTAssertEqual(client.addCount,1);XCTAssertTrue(client.requests.isEmpty);XCTAssertTrue(service.scheduledIDs.isEmpty)
    }
    @MainActor func testCoordinatorCapsAt24RefillsAndReportsFailureForRetry() async throws {
        let client = FakeAgendaClient(), service = AppointmentReminderService(client:client)
        let items = (0..<27).map { index -> RoutineItem in
            var item = RoutineItem();item.title = "安排\(index)";item.reminderAt = .now.addingTimeInterval(Double(300+index*10));return item
        }
        service.update(routines:items,savedRoutineIDs:Set(items.map(\.id)),cases:[],savedCaseIDs:[]);try await settled(service)
        XCTAssertEqual(service.scheduledIDs.count,24);XCTAssertEqual(service.deferredCount,3)
        XCTAssertFalse(service.isScheduled(.routine,id:items[26].id))
        service.update(routines:Array(items.dropFirst(3)),savedRoutineIDs:Set(items.map(\.id)),cases:[],savedCaseIDs:[]);try await settled(service)
        XCTAssertTrue(service.isScheduled(.routine,id:items[26].id));XCTAssertEqual(service.deferredCount,0)
        service.update(routines:[],savedRoutineIDs:[],cases:[],savedCaseIDs:[]);try await settled(service)
        client.fail = true
        service.update(routines:[items[0]],savedRoutineIDs:[items[0].id],cases:[],savedCaseIDs:[]);try await settled(service)
        XCTAssertTrue(service.status.contains("未能安排"));XCTAssertTrue(service.scheduledIDs.isEmpty)
        client.fail = false;service.refresh();try await settled(service)
        XCTAssertEqual(service.scheduledIDs.count,1)
    }
}

@MainActor private final class FakeAgendaClient: AgendaNotificationClient {
    var permission: AgendaAuthorization = .allowed
    var requests: [String:AgendaRequestState] = [:]
    var shown: [String:AgendaRequestState] = [:]
    var addCount = 0
    var promptCount = 0
    var fail = false
    var afterAdd: (() -> Void)?
    func authorization() async -> AgendaAuthorization { permission }
    func requestPermission() async throws { promptCount += 1;permission = .allowed }
    func pending() async -> [AgendaRequestState] { Array(requests.values) }
    func delivered() async -> [AgendaRequestState] { Array(shown.values) }
    func removePending(_ ids:[String]) { ids.forEach { requests[$0] = nil } }
    func removeDelivered(_ ids:[String]) { ids.forEach { shown[$0] = nil } }
    func add(_ notice:ScheduledNotice) async throws {
        if fail { throw DailyError.invalid }
        addCount += 1;requests[notice.id] = .init(id:notice.id,plannedAt:notice.date.timeIntervalSince1970)
        let callback = afterAdd;afterAdd = nil;callback?()
        await Task.yield()
    }
}


extension AgendaIntegrationTests {
    @MainActor func testRestoreSuspendsSchedulingAndResumesOnlyWithFinalRecords() async throws {
        let client = FakeAgendaClient(),service = AppointmentReminderService(client:client)
        var item = RoutineItem();item.title = "恢复前";item.reminderAt = Date().addingTimeInterval(600)
        service.update(routines:[item],savedRoutineIDs:[item.id],cases:[],savedCaseIDs:[]);try await settled(service)
        XCTAssertEqual(service.scheduledIDs.count,1)
        service.suspend();try await settled(service);XCTAssertTrue(service.scheduledIDs.isEmpty)
        item.reminderAt = nil;service.update(routines:[item],savedRoutineIDs:[item.id],cases:[],savedCaseIDs:[])
        service.resume();try await settled(service);XCTAssertTrue(service.scheduledIDs.isEmpty)
    }
}
