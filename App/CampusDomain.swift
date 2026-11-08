import Foundation
import CryptoKit

enum CampusError: LocalizedError {
    case invalid, stale, limit, consent, missing
    var errorDescription: String? {
        switch self {
        case .invalid: return "请检查标题、文字长度和来源摘录。"
        case .stale: return "内容已更新，请重新打开当前版本后确认。"
        case .limit: return "本机记录达到上限，请先整理已有内容。"
        case .consent: return "请先预览并确认要保存的内容。"
        case .missing: return "原记录当前不可用，保留的摘录仍可核对。"
        }
    }
}
enum JourneyStage: String, Codable, CaseIterable, Identifiable {
    case prepare, communicate, check, depart, followUp, finished, paused
    var id: String { rawValue }
    var title: String {
        switch self {
        case .prepare: return "准备材料"; case .communicate: return "现场沟通"
        case .check: return "核对安排"; case .depart: return "出发检查"
        case .followUp: return "办理后跟进"; case .finished: return "已结束"; case .paused: return "已暂停"
        }
    }
}
enum JourneyFactKind: String, Codable, CaseIterable, Identifiable {
    case time, place, fee, material, other
    var id: String { rawValue }
    var title: String { switch self { case .time:return "时间";case .place:return "地点";case .fee:return "费用";case .material:return "材料";case .other:return "其他约定" } }
}
struct JourneyQuestion: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var answer = ""
}
struct JourneyFact: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: JourneyFactKind
    var value: String
    var sourceID: UUID
    var quote: String
    var revision = 1
    var userConfirmedAt: Date?
    // This is a user-entered record, never an authenticated remote signature.
    var counterpartRecordedAt: Date?
    var superseded = false
    var isConfirmed: Bool { !superseded && userConfirmedAt != nil }
    mutating func revise(value: String, quote: String) {
        self.value = value; self.quote = quote; revision += 1
        userConfirmedAt = nil; counterpartRecordedAt = nil
    }
}
struct JourneyConversation: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var title: String
    var text: String
    var conversationID: UUID?
}
struct JourneyOutcome: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var note: String
    var nextAction: String
    var followUpCaseID: UUID?
}
struct CampusJourney: Codable, Equatable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var updatedAt = Date()
    var revision = 1
    var title: String
    var stage: JourneyStage = .prepare
    var resumeStage: JourneyStage?
    var demonstration = false
    var questions: [JourneyQuestion] = []
    var documents: [CaseDocument] = []
    var facts: [JourneyFact] = []
    var conversations: [JourneyConversation] = []
    var caseIDs: [UUID] = []
    var caseVersions:[String:String]?
    var outcomes: [JourneyOutcome] = []
    var plan: JourneyPlan?
    func validate() throws {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.count <= 60,
              (1...1_000_000).contains(revision),createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite,questions.count <= 30,documents.count <= 12,
              documents.map(\.text).joined().count <= 60000,facts.count <= 40,
              conversations.count <= 20,outcomes.count <= 30,caseIDs.count <= 30,
              Set(caseIDs).count == caseIDs.count,Set(questions.map(\.id)).count == questions.count,
              Set(documents.map(\.id)).count == documents.count,Set(documents.map(\.key)).count == documents.count,
              Set(facts.map(\.id)).count == facts.count,Set(conversations.map(\.id)).count == conversations.count,
              Set(outcomes.map(\.id)).count == outcomes.count,
              questions.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 200 && $0.answer.count <= 500 }),
              conversations.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 80 && !$0.text.isEmpty && $0.text.count <= 6000 && $0.date.timeIntervalSince1970.isFinite }),
              outcomes.allSatisfy({ !$0.note.isEmpty && $0.note.count <= 500 && $0.nextAction.count <= 200 && $0.date.timeIntervalSince1970.isFinite }),
              resumeStage != .paused else { throw CampusError.invalid }
        guard (caseVersions ?? [:]).count <= 30,(caseVersions ?? [:]).allSatisfy({ key,value in caseIDs.contains(where:{$0.uuidString == key}) && value.count == 64 && value.allSatisfy(\.isHexDigit) }) else { throw CampusError.invalid }
        try documents.forEach { try $0.validate(); guard $0.demonstration == demonstration else { throw WorkroomError.mixedSource } }
        try plan?.validate(in:self)
        for fact in facts {
            guard !fact.value.isEmpty,fact.value.count <= 300,!fact.quote.isEmpty,fact.quote.count <= 500,
                  (1...1_000_000).contains(fact.revision),documents.contains(where:{$0.id == fact.sourceID && $0.text.contains(fact.quote)}),
                  [fact.userConfirmedAt,fact.counterpartRecordedAt].compactMap({$0}).allSatisfy({$0.timeIntervalSince1970.isFinite}),
                  fact.counterpartRecordedAt == nil || fact.userConfirmedAt != nil else { throw CampusError.invalid }
            if !fact.superseded,let source = documents.first(where:{$0.id == fact.sourceID}),documents.contains(where:{$0.draftID == source.draftID && $0.revision > source.revision}) { throw CampusError.stale }
        }
    }
    func fingerprint() throws -> String { try WatchAgendaCodec.fingerprint(self) }
    mutating func attach(_ source: CaseDocument) throws {
        guard source.demonstration == demonstration else { throw WorkroomError.mixedSource }
        guard !documents.contains(where:{$0.key == source.key}) else { throw WorkspaceUpgradeError.duplicateSource }
        let priorIDs = Set(documents.filter { $0.draftID == source.draftID && $0.revision < source.revision }.map(\.id))
        for i in facts.indices where priorIDs.contains(facts[i].sourceID) {
            facts[i].superseded = true;facts[i].userConfirmedAt = nil;facts[i].counterpartRecordedAt = nil
        }
        documents.append(source)
    }
    func departure(cases: [WorkroomCase]) -> String {
        var lines = [demonstration ? "【演示办事单】"+title : "出发办事单 · "+title,"旅程第 \(revision) 版 · "+stage.title]
        let changes = changedCases(cases)
        if !changes.isEmpty { lines += ["关联事务有变化，以下已确认记录仍需出发前复核："]+changes }
        lines += facts.filter(\.isConfirmed).map { "\($0.kind.title)：\($0.value)" + ($0.counterpartRecordedAt == nil ? "（仅我已核对）" : "（用户记录对方已确认）") }
        let unresolved = facts.filter { !$0.isConfirmed }
        if !unresolved.isEmpty { lines += ["仍待核对："]+unresolved.map { $0.kind.title+"："+$0.value+($0.superseded ? "（旧版依据，需重新确认）" : "") } }
        lines += questions.filter { $0.answer.isEmpty }.map { "待询问："+$0.text }
        for id in caseIDs {
            guard let item = cases.first(where:{$0.id == id}) else { lines.append("关联事务当前不可用，请检查");continue }
            lines.append("事务："+item.title+" · "+item.stateTitle)
            lines += item.materials.map { ($0.done ? "☑ " : "□ ")+$0.title }
            lines += item.steps.filter { !$0.done }.map { "下一步："+$0.title }
        }
        return lines.joined(separator:"\n")
    }
    static func studentCardExample() -> CampusJourney {
        var result = CampusJourney(title:"补办学生证 · 示例",demonstration:true)
        result.questions = [.init(text:"在哪里提交材料？"),.init(text:"什么时候可以领取？")]
        var draft = WorkroomDraft();draft.title = "补办说明 · 示例";draft.origin = .demonstration
        draft.text = "【模拟通知，不代表学校实际规定】\n地点：学生服务中心一楼\n费用：10元\n材料：校园卡、证件照\n领取时间请向窗口确认。"
        let source = CaseDocument(draft:draft);result.documents = [source]
        result.facts = [.init(kind:.place,value:"学生服务中心一楼",sourceID:source.id,quote:"地点：学生服务中心一楼"),.init(kind:.fee,value:"10元",sourceID:source.id,quote:"费用：10元"),.init(kind:.material,value:"校园卡、证件照",sourceID:source.id,quote:"材料：校园卡、证件照")]
        return result
    }
}
struct CaseEditRecovery: Codable, Equatable, Identifiable {
    var id: UUID { item.id }
    var item: WorkroomCase
    var baseline: String?
    var date = Date()
    var saveLocally: Bool
}
struct CampusLedger: Codable, Equatable {
    var journeys: [CampusJourney] = []
    var lastJourneyID: UUID?
    var recoverEdits = false
    var recoveries: [CaseEditRecovery] = []
    var listOptions = CaseListOptions()
    var caseFilter:CaseFilter?
    var includeDemo:Bool?
    var workspace:CampusWorkspaceState?
    func validate() throws {
        guard journeys.count <= 30,Set(journeys.map(\.id)).count == journeys.count,
              recoveries.count <= 10,Set(recoveries.map(\.id)).count == recoveries.count,
              recoverEdits || recoveries.isEmpty,listOptions.folder.count <= 30,listOptions.tag.count <= 20 else { throw CampusError.limit }
        try journeys.forEach { try $0.validate() }
        try workspace?.validate()
        for recovery in recoveries { try recovery.item.validate();guard recovery.date.timeIntervalSince1970.isFinite,recovery.baseline == nil || recovery.baseline?.count == 64 else { throw CampusError.invalid } }
    }
}
struct NoticeCasePart: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var quote: String
    var dueAt: Date?
}
struct NoticeSplitPreview {
    var source: CaseDocument
    var fingerprint: String
    var parts: [NoticeCasePart]
    static func make(_ draft: WorkroomDraft) throws -> NoticeSplitPreview {
        try draft.validate();let source = CaseDocument(draft:draft)
        // Explicit paragraph/heading boundaries only; no invented deadlines or hidden API call.
        let sections = draft.text.components(separatedBy:"\n\n").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let chunks = sections.count > 1 ? sections : draft.text.components(separatedBy:.newlines).filter { $0.hasPrefix("事项") || $0.hasPrefix("任务") || $0.hasPrefix("【") }
        let parts = chunks.filter { $0.count <= 1200 }.prefix(10).map { text -> NoticeCasePart in
            let title = String((text.components(separatedBy:.newlines).first ?? text).prefix(60))
            let dates = CaseUpdateComparison.localCandidates(source:{var copy = source;copy.text = text;return copy}()).compactMap(\.date)
            return NoticeCasePart(title:title,quote:text,dueAt:dates.count == 1 ? dates[0] : nil)
        }
        return .init(source:source,fingerprint:try WatchAgendaCodec.fingerprint(draft),parts:Array(parts))
    }
}
struct EvidenceLocation: Equatable {
    var documentID: UUID
    var revision: Int
    var quote: String
    var firstLine: Int
    static func locate(quote: String, in document: CaseDocument) throws -> EvidenceLocation {
        guard !quote.isEmpty,let range = document.text.range(of:quote) else { throw CampusError.missing }
        let line = document.text[..<range.lowerBound].filter { $0 == "\n" }.count
        return .init(documentID:document.id,revision:document.revision,quote:quote,firstLine:line)
    }
}
enum ShareRedaction {
    static func apply(_ text:String,terms:[String],identifiers:Bool) -> String {
        var result = text
        if identifiers {
            for pattern in [#"(?<!\d)1[3-9]\d{9}(?!\d)"#,#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,#"(?<!\d)\d{17}[\dXx](?!\d)"#] {
                if let regex = try? NSRegularExpression(pattern:pattern) { result = regex.stringByReplacingMatches(in:result,range:NSRange(result.startIndex...,in:result),withTemplate:"[已隐藏]") }
            }
        }
        for term in terms.map({$0.trimmingCharacters(in:.whitespacesAndNewlines)}).filter({!$0.isEmpty}).sorted(by:{$0.count > $1.count}) { result = result.replacingOccurrences(of:term,with:"[已隐藏]") }
        return result
    }
}

