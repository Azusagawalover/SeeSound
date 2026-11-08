import Foundation
import XCTest
@testable import SeeSoundData

final class RecoveryExperienceTests:XCTestCase {
    private func root() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeeSound19-\(UUID())");try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url }
    @MainActor func testSavedCaseCanBeRecoveredAfterRestartWithoutRearmingReminder() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var item = WorkroomCase();item.reminderAt = Date().addingTimeInterval(600);item.materials = [.init(title:"材料",done:true)]
        try service.putCase(item,saveLocally:true);try service.removeCase(item.id)
        XCTAssertTrue(service.cases.isEmpty);XCTAssertEqual(try WorkroomStore(directory:directory).load().trash?.first?.project?.id,item.id)
        let reloaded = WorkroomService(store:.init(directory:directory));try reloaded.restoreDeleted(reloaded.trash[0].id)
        XCTAssertEqual(reloaded.cases[0].id,item.id);XCTAssertNil(reloaded.cases[0].reminderAt);XCTAssertTrue(reloaded.cases[0].materials[0].done);XCTAssertTrue(reloaded.trash.isEmpty)
    }
    @MainActor func testTemporaryDeletedCaseStaysTemporaryAndNeverEntersDiskArchive() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));let item = WorkroomCase();try service.putCase(item,saveLocally:false);try service.removeCase(item.id)
        let saved = try WorkroomStore(directory:directory).load();XCTAssertTrue(saved.trash?.isEmpty != false);XCTAssertTrue(saved.cases.isEmpty)
        XCTAssertEqual(service.trash.count,1);try service.restoreDeleted(service.trash[0].id);XCTAssertFalse(service.savedCaseIDs.contains(item.id));XCTAssertEqual(service.cases[0].id,item.id)
    }
    @MainActor func testRestoreConflictDoesNotOverwriteExistingRecordOrLoseDeletedCopy() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var item = WorkroomCase();item.title = "旧版";try service.putCase(item,saveLocally:true);try service.removeCase(item.id)
        item.title = "已导入的新版本";try service.putCase(item,saveLocally:true)
        XCTAssertThrowsError(try service.restoreDeleted(service.trash[0].id));XCTAssertEqual(service.cases[0].title,"已导入的新版本");XCTAssertEqual(service.trash[0].project?.title,"旧版")
    }
    @MainActor func testFullTrashRejectsNextDeletionWithoutPartiallyChangingRecords() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory))
        for index in 0..<51 { var draft = WorkroomDraft();draft.text = "材料\(index)";try service.use(draft);try service.saveDraft();if index < 50 { try service.removeDraft(draft.id) } }
        let remaining = service.drafts[0];XCTAssertThrowsError(try service.removeDraft(remaining.id));XCTAssertEqual(service.trash.count,50);XCTAssertEqual(service.drafts.map(\.id),[remaining.id])
    }
    @MainActor func testFilingPreviewAndUndoSurviveRestartAndRestoreAbsentKeys() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));let a = "草稿:\(UUID())",b = "事务:\(UUID())"
        try service.updateEnhancements { $0.filing[a] = .init(folder:"课程",tags:["初稿"]) }
        let preview = try service.previewFiling([a,b],filing:.init(folder:"待办",tags:["核对"]))
        XCTAssertNil(service.enhancements.filing[b]);try service.applyFilingPreview(preview)
        let reloaded = WorkroomService(store:.init(directory:directory));XCTAssertNotNil(reloaded.filingUndo);try reloaded.undoLastFiling()
        XCTAssertEqual(reloaded.enhancements.filing[a]?.folder,"课程");XCTAssertNil(reloaded.enhancements.filing[b]);XCTAssertNil(reloaded.filingUndo)
    }
    @MainActor func testFilingUndoRefusesToOverwriteLaterClassificationChanges() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory)),key = "草稿:\(UUID())"
        try service.bulkFile([key],filing:.init(folder:"第一次",tags:[]));try service.updateEnhancements { $0.filing[key] = .init(folder:"后来修改",tags:[]) }
        XCTAssertThrowsError(try service.undoLastFiling());XCTAssertEqual(service.enhancements.filing[key]?.folder,"后来修改")
    }
    @MainActor func testChangedFilingPreviewCannotBeApplied() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory)),key = "草稿:\(UUID())"
        let preview = try service.previewFiling([key],filing:.init(folder:"目标",tags:[]));try service.bulkFile([key],filing:.init(folder:"新分类",tags:[]))
        XCTAssertThrowsError(try service.applyFilingPreview(preview));XCTAssertEqual(service.enhancements.filing[key]?.folder,"新分类")
    }
    @MainActor func testCleanupPreviewRejectsEditedDraftAndDoesNotDeleteAnything() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var draft = WorkroomDraft();draft.text = "原文";try service.use(draft);try service.saveDraft()
        let preview = try service.previewCleanup(draftIDs:[draft.id],caseIDs:[]);try service.edit(title:draft.title,text:"已经修改");try service.saveDraft()
        XCTAssertThrowsError(try service.applyCleanupPreview(preview));XCTAssertEqual(service.drafts[0].text,"已经修改");XCTAssertTrue(service.trash.isEmpty)
    }
    @MainActor func testRestoredDraftRecoversHistoryAndClassification() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var draft = WorkroomDraft();draft.text = "初稿";draft = try draft.edited(title:"草稿",text:"第二版")
        try service.use(draft);try service.saveDraft();try service.bulkFile(["草稿:\(draft.id)"],filing:.init(folder:"作业",tags:["待交"]))
        try service.removeDraft(draft.id);try service.restoreDeleted(service.trash[0].id)
        XCTAssertEqual(service.drafts[0].history,draft.history);XCTAssertEqual(service.enhancements.filing["草稿:\(draft.id)"]?.tags,["待交"])
    }
    @MainActor func testRestoreCapacityFailureKeepsDeletedCopy() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        var deleted = WorkroomDraft();deleted.text = "待恢复"
        let active = (0..<30).map { index -> WorkroomDraft in var draft = WorkroomDraft();draft.text = "材料\(index)";return draft }
        try WorkroomStore(directory:directory).save(.init(drafts:active,trash:[.init(draft:deleted,savedLocally:true)]))
        let service = WorkroomService(store:.init(directory:directory));XCTAssertThrowsError(try service.restoreDeleted(service.trash[0].id));XCTAssertEqual(service.drafts.count,30);XCTAssertEqual(service.trash.count,1)
    }
    @MainActor func testOrdinaryBackupExcludesDeletedContentAndUndoMetadata() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var draft = WorkroomDraft();draft.text = "不应导出的已删除内容";try service.use(draft);try service.saveDraft();try service.removeDraft(draft.id)
        var snapshot = LibrarySnapshot();snapshot.workroom = try WorkroomStore(directory:directory).load()
        let package = try LibraryCryptography.open(LibraryCryptography.seal(.init(snapshot:snapshot),password:"fixture-pass19"),password:"fixture-pass19")
        XCTAssertNil(package.snapshot.workroom.trash);XCTAssertNil(package.snapshot.workroom.filingUndo);XCTAssertTrue(package.snapshot.workroom.drafts.isEmpty)
        XCTAssertNil(try LibraryExportSelection().apply(to:snapshot).workroom.trash)
    }
    @MainActor func testExampleCleanupOnlyTouchesItsOwnMarkedRecords() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));var ordinary = WorkroomDraft();ordinary.text = "我的资料";try service.use(ordinary);try service.saveDraft()
        var otherDemo = WorkroomCase();otherDemo.demonstration = true;otherDemo.title = "我的另一个演示";try service.putCase(otherDemo,saveLocally:true)
        let id = try XCTUnwrap(service.installExampleSources(includeProject:true));try service.removeCase(id);try service.clearExampleExperience()
        XCTAssertEqual(service.cases.map(\.id),[otherDemo.id]);XCTAssertEqual(service.drafts.map(\.id),[ordinary.id]);XCTAssertTrue(service.trash.isEmpty)
    }
    @MainActor func testResumingExampleReplenishesRemovedSupplementWithoutDuplicatingProject() throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at:directory) }
        let service = WorkroomService(store:.init(directory:directory));let first = try service.installExampleSources(includeProject:true)
        let supplement = try XCTUnwrap(service.drafts.first);try service.removeDraft(supplement.id)
        let resumed = try service.installExampleSources(includeProject:true)
        XCTAssertEqual(first,resumed);XCTAssertEqual(service.cases.count,1)
        XCTAssertEqual(service.drafts.filter { $0.exampleGroup == ExampleExperience.groupID }.count,1)
    }
    func testOnlyDemonstrationRecordsMayCarryExampleOwnershipMarker() throws {
        var draft = WorkroomDraft();draft.text = "普通";draft.exampleGroup = ExampleExperience.groupID;XCTAssertThrowsError(try draft.validate())
        var item = WorkroomCase();item.exampleGroup = ExampleExperience.groupID;XCTAssertThrowsError(try item.validate())
        try ExampleExperience.notification().validate();try ExampleExperience.project().validate()
    }
    func testChangeSummaryCollapsesEquivalentConfirmedValues() {
        let source = CaseDocument(draft:ExampleExperience.notification());var item = ExampleExperience.project();item.sources = [source]
        item.arrangements = [.init(kind:.amount,value:"12.00元",documentID:source.id,quote:"12元")]
        let candidate = CaseChangeCandidate(kind:.amount,value:"12 CNY",quote:"12元",date:nil)
        let summary = CaseReviewSummary.make(candidates:[candidate],baseline:item,materialCount:2)
        XCTAssertTrue(summary.changed.isEmpty);XCTAssertEqual(summary.unchanged.count,1);XCTAssertEqual(summary.materialCount,2)
        XCTAssertFalse(CaseReviewSummary.equal("图书馆二楼","图书馆三楼",kind:.place))
    }
    func testMalformedDeletedEntryIsRejectedWithoutUnsafeIdentifierAccess() throws {
        let invalid = WorkroomTrashEntry(savedLocally:true)
        XCTAssertThrowsError(try WorkroomArchive(trash:[invalid]).validate())
    }
}
