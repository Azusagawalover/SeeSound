import Foundation
import CryptoKit

enum WorkspaceUpgradeError: LocalizedError {
    case sourceLimit, duplicateSource, staleReview, missingSource, visualCapacity, inactive, protectedSource
    var errorDescription: String? {
        switch self {
        case .sourceLimit: return "每件事务最多 8 份材料，合计最多 48000 字。请先整理已有材料。"
        case .duplicateSource: return "这份材料的当前版本已经加入，不会重复添加。"
        case .staleReview: return "事务或材料已变化，请刷新对照后再确认。"
        case .missingSource: return "原材料当前不可用，请重新选择。"
        case .visualCapacity: return "保留原图的空间已达上限。可关闭保留原图，继续只保存文字。"
        case .protectedSource: return "这份材料已用于确认安排或变更记录，会保留作为核对依据。"
        case .inactive: return "请先重新打开或恢复这件事务，再更新安排。"
        }
    }
}
struct OCRTextRegion: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var confidence: Double?
    var alternatives: [String]?
    var recognitionPass: String?
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    func validate() throws {
        guard !text.isEmpty, text.count <= 12000, [x,y,width,height].allSatisfy(\.isFinite),
              (confidence.map { $0.isFinite && (0...1).contains($0) } ?? true), (alternatives ?? []).count <= 2, (alternatives ?? []).allSatisfy({ !$0.isEmpty && $0.count <= 12000 }), (recognitionPass?.count ?? 0) <= 30,
              x >= 0, y >= 0, width > 0, height > 0, x+width <= 1.001, y+height <= 1.001 else { throw DailyError.invalid }
    }
}
struct WorkroomVisualEvidence: Codable, Identifiable, Equatable {
    var id = UUID()
    var image: Data
    var regions: [OCRTextRegion]
    var originalText: String
    func validate() throws {
        guard !image.isEmpty, image.count <= 6_000_000, !regions.isEmpty, regions.count <= 600,
              Set(regions.map(\.id)).count == regions.count, originalText.count <= 12000,
              originalText == regions.map(\.text).joined(separator:"\n") else { throw DailyError.invalid }
        try regions.forEach { try $0.validate() }
    }
}
struct WorkroomReadResult {
    var text: String
    var visual: WorkroomVisualEvidence? = nil
}
struct CaseDocument: Codable, Identifiable, Equatable {
    var id = UUID()
    var draftID: UUID
    var revision: Int
    var title: String
    var text: String
    var origin: ConversationOrigin
    var addedAt = Date()
    var visualID: UUID?
    init(draft:WorkroomDraft) {
        draftID = draft.id;revision = draft.revision;title = draft.title;text = draft.text;origin = draft.origin;visualID = draft.visualID
    }
    var demonstration: Bool { origin == .demonstration }
    var asDraft:WorkroomDraft {
        var draft = WorkroomDraft();draft.id = id;draft.title = title;draft.text = text;draft.origin = origin;return draft
    }
    var key: String { "\(draftID):\(revision)" }
    func validate() throws {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, title.count <= 60,
              !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.count <= 12000,
              (1...1_000_000).contains(revision), addedAt.timeIntervalSince1970.isFinite else { throw DailyError.invalid }
    }
}
enum ArrangementKind: String, Codable, CaseIterable, Identifiable {
    case time, place, amount
    var id:String { rawValue }
    var title:String { switch self { case .time:return "时间";case .place:return "地点";case .amount:return "费用" } }
}
struct ConfirmedCaseFact: Codable, Equatable, Identifiable {
    var kind: ArrangementKind
    var value: String
    var documentID: UUID
    var quote: String
    var confirmedAt = Date()
    var id:String { kind.rawValue }
}
struct CaseChangeCandidate: Equatable, Identifiable {
    var kind: ArrangementKind
    var value: String
    var quote: String
    var date: Date?
    var id:String { kind.rawValue+":"+value+":"+quote }
}
struct CaseUpdateReceipt: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var documentID: UUID
    var generator: String
    var changes: [String]
}
struct CaseFollowUp: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var note: String
    var resumed: Bool
}
extension WorkroomCase {
    var documents:[CaseDocument] { sources ?? [] }
    var confirmedFacts:[ConfirmedCaseFact] { arrangements ?? [] }
    func reviewFingerprint() throws -> String {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data:try encoder.encode(self)).map { String(format:"%02x",$0) }.joined()
    }
    func validateDocuments() throws {
        guard documents.count <= 8, documents.map(\.text).joined().count <= 48000,
              Set(documents.map(\.id)).count == documents.count, Set(documents.map(\.key)).count == documents.count,
              documents.allSatisfy({ $0.demonstration == demonstration }), confirmedFacts.count <= 3,
              Set(confirmedFacts.map(\.kind)).count == confirmedFacts.count, (updates ?? []).count <= 20,Set((updates ?? []).map(\.id)).count == (updates ?? []).count else { throw WorkspaceUpgradeError.sourceLimit }
        try documents.forEach { try $0.validate() }
        for fact in confirmedFacts {
            guard !fact.value.isEmpty, fact.value.count <= 160, fact.quote.count <= 200, !fact.quote.isEmpty,
                  fact.confirmedAt.timeIntervalSince1970.isFinite,
                  documents.contains(where:{$0.id == fact.documentID && $0.text.contains(fact.quote)}) else { throw DailyError.invalid }
        }
        for update in updates ?? [] {
            guard update.date.timeIntervalSince1970.isFinite, update.generator.count <= 80, update.changes.count <= 6,
                  update.changes.allSatisfy({ $0.count <= 400 }),documents.contains(where:{$0.id == update.documentID}) else { throw DailyError.invalid }
        }
    }
    func priorValue(for kind:ArrangementKind,excluding documentID:UUID? = nil) -> String {
        if let fact = confirmedFacts.first(where:{$0.kind == kind}) { return fact.value }
        let values = documents.last(where:{$0.id != documentID}).map { CaseUpdateComparison.localCandidates(source:$0).filter { $0.kind == kind }.map(\.value) } ?? []
        if values.count == 1 { return values[0] }
        return values.isEmpty ? "尚未确认" : "原材料有多个候选，请对照全文"
    }
}
enum CaseUpdateComparison {
    static func localCandidates(source:CaseDocument,timeZone:TimeZone = .current) -> [CaseChangeCandidate] {
        var result:[CaseChangeCandidate] = []
        for field in KeyFieldReview.fields(source.text) {
            guard let kind = ArrangementKind.allCases.first(where:{$0.title == field.kind}) else { continue }
            var value = field.text
            if kind == .place, let delimiter = value.firstIndex(where:{$0 == ":" || $0 == "："}) { value = String(value[value.index(after:delimiter)...]).trimmingCharacters(in:.whitespaces) }
            guard !value.isEmpty, value.count <= 160 else { continue }
            result.append(.init(kind:kind,value:value,quote:field.text,date:kind == .time ? explicitDate(value,timeZone:timeZone) : nil))
        }
        var seen = Set<String>();return result.filter { seen.insert($0.id).inserted }
    }
    static func explicitDate(_ text:String,timeZone:TimeZone) -> Date? {
        let formatter = DateFormatter();formatter.locale = Locale(identifier:"en_US_POSIX");formatter.timeZone = timeZone;formatter.isLenient = false
        for format in ["yyyy-MM-dd HH:mm","yyyy/M/d HH:mm","yyyy年M月d日 HH:mm"] { formatter.dateFormat = format;if let value = formatter.date(from:text) { return value } };return nil
    }
    static func request(previous:CaseDocument?,incoming:CaseDocument) -> InsightRequest {
        let old = previous.map { Array($0.asDraft.fragments.prefix(3)) } ?? []
        return InsightRequest(turns:old+Array(incoming.asDraft.fragments.prefix(3)))
    }
    static func assistedCandidates(_ result:InsightResult,request:InsightRequest,incoming:CaseDocument) throws -> [CaseChangeCandidate] {
        try result.validate(request:request)
        let incomingIDs = Set(incoming.asDraft.fragments.prefix(3).map(\.id))
        return result.candidates.compactMap { candidate in
            guard incomingIDs.contains(candidate.sourceID),let kind = ArrangementKind(rawValue:candidate.kind.rawValue) else { return nil }
            if kind == .place && !candidate.quote.contains(candidate.value) { return nil }
            let value = kind == .amount ? candidate.value+" "+(candidate.currency ?? "") : kind == .time && !candidate.quote.contains(candidate.value) ? candidate.quote : candidate.value
            guard value.count <= 160 else { return nil }
            return .init(kind:kind,value:value,quote:candidate.quote,date:kind == .time ? explicitDate(candidate.quote,timeZone:TimeZone(identifier:request.timeZone) ?? .current) : nil)
        }
    }
}
struct CaptionTextChange: Equatable {
    enum Kind:Equatable { case unchanged, appended, rewritten }
    var kind:Kind
    var oldChanged:String
    var newChanged:String
    var prefix:String
    var suffix:String
    static func compare(old:String,new:String) -> CaptionTextChange {
        if old == new { return .init(kind:.unchanged,oldChanged:"",newChanged:"",prefix:new,suffix:"") }
        if new.hasPrefix(old) { return .init(kind:.appended,oldChanged:"",newChanged:String(new.dropFirst(old.count)),prefix:old,suffix:"") }
        let a = Array(old),b = Array(new);var prefix = 0,suffix = 0
        while prefix < min(a.count,b.count) && a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count,b.count)-prefix && a[a.count-1-suffix] == b[b.count-1-suffix] { suffix += 1 }
        return .init(kind:.rewritten,oldChanged:String(a[prefix..<(a.count-suffix)]),newChanged:String(b[prefix..<(b.count-suffix)]),prefix:String(b.prefix(prefix)),suffix:String(b.suffix(suffix)))
    }
}
struct WorkspaceOverview {
    var inbox:Int
    var dueToday:[WorkroomCase]
    var waiting:[WorkroomCase]
    var overdue:[WorkroomCase]
    static func make(drafts:[WorkroomDraft],cases:[WorkroomCase],now:Date,calendar:Calendar = .current) -> WorkspaceOverview {
        let ordinary = cases.filter { !$0.demonstration && $0.isActive }
        return .init(inbox:drafts.filter { !$0.demonstration && $0.inInbox == true }.count,
                     dueToday:ordinary.filter { $0.dueAt.map { calendar.isDate($0,inSameDayAs:now) } == true },
                     waiting:ordinary.filter { $0.workflow.disposition == .waiting },overdue:ordinary.filter { $0.overdue(at:now) })
    }
}
struct SearchDocumentSection: Identifiable {
    var id:String
    var title:String
    var text:String
}
enum SearchDocumentBuilder {
    static func sections(hit:GlobalSearchHit,drafts:[WorkroomDraft],cases:[WorkroomCase],conversations:[SavedConversation]) -> [SearchDocumentSection] {
        switch hit.kind {
        case .draft:
            guard let row = drafts.first(where:{$0.id == hit.recordID}) else { return [] }
            return row.text.components(separatedBy:.newlines).enumerated().map { .init(id:"line:\($0.offset)",title:"第 \($0.offset+1) 行",text:$0.element) }
        case .project:
            guard let row = cases.first(where:{$0.id == hit.recordID}) else { return [] }
            return [.init(id:"overview",title:row.title,text:row.note)] + row.materials.map { .init(id:$0.id.uuidString,title:"材料",text:$0.title) } + row.steps.map { .init(id:$0.id.uuidString,title:"步骤",text:$0.title) } + row.documents.flatMap { document in document.text.components(separatedBy:.newlines).enumerated().map { .init(id:"\(document.id):\($0.offset)",title:"来源 · "+document.title+" · 第 \($0.offset+1) 行",text:$0.element) } }
        case .conversation:
            return conversations.first(where:{$0.id == hit.recordID})?.turns.map { .init(id:$0.id.uuidString,title:$0.displayName,text:$0.text) } ?? []
        default: return [.init(id:"record",title:hit.title,text:hit.detail)]
        }
    }
}