@MainActor extension WorkroomService {
    var campus: CampusLedger { enhancements.campus ?? CampusLedger() }
    func putJourney(_ journey: CampusJourney, baseline: String? = nil) throws {
        try journey.validate()
        let old = campus.journeys.first { $0.id == journey.id }
        if let old { guard baseline == (try old.fingerprint()),old.demonstration == journey.demonstration else { throw CampusError.stale } }
        else { guard baseline == nil else { throw CampusError.stale } }
        var next = journey
        if let old {
            next.revision = old.revision+1;next.updatedAt = Date()
            let changedQuestions = Set(old.questions.filter { previous in
                guard let current = next.questions.first(where:{$0.id == previous.id}) else { return true }
                return current.text != previous.text || current.answer != previous.answer
            }.map(\.id))
            // A manual answer snapshot uses its question ID as the source identity.
            let answerSources = Set(next.documents.filter{changedQuestions.contains($0.draftID)}.map(\.id))
            for index in next.facts.indices where answerSources.contains(next.facts[index].sourceID) {
                next.facts[index].superseded = true
                next.facts[index].userConfirmedAt = nil;next.facts[index].counterpartRecordedAt = nil
            }
        }
        try next.validate()
        try updateEnhancements { extra in
            var ledger = extra.campus ?? .init();ledger.journeys.removeAll { $0.id == next.id };ledger.journeys.insert(next,at:0);ledger.lastJourneyID = next.id;extra.campus = ledger
        }
    }
    func changeJourney(_ id:UUID,_ change:(inout CampusJourney)throws->Void) throws {
        guard var item = campus.journeys.first(where:{$0.id == id}) else { throw CampusError.missing }
        let baseline = try item.fingerprint();try change(&item);try putJourney(item,baseline:baseline)
    }
    func removeJourney(_ id:UUID) throws {
        try updateEnhancements { extra in var ledger = extra.campus ?? .init();ledger.journeys.removeAll { $0.id == id };if ledger.lastJourneyID == id { ledger.lastJourneyID = nil };ledger.workspace?.bookmarks.removeAll{$0.journeyID == id};ledger.workspace?.favoriteJourneyIDs.removeAll{$0 == id};ledger.workspace?.watchSeenVersions.removeValue(forKey:id.uuidString);extra.campus = ledger }
    }
    func confirmJourneyFact(_ journeyID:UUID,factID:UUID,revision:Int,counterpart:Bool) throws {
        guard let journey = campus.journeys.first(where:{$0.id == journeyID}),journey.changedCases(cases).isEmpty else { throw CampusError.stale }
        try changeJourney(journeyID) { item in
            guard let index = item.facts.firstIndex(where:{$0.id == factID}),item.facts[index].revision == revision,!item.facts[index].superseded else { throw CampusError.stale }
            if counterpart { guard item.facts[index].userConfirmedAt != nil else { throw CampusError.consent };item.facts[index].counterpartRecordedAt = Date() }
            else { item.facts[index].userConfirmedAt = Date() }
        }
    }
    func captureRecovery(_ item:WorkroomCase,baseline:String?,saveLocally:Bool) throws {
        guard campus.recoverEdits else { return };try item.validate()
        try updateEnhancements { extra in var ledger = extra.campus ?? .init();ledger.recoveries.removeAll { $0.id == item.id };ledger.recoveries.insert(.init(item:item,baseline:baseline,saveLocally:saveLocally),at:0);ledger.recoveries = Array(ledger.recoveries.prefix(10));extra.campus = ledger }
    }
    func clearRecovery(_ id:UUID) throws {
        guard campus.recoveries.contains(where:{$0.id == id}) else { return }
        try updateEnhancements { $0.campus?.recoveries.removeAll { $0.id == id } }
    }
    func restoreRecovery(_ recovery:CaseEditRecovery) throws {
        let current = cases.first { $0.id == recovery.id }
        guard recovery.baseline == (try current.map { try $0.reviewFingerprint() }) else { throw CampusError.stale }
        try putCase(recovery.item,saveLocally:recovery.saveLocally,discardRecovery:true)
    }
}

