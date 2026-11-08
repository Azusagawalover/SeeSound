import CryptoKit
import Foundation

enum WorkroomStage: Int, CaseIterable, Identifiable {
    case importing, reviewing, organizing, preparing
    var id: Int { rawValue }
    var title: String { switch self { case .importing: return "导入"; case .reviewing: return "核对"; case .organizing: return "整理"; case .preparing: return "事务" } }
    var heading: String { switch self { case .importing: return "先选一份材料"; case .reviewing: return "把原文看清楚"; case .organizing: return "选好范围，再整理"; case .preparing: return "挑选这件事要做什么" } }
}

enum CasePlanKind: String, Codable, CaseIterable, Identifiable {
    case material, step
    var id: String { rawValue }
    var title: String { self == .material ? "材料" : "步骤" }
}
enum CasePlanBasis: String, Codable {
    case stated, suggested
    var title: String { self == .stated ? "原文明示" : "建议步骤" }
}
struct CasePlanItem: Codable, Equatable, Identifiable {
    var kind: CasePlanKind
    var value: String
    var basis: CasePlanBasis
    var sourceID: UUID
    var quote: String
    var id: String { "\(kind.rawValue):\(sourceID):\(value):\(quote)" }
    enum CodingKeys: String, CodingKey { case kind, value, basis, quote; case sourceID = "source_id" }
    func validate(request: InsightRequest) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 100,
              !InsightEvidence.claimsAction(value), value.range(of: #"^(?:已|已经)(?:完成|确认|报名|提交|准备|携带|到场|参加)"#, options: .regularExpression) == nil,
              kind != .material || basis == .stated && quote.contains(value),
              !quote.isEmpty, quote.count <= 200, let turn = request.turns.first(where: { $0.id == sourceID }), turn.text.contains(quote) else { throw InsightError.invalid }
    }
}
struct CasePlan: Codable, Equatable {
    var title: String
    var items: [CasePlanItem]
    func validate(request: InsightRequest) throws {
        try request.validate()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 60,
              items.count <= 20, items.filter({ $0.kind == .material }).count <= 10,
              items.filter({ $0.kind == .step }).count <= 10, Set(items.map(\.id)).count == items.count else { throw InsightError.invalid }
        try items.forEach { try $0.validate(request: request) }
    }
}

enum LocalCasePlanner {
    static func propose(_ request: InsightRequest) throws -> CasePlan {
        try request.validate()
        var title = "待核对事务", items: [CasePlanItem] = []
        for turn in request.turns {
            if ["取消","改为","作废"].contains(where: turn.text.contains) { return CasePlan(title: title, items: []) }
            for raw in turn.text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, line.count <= 200 else { continue }
                if let range = line.range(of: #"^(?:活动|主题|事项)[:：]\s*"#, options: .regularExpression) {
                    let value = String(line[range.upperBound...]); if !value.isEmpty && value.count <= 60 { title = value }
                }
                if !["不要","不用","无需","不必","禁止","勿","不带","不能携带","不需要"].contains(where: line.contains),
                   let range = line.range(of: #"(?:所需材料[:：]|材料清单[:：]|材料[:：]|请带上|请携带|请带|需携带|需要携带|需带|携带)\s*"#, options: .regularExpression) {
                    let tail = String(line[range.upperBound...]).components(separatedBy: CharacterSet(charactersIn: "。；;！!"))[0]
                    let pieces = tail.components(separatedBy: "和").flatMap { $0.components(separatedBy: "、") }.flatMap { $0.components(separatedBy: "以及") }
                    for piece in pieces {
                        let value = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty && value.count <= 100 { items.append(.init(kind: .material, value: value, basis: .stated, sourceID: turn.id, quote: line)) }
                    }
                }
                if line.contains("报名截止") && ["待定","未定","询问","确认"].contains(where: line.contains) {
                    items.append(.init(kind: .step, value: "向组织者确认报名截止时间", basis: .suggested, sourceID: turn.id, quote: line))
                } else if let range = line.range(of: #"请(?=(?:询问|核对|确认|提交|填写|联系|归还))"#, options: .regularExpression) {
                    let value = String(line[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "。；; "))
                    if !value.isEmpty && value.count <= 100 { items.append(.init(kind: .step, value: value, basis: .stated, sourceID: turn.id, quote: line)) }
                }
            }
        }
        var seen = Set<String>(), counts: [CasePlanKind:Int] = [:]
        items = items.filter { row in
            guard seen.insert("\(row.kind):\(row.value)").inserted, counts[row.kind, default: 0] < 10 else { return false }
            counts[row.kind, default: 0] += 1; return true
        }
        let plan = CasePlan(title: title, items: items); try plan.validate(request: request); return plan
    }
}

