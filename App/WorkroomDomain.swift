import CryptoKit
import Foundation

enum WorkroomError: LocalizedError {
    case empty, tooLarge, unreadable, stale, mixedSource, reviewRequired, incomplete
    var errorDescription: String? {
        switch self {
        case .incomplete: return "请先处理所有材料、步骤和关联待办，再标记事务完成。"
        case .empty: return "没有可处理的文字，请输入或换一份材料。"
        case .tooLarge: return "材料超过限制：文字最多 12000 字、文件最多 20 MB、PDF 每次最多读取 12 页。请选择较短材料或较少页面。"
        case .unreadable: return "未能读取文字。请使用清晰图片、UTF-8 文本或未加密 PDF。"
        case .stale: return "原文已变化，请重新选择文字；旧结果仅可用于对照。"
        case .mixedSource: return "演示材料与普通事务分开保存，请选择来源一致的内容。"
        case .reviewRequired: return "请先检查所选材料和步骤，再确认建立事务。"
        }
    }
}

struct TextRevision: Codable, Identifiable, Equatable {
    var id = UUID()
    var number: Int
    var text: String
    var date: Date
}

struct WorkroomDraft: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "未命名材料"
    var text = ""
    var origin: ConversationOrigin = .typed
    var updatedAt = Date()
    var revision = 1
    var history: [TextRevision] = []
    var inInbox: Bool?
    var visualID: UUID?
    var exampleGroup: UUID?
    var demonstration: Bool { origin == .demonstration }
    func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkroomError.empty }
        guard exampleGroup == nil || demonstration else { throw RecoveryExperienceError.invalidExample }
        guard text.count <= 12000 else { throw WorkroomError.tooLarge }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 60,
              (1...1_000_000).contains(revision), updatedAt.timeIntervalSince1970.isFinite, history.count <= 6,
              Set(history.map(\.id)).count == history.count,
              history.allSatisfy({ (1..<revision).contains($0.number) && $0.text.count <= 12000 && $0.date.timeIntervalSince1970.isFinite }) else { throw DailyError.invalid }
    }
    func edited(title: String, text: String, at date: Date = Date()) throws -> WorkroomDraft {
        var copy = self
        if text != self.text {
            guard revision < 1_000_000 else { throw DailyError.capacity }
            if !self.text.isEmpty { copy.history.append(TextRevision(number: revision, text: self.text, date: updatedAt)) }
            copy.history = Array(copy.history.suffix(6)); copy.revision += 1
        }
        copy.title = title; copy.text = text; copy.updatedAt = date
        try copy.validate(); return copy
    }
    var fragments: [InsightTurn] {
        var pieces: [String] = [], current = ""
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if !current.isEmpty && current.count + line.count + 1 > 500 { pieces.append(current); current = "" }
            var remainder = line
            while remainder.count > 500 { if !current.isEmpty { pieces.append(current); current = "" }; pieces.append(String(remainder.prefix(500))); remainder = String(remainder.dropFirst(500)) }
            if !remainder.isEmpty { current += (current.isEmpty ? "" : "\n") + remainder }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.enumerated().map { index, value in
            let hash = SHA256.hash(data: Data("\(id):\(revision):\(index):\(value)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            let uuid = "\(hash.prefix(8))-\(hash.dropFirst(8).prefix(4))-\(hash.dropFirst(12).prefix(4))-\(hash.dropFirst(16).prefix(4))-\(hash.suffix(12))"
            return InsightTurn(id: UUID(uuidString: uuid)!, text: value, origin: origin)
        }
    }
    static func demonstrationDraft() -> WorkroomDraft {
        var draft = WorkroomDraft(); draft.title = "演示 · 读书会通知"; draft.origin = .demonstration
        draft.text = "【演示通知】\n活动：校园读书会\n时间：2026-10-30 15:00\n地点：图书馆二楼\n材料费：12元人民币\n联系电话：+1 (202) 555-0147\n请带学生证和一本喜欢的书。\n报名截止时间待定，请询问组织者。"
        return draft
    }
}

struct TextComparison {
    let old: String
    let new: String
    var removed: [String] { lines(new).difference(from: lines(old)).compactMap { change -> (Int,String)? in if case let .remove(offset,element,_) = change { return (offset,element) }; return nil }.sorted { $0.0 < $1.0 }.map(\.1) }
    var added: [String] { lines(new).difference(from: lines(old)).compactMap { change -> (Int,String)? in if case let .insert(offset,element,_) = change { return (offset,element) }; return nil }.sorted { $0.0 < $1.0 }.map(\.1) }
    private func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).filter { !$0.isEmpty } }
}

