import Foundation

enum ChecklistKind:String,CaseIterable,Identifiable {
    case material,step
    var id:String { rawValue }
    var title:String { self == .material ? "材料" : "步骤" }
    func rows(in item:WorkroomCase) -> [CaseStep] { self == .material ? item.materials : item.steps }
}
enum ChecklistError:LocalizedError {
    case stale,blocked,inactive,invalidSelection,invalidName,dependentCompleted
    var errorDescription:String? {
        switch self {
        case .stale:return "清单或事务已变化，请重新查看后再操作。原有修改没有被覆盖。"
        case .blocked:return "所选项目还有未处理的前置项，请先完成前置项。"
        case .inactive:return "事务目前不能推进，请先重新打开或恢复推进。"
        case .invalidSelection:return "请选择当前清单中的项目；排序需要保留全部项目。"
        case .invalidName:return "名称需要 1–100 字，请检查后再保存。"
        case .dependentCompleted:return "已有完成项目依赖这一项。请先撤回这些后续项目，再取消本项完成。"
        }
    }
}
enum ChecklistChange {
    case complete(Set<UUID>,Bool)
    case rename(UUID,String)
    case reorder(ChecklistKind,[UUID])
    case remove(UUID)
}
struct ChecklistUndo:Identifiable {
    var id = UUID()
    let before:WorkroomCase
    let afterFingerprint:String
    let message:String
}
struct ChecklistBatchPreview:Identifiable {
    var id = UUID()
    let caseID:UUID
    let fingerprint:String
    let ids:Set<UUID>
    let titles:[String]
    static func make(item:WorkroomCase,ids:Set<UUID>) throws -> ChecklistBatchPreview {
        let rows = (item.materials+item.steps).filter { ids.contains($0.id) }
        guard !ids.isEmpty,rows.count == ids.count,rows.allSatisfy({!$0.done}) else { throw ChecklistError.invalidSelection }
        guard item.isActive,item.workflow.disposition == .ready else { throw ChecklistError.inactive }
        guard rows.allSatisfy({item.blockedBy($0).isEmpty}) else { throw ChecklistError.blocked }
        return .init(caseID:item.id,fingerprint:try item.reviewFingerprint(),ids:ids,titles:rows.map(\.title))
    }
}
struct CaseFocusRow:Identifiable {
    let kind:ChecklistKind
    let row:CaseStep
    var id:UUID { row.id }
}
enum CaseFocusQueue {
    static func ready(in item:WorkroomCase,skipping:Set<UUID> = []) -> [CaseFocusRow] {
        guard item.isActive,item.workflow.disposition == .ready else { return [] }
        return ChecklistKind.allCases.flatMap { kind in kind.rows(in:item).filter { !$0.done && !skipping.contains($0.id) && item.blockedBy($0).isEmpty }.map { CaseFocusRow(kind:kind,row:$0) } }
    }
}
@MainActor extension WorkroomService {
    @discardableResult func changeChecklist(caseID:UUID,fingerprint:String,change:ChecklistChange) throws -> ChecklistUndo {
        guard let current = cases.first(where:{$0.id == caseID}),try current.reviewFingerprint() == fingerprint else { throw ChecklistError.stale }
        guard current.isActive else { throw ChecklistError.inactive }
        var next = current
        let message:String
        switch change {
        case .complete(let ids,let done):
            let selected = (current.materials+current.steps).filter { ids.contains($0.id) }
            guard !ids.isEmpty,selected.count == ids.count,selected.allSatisfy({$0.done != done}) else { throw ChecklistError.invalidSelection }
            if done {
                guard current.workflow.disposition == .ready else { throw ChecklistError.inactive }
                guard selected.allSatisfy({current.blockedBy($0).isEmpty}) else { throw ChecklistError.blocked }
            } else {
                let dependents = (current.materials+current.steps).filter { $0.done && !ids.contains($0.id) && !(current.workflow.dependencies[$0.id.uuidString] ?? []).allSatisfy({!ids.contains($0)}) }
                guard dependents.isEmpty else { throw ChecklistError.dependentCompleted }
            }
            for i in next.materials.indices where ids.contains(next.materials[i].id) { next.materials[i].done = done }
            for i in next.steps.indices where ids.contains(next.steps[i].id) { next.steps[i].done = done }
            message = done ? "已处理 \(ids.count) 项" : "已恢复为未处理"
        case .rename(let id,let proposed):
            let name = proposed.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty,name.count <= 100 else { throw ChecklistError.invalidName }
            guard (current.materials+current.steps).contains(where:{$0.id == id}) else { throw ChecklistError.invalidSelection }
            if let i = next.materials.firstIndex(where:{$0.id == id}) { next.materials[i].title = name;next.materials[i].renamedByUser = true }
            if let i = next.steps.firstIndex(where:{$0.id == id}) { next.steps[i].title = name;next.steps[i].renamedByUser = true }
            message = "名称已更新，原依据保留"
        case .reorder(let kind,let ids):
            let rows = kind.rows(in:current)
            guard ids.count == rows.count,Set(ids).count == ids.count,Set(ids) == Set(rows.map(\.id)) else { throw ChecklistError.invalidSelection }
            let lookup = Dictionary(uniqueKeysWithValues:rows.map { ($0.id,$0) }),ordered = ids.compactMap { lookup[$0] }
            if kind == .material { next.materials = ordered } else { next.steps = ordered }
            message = kind.title+"顺序已更新"
        case .remove(let id):
            guard (current.materials+current.steps).contains(where:{$0.id == id}) else { throw ChecklistError.invalidSelection }
            next.materials.removeAll { $0.id == id };next.steps.removeAll { $0.id == id }
            var flow = next.workflow;flow.dependencies.removeValue(forKey:id.uuidString)
            for key in flow.dependencies.keys { flow.dependencies[key]?.removeAll { $0 == id } };next.flow = flow
            message = "已从清单移除，可撤销"
        }
        try putCase(next,saveLocally:savedCaseIDs.contains(caseID))
        return .init(before:current,afterFingerprint:try next.reviewFingerprint(),message:message)
    }
    func undoChecklist(_ undo:ChecklistUndo) throws {
        guard let current = cases.first(where:{$0.id == undo.before.id}),current.isActive,try current.reviewFingerprint() == undo.afterFingerprint else { throw ChecklistError.stale }
        var next = current;next.materials = undo.before.materials;next.steps = undo.before.steps;next.flow = undo.before.flow
        try putCase(next,saveLocally:savedCaseIDs.contains(next.id))
    }
    @discardableResult func applyChecklistBatch(_ preview:ChecklistBatchPreview) throws -> ChecklistUndo {
        try changeChecklist(caseID:preview.caseID,fingerprint:preview.fingerprint,change:.complete(preview.ids,true))
    }
}
enum CaseListSort:String,Codable,CaseIterable,Identifiable {
    case smart,due,newest,remaining
    var id:String { rawValue }
    var title:String { switch self { case .smart:return "智能顺序";case .due:return "截止时间先后";case .newest:return "最近建立";case .remaining:return "剩余项目从少到多" } }
}
enum CaseListScope:String,Codable,CaseIterable,Identifiable {
    case all,important,nextWeek,withoutDue
    var id:String { rawValue }
    var title:String { switch self { case .all:return "不限范围";case .important:return "仅重要事务";case .nextWeek:return "未来七天截止";case .withoutDue:return "未设置截止时间" } }
}
struct CaseListOptions:Codable,Equatable {
    var sort:CaseListSort = .smart
    var scope:CaseListScope = .all
    var folder = ""
    var tag = ""
    var isDefault:Bool { self == CaseListOptions() }
    func select(_ items:[WorkroomCase],query:String,filter:CaseFilter,includeDemo:Bool,filing:[String:RecordFiling],routines:[RoutineItem],now:Date,calendar:Calendar = .current) -> [WorkroomCase] {
        // Filing names and source text participate in the same search as the original fields.
        let search = query.trimmingCharacters(in:.whitespacesAndNewlines)
        let source = items.filter { item in
            let entry = filing["事务:\(item.id)"] ?? RecordFiling()
            let textMatches = search.isEmpty || ([item.title,item.note,entry.folder]+entry.tags+(item.materials+item.steps).map(\.title)+item.links.map(\.snapshot)+item.documents.map(\.text)).contains { $0.localizedCaseInsensitiveContains(search) }
            guard textMatches,(folder.isEmpty || entry.folder == folder),(tag.isEmpty || entry.tags.contains(tag)) else { return false }
            switch scope {
            case .all:return true
            case .important:return item.priority == .important
            case .withoutDue:return item.dueAt == nil
            case .nextWeek:
                guard item.isActive,let date = item.dueAt,let end = calendar.date(byAdding:.day,value:7,to:now) else { return false };return date >= now && date < end
            }
        }
        let base = WorkroomCase.select(source,query:"",filter:filter,includeDemonstrations:includeDemo,now:now,calendar:calendar)
        guard sort != .smart else { return base }
        return base.sorted { a,b in
            if a.isPinned != b.isPinned { return a.isPinned }
            switch sort {
            case .due:if a.dueAt != b.dueAt { return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture) }
            case .newest:if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            case .remaining:
                let x = a.progress(routines:routines),y = b.progress(routines:routines)
                if x.total-x.done != y.total-y.done { return x.total-x.done < y.total-y.done }
            case .smart:break
            }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
