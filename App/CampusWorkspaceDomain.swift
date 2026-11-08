import Foundation

enum CampusScenario:String,Codable,CaseIterable,Identifiable {
    case certificate, clinic, counter, activity
    var id:String { rawValue }
    var title:String { switch self { case .certificate:return "补办证件";case .clinic:return "就医沟通";case .counter:return "窗口咨询";case .activity:return "活动报名" } }
    var symbol:String { switch self { case .certificate:return "person.text.rectangle";case .clinic:return "cross.case";case .counter:return "person.bubble";case .activity:return "ticket" } }
    var questions:[String] {
        switch self {
        case .certificate:return ["在哪里提交申请？","需要哪些材料和费用？","什么时候、在哪里领取？"]
        case .clinic:return ["应该到哪个窗口或科室？","接下来需要做什么准备？","何时查看结果或复诊？"]
        case .counter:return ["这项业务在这里办理吗？","需要补充哪些材料？","办理后怎样查询进度？"]
        case .activity:return ["怎样报名，截止时间是什么？","活动的时间和地点是什么？","需要携带材料或支付费用吗？"]
        }
    }
    var phrases:[String] {
        ["我听声音不太方便，请把重要内容写下来。","请帮我核对时间、地点和费用。"] + questions
    }
    func makeJourney(title:String,questions:[String],date:Date?) throws -> CampusJourney {
        var result = CampusJourney(title:title.trimmingCharacters(in:.whitespacesAndNewlines))
        result.questions = questions.map { JourneyQuestion(text:$0) }
        result.plan = JourneyPlan(scenario:self,plannedAt:date)
        try result.validate();return result
    }
}

