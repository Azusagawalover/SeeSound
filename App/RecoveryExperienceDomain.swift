import Foundation
import CryptoKit

enum RecoveryExperienceError:LocalizedError {
    case full, missing, conflict, stale, invalidExample
    var errorDescription:String? {
        switch self {
        case .full:return "最近删除最多保留 50 条，请先恢复或永久删除其中的记录。"
        case .missing:return "这条记录已被处理，请刷新列表。"
        case .conflict:return "本机已有同一标识的记录，恢复没有覆盖它。请先检查现有记录。"
        case .stale:return "所选记录的分类已经变化，请重新预览；撤销也不会覆盖后来的修改。"
        case .invalidExample:return "示例标记不一致，没有修改普通资料。"
        }
    }
}
struct WorkroomTrashEntry:Codable,Identifiable,Equatable {
    var id = UUID()
    var deletedAt = Date()
    var draft:WorkroomDraft?
    var project:WorkroomCase?
    var savedLocally:Bool
    var filing:RecordFiling?
    var title:String { draft?.title ?? project?.title ?? "已删除记录" }
    var recordID:UUID { draft?.id ?? project?.id ?? id }
    var key:String { (draft == nil ? "事务:" : "草稿:")+recordID.uuidString }
    var exampleGroup:UUID? { draft?.exampleGroup ?? project?.exampleGroup }
    var demonstration:Bool { draft?.demonstration ?? project?.demonstration ?? false }
    var visualIDs:[UUID] { draft.map { [$0.visualID].compactMap { $0 } } ?? project?.documents.compactMap(\.visualID) ?? [] }
    func validate() throws {
        guard (draft == nil) != (project == nil),deletedAt.timeIntervalSince1970.isFinite else { throw DailyError.invalid }
        try draft?.validate();try project?.validate();try filing?.validate()
    }
}
struct FilingUndo:Codable,Equatable,Identifiable {
    var id = UUID()
    var date = Date()
    var previous:[String:RecordFiling]
    var previouslyAbsent:[String]
    var applied:[String:RecordFiling]
    func validate() throws {
        guard date.timeIntervalSince1970.isFinite,applied.count <= 1000,!applied.isEmpty,
              Set(previous.keys).isDisjoint(with:Set(previouslyAbsent)),Set(previous.keys).union(previouslyAbsent) == Set(applied.keys),
              applied.keys.allSatisfy({$0.count <= 100}) else { throw DailyError.invalid }
        try previous.values.forEach { try $0.validate() };try applied.values.forEach { try $0.validate() }
    }
}
struct FilingChangePreview:Equatable,Identifiable {
    var id = UUID()
    var keys:Set<String>
    var replacement:RecordFiling
    var fingerprint:String
    var previous:[String:RecordFiling]
    var absent:[String]
    static func make(keys:Set<String>,replacement:RecordFiling,current:[String:RecordFiling]) throws -> FilingChangePreview {
        guard !keys.isEmpty,keys.count <= 1000 else { throw DailyError.invalid };try replacement.validate()
        let old = current.filter { keys.contains($0.key) },absent = keys.filter { current[$0] == nil }.sorted()
        struct Selected:Encodable { var values:[String:RecordFiling];var absent:[String] }
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let hash = SHA256.hash(data:try encoder.encode(Selected(values:old,absent:absent))).map { String(format:"%02x",$0) }.joined()
        return .init(keys:keys,replacement:replacement,fingerprint:hash,previous:old,absent:absent)
    }
}
struct WorkroomNotice:Identifiable,Equatable {
    enum Action:Equatable { case none,restore(UUID),undoFiling,recentlyDeleted }
    var id = UUID()
    var text:String
    var action:Action = .none
}
enum ExampleExperience {
    static let groupID = UUID(uuidString:"01901900-1111-4444-8888-000000000019")!
    static func notification() -> WorkroomDraft {
        var draft = WorkroomDraft();draft.title = "内置体验 · 读书会通知";draft.origin = .demonstration;draft.exampleGroup = groupID
        draft.text = "【内置体验，非真实活动】\n活动：校园读书会\n时间：2026-11-02 15:00\n地点：图书馆二楼\n材料费：12元人民币\n请带学生证。\n请确认报名。"
        return draft
    }
    static func supplement() -> WorkroomDraft {
        var draft = notification();draft.id = UUID();draft.title = "内置体验 · 补充通知"
        draft.text = "【内置体验补充通知】\n时间：2026-11-03 16:00\n地点：图书馆三楼\n材料费：20元人民币\n请带学生证和报名凭证。"
        return draft
    }
    static func project() -> WorkroomCase {
        let draft = notification(),document = CaseDocument(draft:draft)
        var item = WorkroomCase();item.title = "内置体验 · 校园读书会";item.demonstration = true;item.exampleGroup = groupID;item.sources = [document]
        item.materials = [.init(title:"学生证")];item.steps = [.init(title:"确认报名")]
        item.arrangements = CaseUpdateComparison.localCandidates(source:document).map { .init(kind:$0.kind,value:$0.value,documentID:document.id,quote:$0.quote) }
        return item
    }
}
struct CaseReviewSummary {
    var changed:[CaseChangeCandidate]
    var unchanged:[CaseChangeCandidate]
    var materialCount:Int
    static func equal(_ a:String,_ b:String,kind:ArrangementKind) -> Bool {
        if a.trimmingCharacters(in:.whitespacesAndNewlines) == b.trimmingCharacters(in:.whitespacesAndNewlines) { return true }
        if kind == .time,let x = CaseUpdateComparison.explicitDate(a,timeZone:.current),let y = CaseUpdateComparison.explicitDate(b,timeZone:.current) { return x == y }
        if kind == .amount {
            let x = InsightEvidence.amounts(in:a),y = InsightEvidence.amounts(in:b)
            if x.count == 1,y.count == 1 { return x[0].value == y[0].value && x[0].currency == y[0].currency }
        }
        return false
    }
    static func make(candidates:[CaseChangeCandidate],baseline:WorkroomCase?,materialCount:Int) -> CaseReviewSummary {
        let unchanged = candidates.filter { candidate in baseline?.confirmedFacts.contains { $0.kind == candidate.kind && equal($0.value,candidate.value,kind:candidate.kind) } == true }
        return .init(changed:candidates.filter { candidate in !unchanged.contains { $0.id == candidate.id } },unchanged:unchanged,materialCount:materialCount)
    }
}