struct InsightQuestion: Codable, Identifiable, Equatable {
    var kind: InsightKind
    var question: String
    var sourceID: UUID
    var quote: String
    var id: String { "\(sourceID):\(kind.rawValue):\(question)" }
    enum CodingKeys: String, CodingKey { case kind, question, quote; case sourceID = "source_id" }
    func validate(request: InsightRequest) throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.count <= 100,
              !quote.isEmpty, quote.count <= 200, let turn = request.turns.first(where: { $0.id == sourceID }), turn.text.contains(quote) else { throw InsightError.invalid }
    }
}

enum LocalTextOrganizer {
    static func organize(_ request: InsightRequest) throws -> InsightResult {
        try request.validate()
        var candidates: [InsightCandidate] = []
        for turn in request.turns {
            for amount in InsightEvidence.amounts(in: turn.text) {
                candidates.append(.init(kind: .amount, value: amount.value, sourceID: turn.id, quote: amount.quote, dateISO: nil, currency: amount.currency))
            }
            if turn.text.contains("电话") || turn.text.contains("号码") || turn.text.contains("联系") {
                for phone in matches(#"\+?[0-9][0-9() -]{5,38}[0-9]"#, turn.text) {
                    let digits = phone.filter(\.isNumber)
                    guard (7...20).contains(digits.count), phone.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil else { continue }
                    candidates.append(.init(kind: .phone, value: phone.trimmingCharacters(in: .whitespaces), sourceID: turn.id, quote: phone, dateISO: nil))
                }
            }
            for line in turn.text.components(separatedBy: .newlines) {
                if let r = line.range(of: #"(?:地点|地址|会场)[:：]\s*"#, options: .regularExpression) {
                    let place = String(line[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !place.isEmpty && place.count <= 100 && !["未定","待定","不确定"].contains(where: place.contains) {
                        candidates.append(.init(kind: .place, value: place, sourceID: turn.id, quote: String(line.prefix(200)), dateISO: nil))
                    }
                }
                for literal in matches(#"\d{4}[-/]\d{1,2}[-/]\d{1,2}\s+\d{1,2}:\d{2}"#, line) {
                    if let date = parseDate(literal, timeZone: request.timeZone) {
                        candidates.append(.init(kind: .time, value: literal, sourceID: turn.id, quote: literal, dateISO: ISO8601DateFormatter().string(from: date)))
                    }
                }
            }
        }
        var seen = Set<String>(); candidates = candidates.filter { seen.insert($0.id).inserted }
        // Offline rules do not resolve conflicting or cancelled arrangements.
        if request.turns.contains(where: { ["取消","改为","改成","作废"].contains(where: $0.text.contains) }) { candidates = []; }
        let result = InsightResult(version: 1, provider: "LocalRules", model: "explicit-text-v1",
            summary: "本地规则只提取明确格式的日期、带币种金额、标记地点及电话；不理解改约或复杂上下文，请逐项核对。",
            candidates: Array(candidates.prefix(8)), replies: [], questions: questions(request: request, candidates: candidates),
            casePlan: request.includeCasePlan == true ? try LocalCasePlanner.propose(request) : nil)
        try result.validate(request: request); return result
    }
    static func questions(request: InsightRequest, candidates: [InsightCandidate]) -> [InsightQuestion] {
        var questions: [InsightQuestion] = []
        for turn in request.turns {
            let quote = String(turn.text.prefix(200))
            if ["时间待定","时间未定","日期待定","哪天","有空再约"].contains(where: turn.text.contains) {
                questions.append(.init(kind: .time, question: turn.text.contains("报名截止") ? "报名截止的具体日期和时间是什么？" : "还没确定的具体日期和时间是什么？", sourceID: turn.id, quote: quote))
            }
            if candidates.contains(where: { $0.sourceID == turn.id && $0.kind == .time && $0.date == nil }) {
                questions.append(.init(kind: .time, question: "请确认这句话对应的完整日期和时间。", sourceID: turn.id, quote: quote))
            }
            if turn.text.range(of: #"(?:地点|地方)[:：\s]*(?:还没定|没定|待定|未定)"#, options: .regularExpression) != nil {
                questions.append(.init(kind: .place, question: "具体地点在哪里？", sourceID: turn.id, quote: quote))
            }
        }
        return Array(questions.prefix(4))
    }
    private static func matches(_ pattern: String, _ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
    private static func parseDate(_ text: String, timeZone: String) -> Date? {
        let values = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard values.count == 5, (1900...2200).contains(values[0]), (1...12).contains(values[1]), (1...31).contains(values[2]), (0...23).contains(values[3]), (0...59).contains(values[4]) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZone)!
        let components = DateComponents(year: values[0], month: values[1], day: values[2], hour: values[3], minute: values[4])
        guard let date = calendar.date(from: components), calendar.dateComponents([.year,.month,.day,.hour,.minute], from: date) == components else { return nil }
        return date
    }
}

struct CaseStep: Codable, Identifiable, Equatable {
    var id = UUID(); var title: String; var done = false
    var sourceQuote: String?
    var sourceLabel: String?
    var renamedByUser: Bool?
}
struct CaseLink: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case card, routine }
    var id: UUID
    var kind: Kind
    var snapshot: String
    var revision: Int?
    var demonstration = false
}
struct WorkroomCase: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "新事务"
    var note = ""
    var demonstration = false
    var createdAt = Date()
    var materials: [CaseStep] = []
    var steps: [CaseStep] = []
    var links: [CaseLink] = []
    var preparation: CasePreparationSource?
    var dueAt: Date?
    var reminderAt: Date?
    var priority: RoutinePriority?
    var pinned: Bool?
    var archivedAt: Date?
    var completedAt: Date?
    var watchSeenAt: Date?
    var watchSeenVersion:String?
    var flow: CaseFlow?
    var sources: [CaseDocument]?
    var exampleGroup: UUID?
    var arrangements: [ConfirmedCaseFact]?
    var updates: [CaseUpdateReceipt]?
    var isArchived: Bool { archivedAt != nil }
    var isCompleted: Bool { completedAt != nil }
    var isActive: Bool { !isArchived && !isCompleted }
    var isPinned: Bool { pinned == true }
    func overdue(at now: Date) -> Bool { isActive && dueAt.map { $0 <= now } == true }
    var stateTitle: String { isArchived ? "已归档" : isCompleted ? "已完成" : workflow.disposition.title }
    func nextAction(routines: [RoutineItem]) -> String? {
        if workflow.disposition == .waiting { return "等待：" + (workflow.waitingFor.isEmpty ? "对方回复" : workflow.waitingFor) }
        if workflow.disposition == .deferred, workflow.resumeAt.map({ $0 > Date() }) != false { return "暂缓，稍后继续" }
        if let material = materials.first(where: { !$0.done && blockedBy($0).isEmpty }) { return "准备：" + material.title }
        if let step = steps.first(where: { !$0.done && blockedBy($0).isEmpty }) { return step.title }
        if let link = links.first(where: { link in link.kind == .routine && !routines.contains { $0.id == link.id && $0.completed } }) { return "处理关联待办：" + link.snapshot }
        return nil
    }
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 60, note.count <= 500,
              createdAt.timeIntervalSince1970.isFinite, materials.count <= 30, steps.count <= 30, links.count <= 50,
              Set((materials + steps).map(\.id)).count == materials.count + steps.count,
              Set(links.map { "\($0.kind):\($0.id)" }).count == links.count,
              (materials + steps).allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 100 && ($0.sourceQuote?.count ?? 0) <= 200 && ($0.sourceLabel?.count ?? 0) <= 80 }),
              links.allSatisfy({ $0.demonstration == demonstration && !$0.snapshot.isEmpty && $0.snapshot.count <= 300 && ($0.kind != .card || $0.revision.map { (1...1_000_000).contains($0) } == true) }) else { throw DailyError.invalid }
        guard watchSeenVersion == nil || (watchSeenVersion?.count == 64 && watchSeenVersion!.allSatisfy(\.isHexDigit)) else { throw DailyError.invalid }
        for date in [dueAt, reminderAt, archivedAt, completedAt,watchSeenAt].compactMap({ $0 }) {
            guard date.timeIntervalSince1970.isFinite, (1900...2200).contains(Calendar.current.component(.year, from: date)) else { throw DailyError.invalid }
        }
        guard exampleGroup == nil || demonstration else { throw RecoveryExperienceError.invalidExample }
        try validateFlow();try validateDocuments()
        if let completedAt, completedAt < createdAt { throw DailyError.invalid }
        if let preparation { try preparation.validate(); guard (preparation.origin == .demonstration) == demonstration else { throw WorkroomError.mixedSource } }
    }
    func progress(routines: [RoutineItem]) -> (done: Int, total: Int) {
        let taskLinks = links.filter { $0.kind == .routine }
        return ((steps + materials).filter(\.done).count + taskLinks.filter { link in routines.contains { $0.id == link.id && $0.completed } }.count,
                steps.count + materials.count + taskLinks.count)
    }
    func export(routines: [RoutineItem]) -> String {
        var lines = [demonstration ? "【演示事务】\(title)" : title, note]
        lines.append("状态：" + stateTitle)
        if priority == .important { lines.append("优先级：重要") }
        if let dueAt { lines.append("截止时间：" + dueAt.formatted(date: .abbreviated, time: .shortened)) }
        if let reminderAt { lines.append("手动设置的提醒时间：" + reminderAt.formatted(date: .abbreviated, time: .shortened)) }
        if let preparation { lines.append("草稿来源：\(preparation.generator)，\(preparation.title) 第 \(preparation.revision) 版；由用户预览后建立。") }
        for (kind,rows) in [("材料",materials),("步骤",steps)] {
            for row in rows {
                lines.append("\(kind) \(row.done ? "☑" : "□") \(row.title)")
                if row.renamedByUser == true { lines.append("  名称由用户修改，原依据保留。") }
                if let label=row.sourceLabel { lines.append("  来源："+label) }
                if let quote=row.sourceQuote { lines.append("  建立时依据："+quote) }
            }
        }
        lines += links.map { "关联 \($0.kind == .card ? "信息卡" : "待办")：\($0.snapshot)" }
        return lines.filter { !$0.isEmpty }.joined(separator:"\n")
    }
}