enum JourneySection:String,Codable,CaseIterable,Identifiable {
    case overview, questions, materials, communication, confirmation, changes, departure, outcome
    var id:String { rawValue }
    var title:String { switch self {
    case .overview:return "旅程总览";case .questions:return "问题与回答";case .materials:return "材料与版本";case .communication:return "沟通摘录"
    case .confirmation:return "信息确认";case .changes:return "变更处理";case .departure:return "出发检查";case .outcome:return "办理结果"
    } }
}
struct JourneyBookmark:Codable,Equatable,Identifiable {
    var id:UUID { journeyID }
    var journeyID:UUID
    var section:JourneySection
    var targetID:UUID?
    var date = Date()
}
struct QuestionEvidence:Codable,Equatable,Identifiable {
    var id:UUID { questionID }
    var questionID:UUID
    var excerptID:UUID
    var quote:String
    var answer:String
    var date = Date()
}
struct JourneyConflictResolution:Codable,Equatable,Identifiable {
    var id:String
    var selectedSourceID:UUID
    var note:String
    var date = Date()
}
struct JourneyPlan:Codable,Equatable {
    var scenario:CampusScenario?
    var plannedAt:Date?
    var questionEvidence:[QuestionEvidence] = []
    var resolutions:[JourneyConflictResolution] = []
    // Only this group's built-in records can be reset by the guided presentation.
    var presentationID:String?
    func validate(in journey:CampusJourney) throws {
        guard plannedAt.map({$0.timeIntervalSince1970.isFinite}) ?? true,
              questionEvidence.count <= 30,Set(questionEvidence.map(\.id)).count == questionEvidence.count,
              resolutions.count <= 40,Set(resolutions.map(\.id)).count == resolutions.count,
              presentationID == nil || (presentationID == "campus-040" && journey.demonstration) else { throw CampusError.invalid }
        for link in questionEvidence {
            guard journey.questions.contains(where:{$0.id == link.questionID}),
                  let excerpt = journey.conversations.first(where:{$0.id == link.excerptID}),
                  !link.quote.isEmpty,link.quote.count <= 500,excerpt.text.contains(link.quote),
                  !link.answer.isEmpty,link.answer.count <= 500,link.date.timeIntervalSince1970.isFinite else { throw CampusError.invalid }
        }
        for row in resolutions {
            guard row.id.count == 64,row.id.allSatisfy(\.isHexDigit),
                  journey.documents.contains(where:{$0.id == row.selectedSourceID}),
                  !row.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,row.note.count <= 300,
                  row.date.timeIntervalSince1970.isFinite else { throw CampusError.invalid }
        }
    }
}
struct CampusWorkspaceState:Codable,Equatable {
    var favoriteScenarios:[CampusScenario] = []
    var favoriteJourneyIDs:[UUID] = []
    var bookmarks:[JourneyBookmark] = []
    var watchSeenVersions:[String:String] = [:]
    func validate() throws {
        guard Set(favoriteScenarios).count == favoriteScenarios.count,
              favoriteJourneyIDs.count <= 30,Set(favoriteJourneyIDs).count == favoriteJourneyIDs.count,
              bookmarks.count <= 30,Set(bookmarks.map(\.id)).count == bookmarks.count,
              bookmarks.allSatisfy({$0.date.timeIntervalSince1970.isFinite}),watchSeenVersions.count <= 30,
              watchSeenVersions.allSatisfy({UUID(uuidString:$0.key) != nil && $0.value.count == 64 && $0.value.allSatisfy(\.isHexDigit)}) else { throw CampusError.invalid }
    }
}
struct JourneyConflictOption:Equatable,Identifiable {
    var id:String { sourceID.uuidString + ":" + value }
    var sourceID:UUID
    var title:String
    var revision:Int
    var value:String
    var quote:String
}
struct JourneyConflict:Identifiable {
    var id:String
    var kind:ArrangementKind
    var options:[JourneyConflictOption]
}
enum JourneyMaterialAnalysis {
    static func normalized(_ text:String) -> String {
        text.precomposedStringWithCanonicalMapping.components(separatedBy:.whitespacesAndNewlines).filter{!$0.isEmpty}.joined(separator:" ")
    }
    static func duplicates(_ source:CaseDocument,in journey:CampusJourney) -> [CaseDocument] {
        journey.documents.filter { $0.key != source.key && normalized($0.text) == normalized(source.text) }
    }
    static func conflicts(_ journey:CampusJourney) -> [JourneyConflict] {
        let latest = journey.documents.filter { source in
            !journey.documents.contains(where:{$0.draftID == source.draftID && $0.revision > source.revision})
        }
        return ArrangementKind.allCases.compactMap { kind in
            let options = latest.flatMap { source in
                CaseUpdateComparison.localCandidates(source:source).filter{$0.kind == kind}.map {
                    JourneyConflictOption(sourceID:source.id,title:source.title,revision:source.revision,value:$0.value,quote:$0.quote)
                }
            }
            guard Set(options.map{normalized($0.value)}).count > 1,Set(options.map(\.sourceID)).count > 1 else { return nil }
            let key = options.map{"\($0.sourceID):\($0.revision):\($0.value):\($0.quote)"}.sorted()
            guard let digest = try? WatchAgendaCodec.fingerprint([kind.rawValue]+key) else { return nil }
            return JourneyConflict(id:digest,kind:kind,options:options)
        }
    }
}
struct JourneyRevisionDelta {
    var before:CaseDocument?
    var after:CaseDocument
    var added:[String] {
        let old = Set(before?.text.components(separatedBy:.newlines) ?? [])
        return after.text.components(separatedBy:.newlines).filter{!$0.isEmpty && !old.contains($0)}
    }
    var removed:[String] {
        let new = Set(after.text.components(separatedBy:.newlines))
        return (before?.text.components(separatedBy:.newlines) ?? []).filter{!$0.isEmpty && !new.contains($0)}
    }
    static func history(_ journey:CampusJourney) -> [JourneyRevisionDelta] {
        journey.documents.map { source in
            .init(before:journey.documents.filter{$0.draftID == source.draftID && $0.revision < source.revision}.max(by:{$0.revision < $1.revision}),after:source)
        }
    }
}
struct JourneyAttention:Identifiable {
    var id:String
    var journeyID:UUID
    var title:String
    var detail:String
    var section:JourneySection
    var targetID:UUID?
}
enum CampusOverview {
    static func attention(_ journeys:[CampusJourney],cases:[WorkroomCase]) -> [JourneyAttention] {
        journeys.filter{$0.stage != .finished}.flatMap { journey in
            var rows = journey.facts.filter(\.superseded).map {
                JourneyAttention(id:journey.id.uuidString+":"+$0.id.uuidString,journeyID:journey.id,title:$0.kind.title+"需要重新核对",detail:$0.value,section:.confirmation,targetID:$0.id)
            }
            if !journey.changedCases(cases).isEmpty {
                rows.append(.init(id:"cases:"+journey.id.uuidString,journeyID:journey.id,title:"关联事务发生变化",detail:journey.changedCases(cases).joined(separator:"\n"),section:.changes))
            }
            rows += JourneyMaterialAnalysis.conflicts(journey).filter { conflict in !(journey.plan?.resolutions.contains(where:{$0.id == conflict.id}) ?? false) }.map {
                .init(id:journey.id.uuidString+":"+$0.id,journeyID:journey.id,title:$0.kind.title+"有不同说法",detail:"请先确认是否属于同一安排，再记录采用的依据。",section:.materials)
            }
            return rows
        }
    }
    static func scheduled(_ journeys:[CampusJourney],on date:Date,week:Bool,calendar:Calendar = .current) -> [CampusJourney] {
        let interval = calendar.dateInterval(of:week ? .weekOfYear : .day,for:date)
        return journeys.filter { journey in
            guard journey.stage != .finished,let date = journey.plan?.plannedAt,let interval else { return false }
            return date >= interval.start && date < interval.end
        }.sorted { ($0.plan?.plannedAt ?? .distantFuture) < ($1.plan?.plannedAt ?? .distantFuture) }
    }
}
extension CampusJourney {
    var contextualPhrases:[String] {
        var output = plan?.scenario?.phrases ?? ["我听声音不太方便，请把重要内容写下来。","请帮我核对这次的安排。"]
        output += questions.filter{$0.answer.isEmpty}.map(\.text)
        output += facts.filter{!$0.superseded}.map { "请确认\($0.kind.title)是否为：\($0.value)？" }
        var seen = Set<String>();return output.filter{seen.insert($0).inserted}
    }
    func watchJourneySummary() throws -> WatchAgendaItem {
        let pending = questions.first{$0.answer.isEmpty}?.text ?? facts.first{!$0.isConfirmed} .map{"核对"+$0.kind.title} ?? "查看随身办事单"
        let confirmed = facts.filter(\.isConfirmed).filter{$0.kind == .place || $0.kind == .time}.prefix(2).map{$0.kind.title+"："+$0.value}
        // Local bookmarks, reading position and previous receipts do not alter the content version.
        let digest = try fingerprint()
        return .init(id:id,kind:.journey,title:String(title.prefix(100)),next:String(([stage.title,pending]+confirmed).joined(separator:" · ").prefix(120)),dueAt:plan?.plannedAt,fingerprint:digest,demonstration:demonstration,completed:stage == .finished)
    }
}
struct LibraryJourneyDifference:Identifiable {
    var id:UUID
    var title:String
    var summary:[String]
    var appliesIncoming:Bool
    static func make(local:LibrarySnapshot,package:LibraryPackage,preferIncoming:Bool) -> [LibraryJourneyDifference] {
        (package.snapshot.workroom.enhancements?.campus?.journeys ?? []).map { incoming in
            guard let old = local.workroom.enhancements?.campus?.journeys.first(where:{$0.id == incoming.id}) else {
                return .init(id:incoming.id,title:incoming.title,summary:["新增旅程","\(incoming.documents.count)份来源 · \(incoming.questions.count)个问题 · \(incoming.facts.count)张确认卡"],appliesIncoming:true)
            }
            var changes:[String] = []
            if old.title != incoming.title { changes.append("标题："+old.title+" → "+incoming.title) }
            if old.stage != incoming.stage { changes.append("阶段："+old.stage.title+" → "+incoming.stage.title) }
            if old.documents != incoming.documents { changes.append("来源材料或版本不同，请重新查看材料依据。") }
            if old.questions != incoming.questions { changes.append("提问或回答有变化。") }
            if old.facts != incoming.facts { changes.append("确认卡内容或确认状态不同。") }
            if old.conversations != incoming.conversations { changes.append("沟通摘录不同。") }
            if old.outcomes != incoming.outcomes { changes.append("办理结果不同。") }
            if old.caseIDs != incoming.caseIDs { changes.append("关联事务有所变化。") }
            if old.plan != incoming.plan { changes.append("计划日期、回答依据或来源判断不同。") }
            if changes.isEmpty { changes = ["可见内容相同；保留原版本选择。"] }
            return .init(id:incoming.id,title:incoming.title,summary:changes,appliesIncoming:preferIncoming)
        }
    }
}

