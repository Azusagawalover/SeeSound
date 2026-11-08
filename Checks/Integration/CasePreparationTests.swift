import Foundation
import XCTest
@testable import SeeSoundData

final class CasePreparationTests: XCTestCase {
    private func sample() throws -> (WorkroomDraft,InsightRequest,CasePlan) {
        let draft=WorkroomDraft.demonstrationDraft()
        let request=InsightRequest(turns:draft.fragments,includeCasePlan:true)
        return (draft,request,try LocalCasePlanner.propose(request))
    }
    func testOfflinePlanExtractsTwoNamedMaterialsAndAnUnresolvedAction() throws {
        let (_,request,plan)=try sample();try plan.validate(request:request)
        XCTAssertEqual(plan.title,"校园读书会")
        XCTAssertEqual(Set(plan.items.filter { $0.kind == .material }.map(\.value)),["学生证","一本喜欢的书"])
        XCTAssertTrue(plan.items.contains { $0.kind == .step && $0.value.contains("报名截止") && $0.basis == .suggested })
        XCTAssertFalse(plan.items.contains { $0.value.contains("12元") || $0.value.contains("已完成") })
        XCTAssertNotNil(try LocalTextOrganizer.organize(request).casePlan)
        XCTAssertNil(try LocalTextOrganizer.organize(.init(turns:request.turns)).casePlan)
    }
    func testOfflinePlanDoesNotAddForbiddenMaterialsOrCancelledActivities() throws {
        var draft=WorkroomDraft();draft.text="请勿携带手机。\n无需准备现金。\n请带学生证。\n请携带学生证。"
        var plan=try LocalCasePlanner.propose(.init(turns:draft.fragments))
        XCTAssertEqual(plan.items.filter { $0.kind == .material }.map(\.value),["学生证"])
        draft.text += "\n本活动已经取消。"
        plan=try LocalCasePlanner.propose(.init(turns:draft.fragments));XCTAssertTrue(plan.items.isEmpty)
    }
    func testModelPlanRejectsUnsupportedQuotesAndInventedRequiredMaterials() throws {
        let (_,request,plan)=try sample()
        var bad=plan;bad.items[0].quote="不存在的原文";XCTAssertThrowsError(try bad.validate(request:request))
        bad=plan;bad.items[0].sourceID=UUID();XCTAssertThrowsError(try bad.validate(request:request))
        bad=plan;bad.items[0].basis = .suggested;XCTAssertThrowsError(try bad.validate(request:request))
        bad=plan;bad.items[0].value="护照";XCTAssertThrowsError(try bad.validate(request:request))
        bad=plan;bad.items[0].value="已完成报名";XCTAssertThrowsError(try bad.validate(request:request))
        bad=plan;bad.items += plan.items;XCTAssertThrowsError(try bad.validate(request:request))
        let result=InsightResult(version:1,provider:"DeepSeek",model:"test",summary:"",candidates:[],replies:[],casePlan:plan)
        XCTAssertNoThrow(try result.validate(request:request))
        XCTAssertThrowsError(try result.validate(request:.init(turns:request.turns)))
    }
    func testPreviewCanEditSelectAndAddManualItemsWithoutMarkingAnythingDone() throws {
        let (draft,request,plan)=try sample()
        var review=try PreparedCaseDraft(draft:draft,request:request,plan:plan,generator:"本地规则")
        review.title="参加读书会"
        review.items[0].title="我自己的学生证";review.items[1].selected=false
        review.items.append(.init(kind:.step,title:"检查出门路线",proposal:nil))
        let item=try review.makeCase(current:draft)
        XCTAssertEqual(item.materials.count,1);XCTAssertTrue(item.materials[0].sourceLabel?.contains("用户修改") == true)
        XCTAssertTrue(item.steps.contains { $0.title == "检查出门路线" && $0.sourceQuote == nil })
        XCTAssertTrue((item.steps+item.materials).allSatisfy { !$0.done })
        XCTAssertTrue(item.demonstration);XCTAssertEqual(item.preparation?.draftID,draft.id)
        XCTAssertTrue(item.export(routines:[]).contains("建立时依据"))
        for index in review.items.indices { review.items[index].selected=false }
        XCTAssertThrowsError(try review.makeCase(current:draft))
    }
    func testOriginalChangesIncludingTitleOrNewMaterialInvalidateThePreview() throws {
        let (draft,request,plan)=try sample()
        let review=try PreparedCaseDraft(draft:draft,request:request,plan:plan,generator:"DeepSeek")
        XCTAssertThrowsError(try review.makeCase(current:draft.edited(title:draft.title,text:draft.text+"\n时间改为四点。")))
        XCTAssertThrowsError(try review.makeCase(current:draft.edited(title:"新标题",text:draft.text)))
        var other=draft;other.id=UUID();XCTAssertFalse(review.isFresh(other))
    }
    @MainActor
    func testConfirmedCreationIsOptInAndRepeatedTapDoesNotDuplicateOrResetProgress() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("CasePreparation-\(UUID())")
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=WorkroomStore(directory:directory),service=WorkroomService(store:store)
        let (draft,request,plan)=try sample();try service.use(draft)
        let review=try PreparedCaseDraft(draft:draft,request:request,plan:plan,generator:"本地规则")
        XCTAssertThrowsError(try service.createPreparedCase(review,confirmed:false,saveLocally:true))
        XCTAssertTrue(service.cases.isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:store.url.path))
        let id=try service.createPreparedCase(review,confirmed:true,saveLocally:false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.url.path))
        var item=try XCTUnwrap(service.cases.first);item.materials[0].done=true
        try service.putCase(item,saveLocally:false)
        XCTAssertEqual(try service.createPreparedCase(review,confirmed:true,saveLocally:false),id)
        XCTAssertEqual(service.cases.count,1);XCTAssertTrue(service.cases[0].materials[0].done)
        try service.putCase(service.cases[0],saveLocally:true)
        let restored=try store.load().cases[0]
        XCTAssertEqual(restored.preparation,review.source);XCTAssertTrue(restored.materials[0].done)
    }
    func testVersion013CasesWithoutPreparationMetadataStillLoad() throws {
        let raw="""
        {"id":"13BD3153-1908-45DE-9926-D7176CE4E814","title":"旧事务","note":"","demonstration":false,"createdAt":0,
        "materials":[{"id":"49BCCAA5-5745-46B9-8230-E6BD0A19B526","title":"学生证","done":false}],"steps":[],"links":[]}
        """
        let item=try JSONDecoder().decode(WorkroomCase.self,from:Data(raw.utf8));try item.validate()
        XCTAssertNil(item.preparation);XCTAssertNil(item.materials[0].sourceQuote)
    }
    func testRealAPIPlanDecodesAndBuildsAnUncompletedSourceMatchedCase() throws {
        struct Fixture:Decodable {
            var draftID:UUID
            var draftTitle:String
            var request:InsightRequest
            var result:InsightResult
            var status:Int
            enum CodingKeys:String,CodingKey { case request,result,status;case draftID="draft_id",draftTitle="draft_title" }
        }
        let url=try XCTUnwrap(Bundle.module.url(forResource:"CasePlanLive",withExtension:"json",subdirectory:"Fixtures"))
        let fixture=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
        XCTAssertEqual(fixture.status,200);try fixture.result.validate(request:fixture.request)
        let plan=try XCTUnwrap(fixture.result.casePlan)
        var draft=WorkroomDraft();draft.id=fixture.draftID;draft.title=fixture.draftTitle;draft.origin = .demonstration;draft.text=fixture.request.turns.map(\.text).joined(separator:"\n")
        XCTAssertEqual(draft.fragments,fixture.request.turns)
        let review=try PreparedCaseDraft(draft:draft,request:fixture.request,plan:plan,generator:fixture.result.assistantTitle)
        let item=try review.makeCase(current:draft)
        XCTAssertEqual(Set(item.materials.map(\.title)),["学生证","一本喜欢的书"])
        XCTAssertTrue(item.steps.contains { $0.title.contains("报名截止") })
        XCTAssertTrue((item.materials+item.steps).allSatisfy { !$0.done && $0.sourceQuote != nil })
        XCTAssertTrue(item.links.isEmpty);XCTAssertEqual(item.preparation?.generator,"DeepSeek")
    }
}
