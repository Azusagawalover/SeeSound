import Foundation

enum CaseDisposition: String, Codable, CaseIterable, Identifiable {
    case ready, waiting, deferred
    var id: String { rawValue }
    var title: String { switch self { case .ready: return "可推进"; case .waiting: return "等待回复"; case .deferred: return "暂缓" } }
}
enum CaseCadence: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekly, monthly
    var id: String { rawValue }
    var title: String { switch self { case .none: return "不重复"; case .daily: return "每天"; case .weekly: return "每周"; case .monthly: return "每月" } }
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self { case .none: return nil; case .daily: return calendar.date(byAdding:.day,value:1,to:date); case .weekly: return calendar.date(byAdding:.day,value:7,to:date); case .monthly: return calendar.date(byAdding:.month,value:1,to:date) }
    }
}
struct CaseFlow: Codable, Equatable {
    var disposition: CaseDisposition = .ready
    var waitingFor = ""
    var waitingSince: Date?
    var followUpAt: Date?
    var followUps: [CaseFollowUp]?
    var resumeAt: Date?
    var cadence: CaseCadence = .none
    var nextOccurrenceID: UUID?
    var dependencies: [String:[UUID]] = [:]
}
struct RecordFiling: Codable, Equatable {
    var folder = ""
    var tags: [String] = []
    func validate() throws {
        guard folder.count <= 30, tags.count <= 8, Set(tags).count == tags.count,
              tags.allSatisfy({ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count <= 20 }) else { throw DailyError.invalid }
    }
}
struct CaseTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var materials: [String]
    var steps: [String]
    func validate() throws {
        guard !title.isEmpty, title.count <= 60, materials.count <= 30, steps.count <= 30,
              (materials+steps).allSatisfy({ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count <= 100 }) else { throw DailyError.invalid }
    }
    func makeCase() -> WorkroomCase {
        var item = WorkroomCase();item.title = title;item.materials = materials.map { CaseStep(title:$0) };item.steps = steps.map { CaseStep(title:$0) };return item
    }
    static let presets: [CaseTemplate] = [
        .init(title:"活动报名",materials:["报名所需证件","需要提交的材料"],steps:["核对时间、地点与费用","确认报名","出发前检查"]),
        .init(title:"课程作业",materials:["作业要求","参考资料"],steps:["确认提交格式与截止时间","完成初稿","检查后提交"]),
        .init(title:"预约办事",materials:["身份证明","预约凭证"],steps:["核对预约时间和地点","准备材料","现场办理"])
    ]
}
struct WorkroomEnhancements: Codable, Equatable {
    var campus: CampusLedger?
    var autosave = false
    var lastDraftID: UUID?
    var lastCaseID: UUID?
    var lastStage = 1
    var filing: [String:RecordFiling] = [:]
    var templates: [CaseTemplate] = []
    func validate() throws {
        try campus?.validate()
        guard (0...3).contains(lastStage), filing.count <= 1000, templates.count <= 20,
              Set(templates.map(\.id)).count == templates.count, filing.keys.allSatisfy({ $0.count <= 100 }) else { throw DailyError.capacity }
        try filing.values.forEach { try $0.validate() };try templates.forEach { try $0.validate() }
    }
}
extension WorkroomCase {
    var workflow: CaseFlow { flow ?? CaseFlow() }
    func blockedBy(_ row: CaseStep) -> [CaseStep] {
        let required = workflow.dependencies[row.id.uuidString] ?? []
        return (materials+steps).filter { required.contains($0.id) && !$0.done }
    }
    func validateFlow() throws {
        let flow = workflow, rows = materials+steps, ids = Set(rows.map(\.id))
        guard (flow.followUps ?? []).count <= 30,Set((flow.followUps ?? []).map(\.id)).count == (flow.followUps ?? []).count, (flow.followUps ?? []).allSatisfy({ !$0.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.note.count <= 300 && $0.date.timeIntervalSince1970.isFinite }),
              [flow.waitingSince,flow.followUpAt].compactMap({$0}).allSatisfy({ $0.timeIntervalSince1970.isFinite }),flow.waitingFor.count <= 100, flow.dependencies.count <= 60, flow.nextOccurrenceID != id,
              flow.resumeAt.map({ $0.timeIntervalSince1970.isFinite && (1900...2200).contains(Calendar.current.component(.year,from:$0)) }) != false else { throw DailyError.invalid }
        for (key, dependencies) in flow.dependencies {
            guard let row = UUID(uuidString:key), ids.contains(row), dependencies.count <= 59,
                  Set(dependencies).count == dependencies.count, !dependencies.contains(row), dependencies.allSatisfy(ids.contains) else { throw DailyError.invalid }
            var visiting = Set<UUID>(), visited = Set<UUID>()
            func visit(_ node: UUID) throws {
                if visited.contains(node) { return };guard visiting.insert(node).inserted else { throw DailyError.invalid }
                for parent in flow.dependencies[node.uuidString] ?? [] { try visit(parent) }
                visiting.remove(node);visited.insert(node)
            }
            try visit(row)
        }
        guard rows.filter(\.done).allSatisfy({ blockedBy($0).isEmpty }) else { throw WorkroomError.incomplete }
    }
    func nextOccurrence(at now: Date = Date(), calendar: Calendar = .current) throws -> WorkroomCase {
        guard isCompleted, !isArchived, workflow.cadence != .none, workflow.nextOccurrenceID == nil else { throw DailyError.stale }
        var next = self;next.id = UUID();next.createdAt = now;next.completedAt = nil;next.archivedAt = nil;next.watchSeenAt = nil;next.watchSeenVersion = nil;next.reminderAt = nil
        next.dueAt = workflow.cadence.next(after:dueAt ?? completedAt ?? now,calendar:calendar)
        let mapping = Dictionary(uniqueKeysWithValues:(materials+steps).map { ($0.id,UUID()) })
        func reset(_ row:CaseStep) -> CaseStep { var copy = row;copy.id = mapping[row.id]!;copy.done = false;return copy }
        next.materials = materials.map(reset);next.steps = steps.map(reset)
        // Past task completions and source claims do not carry into a new occurrence.
        next.links = links.filter { $0.kind == .card };next.preparation = nil;next.sources = nil;next.arrangements = nil;next.updates = nil
        var f = CaseFlow();f.cadence = workflow.cadence
        for (key,values) in workflow.dependencies { if let id = UUID(uuidString:key),let newID = mapping[id] { f.dependencies[newID.uuidString] = values.compactMap { mapping[$0] } } }
        next.flow = f;try next.validate();return next
    }
}
struct KeyField: Identifiable, Equatable {
    let id: String
    let kind: String
    let text: String
}
enum KeyFieldReview {
    static func fields(_ text:String) -> [KeyField] {
        let patterns = [("时间",#"\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?(?:\s+\d{1,2}:\d{2})?|(?:今天|明天|后天|周[一二三四五六日天]|星期[一二三四五六日天])[^，。；\n]{0,12}|(?:上午|下午|晚上)?\d{1,2}[:：点]\d{0,2}分?"#),
                        ("地点",#"(?:地点|地址|会场)[:：]\s*[^\n，。；]{1,80}"#),
                        ("费用",#"(?:[¥￥$]\s*\d+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?\s*(?:元|人民币|美元))"#)]
        return patterns.flatMap { kind,pattern -> [KeyField] in
            guard let regex = try? NSRegularExpression(pattern:pattern) else { return [] }
            return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { match in
                guard let range = Range(match.range,in:text) else { return nil };let value = String(text[range]);return KeyField(id:"\(kind):\(match.range.location):\(value)",kind:kind,text:value)
            }
        }
    }
    static func changed(old:String,new:String) -> [String] {
        let before = fields(old),after = fields(new)
        return ["时间","地点","费用"].compactMap { kind in
            let a = before.filter { $0.kind == kind }.map(\.text),b = after.filter { $0.kind == kind }.map(\.text)
            return a == b ? nil : "\(kind)：\(a.isEmpty ? "未提取到" : a.joined(separator:"、")) → \(b.isEmpty ? "未提取到" : b.joined(separator:"、"))"
        }
    }
}
struct LibraryExportSelection {
    var cases = true, drafts = true, cards = true, routines = true, conversations = true, history = true, quality = true, settings = true
    var caseIDs: Set<UUID>?
    var includeDependencies = true
    func apply(to original:LibrarySnapshot) throws -> LibrarySnapshot {
        var result = original;result.workroom.trash = nil;result.workroom.filingUndo = nil
        if !cases { result.workroom.cases = [] }
        else if let caseIDs { result.workroom.cases.removeAll { !caseIDs.contains($0.id) } }
        if !drafts { result.workroom.drafts = [] };if !cards { result.cards = [] };if !routines { result.routines = [] }
        if includeDependencies {
            let ids = Set(result.workroom.cases.flatMap(\.links).filter { $0.kind == .routine }.map(\.id))
            for row in original.routines where ids.contains(row.id) && !result.routines.contains(where:{$0.id == row.id}) { result.routines.append(row) }
            let cards = Set(result.workroom.cases.flatMap(\.links).filter { $0.kind == .card }.map(\.id)+result.routines.compactMap(\.sourceCardID))
            for row in original.cards where cards.contains(row.id) && !result.cards.contains(where:{$0.id == row.id}) { result.cards.append(row) }
            let drafts = Set(result.workroom.cases.compactMap { $0.preparation?.draftID })
            for row in original.workroom.drafts where drafts.contains(row.id) && !result.workroom.drafts.contains(where:{$0.id == row.id}) { result.workroom.drafts.append(row) }
        }
        if !conversations { result.conversations = [] };if !history { result.history = JournalArchive(events:[],annotations:[:]);result.preferences.saveHistory = false }
        if !quality { result.quality = QualityArchive() };if !settings { result.preferences = AppPreferences();result.preferences.saveHistory = !result.history.events.isEmpty }
        let keys = Set(result.workroom.cases.map { "事务:\($0.id)" }+result.workroom.drafts.map { "草稿:\($0.id)" }+result.cards.map { "信息卡:\($0.id)" }+result.routines.map { "待办:\($0.id)" }+result.conversations.map { "已存会话:\($0.id)" }+result.history.events.map { "事件:\($0.id)" })
        var extra = result.workroom.enhancements ?? WorkroomEnhancements();extra.filing = extra.filing.filter { keys.contains($0.key) };extra.lastDraftID = nil;extra.lastCaseID = nil;extra.autosave = false
        if !settings { extra.templates = [];extra.campus?.listOptions = .init();extra.campus?.caseFilter = nil;extra.campus?.includeDemo = nil;extra.campus?.lastJourneyID = nil }
        extra.campus?.recoveries = [];extra.campus?.recoverEdits = false
        if !cases || caseIDs != nil { extra.campus?.journeys = [];extra.campus?.lastJourneyID = nil }
        result.workroom.enhancements = extra
        try result.validate();return result
    }
}
extension GlobalSearchHit {
    func excerpt(for query:String) -> String {
        guard let range = detail.range(of:query,options:.caseInsensitive) else { return String(detail.prefix(180)) }
        let start = detail.index(range.lowerBound,offsetBy:-40,limitedBy:detail.startIndex) ?? detail.startIndex
        return (start == detail.startIndex ? "" : "…")+String(detail[start...].prefix(180))
    }
}