enum TranslationLanguage: String, Codable, CaseIterable, Identifiable {
    case chinese = "zh-Hans", english = "en", japanese = "ja", korean = "ko"
    var id: String { rawValue }
    var title: String { switch self { case .chinese: return "中文"; case .english: return "English"; case .japanese: return "日本語"; case .korean: return "한국어" } }
    var voice: String { switch self { case .chinese: return "zh-CN"; case .english: return "en-US"; case .japanese: return "ja-JP"; case .korean: return "ko-KR" } }
}
struct TranslationRequest: Codable, Equatable {
    var version = 1
    var sourceID = UUID()
    var text: String
    var target: TranslationLanguage
    var origin: ConversationOrigin
    enum CodingKeys: String, CodingKey { case version, text, target, origin; case sourceID = "source_id" }
    func validate() throws {
        guard version == 1, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 1500 else { throw InsightError.invalid }
    }
}
struct TranslationResult: Codable {
    var version: Int
    var provider: String
    var model: String
    var sourceID: UUID
    var target: TranslationLanguage
    var text: String
    enum CodingKeys: String, CodingKey { case version, provider, model, target, text; case sourceID = "source_id" }
    func validate(request: TranslationRequest) throws {
        try request.validate()
        guard version == 1, provider == "DeepSeek", !model.isEmpty, model.count <= 80, sourceID == request.sourceID, target == request.target,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 3000 else { throw InsightError.invalid }
    }
}