extension LibrarySnapshot {
    func withoutLocalVisualReferences() -> LibrarySnapshot {
        var result = self
        if result.workroom.enhancements?.campus != nil {
            for i in result.workroom.enhancements!.campus!.journeys.indices {
                for j in result.workroom.enhancements!.campus!.journeys[i].documents.indices { result.workroom.enhancements!.campus!.journeys[i].documents[j].visualID = nil }
            }
        }
        for i in result.workroom.drafts.indices { result.workroom.drafts[i].visualID = nil }
        for i in result.workroom.cases.indices {
            if result.workroom.cases[i].sources != nil { for j in result.workroom.cases[i].sources!.indices { result.workroom.cases[i].sources![j].visualID = nil } }
        }
        if result.workroom.trash != nil {
            for i in result.workroom.trash!.indices {
                result.workroom.trash![i].draft?.visualID = nil
                if result.workroom.trash![i].project?.sources != nil { for j in result.workroom.trash![i].project!.sources!.indices { result.workroom.trash![i].project!.sources![j].visualID = nil } }
            }
        }
        return result
    }
}

struct CaseMaterialSuggestion:Equatable,Identifiable {
    var title:String
    var quote:String
    var id:String { title+":"+quote }
}
extension CaseUpdateComparison {
    static func materialSuggestions(source:CaseDocument,existing:[CaseStep]) -> [CaseMaterialSuggestion] {
        let existingNames = Set(existing.map { $0.title.trimmingCharacters(in:.whitespacesAndNewlines) })
        var rows:[CaseMaterialSuggestion] = [],seen = Set<String>()
        for raw in source.text.components(separatedBy:.newlines) {
            let line = raw.trimmingCharacters(in:.whitespacesAndNewlines)
            guard line.count <= 200,["材料","携带","请带","需带"].contains(where:line.contains) else { continue }
            let turn = InsightTurn(id:source.id,text:line,origin:source.origin),request = InsightRequest(turns:[turn])
            guard let plan = try? LocalCasePlanner.propose(request) else { continue }
            for material in plan.items where material.kind == .material && !existingNames.contains(material.value) && seen.insert(material.value).inserted {
                rows.append(.init(title:material.value,quote:material.quote))
            }
        }
        return Array(rows.prefix(10))
    }
}