extension LibrarySnapshot {
    func handoff(journeyID:UUID) throws -> LibrarySnapshot {
        guard let journey = workroom.enhancements?.campus?.journeys.first(where:{$0.id == journeyID}) else { throw CampusError.missing }
        var result = LibrarySnapshot()
        for id in journey.caseIDs where workroom.cases.contains(where:{$0.id == id}) {
            let subset = try handoff(caseID:id)
            for item in subset.workroom.cases where !result.workroom.cases.contains(where:{$0.id == item.id}) { result.workroom.cases.append(item) }
            for row in subset.routines where !result.routines.contains(where:{$0.id == row.id}) { result.routines.append(row) }
            for row in subset.cards where !result.cards.contains(where:{$0.id == row.id}) { result.cards.append(row) }
        }
        let draftIDs = Set(journey.documents.map(\.draftID)+result.workroom.cases.compactMap{$0.preparation?.draftID})
        result.workroom.drafts = workroom.drafts.filter { draftIDs.contains($0.id) }
        let conversationIDs = Set(journey.conversations.compactMap(\.conversationID));result.conversations = conversations.filter { conversationIDs.contains($0.id) }
        var ledger = CampusLedger();ledger.journeys = [journey];ledger.lastJourneyID = journey.id
        var extra = WorkroomEnhancements();extra.campus = ledger;result.workroom.enhancements = extra
        try result.validate();return result
    }
}