enum CaseFilter: String, Codable, CaseIterable, Identifiable {
    case active, waiting, deferred, today, overdue, completed, archived, all
    var id: String { rawValue }
    var title: String {
        switch self { case .waiting:return "等待回复";case .deferred:return "暂缓";case .active: return "进行中"; case .today: return "今天到期"; case .overdue: return "已到期"; case .completed: return "已完成"; case .archived: return "已归档"; case .all: return "全部" }
    }
}
extension WorkroomCase {
    static func select(_ items: [WorkroomCase], query: String, filter: CaseFilter, includeDemonstrations: Bool, now: Date, calendar: Calendar = .current) -> [WorkroomCase] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            let matchesText = query.isEmpty || ([item.title,item.note] + (item.materials + item.steps).map(\.title) + item.links.map(\.snapshot)).contains { $0.localizedCaseInsensitiveContains(query) }
            let matchesFilter: Bool
            switch filter {
            case .waiting: matchesFilter = item.isActive && item.workflow.disposition == .waiting
            case .deferred: matchesFilter = item.isActive && item.workflow.disposition == .deferred
            case .active: matchesFilter = item.isActive
            case .today: matchesFilter = item.isActive && item.dueAt.map { calendar.isDate($0, inSameDayAs: now) } == true
            case .overdue: matchesFilter = item.overdue(at: now)
            case .completed: matchesFilter = item.isCompleted && !item.isArchived
            case .archived: matchesFilter = item.isArchived
            case .all: matchesFilter = true
            }
            return matchesText && matchesFilter && (includeDemonstrations || !item.demonstration)
        }.sorted { a,b in
            if a.isPinned != b.isPinned { return a.isPinned }
            if a.overdue(at: now) != b.overdue(at: now) { return a.overdue(at: now) }
            if (a.priority == .important) != (b.priority == .important) { return a.priority == .important }
            if a.dueAt != b.dueAt { return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture) }
            return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id.uuidString < b.id.uuidString
        }
    }
}

