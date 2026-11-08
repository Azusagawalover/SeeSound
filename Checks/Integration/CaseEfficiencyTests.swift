import Foundation
import XCTest
@testable import SeeSoundData

final class CaseEfficiencyTests:XCTestCase {
    private func directory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeeSound20-\(UUID())");try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url }
    private func fixture() -> WorkroomCase {
        var item = WorkroomCase();item.title = "准备申请";item.materials = [.init(title:"学生证",sourceQuote:"请带学生证",sourceLabel:"原文明示"),.init(title:"报名凭证")];item.steps = [.init(title:"确认报名")];return item
    }
    func testLegacyStepDecodesWithoutRenameMarker() throws {
        let id = UUID(),data = Data("{\"id\":\"\(id)\",\"title\":\"学生证\",\"done\":false}".utf8)
        let row = try JSONDecoder().decode(CaseStep.self,from:data);XCTAssertEqual(row.id,id);XCTAssertNil(row.renamedByUser)
    }
    @MainActor func testBatchPreviewDoesNotMutateAndApplyCanBeUndoneAndReloaded() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root)),item = fixture()
        try studio.putCase(item,saveLocally:true);let preview = try ChecklistBatchPreview.make(item:item,ids:Set(item.materials.map(\.id)))
        XCTAssertTrue(studio.cases[0].materials.allSatisfy { !$0.done });let undo = try studio.applyChecklistBatch(preview)
        XCTAssertTrue(studio.cases[0].materials.allSatisfy(\.done));XCTAssertTrue(try WorkroomStore(directory:root).load().cases[0].materials.allSatisfy(\.done))
        try studio.undoChecklist(undo);XCTAssertEqual(studio.cases[0],item);XCTAssertEqual(try WorkroomStore(directory:root).load().cases[0],item)
    }
    @MainActor func testChangedBatchPreviewRefusesToOverwriteNewNote() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root));var item = fixture()
        try studio.putCase(item,saveLocally:true);let preview = try ChecklistBatchPreview.make(item:item,ids:[item.materials[0].id]);item.note = "刚更新的说明";try studio.putCase(item,saveLocally:true)
        XCTAssertThrowsError(try studio.applyChecklistBatch(preview));XCTAssertEqual(studio.cases[0].note,item.note);XCTAssertFalse(studio.cases[0].materials[0].done)
    }
    @MainActor func testTemporaryChecklistChangesDoNotSaveContent() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root)),item = fixture()
        try studio.putCase(item,saveLocally:false);let undo = try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.complete([item.materials[0].id],true))
        XCTAssertFalse(studio.savedCaseIDs.contains(item.id));XCTAssertTrue(try WorkroomStore(directory:root).load().cases.isEmpty);try studio.undoChecklist(undo);XCTAssertFalse(studio.savedCaseIDs.contains(item.id))
    }
    @MainActor func testUndoRejectsLaterChangesWithoutOverwritingThem() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root));var item = fixture()
        try studio.putCase(item,saveLocally:true);let undo = try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.complete([item.materials[0].id],true))
        item = studio.cases[0];item.note = "后续更改";try studio.putCase(item,saveLocally:true)
        XCTAssertThrowsError(try studio.undoChecklist(undo));XCTAssertEqual(studio.cases[0],item)
    }
    @MainActor func testRenamePreservesSourceIdentityAndCompletionAndMarksHumanEdit() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root));var item = fixture();item.materials[0].done = true
        try studio.putCase(item,saveLocally:true);let old = item.materials[0]
        let undo = try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.rename(old.id,"  有照片的学生证  "))
        let row = studio.cases[0].materials[0];XCTAssertEqual(row.id,old.id);XCTAssertTrue(row.done);XCTAssertEqual(row.title,"有照片的学生证");XCTAssertEqual(row.sourceQuote,old.sourceQuote);XCTAssertEqual(row.sourceLabel,old.sourceLabel);XCTAssertEqual(row.renamedByUser,true)
        XCTAssertTrue(studio.cases[0].export(routines:[]).contains("名称由用户修改"));try studio.undoChecklist(undo);XCTAssertEqual(studio.cases[0].materials[0],old)
    }
    @MainActor func testEmptyAndOverlongNamesAreRejected() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root)),item = fixture();try studio.putCase(item,saveLocally:false)
        for name in [" \n ",String(repeating:"名",count:101)] { XCTAssertThrowsError(try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.rename(item.materials[0].id,name))) };XCTAssertEqual(studio.cases[0],item)
    }
    @MainActor func testReorderPreservesSourceProgressAndDependencies() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root));var item = fixture();item.materials[0].done = true
        var flow = CaseFlow();flow.dependencies[item.steps[0].id.uuidString] = [item.materials[0].id];item.flow = flow;try studio.putCase(item,saveLocally:true)
        let undo = try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.reorder(.material,item.materials.reversed().map(\.id)))
        XCTAssertEqual(studio.cases[0].materials,Array(item.materials.reversed()));XCTAssertEqual(studio.cases[0].flow,flow);try studio.undoChecklist(undo);XCTAssertEqual(studio.cases[0],item)
    }
    @MainActor func testReorderCannotDropDuplicateOrInventRows() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root)),item = fixture();try studio.putCase(item,saveLocally:true)
        for ids in [[item.materials[0].id],[item.materials[0].id,item.materials[0].id],[UUID(),UUID()]] { XCTAssertThrowsError(try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.reorder(.material,ids))) };XCTAssertEqual(studio.cases[0],item)
    }
    @MainActor func testRemovalAndUndoRestoreDependencyGraph() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root));var item = fixture();var flow = CaseFlow();flow.dependencies[item.steps[0].id.uuidString] = [item.materials[0].id];item.flow = flow;try studio.putCase(item,saveLocally:true)
        let undo = try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.remove(item.materials[0].id));try studio.cases[0].validateFlow();XCTAssertTrue(studio.cases[0].workflow.dependencies[item.steps[0].id.uuidString]?.isEmpty == true)
        try studio.undoChecklist(undo);XCTAssertEqual(studio.cases[0],item)
    }
    @MainActor func testBlockedCompletionAndBatchAreRejectedEvenWhenPrerequisiteSelected() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root));var item = fixture();var flow = CaseFlow();flow.dependencies[item.steps[0].id.uuidString] = [item.materials[0].id];item.flow = flow;try studio.putCase(item,saveLocally:false)
        let ids:Set<UUID> = [item.steps[0].id,item.materials[0].id]
        XCTAssertThrowsError(try ChecklistBatchPreview.make(item:item,ids:ids));XCTAssertThrowsError(try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.complete(ids,true)));XCTAssertEqual(studio.cases[0],item)
    }
    @MainActor func testCannotUncompletePrerequisiteOfCompletedDependent() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root));var item = fixture();item.materials[0].done = true;item.steps[0].done = true;var flow = CaseFlow();flow.dependencies[item.steps[0].id.uuidString] = [item.materials[0].id];item.flow = flow;try studio.putCase(item,saveLocally:false)
        XCTAssertThrowsError(try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.complete([item.materials[0].id],false)));XCTAssertEqual(studio.cases[0],item)
    }
    func testFocusQueueRespectsOrderingSkippingAndWaiting() {
        var item = fixture();var flow = CaseFlow();flow.dependencies[item.steps[0].id.uuidString] = [item.materials[0].id];item.flow = flow
        XCTAssertEqual(CaseFocusQueue.ready(in:item).map(\.id),item.materials.map(\.id))
        XCTAssertEqual(CaseFocusQueue.ready(in:item,skipping:[item.materials[0].id]).map(\.id),[item.materials[1].id]);XCTAssertFalse(item.materials[0].done)
        item.materials[0].done = true;XCTAssertEqual(CaseFocusQueue.ready(in:item).map(\.id),[item.materials[1].id,item.steps[0].id]);flow.disposition = .waiting;item.flow = flow;XCTAssertTrue(CaseFocusQueue.ready(in:item).isEmpty)
    }
    @MainActor func testCompletedAndWaitingCasesDoNotAdvance() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let studio = WorkroomService(store:.init(directory:root));var item = fixture();item.completedAt = item.createdAt;try studio.putCase(item,saveLocally:true)
        XCTAssertThrowsError(try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.complete([item.materials[0].id],true)))
        item.completedAt = nil;var flow = CaseFlow();flow.disposition = .waiting;item.flow = flow;try studio.putCase(item,saveLocally:true)
        XCTAssertThrowsError(try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.complete([item.materials[0].id],true)))
    }
    @MainActor func testDiskFailureDoesNotPartiallyUpdateLiveChecklist() throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at:root) };let store = WorkroomStore(directory:root),studio = WorkroomService(store:store),item = fixture();try studio.putCase(item,saveLocally:true)
        try Data("damaged".utf8).write(to:store.url)
        XCTAssertThrowsError(try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.complete([item.materials[0].id],true)));XCTAssertEqual(studio.cases[0],item);XCTAssertEqual(try Data(contentsOf:store.url),Data("damaged".utf8))
    }
    func testNextSevenDaysUsesCalendarWindowAndExcludesExpiredAndArchived() {
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = TimeZone(identifier:"America/New_York")!
        let now = calendar.date(from:.init(year:2026,month:10,day:30,hour:12))!,end = calendar.date(byAdding:.day,value:7,to:now)!
        var future = fixture();future.dueAt = end.addingTimeInterval(-1)
        var expired = fixture();expired.dueAt = now.addingTimeInterval(-1)
        var boundary = fixture();boundary.dueAt = end
        var archived = future;archived.id = UUID();archived.archivedAt = now
        var options = CaseListOptions();options.scope = .nextWeek
        XCTAssertEqual(options.select([future,expired,boundary,archived],query:"",filter:.all,includeDemo:true,filing:[:],routines:[],now:now,calendar:calendar).map(\.id),[future.id])
    }
    func testSortKeepsPinnedFirstAndDeadlinelessLastAndDeterministicTies() {
        let now = Date();var pinned = fixture();pinned.pinned = true
        var early = fixture();early.dueAt = now
        var late = fixture();late.dueAt = now.addingTimeInterval(600)
        var options = CaseListOptions();options.sort = .due
        XCTAssertEqual(options.select([late,pinned,early],query:"",filter:.active,includeDemo:true,filing:[:],routines:[],now:now).map(\.id),[pinned.id,early.id,late.id])
        pinned.pinned = false;pinned.dueAt = now
        let a = options.select([pinned,early],query:"",filter:.all,includeDemo:true,filing:[:],routines:[],now:now).map(\.id)
        let b = options.select([early,pinned],query:"",filter:.all,includeDemo:true,filing:[:],routines:[],now:now).map(\.id);XCTAssertEqual(a,b)
    }
    func testSearchFindsSourceTextAndCombinesFolderTagsScopeAndDemoFilter() {
        var item = fixture();item.priority = .important;var draft = WorkroomDraft();draft.text = "原文专属检索词";item.sources = [CaseDocument(draft:draft)]
        var demo = item;demo.id = UUID();demo.demonstration = true
        let filing = ["事务:\(item.id)":RecordFiling(folder:"课程",tags:["报名"])]
        var options = CaseListOptions();options.scope = .important;options.folder = "课程";options.tag = "报名"
        XCTAssertEqual(options.select([item,demo],query:"原文专属",filter:.active,includeDemo:false,filing:filing,routines:[],now:Date()).map(\.id),[item.id])
        XCTAssertEqual(options.select([item],query:"报名",filter:.active,includeDemo:false,filing:filing,routines:[],now:Date()).count,1)
        options.tag = "不存在";XCTAssertTrue(options.select([item],query:"",filter:.all,includeDemo:true,filing:filing,routines:[],now:Date()).isEmpty)
    }
}
