import Foundation
import XCTest
@testable import SeeSoundData

final class ProductTests:XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeeSound17-\(UUID())");try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    func testLegacyArchiveAndConversationDecodeWithDefaults() throws {
        var draft = WorkroomDraft();draft.text = "旧材料"
        let old = WorkroomArchive(drafts:[draft],cases:[WorkroomCase()])
        let decoded = try JSONDecoder().decode(WorkroomArchive.self,from:JSONEncoder().encode(old))
        XCTAssertNil(decoded.enhancements);XCTAssertNil(decoded.drafts[0].inInbox);XCTAssertEqual(decoded.cases[0].workflow.disposition,.ready)
        let turn = ConversationTurn(id:UUID(),speaker:.partner,origin:.speech,createdAt:.now,text:"旧字幕",state:.completed)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(SavedConversationTurn(turn))) as? [String:Any]);object.removeValue(forKey:"recognitionRevision")
        let saved = try JSONDecoder().decode(SavedConversationTurn.self,from:JSONSerialization.data(withJSONObject:object));try saved.validate();XCTAssertNil(saved.recognitionRevision)
    }
    func testDependenciesRejectCyclesUnknownParentsAndUnfinishedPrerequisites() throws {
        var item = WorkroomCase();let a = CaseStep(title:"材料"),b = CaseStep(title:"提交")
        item.materials = [a];item.steps = [b];var f = CaseFlow();f.dependencies[b.id.uuidString] = [a.id];item.flow = f
        try item.validate();XCTAssertEqual(item.blockedBy(b).map(\.id),[a.id]);XCTAssertEqual(item.nextAction(routines:[]),"准备：材料")
        item.steps[0].done = true;XCTAssertThrowsError(try item.validate());item.materials[0].done = true;try item.validate()
        f.dependencies[a.id.uuidString] = [b.id];item.flow = f;XCTAssertThrowsError(try item.validate())
        f.dependencies = [b.id.uuidString:[UUID()]];item.flow = f;XCTAssertThrowsError(try item.validate())
    }
    func testWaitingAndDeferredKeepProgressIndependent() throws {
        var item = WorkroomCase();item.steps = [.init(title:"确认")];var f = CaseFlow();f.disposition = .waiting;f.waitingFor = "老师回复";item.flow = f
        XCTAssertEqual(item.nextAction(routines:[]),"等待：老师回复");XCTAssertTrue(item.isActive);XCTAssertEqual(item.progress(routines:[]).done,0)
        f.disposition = .deferred;f.resumeAt = Date().addingTimeInterval(86400);item.flow = f;XCTAssertTrue(item.nextAction(routines:[])!.contains("暂缓"));try item.validate()
    }
    func testRepeatedCaseResetsProgressRemindersAndRemapsDependencies() throws {
        var item = WorkroomCase();item.materials = [.init(title:"证件",done:true)];item.steps = [.init(title:"办理",done:true)]
        item.completedAt = item.createdAt;item.dueAt = .now;item.reminderAt = .now;item.watchSeenAt = .now
        var f = CaseFlow();f.cadence = .weekly;f.dependencies[item.steps[0].id.uuidString] = [item.materials[0].id];item.flow = f
        let next = try item.nextOccurrence();XCTAssertNotEqual(next.id,item.id);XCTAssertFalse(next.isCompleted);XCTAssertNil(next.reminderAt);XCTAssertNil(next.watchSeenAt)
        XCTAssertTrue((next.materials+next.steps).allSatisfy { !$0.done });XCTAssertEqual(next.blockedBy(next.steps[0]).map(\.id),[next.materials[0].id]);XCTAssertGreaterThan(next.dueAt!,item.dueAt!)
        item.completedAt = nil;XCTAssertThrowsError(try item.nextOccurrence())
    }
    @MainActor func testNextOccurrenceCreationIsIdempotentAndDurable() throws {
        let root = try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:.init(directory:root));var item = WorkroomCase();item.steps = [.init(title:"检查",done:true)];item.completedAt = item.createdAt;var f = CaseFlow();f.cadence = .daily;item.flow = f
        try service.putCase(item,saveLocally:true);let first = try service.createNextOccurrence(item.id);let second = try service.createNextOccurrence(item.id)
        XCTAssertEqual(first,second);XCTAssertEqual(service.cases.count,2)
        let reloaded = WorkroomService(store:.init(directory:root));XCTAssertEqual(reloaded.cases.count,2);XCTAssertEqual(reloaded.cases.first(where:{$0.id == item.id})?.workflow.nextOccurrenceID,first)
    }
    @MainActor func testAutosaveRequiresOptInAndDoesNotReplaceActiveBuffer() throws {
        let root = try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:.init(directory:root));try service.protectDraft(title:"材料",text:"第一版",stage:1);XCTAssertTrue(service.drafts.isEmpty)
        try service.updateEnhancements { $0.autosave = true };let active = service.active
        try service.protectDraft(title:"材料",text:"第一版",stage:1);XCTAssertEqual(service.active,active)
        XCTAssertEqual(try WorkroomStore(directory:root).load().drafts.first?.text,"第一版")
        try service.edit(title:"材料",text:"最终版");XCTAssertEqual(try WorkroomStore(directory:root).load().drafts.first?.text,"最终版")
        try service.updateEnhancements { $0.autosave = false };try service.edit(title:"材料",text:"未保存修改")
        XCTAssertEqual(try WorkroomStore(directory:root).load().drafts.first?.text,"最终版")
        try service.saveDraft();let saved = try WorkroomStore(directory:root).load();XCTAssertEqual(saved.drafts.first?.text,"未保存修改");XCTAssertEqual(saved.enhancements?.lastDraftID,service.active.id)
    }
    @MainActor func testInboxAndCleanupKeepUnrelatedRecordsAndPersistAtomically() throws {
        let root = try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let service = WorkroomService(store:.init(directory:root));var draft = WorkroomDraft();draft.text = "待整理"
        try service.addToInbox(draft);var retry = draft;retry.text = "重复导入不覆盖编辑";try service.addToInbox(retry);XCTAssertEqual(service.drafts.count,1);XCTAssertEqual(service.drafts[0].text,draft.text);XCTAssertTrue(service.drafts[0].inInbox == true);try service.openInbox(draft.id);XCTAssertFalse(service.drafts[0].inInbox == true)
        var item = WorkroomCase();try service.putCase(item,saveLocally:true)
        XCTAssertThrowsError(try service.cleanup(drafts:[draft.id],cases:[item.id]));XCTAssertEqual(service.drafts.count,1)
        item.archivedAt = .now;try service.putCase(item,saveLocally:true);try service.cleanup(drafts:[draft.id],cases:[item.id])
        XCTAssertTrue(try WorkroomStore(directory:root).load().drafts.isEmpty);XCTAssertTrue(service.cases.isEmpty);XCTAssertEqual(service.active.id,draft.id)
    }
    func testSelectiveBackupCompletesDependenciesAndExcludesUnselectedPrivateContent() throws {
        var snapshot = LibrarySnapshot();var card = InformationCard();card.kind = .place;card.value = "会场";snapshot.cards = [card]
        var task = RoutineItem();task.title = "准备";snapshot.routines = [task]
        var item = WorkroomCase();item.links = [.init(id:card.id,kind:.card,snapshot:card.value,revision:card.revision),.init(id:task.id,kind:.routine,snapshot:task.title)]
        var other = WorkroomCase();other.title = "不应导出";snapshot.workroom.cases = [item,other]
        var selection = LibraryExportSelection();selection.caseIDs = [item.id];selection.cards = false;selection.routines = false;selection.settings = false
        let result = try selection.apply(to:snapshot);XCTAssertEqual(result.workroom.cases.map(\.id),[item.id]);XCTAssertEqual(result.cards.map(\.id),[card.id]);XCTAssertEqual(result.routines.map(\.id),[task.id])
        selection.includeDependencies = false;let sparse = try selection.apply(to:snapshot);XCTAssertTrue(sparse.cards.isEmpty);XCTAssertTrue(sparse.routines.isEmpty);XCTAssertEqual(sparse.workroom.cases[0].links.count,2)
    }
    func testFilingSurvivesBackupMergeWithoutOverwritingLocalOptIn() throws {
        var local = LibrarySnapshot();var extra = WorkroomEnhancements();extra.autosave = true;local.workroom.enhancements = extra
        var incoming = LibrarySnapshot();var row = WorkroomDraft();row.text = "材料";incoming.workroom.drafts = [row];extra = WorkroomEnhancements();extra.filing["草稿:\(row.id)"] = .init(folder:"课程",tags:["待核对"]);incoming.workroom.enhancements = extra
        let preview = try LibraryMerge.preview(local:local,package:.init(snapshot:incoming),options:.init())
        XCTAssertTrue(preview.target.workroom.enhancements?.autosave == true);XCTAssertEqual(preview.target.workroom.enhancements?.filing["草稿:\(row.id)"]?.tags,["待核对"])
        XCTAssertEqual(try preview.target.fingerprint(),try preview.target.fingerprint())
    }
    func testTemplateDoesNotCarryCompletionOrEvidence() throws {
        let template = CaseTemplate(title:"作业",materials:["要求"],steps:["提交"]);let a = template.makeCase(),b = template.makeCase()
        try a.validate();XCTAssertNotEqual(a.id,b.id);XCTAssertNotEqual(a.steps[0].id,b.steps[0].id);XCTAssertNil(a.steps[0].sourceQuote);XCTAssertNil(a.reminderAt);XCTAssertTrue(a.links.isEmpty)
    }
    func testCaptionRevisionOnlyCountsChangedRecognitionAndRemainsDistinctFromEdits() throws {
        var session = ConversationSession();let id = session.beginCapture()
        session.receive("下午三点",capture:id,isFinal:false);session.receive("下午三点",capture:id,isFinal:false);XCTAssertEqual(session.turns[0].recognitionRevision,0)
        session.receive("下午四点",capture:id,isFinal:true);XCTAssertEqual(session.turns[0].recognitionRevision,1);XCTAssertEqual(session.turns[0].previousRecognitionText,"下午三点");XCTAssertFalse(session.turns[0].isEdited)
        session.edit(id,text:"下午五点");XCTAssertTrue(session.turns[0].isEdited);XCTAssertEqual(SavedConversationTurn(session.turns[0]).recognitionRevision,1)
    }
    func testKeyFieldReviewShowsChangesWithoutMutatingSource() {
        let old = "时间：2026-10-30 15:00\n地点：二楼\n费用：12元",new = "时间：2026-10-31 15:00\n地点：三楼\n费用：20元"
        XCTAssertEqual(Set(KeyFieldReview.fields(old).map(\.kind)),["时间","地点","费用"])
        XCTAssertEqual(KeyFieldReview.changed(old:old,new:new).count,3);XCTAssertTrue(KeyFieldReview.changed(old:old,new:old).isEmpty)
    }
    func testShareInboxLimitsAndExplicitRemoval() throws {
        let root = try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let store = ShareInboxStore(directory:root);var invalid = SharePacket();XCTAssertThrowsError(try store.save(invalid));invalid.text = String(repeating:"字",count:12001);XCTAssertThrowsError(try store.save(invalid))
        for i in 0..<10 { var packet = SharePacket();packet.text = "材料 \(i)";try store.save(packet) }
        XCTAssertEqual(try store.load().count,10);var overflow = SharePacket();overflow.text = "第11条";XCTAssertThrowsError(try store.save(overflow))
        let id = try XCTUnwrap(store.load().first?.id);try store.remove(id);XCTAssertEqual(try store.load().count,9)
    }
    func testEmptyOrganizerQueryListsRecordsAndTagsValidate() throws {
        var draft = WorkroomDraft();draft.text = "材料"
        XCTAssertEqual(WorkroomSearch.hits(query:"",events:[],conversations:[],cards:[],routines:[],drafts:[draft],cases:[],includeAllWhenEmpty:true).count,1)
        XCTAssertThrowsError(try RecordFiling(folder:"课程",tags:["重复","重复"]).validate())
        XCTAssertThrowsError(try RecordFiling(folder:"课程",tags:[String(repeating:"字",count:21)]).validate())
    }
    func testSearchExcerptCentersMatchAfterLongPrefix() {
        let hit = GlobalSearchHit(recordID:UUID(),kind:.draft,title:"材料",detail:String(repeating:"无关内容",count:100)+"目标地点"+String(repeating:"尾",count:100),demonstration:false)
        let excerpt = hit.excerpt(for:"目标地点");XCTAssertTrue(excerpt.contains("目标地点"));XCTAssertLessThan(excerpt.count,182);XCTAssertTrue(excerpt.hasPrefix("…"))
    }
}