@MainActor extension WorkroomService {
    var campusWorkspace:CampusWorkspaceState { campus.workspace ?? .init() }
    func updateCampusWorkspace(_ change:(inout CampusWorkspaceState)->Void) throws {
        try updateEnhancements { extra in
            var ledger = extra.campus ?? .init(),state = ledger.workspace ?? .init()
            change(&state);ledger.workspace = state;extra.campus = ledger
        }
    }
    func rememberJourney(_ id:UUID,section:JourneySection,targetID:UUID? = nil) throws {
        guard campus.journeys.contains(where:{$0.id == id}) else { throw CampusError.missing }
        let next = JourneyBookmark(journeyID:id,section:section,targetID:targetID)
        let old = campusWorkspace.bookmarks.first{$0.journeyID == id}
        guard old?.section != section || old?.targetID != targetID || campus.lastJourneyID != id else { return }
        try updateEnhancements { extra in
            var ledger = extra.campus ?? .init(),state = ledger.workspace ?? .init()
            state.bookmarks.removeAll{$0.journeyID == id};state.bookmarks.insert(next,at:0);state.bookmarks = Array(state.bookmarks.prefix(30))
            ledger.workspace = state;ledger.lastJourneyID = id;extra.campus = ledger
        }
    }
    func visitJourney(_ id:UUID) throws {
        guard campus.journeys.contains(where:{$0.id == id}) else { throw CampusError.missing }
        guard campus.lastJourneyID != id else { return }
        try updateEnhancements { $0.campus?.lastJourneyID = id }
    }
    func attachJourneySource(_ source:CaseDocument,to id:UUID,baseline:String,allowDuplicate:Bool) throws {
        guard let journey = campus.journeys.first(where:{$0.id == id}),try journey.fingerprint() == baseline else { throw CampusError.stale }
        guard allowDuplicate || JourneyMaterialAnalysis.duplicates(source,in:journey).isEmpty else { throw WorkspaceUpgradeError.duplicateSource }
        try changeJourney(id) { try $0.attach(source) }
    }
    func resolveJourneyConflict(_ id:UUID,key:String,sourceID:UUID,note:String,baseline:String) throws {
        guard let journey = campus.journeys.first(where:{$0.id == id}),try journey.fingerprint() == baseline,
              let conflict = JourneyMaterialAnalysis.conflicts(journey).first(where:{$0.id == key}),
              conflict.options.contains(where:{$0.sourceID == sourceID}) else { throw CampusError.stale }
        try changeJourney(id) {
            var plan = $0.plan ?? .init();plan.resolutions.removeAll{$0.id == key}
            plan.resolutions.append(.init(id:key,selectedSourceID:sourceID,note:note));plan.resolutions = Array(plan.resolutions.suffix(40));$0.plan = plan
        }
    }
    func linkJourneyAnswer(_ id:UUID,questionID:UUID,excerptID:UUID,quote:String,answer:String,baseline:String,consent:Bool) throws {
        guard consent else { throw CampusError.consent }
        guard let journey = campus.journeys.first(where:{$0.id == id}),try journey.fingerprint() == baseline,
              journey.questions.contains(where:{$0.id == questionID}),let row = journey.conversations.first(where:{$0.id == excerptID}),row.text.contains(quote) else { throw CampusError.stale }
        try changeJourney(id) {
            var plan = $0.plan ?? .init();plan.questionEvidence.removeAll{$0.questionID == questionID}
            plan.questionEvidence.append(.init(questionID:questionID,excerptID:excerptID,quote:quote,answer:answer));$0.plan = plan
            if let index = $0.questions.firstIndex(where:{$0.id == questionID}) { $0.questions[index].answer = answer }
        }
    }
    func addJourneyExcerpt(_ id:UUID,text:String,title:String,demonstration:Bool,consent:Bool) throws {
        guard consent else { throw CampusError.consent }
        try changeJourney(id) {
            guard $0.demonstration == demonstration else { throw WorkroomError.mixedSource }
            $0.conversations.append(.init(title:title,text:text))
        }
    }
    @discardableResult
    func makeJourneyAnswerFact(_ id:UUID,questionID:UUID,kind:JourneyFactKind,value:String,baseline:String,consent:Bool) throws -> UUID {
        guard consent else { throw CampusError.consent }
        guard var journey = campus.journeys.first(where:{$0.id == id}),try journey.fingerprint() == baseline,
              let question = journey.questions.first(where:{$0.id == questionID}) else { throw CampusError.stale }
        let value = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.count <= 300,!question.answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              question.answer.contains(value) else { throw CampusError.invalid }
        let text = (journey.demonstration ? "【模拟窗口回答，非实际校园规定】" : "【用户手动记录并核对的回答，非逐字录音】")
            + "\n问题："+question.text+"\n回答："+question.answer
        let previous = journey.documents.filter{$0.draftID == question.id}.max(by:{$0.revision < $1.revision})
        let source:CaseDocument
        if let previous,previous.text == text {
            source = previous
        } else {
            guard journey.documents.count < 12 else { throw CampusError.limit }
            var draft = WorkroomDraft();draft.id = question.id
            draft.title = String(("窗口回答 · "+question.text).prefix(60));draft.text = text
            draft.origin = journey.demonstration ? .demonstration : .typed
            draft.revision = (previous?.revision ?? 0)+1;try draft.validate()
            source = CaseDocument(draft:draft);try journey.attach(source)
        }
        if let existing = journey.facts.first(where:{$0.sourceID == source.id && $0.kind == kind && $0.value == value && !$0.superseded}) {
            return existing.id
        }
        guard journey.facts.count < 40 else { throw CampusError.limit }
        let fact = JourneyFact(kind:kind,value:value,sourceID:source.id,quote:question.answer)
        journey.facts.append(fact);try putJourney(journey,baseline:baseline)
        return fact.id
    }
    func startCampusPresentation(reset:Bool) throws -> UUID {
        let group = "campus-040"
        if !reset,let existing = campus.journeys.first(where:{$0.plan?.presentationID == group}) { return existing.id }
        var example = CampusJourney.studentCardExample();example.title = "演示 · 校园办事全过程"
        example.plan = JourneyPlan(scenario:.certificate,presentationID:group)
        let id = example.id
        try updateEnhancements { extra in
            var ledger = extra.campus ?? .init()
            if reset {
                let removed = Set(ledger.journeys.filter{$0.demonstration && $0.plan?.presentationID == group}.map(\.id))
                ledger.journeys.removeAll{removed.contains($0.id)}
                ledger.workspace?.favoriteJourneyIDs.removeAll{removed.contains($0)}
                ledger.workspace?.bookmarks.removeAll{removed.contains($0.journeyID)}
                for id in removed { ledger.workspace?.watchSeenVersions.removeValue(forKey:id.uuidString) }
            }
            ledger.journeys.insert(example,at:0);ledger.lastJourneyID = id;extra.campus = ledger
        }
        return id
    }
}