struct ScheduledDestination: Identifiable, Equatable {
    enum Kind: String { case routine, project }
    var kind: Kind
    var recordID: UUID
    var id: String { kind.rawValue + ":" + recordID.uuidString }
    static func parse(kind: String?, id: String?) -> ScheduledDestination? {
        guard let kind, let type = Kind(rawValue: kind), let id, let uuid = UUID(uuidString: id) else { return nil }
        return .init(kind: type, recordID: uuid)
    }
}
struct ScheduledNotice: Equatable, Identifiable {
    var destination: ScheduledDestination
    var date: Date
    var id: String { "seesound-agenda-" + destination.kind.rawValue + "-" + destination.recordID.uuidString }
}
enum AgendaPlanner {
    // Leave room for event reminders (at most 30) below iOS's pending notification limit.
    static let limit = 24
    static func notices(routines: [RoutineItem], savedRoutineIDs: Set<UUID>, cases: [WorkroomCase], savedCaseIDs: Set<UUID>, now: Date) -> [ScheduledNotice] {
        var notices = routines.compactMap { item -> ScheduledNotice? in
            guard savedRoutineIDs.contains(item.id), !item.isDemonstration, !item.completed, let date = item.reminderAt, date > now else { return nil }
            return .init(destination: .init(kind: .routine, recordID: item.id), date: date)
        }
        notices += cases.compactMap { item -> ScheduledNotice? in
            guard savedCaseIDs.contains(item.id), !item.demonstration, item.isActive, let date = item.reminderAt, date > now else { return nil }
            return .init(destination: .init(kind: .project, recordID: item.id), date: date)
        }
        return notices.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
    }
}


enum ReminderForegroundPolicy {
    static func suppress(eventID: String?, activeEventID: UUID?) -> Bool {
        guard let eventID, let activeEventID else { return false }
        return eventID == activeEventID.uuidString
    }
}