struct ReviewedCaseItem: Identifiable, Equatable {
    var id = UUID()
    var kind: CasePlanKind
    var title: String
    var selected = true
    let proposal: CasePlanItem?
    var basisTitle: String { proposal.map { $0.basis.title + ($0.value == title ? "" : " · 已由你修改") } ?? "手动添加" }
}

struct CasePreparationSource: Codable, Equatable {
    var draftID: UUID
    var revision: Int
    var title: String
    var origin: ConversationOrigin
    var fingerprint: String
    var generator: String
    func validate() throws {
        guard (1...1_000_000).contains(revision), !title.isEmpty, title.count <= 60,
              fingerprint.count == 64, fingerprint.allSatisfy(\.isHexDigit), ["DeepSeek","本地规则"].contains(generator) else { throw DailyError.invalid }
    }
}

struct PreparedCaseDraft: Equatable {
    let id: UUID
    let source: CasePreparationSource
    let request: InsightRequest
    var title: String
    var note: String
    var items: [ReviewedCaseItem]
    init(draft: WorkroomDraft, request: InsightRequest, plan: CasePlan, generator: String) throws {
        try draft.validate(); try plan.validate(request: request)
        guard request.turns.allSatisfy({ draft.fragments.contains($0) }) else { throw WorkroomError.stale }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let fingerprint = SHA256.hash(data: try encoder.encode(request.turns)).map { String(format: "%02x",$0) }.joined()
        self.id = UUID(); self.request = request
        source = CasePreparationSource(draftID: draft.id, revision: draft.revision, title: draft.title, origin: draft.origin, fingerprint: fingerprint, generator: generator)
        try source.validate()
        title = plan.title; note = ""
        items = plan.items.map { ReviewedCaseItem(kind: $0.kind, title: $0.value, proposal: $0) }
    }
    func isFresh(_ draft: WorkroomDraft) -> Bool {
        draft.id == source.draftID && draft.revision == source.revision && draft.title == source.title && draft.origin == source.origin && request.turns.allSatisfy { draft.fragments.contains($0) }
    }
    func makeCase(current draft: WorkroomDraft) throws -> WorkroomCase {
        guard isFresh(draft) else { throw WorkroomError.stale }
        try source.validate(); try request.validate()
        let picked = items.filter(\.selected)
        guard !picked.isEmpty, picked.count <= 60, Set(items.map(\.id)).count == items.count else { throw DailyError.invalid }
        var item = WorkroomCase(); item.id = id; item.title = title; item.note = note
        item.demonstration = source.origin == .demonstration; item.preparation = source
        for row in picked {
            if let proposal = row.proposal { try proposal.validate(request: request); guard proposal.kind == row.kind else { throw DailyError.invalid } }
            var step = CaseStep(id: row.id, title: row.title)
            step.sourceQuote = row.proposal?.quote
            step.sourceLabel = row.proposal.map { source.generator + " · " + $0.basis.title + ($0.value == row.title ? "" : " · 用户修改") } ?? "用户手动添加"
            if row.kind == .material { item.materials.append(step) } else { item.steps.append(step) }
        }
        try item.validate(); return item
    }
}