struct CaseAffectedRow:Identifiable {
    var id:UUID
    var title:String
    var reasons:[String]
}
extension CaseUpdateComparison {
    static func affectedRows(item:WorkroomCase,changes:[CaseChangeCandidate]) -> [CaseAffectedRow] {
        (item.materials+item.steps).compactMap { row in
            let evidence = row.title+"\n"+(row.sourceQuote ?? "")
            let reasons = changes.compactMap { change -> String? in
                guard let old = item.confirmedFacts.first(where:{$0.kind == change.kind}),old.value != change.value,evidence.contains(old.value) else { return nil }
                return change.kind.title+"由“"+old.value+"”改为“"+change.value+"”，原项目仍保留，请核对。"
            }
            return reasons.isEmpty ? nil : .init(id:row.id,title:row.title,reasons:reasons)
        }
    }
}

private struct JourneyCaseVersion:Encodable {
    var title:String
    var note:String
    var dueAt:Date?
    var sources:[String]
    var facts:[String]
    var rows:[String]
    var waitingFor:String
}
extension WorkroomCase {
    /// Information version excludes completion ticks and Watch receipts.
    func journeyVersion() throws -> String {
        try WatchAgendaCodec.fingerprint(JourneyCaseVersion(title:title,note:note,dueAt:dueAt,
            sources:documents.map { "\($0.draftID):\($0.revision):\($0.title):\($0.text)" },
            facts:confirmedFacts.map { "\($0.kind.rawValue):\($0.value):\($0.quote)" },
            rows:(materials+steps).map { "\($0.id):\($0.title):\($0.sourceQuote ?? "")" },waitingFor:workflow.waitingFor))
    }
}
extension CampusJourney {
    func changedCases(_ cases:[WorkroomCase]) -> [String] {
        caseIDs.compactMap { id in
            guard let item = cases.first(where:{$0.id == id}) else { return "关联事务当前不可用" }
            return (try? item.journeyVersion()) == caseVersions?[id.uuidString] ? nil : item.title+" · 安排或材料已有变化，请复核"
        }
    }
}
extension CampusLedger {
    mutating func invalidateFacts(before:WorkroomCase?,after:WorkroomCase) throws {
        guard let before,try before.journeyVersion() != after.journeyVersion() else { return }
        let changed = Set(after.confirmedFacts.filter { next in before.confirmedFacts.first(where:{$0.kind == next.kind})?.value != next.value }.map(\.kind))
        for index in journeys.indices where journeys[index].caseIDs.contains(after.id) {
            var didChange = false
            if journeys[index].caseVersions?[after.id.uuidString] == nil {
                var versions = journeys[index].caseVersions ?? [:];versions[after.id.uuidString] = try before.journeyVersion();journeys[index].caseVersions = versions;didChange = true
            }
            for i in journeys[index].facts.indices {
                let fact = journeys[index].facts[i]
                let kind:ArrangementKind? = fact.kind == .time ? .time : fact.kind == .place ? .place : fact.kind == .fee ? .amount : nil
                guard let kind,changed.contains(kind),let source = journeys[index].documents.first(where:{$0.id == fact.sourceID}),before.documents.contains(where:{$0.draftID == source.draftID}) else { continue }
                journeys[index].facts[i].superseded = true;journeys[index].facts[i].userConfirmedAt = nil;journeys[index].facts[i].counterpartRecordedAt = nil;didChange = true
            }
            if didChange { journeys[index].revision += 1;journeys[index].updatedAt = Date() }
        }
    }
}
@MainActor extension WorkroomService {
    func linkCaseToJourney(_ caseID:UUID,journeyID:UUID) throws {
        guard let project = cases.first(where:{$0.id == caseID}) else { throw CampusError.missing }
        try changeJourney(journeyID) { journey in
            guard journey.demonstration == project.demonstration,!journey.caseIDs.contains(caseID) else { throw CampusError.invalid }
            journey.caseIDs.append(caseID);var versions = journey.caseVersions ?? [:];versions[caseID.uuidString] = try project.journeyVersion();journey.caseVersions = versions
        }
    }
    func acknowledgeJourneyCases(_ id:UUID) throws {
        try changeJourney(id) { journey in
            var versions:[String:String] = [:]
            for id in journey.caseIDs { if let item = cases.first(where:{$0.id == id}) { versions[id.uuidString] = try item.journeyVersion() } }
            journey.caseVersions = versions
        }
    }
}