struct CleanupChangePreview:Identifiable {
    var id = UUID()
    var draftIDs:Set<UUID>
    var caseIDs:Set<UUID>
    var titles:[String]
    var fingerprint:String
    static func make(draftIDs:Set<UUID>,caseIDs:Set<UUID>,drafts:[WorkroomDraft],cases:[WorkroomCase],savedIDs:Set<UUID>) throws -> CleanupChangePreview {
        let selectedDrafts = drafts.filter { draftIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let selectedCases = cases.filter { caseIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard !draftIDs.isEmpty || !caseIDs.isEmpty,selectedDrafts.count == draftIDs.count,selectedCases.count == caseIDs.count,
              selectedCases.allSatisfy({$0.isArchived && savedIDs.contains($0.id)}) else { throw RecoveryExperienceError.stale }
        struct Selection:Encodable { var drafts:[WorkroomDraft];var cases:[WorkroomCase] }
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let fingerprint = SHA256.hash(data:try encoder.encode(Selection(drafts:selectedDrafts,cases:selectedCases))).map { String(format:"%02x",$0) }.joined()
        return .init(draftIDs:draftIDs,caseIDs:caseIDs,titles:selectedDrafts.map { "草稿 · "+$0.title }+selectedCases.map { "归档事务 · "+$0.title },fingerprint:fingerprint)
    }
}

struct PendingExampleImport {
    var image:Data
    var title:String
    var group:UUID
}
