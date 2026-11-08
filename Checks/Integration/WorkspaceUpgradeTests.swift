import Foundation
import XCTest
@testable import SeeSoundData

final class WorkspaceUpgradeTests:XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeeSound18-\(UUID())");try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    private func source(text:String = "时间：2026-11-02 15:00\n地点：图书馆三楼\n费用：20元") -> CaseDocument {
        var draft = WorkroomDraft();draft.title = "补充通知";draft.text = text;return CaseDocument(draft:draft)
    }
    private func visual() -> WorkroomVisualEvidence {
        .init(image:Data("LOCAL TEST IMAGE BYTES".utf8),regions:[.init(text:"演示文字",x:0.1,y:0.6,width:0.5,height:0.1)],originalText:"演示文字")
    }
    func testLegacyDataStillDecodesWithoutAttachmentsAndFollowUps() throws {
        let encoded = try JSONEncoder().encode(WorkroomCase())
        let item = try JSONDecoder().decode(WorkroomCase.self,from:encoded);try item.validate()
        XCTAssertTrue(item.documents.isEmpty);XCTAssertTrue(item.confirmedFacts.isEmpty);XCTAssertNil(item.workflow.followUps)
    }
    @MainActor func testAttachedSourcesAreIndependentSnapshotsAndRejectDuplicateVersion() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));let item = WorkroomCase();try service.putCase(item,saveLocally:true)
        var draft = WorkroomDraft();draft.text = "原通知";let first = CaseDocument(draft:draft)
        try service.attach(first,to:item.id);XCTAssertThrowsError(try service.attach(first,to:item.id))
        draft = try draft.edited(title:draft.title,text:"新通知");try service.attach(CaseDocument(draft:draft),to:item.id)
        let reloaded = WorkroomService(store:.init(directory:directory));XCTAssertEqual(reloaded.cases[0].documents.map(\.text),["原通知","新通知"])
        var mixed = draft;mixed.origin = .demonstration;XCTAssertThrowsError(try service.attach(CaseDocument(draft:mixed),to:item.id))
    }
    @MainActor func testAttachmentLimitAndUnsavedConsentArePreserved() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));let item = WorkroomCase();try service.putCase(item,saveLocally:false)
        for _ in 0..<8 { try service.attach(source(text:"一份通知"),to:item.id) }
        XCTAssertThrowsError(try service.attach(source(),to:item.id));XCTAssertEqual(service.cases[0].documents.count,8)
        XCTAssertTrue(try WorkroomStore(directory:directory).load().cases.isEmpty)
    }
    @MainActor func testUpdateDoesNotChangeDeadlineReminderOrProgressUnlessSeparatelyConfirmed() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var item = WorkroomCase()
        item.steps = [.init(title:"已报名",done:true),.init(title:"参加活动")];item.dueAt = Date().addingTimeInterval(4000);item.reminderAt = Date().addingTimeInterval(3000)
        let old = source(text:"地点：图书馆二楼");item.sources = [old];try service.putCase(item,saveLocally:true)
        let incoming = source(),changes = CaseUpdateComparison.localCandidates(source:incoming)
        try service.applyUpdate(caseID:item.id,fingerprint:item.reviewFingerprint(),document:incoming,candidates:changes,generator:"本机对照",changeDue:false,dueAt:.now,changeReminder:false,reminderAt:.now,saveLocally:true,confirmed:true)
        let updated = service.cases[0];XCTAssertEqual(updated.dueAt,item.dueAt);XCTAssertEqual(updated.reminderAt,item.reminderAt);XCTAssertEqual(updated.steps,item.steps)
        XCTAssertEqual(updated.confirmedFacts.count,3);XCTAssertEqual(updated.updates?.count,1);XCTAssertTrue(updated.updates![0].changes.contains { $0.contains("图书馆二楼 → 图书馆三楼") })
        XCTAssertThrowsError(try service.removeDocument(incoming.id,from:item.id))
    }
    @MainActor func testUpdateRejectsStaleReviewAndUngroundedQuoteWithoutWriting() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var item = WorkroomCase();try service.putCase(item,saveLocally:true)
        let fingerprint = try item.reviewFingerprint();item.note = "其他编辑";try service.putCase(item,saveLocally:true)
        let document = source(),changes = CaseUpdateComparison.localCandidates(source:document)
        XCTAssertThrowsError(try service.applyUpdate(caseID:item.id,fingerprint:fingerprint,document:document,candidates:changes,generator:"本机",changeDue:false,dueAt:nil,changeReminder:false,reminderAt:nil,saveLocally:true,confirmed:true))
        let fake = CaseChangeCandidate(kind:.place,value:"其他地点",quote:"原文没有这段",date:nil)
        XCTAssertThrowsError(try service.applyUpdate(caseID:item.id,fingerprint:item.reviewFingerprint(),document:document,candidates:[fake],generator:"本机",changeDue:false,dueAt:nil,changeReminder:false,reminderAt:nil,saveLocally:true,confirmed:true))
        XCTAssertEqual(try WorkroomStore(directory:directory).load().cases[0],item)
    }
    @MainActor func testEachFieldHasAtMostOneChoiceAndReminderRequiresExplicitSavedConsent() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));let item = WorkroomCase();try service.putCase(item,saveLocally:false)
        let document = source(text:"地点：东楼\n地点：西楼"),changes = CaseUpdateComparison.localCandidates(source:document)
        XCTAssertThrowsError(try service.applyUpdate(caseID:item.id,fingerprint:item.reviewFingerprint(),document:document,candidates:changes,generator:"本机",changeDue:false,dueAt:nil,changeReminder:false,reminderAt:nil,saveLocally:false,confirmed:true))
        XCTAssertThrowsError(try service.applyUpdate(caseID:item.id,fingerprint:item.reviewFingerprint(),document:document,candidates:[],generator:"本机",changeDue:false,dueAt:nil,changeReminder:true,reminderAt:Date().addingTimeInterval(60),saveLocally:false,confirmed:true))
        try service.applyUpdate(caseID:item.id,fingerprint:item.reviewFingerprint(),document:document,candidates:[changes[0]],generator:"本机",changeDue:true,dueAt:Date().addingTimeInterval(400),changeReminder:true,reminderAt:Date().addingTimeInterval(60),saveLocally:true,confirmed:true)
        XCTAssertNotNil(service.cases[0].dueAt);XCTAssertNotNil(service.cases[0].reminderAt);XCTAssertTrue(service.savedCaseIDs.contains(item.id))
    }
    func testUpdateRequestIsBoundedAndAssistantCannotUseOldSourceAsNewEvidence() throws {
        let previous = source(text:"地点：旧楼"),incoming = source(text:"地点：新楼")
        let request = CaseUpdateComparison.request(previous:previous,incoming:incoming);try request.validate()
        let oldTurn = request.turns[0],newTurn = request.turns[1]
        let result = InsightResult(version:1,provider:"DeepSeek",model:"fixture",summary:"待核对",candidates:[.init(kind:.place,value:"旧楼",sourceID:oldTurn.id,quote:"地点：旧楼",dateISO:nil),.init(kind:.place,value:"新楼",sourceID:newTurn.id,quote:"地点：新楼",dateISO:nil)],replies:[])
        XCTAssertEqual(try CaseUpdateComparison.assistedCandidates(result,request:request,incoming:incoming).map(\.value),["新楼"])
        var large = incoming;large.text = String(repeating:"材料",count:6000)
        let bounded = CaseUpdateComparison.request(previous:large,incoming:incoming);try bounded.validate();XCTAssertLessThanOrEqual(bounded.turns.map(\.text).joined().count,3000)
    }
    @MainActor func testWaitingFollowUpPersistsResponseAndResumesWithoutCompletingSteps() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var item = WorkroomCase();item.steps = [.init(title:"办理")]
        var flow = CaseFlow();flow.disposition = .waiting;flow.waitingSince = Date().addingTimeInterval(-86400);item.flow = flow;try service.putCase(item,saveLocally:true)
        try service.recordFollowUp(item.id,note:"已收到回复",resume:true,nextDate:nil)
        let saved = try WorkroomStore(directory:directory).load().cases[0]
        XCTAssertEqual(saved.workflow.disposition,.ready);XCTAssertNil(saved.workflow.waitingSince);XCTAssertEqual(saved.workflow.followUps?.first?.note,"已收到回复");XCTAssertFalse(saved.steps[0].done)
        XCTAssertThrowsError(try service.recordFollowUp(item.id,note:"",resume:false,nextDate:nil))
    }
    func testCaptionAppendDoesNotCountAsRevisionAndRewriteHasPreciseChangedSpan() {
        var session = ConversationSession();let id = session.beginCapture()
        session.receive("下午",capture:id,isFinal:false);session.receive("下午三点",capture:id,isFinal:false)
        XCTAssertEqual(session.turns[0].recognitionRevision,0);XCTAssertNil(session.turns[0].previousRecognitionText)
        session.receive("下午四点",capture:id,isFinal:false)
        XCTAssertEqual(session.turns[0].recognitionChange?.oldChanged,"三");XCTAssertEqual(session.turns[0].recognitionChange?.newChanged,"四")
        session.receive("下午四点见",capture:id,isFinal:true);XCTAssertEqual(session.turns[0].recognitionRevision,1)
        session.edit(id,text:"人工确认四点见");XCTAssertNil(session.turns[0].recognitionChange);XCTAssertEqual(session.turns[0].recognitionRevision,1)
    }
    func testCaptionDeletionAndEmojiAreComparedByCharacters() {
        let deleted = CaptionTextChange.compare(old:"明天三点",new:"明天")
        XCTAssertEqual(deleted.kind,.rewritten);XCTAssertEqual(deleted.oldChanged,"三点");XCTAssertEqual(deleted.newChanged,"")
        let emoji = CaptionTextChange.compare(old:"👨‍👩‍👧三点",new:"👨‍👩‍👧四点");XCTAssertEqual(emoji.prefix,"👨‍👩‍👧");XCTAssertEqual(emoji.newChanged,"四")
    }
    @MainActor func testOriginalIsOnlyWrittenWhenOptedInAndCanBeRemovedWithoutLosingText() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var draft = WorkroomDraft();draft.text = "演示文字";let evidence = visual()
        try service.use(draft);try service.stageVisual(evidence,retain:false);try service.saveDraft()
        XCTAssertNil(try WorkroomVisualStore(directory:directory).load(evidence.id))
        try service.stageVisual(evidence,retain:true);try service.saveDraft();XCTAssertNotNil(try WorkroomVisualStore(directory:directory).load(evidence.id))
        var item = WorkroomCase();item.sources = [CaseDocument(draft:service.active)];try service.putCase(item,saveLocally:true)
        try service.forgetOriginal(evidence.id);XCTAssertNil(try WorkroomVisualStore(directory:directory).load(evidence.id));XCTAssertEqual(service.drafts[0].text,draft.text);XCTAssertNil(service.cases[0].documents[0].visualID)
    }
    func testEncryptedBackupExcludesLocalOriginalPointersButKeepsSourceText() throws {
        var snapshot = LibrarySnapshot();var draft = WorkroomDraft();draft.text = "资料文字";draft.visualID = UUID();snapshot.workroom.drafts = [draft]
        var item = WorkroomCase();item.sources = [CaseDocument(draft:draft)];snapshot.workroom.cases = [item]
        let data = try LibraryCryptography.seal(.init(snapshot:snapshot),password:"fixture-pass-18")
        let decoded = try LibraryCryptography.open(data,password:"fixture-pass-18")
        XCTAssertNil(decoded.snapshot.workroom.drafts[0].visualID);XCTAssertNil(decoded.snapshot.workroom.cases[0].documents[0].visualID);XCTAssertEqual(decoded.snapshot.workroom.cases[0].documents[0].text,"资料文字")
    }
    func testInvalidVisualCoordinatesAndCorruptCacheAreRejected() throws {
        var evidence = visual();evidence.regions[0].x = .infinity;XCTAssertThrowsError(try evidence.validate())
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let store = WorkroomVisualStore(directory:directory);let valid = visual();try store.save(valid)
        let path = directory.appendingPathComponent("Visuals/\(valid.id).json");try Data("broken".utf8).write(to:path)
        XCTAssertThrowsError(try store.load(valid.id))
    }
    func testWorkstationMetricsExcludeDemonstrationsAndCompletedCases() {
        let now = Date();var item = WorkroomCase();item.dueAt = now;var flow = CaseFlow();flow.disposition = .waiting;item.flow = flow
        var demo = item;demo.id = UUID();demo.demonstration = true
        var done = item;done.id = UUID();done.completedAt = now
        var draft = WorkroomDraft();draft.text = "收件箱";draft.inInbox = true
        let result = WorkspaceOverview.make(drafts:[draft,.demonstrationDraft()],cases:[item,demo,done],now:now)
        XCTAssertEqual(result.inbox,1);XCTAssertEqual(result.dueToday.map(\.id),[item.id]);XCTAssertEqual(result.waiting.count,1)
    }
    func testSearchIncludesAttachedSourceAndLocatesIndividualLines() {
        var item = WorkroomCase();item.sources = [source(text:"第一行\n目标地点\n第三行")]
        let hits = WorkroomSearch.hits(query:"目标地点",events:[],conversations:[],cards:[],routines:[],drafts:[],cases:[item])
        XCTAssertEqual(hits.count,1)
        let sections = SearchDocumentBuilder.sections(hit:hits[0],drafts:[],cases:[item],conversations:[])
        XCTAssertEqual(sections.filter { $0.text.contains("目标地点") }.count,1);XCTAssertTrue(sections.contains { $0.title.contains("第 2 行") })
    }
    func testWatchConnectionStatesDoNotConfuseReachabilityWithReceipt() {
        XCTAssertEqual(WatchLinkState.evaluate(supported:false,active:false,paired:false,installed:false,reachable:false),.unsupported)
        XCTAssertEqual(WatchLinkState.evaluate(supported:true,active:true,paired:false,installed:false,reachable:false),.unpaired)
        XCTAssertEqual(WatchLinkState.evaluate(supported:true,active:true,paired:true,installed:false,reachable:false),.needsInstallation)
        XCTAssertEqual(WatchLinkState.evaluate(supported:true,active:true,paired:true,installed:true,reachable:false),.unreachable)
        XCTAssertEqual(WatchLinkState.evaluate(supported:true,active:true,paired:true,installed:true,reachable:true),.ready)
        XCTAssertNotEqual(WatchAgendaDeliveryState.awaitingReceipt,.applied)
    }
    @MainActor func testUnconfirmedUpdateCannotWriteAndSameValueMayBeFirstConfirmed() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var item = WorkroomCase();let old = source(text:"地点：图书馆");item.sources = [old];try service.putCase(item,saveLocally:true)
        let incoming = source(text:"地点：图书馆"),choices = CaseUpdateComparison.localCandidates(source:incoming)
        XCTAssertThrowsError(try service.applyUpdate(caseID:item.id,fingerprint:item.reviewFingerprint(),document:incoming,candidates:choices,generator:"本机",changeDue:false,dueAt:nil,changeReminder:false,reminderAt:nil,saveLocally:true))
        XCTAssertTrue(service.cases[0].confirmedFacts.isEmpty)
        try service.applyUpdate(caseID:item.id,fingerprint:item.reviewFingerprint(),document:incoming,candidates:choices,generator:"本机",changeDue:false,dueAt:nil,changeReminder:false,reminderAt:nil,saveLocally:true,confirmed:true)
        XCTAssertEqual(service.cases[0].confirmedFacts[0].value,"图书馆")
    }
    @MainActor func testUnreadableOptionalOriginalDoesNotBlockTextEditing() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var draft = WorkroomDraft();draft.text = "可继续编辑";draft.visualID = UUID()
        let path = directory.appendingPathComponent("Visuals/\(draft.visualID!).json");try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("broken".utf8).write(to:path)
        try service.use(draft);XCTAssertEqual(service.active.text,draft.text);XCTAssertNil(service.activeVisual);XCTAssertNotNil(service.visualWarning)
        try service.edit(title:draft.title,text:"编辑成功");XCTAssertEqual(service.active.text,"编辑成功")
    }
    @MainActor func testRestoreRollbackKeepsExistingOriginalFilesAvailable() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory.appendingPathComponent("SeeSoundWorkroom")))
        var draft = WorkroomDraft();draft.text = "演示文字";let evidence = visual();try service.use(draft);try service.stageVisual(evidence,retain:true);try service.saveDraft()
        let repo = LibraryRepository(base:directory),before = try repo.read()
        var options = LibraryRestoreOptions();options.preferIncoming = true
        let preview = try LibraryMerge.preview(local:before,package:.init(snapshot:before),options:options)
        struct Injected:Error {};repo.afterWrite = { index in if index == 1 { throw Injected() } }
        XCTAssertThrowsError(try repo.commit(preview))
        XCTAssertEqual(try repo.read().workroom.drafts[0].visualID,evidence.id)
        XCTAssertNotNil(try WorkroomVisualStore(directory:directory.appendingPathComponent("SeeSoundWorkroom")).load(evidence.id))
    }

    @MainActor func testOriginalRetainedByCaseSurvivesDraftDeletionUntilLastReferenceRemoved() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var draft = WorkroomDraft();draft.text = "演示文字";let evidence = visual()
        try service.use(draft);try service.stageVisual(evidence,retain:true);try service.saveDraft()
        var item = WorkroomCase();item.sources = [CaseDocument(draft:service.active)];try service.putCase(item,saveLocally:true)
        try service.removeDraft(draft.id);XCTAssertNotNil(try WorkroomVisualStore(directory:directory).load(evidence.id))
        try service.removeCase(item.id);XCTAssertNotNil(try WorkroomVisualStore(directory:directory).load(evidence.id))
        try service.permanentlyRemoveDeleted(Set(service.trash.map(\.id)));XCTAssertNil(try WorkroomVisualStore(directory:directory).load(evidence.id))
    }
    func testReceiptWithoutMatchingResultCannotClaimPhoneAppliedOperation() {
        let id = UUID(),fingerprint = String(repeating:"a",count:64)
        let request = WatchAgendaPacket(kind:.action,recordID:id,fingerprint:fingerprint,action:.complete)
        var reply = WatchAgendaPacket(id:request.id,kind:.receipt,recordID:id,fingerprint:fingerprint,action:.complete,accepted:true)
        XCTAssertEqual(WatchReceiptPolicy.state(request:request,response:reply),.unknown)
        var result = WatchAgendaItem(id:id,kind:.routine,title:"演示",next:"",fingerprint:fingerprint,demonstration:true,completed:false)
        reply.items = [result];XCTAssertEqual(WatchReceiptPolicy.state(request:request,response:reply),.unknown)
        result.completed = true;reply.items = [result];XCTAssertEqual(WatchReceiptPolicy.state(request:request,response:reply),.applied)
        reply.id = UUID();XCTAssertEqual(WatchReceiptPolicy.state(request:request,response:reply),.unknown)
    }

    @MainActor func testNewMaterialRequirementsRequireExplicitChoiceAndPreservePreparedRows() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var item = WorkroomCase();item.materials = [.init(title:"学生证",done:true)];try service.putCase(item,saveLocally:true)
        let incoming = source(text:"请带学生证和报名凭证。\n无需携带相机。")
        let materials = CaseUpdateComparison.materialSuggestions(source:incoming,existing:item.materials)
        XCTAssertEqual(materials.map(\.title),["报名凭证"])
        try service.applyUpdate(caseID:item.id,fingerprint:item.reviewFingerprint(),document:incoming,candidates:[],generator:"本机材料",changeDue:false,dueAt:nil,changeReminder:false,reminderAt:nil,saveLocally:true,confirmed:true,materials:materials)
        let updated = service.cases[0];XCTAssertTrue(updated.materials[0].done);XCTAssertEqual(updated.materials[1].title,"报名凭证");XCTAssertFalse(updated.materials[1].done)
        XCTAssertEqual(updated.materials[1].sourceQuote,"请带学生证和报名凭证。")
        let invented = CaseMaterialSuggestion(title:"护照",quote:"请带学生证和报名凭证。")
        XCTAssertThrowsError(try service.applyUpdate(caseID:item.id,fingerprint:updated.reviewFingerprint(),document:incoming,candidates:[],generator:"本机",changeDue:false,dueAt:nil,changeReminder:false,reminderAt:nil,saveLocally:true,confirmed:true,materials:[invented]))
    }

}
