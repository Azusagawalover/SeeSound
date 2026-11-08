import Combine
import Foundation

struct WorkroomArchive: Codable {
    var version = 1
    var drafts: [WorkroomDraft] = []
    var cases: [WorkroomCase] = []
    var enhancements: WorkroomEnhancements?
    var trash:[WorkroomTrashEntry]?
    var filingUndo:FilingUndo?
    func validate() throws {
        guard version == 1, drafts.count <= 30, cases.count <= 100,
              Set(drafts.map(\.id)).count == drafts.count, Set(cases.map(\.id)).count == cases.count else { throw DailyError.capacity }
        guard (trash ?? []).count <= 50,Set((trash ?? []).map(\.id)).count == (trash ?? []).count,Set((trash ?? []).map(\.key)).count == (trash ?? []).count,(trash ?? []).allSatisfy(\.savedLocally) else { throw RecoveryExperienceError.full }
        try (trash ?? []).forEach { try $0.validate() };try filingUndo?.validate()
        try drafts.forEach { try $0.validate() }; try cases.forEach { try $0.validate() };try enhancements?.validate()
    }
}
final class WorkroomStore {
    let directory: URL
    var url: URL { directory.appendingPathComponent("workroom.json") }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SeeSoundWorkroom")
    }
    func load() throws -> WorkroomArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkroomArchive() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 8_000_000 else { throw DailyError.invalid }
        let archive = try JSONDecoder().decode(WorkroomArchive.self, from: Data(contentsOf: url)); try archive.validate(); return archive
    }
    func save(_ archive: WorkroomArchive) throws {
        _ = try load(); try archive.validate()
        let data = try JSONEncoder().encode(archive); guard data.count <= 8_000_000 else { throw DailyError.capacity }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var root = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
        #if os(iOS)
        try data.write(to: url, options: [.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func reset() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) };let images = directory.appendingPathComponent("Visuals");if FileManager.default.fileExists(atPath:images.path) { try FileManager.default.removeItem(at:images) } }
}

@MainActor
final class WorkroomService: ObservableObject {
    @Published private(set) var active = WorkroomDraft()
    @Published private(set) var activeVisual:WorkroomVisualEvidence?
    @Published private(set) var visualWarning:String?
    @Published private(set) var trash:[WorkroomTrashEntry] = []
    @Published private(set) var filingUndo:FilingUndo?
    @Published private(set) var notice:WorkroomNotice?
    @Published private(set) var drafts: [WorkroomDraft] = []
    @Published private(set) var cases: [WorkroomCase] = []
    @Published private(set) var savedCaseIDs: Set<UUID> = []
    @Published private(set) var error: String?
    @Published private(set) var enhancements = WorkroomEnhancements()
    private var writtenVisualIDs = Set<UUID>()
    private let store: WorkroomStore
    init(store: WorkroomStore = WorkroomStore()) {
        self.store = store
        do { let archive = try store.load(); drafts = archive.drafts; cases = archive.cases; savedCaseIDs = Set(cases.map(\.id));enhancements = archive.enhancements ?? WorkroomEnhancements();trash = archive.trash ?? [];filingUndo = archive.filingUndo }
        catch { self.error = "工作室读取失败，已保留原文件并暂停保存：\(error.localizedDescription)" }
    }
    func use(_ draft:WorkroomDraft) throws {
        try draft.validate();active = draft;visualWarning = nil;activeVisual = nil
        do { activeVisual = try draft.visualID.flatMap { try WorkroomVisualStore(directory:store.directory).load($0) } }
        catch { visualWarning = "原图暂时无法读取，材料文字仍可继续核对和编辑。" }
    }
    func newDraft() { active = WorkroomDraft();activeVisual = nil;visualWarning = nil }
    func edit(title: String, text: String) throws {
        let next = try active.edited(title:title,text:text)
        if enhancements.autosave {
            var saved = drafts.filter { $0.id != next.id };saved.insert(next,at:0)
            var extra = enhancements;extra.lastDraftID = next.id
            try writeActiveVisual(for:saved,cases:cases);try store.save(WorkroomArchive(drafts:saved,cases:cases.filter { savedCaseIDs.contains($0.id) },enhancements:extra,trash:trash.filter(\.savedLocally),filingUndo:filingUndo));drafts = saved;enhancements = extra
        };active = next
    }
    func answer(_ question: InsightQuestion, text: String) throws {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.count <= 300 else { throw DailyError.invalid }
        guard active.fragments.contains(where: { $0.id == question.sourceID && $0.text.contains(question.quote) }) else { throw WorkroomError.stale }
        try edit(title: active.title, text: active.text + "\n补充核对：\(question.question)\n我的补充：\(answer)")
    }
    func saveDraft() throws {
        try active.validate(); guard error == nil else { throw DailyError.invalid }
        var next = drafts.filter { $0.id != active.id }; next.insert(active, at: 0)
        guard next.count <= 30 else { throw DailyError.capacity }
        var extra = enhancements;extra.lastDraftID = active.id
        try writeActiveVisual(for:next,cases:cases);try store.save(WorkroomArchive(drafts:next,cases:cases.filter { savedCaseIDs.contains($0.id) },enhancements:extra,trash:trash.filter(\.savedLocally),filingUndo:filingUndo));drafts = next;enhancements = extra
    }
    func removeDraft(_ id:UUID) throws { try moveToTrash(draftIDs:[id],caseIDs:[]) }
    func putCase(_ item: WorkroomCase, saveLocally: Bool,discardRecovery:Bool = false) throws {
        try item.validate()
        if let old = cases.first(where: { $0.id == item.id }), old.demonstration != item.demonstration { throw WorkroomError.mixedSource }
        var next = cases.filter { $0.id != item.id }; next.insert(item, at: 0)
        guard next.count <= 100 else { throw DailyError.capacity }
        var ids = savedCaseIDs; if saveLocally { ids.insert(item.id) } else { ids.remove(item.id) }
        var extra = enhancements
        try extra.campus?.invalidateFacts(before:cases.first(where:{$0.id == item.id}),after:item)
        if discardRecovery { extra.campus?.recoveries.removeAll { $0.id == item.id } }
        if saveLocally || savedCaseIDs.contains(item.id) || extra != enhancements {
            guard error == nil else { throw DailyError.invalid }
            try writeActiveVisual(for:drafts,cases:next)
            try store.save(WorkroomArchive(drafts:drafts,cases:next.filter{ids.contains($0.id)},enhancements:extra,trash:trash.filter(\.savedLocally),filingUndo:filingUndo));enhancements = extra
            pruneOriginals(drafts:drafts,cases:next,ids:ids)
        }
        cases = next; savedCaseIDs = ids
    }
    @discardableResult
    func createPreparedCase(_ review: PreparedCaseDraft, confirmed: Bool, saveLocally: Bool) throws -> UUID {
        guard confirmed else { throw WorkroomError.reviewRequired }
        var item = try review.makeCase(current: active);item.sources = [CaseDocument(draft:active)];item.exampleGroup = active.exampleGroup
        if cases.contains(where: { $0.id == item.id }) { return item.id }
        try putCase(item, saveLocally: saveLocally); return item.id
    }
    func removeCase(_ id:UUID) throws { try moveToTrash(draftIDs:[],caseIDs:[id]) }
    func completeCase(_ id: UUID, completed: Bool, routines: [RoutineItem], now: Date = Date()) throws {
        guard var item = cases.first(where: { $0.id == id }) else { throw DailyError.stale }
        if completed {
            let progress = item.progress(routines: routines)
            guard progress.total > 0, progress.done == progress.total else { throw WorkroomError.incomplete }
        }
        item.completedAt = completed ? max(now, item.createdAt) : nil
        try putCase(item, saveLocally: savedCaseIDs.contains(id))
    }
    func archiveCase(_ id: UUID, archived: Bool, now: Date = Date()) throws {
        guard var item = cases.first(where: { $0.id == id }) else { throw DailyError.stale }
        item.archivedAt = archived ? now : nil
        try putCase(item, saveLocally: savedCaseIDs.contains(id))
    }
    func reloadFromDisk() throws {
        let archive = try store.load()
        // Saved records are reloaded; temporary records are retained only when their IDs do not collide.
        let importedIDs = Set(archive.cases.map(\.id))
        let unsaved = cases.filter { !savedCaseIDs.contains($0.id) && !importedIDs.contains($0.id) }
        let temporaryTrash = trash.filter { !$0.savedLocally }
        guard archive.cases.count+unsaved.count <= 100 else { throw DailyError.capacity }
        enhancements = archive.enhancements ?? WorkroomEnhancements();trash = (archive.trash ?? [])+temporaryTrash;filingUndo = archive.filingUndo;drafts = archive.drafts;cases = archive.cases+unsaved;savedCaseIDs = importedIDs;error = nil
    }
    func reset() throws { try store.reset(); drafts = []; cases = []; savedCaseIDs = [];activeVisual = nil;writtenVisualIDs = [];trash = [];filingUndo = nil;notice = nil; enhancements = WorkroomEnhancements();error = nil }
    private func persist(drafts: [WorkroomDraft], cases: [WorkroomCase], ids: Set<UUID>) throws {
        guard error == nil else { throw DailyError.invalid }
        try writeActiveVisual(for:drafts,cases:cases);try store.save(WorkroomArchive(drafts: drafts, cases: cases.filter { ids.contains($0.id) },enhancements:enhancements,trash:trash.filter(\.savedLocally),filingUndo:filingUndo))
        pruneOriginals(drafts:drafts,cases:cases,ids:ids)
    }
}

struct GlobalSearchHit: Identifiable {
    enum Kind: String, CaseIterable { case event = "事件", conversation = "已存会话", card = "信息卡", routine = "待办", draft = "草稿", project = "事务", journey = "办事旅程", question = "旅程问题", journeyFact = "旅程确认", excerpt = "沟通摘录", journeySource = "旅程材料" }
    var recordID: UUID
    var kind: Kind
    var title: String
    var detail: String
    var demonstration: Bool
    var parentJourneyID:UUID?
    var id: String { "\(kind.rawValue):\(recordID)" + (parentJourneyID.map{":\($0.uuidString)"} ?? "") }
    func matches(_ query: String) -> Bool { title.localizedCaseInsensitiveContains(query) || detail.localizedCaseInsensitiveContains(query) }
}

enum WorkroomSearch {
    static func hits(query: String, events: [SenseEvent], conversations: [SavedConversation], cards: [InformationCard], routines: [RoutineItem], drafts: [WorkroomDraft], cases: [WorkroomCase], annotations: [UUID:EventAnnotation] = [:], includeAllWhenEmpty:Bool = false, journeys:[CampusJourney] = []) -> [GlobalSearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines);guard !query.isEmpty || includeAllWhenEmpty else { return [] }
        var result = events.map { GlobalSearchHit(recordID: $0.id, kind: .event, title: $0.title, detail: $0.category + "\n" + (annotations[$0.id]?.note ?? ""), demonstration: $0.isDemonstration) }
        result += conversations.map { GlobalSearchHit(recordID: $0.id, kind: .conversation, title: $0.title, detail: $0.turns.map(\.text).joined(separator: "\n"), demonstration: $0.containsDemonstration) }
        result += cards.map { GlobalSearchHit(recordID: $0.id, kind: .card, title: $0.kind.title + "：" + $0.displayValue, detail: $0.note + "\n" + $0.sourceQuote, demonstration: $0.origin == .demonstration) }
        result += routines.map { GlobalSearchHit(recordID: $0.id, kind: .routine, title: $0.title, detail: $0.note + "\n" + $0.sourceSnapshot, demonstration: $0.isDemonstration) }
        result += drafts.map { GlobalSearchHit(recordID: $0.id, kind: .draft, title: $0.title, detail: $0.text, demonstration: $0.demonstration) }
        result += cases.map { GlobalSearchHit(recordID: $0.id, kind: .project, title: $0.title, detail: $0.note + "\n" + ($0.materials + $0.steps).map(\.title).joined(separator: "\n") + "\n" + $0.links.map(\.snapshot).joined(separator: "\n") + "\n" + $0.documents.map { $0.title+"\n"+$0.text }.joined(separator:"\n"), demonstration: $0.demonstration) }
        for journey in journeys {
            result.append(.init(recordID:journey.id,kind:.journey,title:journey.title,detail:journey.stage.title,demonstration:journey.demonstration,parentJourneyID:journey.id))
            result += journey.questions.map{.init(recordID:$0.id,kind:.question,title:$0.text,detail:$0.answer,demonstration:journey.demonstration,parentJourneyID:journey.id)}
            result += journey.facts.map{.init(recordID:$0.id,kind:.journeyFact,title:$0.kind.title+"："+$0.value,detail:$0.quote,demonstration:journey.demonstration,parentJourneyID:journey.id)}
            result += journey.conversations.map{.init(recordID:$0.id,kind:.excerpt,title:$0.title,detail:$0.text,demonstration:journey.demonstration,parentJourneyID:journey.id)}
            result += journey.documents.map{.init(recordID:$0.id,kind:.journeySource,title:$0.title,detail:$0.text,demonstration:journey.demonstration,parentJourneyID:journey.id)}
        }
        return result.filter { query.isEmpty || $0.matches(query) }
    }
}

@MainActor extension WorkroomService {
    func updateEnhancements(_ change:(inout WorkroomEnhancements)->Void) throws {
        guard error == nil else { throw DailyError.invalid };var next = enhancements;change(&next);try next.validate()
        if let visual = activeVisual, (next.campus?.journeys ?? []).flatMap(\.documents).contains(where:{$0.visualID == visual.id}) { try WorkroomVisualStore(directory:store.directory).save(visual) }
        try store.save(WorkroomArchive(drafts:drafts,cases:cases.filter { savedCaseIDs.contains($0.id) },enhancements:next,trash:trash.filter(\.savedLocally),filingUndo:filingUndo));enhancements = next
    }
    func protectDraft(title:String,text:String,stage:Int) throws {
        guard enhancements.autosave,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        let next = try active.edited(title:title,text:text)
        var saved = drafts.filter { $0.id != next.id };saved.insert(next,at:0)
        var extra = enhancements;extra.lastDraftID = next.id;extra.lastStage = stage
        try writeActiveVisual(for:saved,cases:cases);try store.save(WorkroomArchive(drafts:saved,cases:cases.filter { savedCaseIDs.contains($0.id) },enhancements:extra,trash:trash.filter(\.savedLocally),filingUndo:filingUndo))
        // Keep the editor stable: recovery copies are durable without replacing the active selection.
        drafts = saved;enhancements = extra
    }
    func addToInbox(_ draft:WorkroomDraft) throws {
        try draft.validate()
        if let previous = drafts.first(where:{$0.id == draft.id}) { guard previous.origin == draft.origin else { throw WorkroomError.mixedSource };return }
        var copy = draft;copy.inInbox = true
        var next = drafts.filter { $0.id != copy.id };next.insert(copy,at:0)
        try persist(drafts:next,cases:cases,ids:savedCaseIDs);drafts = next
    }
    func openInbox(_ id:UUID) throws {
        guard var draft = drafts.first(where:{$0.id == id}) else { throw DailyError.stale }
        draft.inInbox = false;let next = drafts.map { $0.id == id ? draft : $0 }
        try persist(drafts:next,cases:cases,ids:savedCaseIDs);drafts = next;active = draft
    }
    func createNextOccurrence(_ id:UUID,now:Date = Date()) throws -> UUID {
        guard var previous = cases.first(where:{$0.id == id}) else { throw DailyError.stale }
        if let existing = previous.workflow.nextOccurrenceID { guard cases.contains(where:{$0.id == existing}) else { throw DailyError.stale };return existing }
        let next = try previous.nextOccurrence(at:now);var flow = previous.workflow;flow.nextOccurrenceID = next.id;previous.flow = flow
        var items = cases.filter { $0.id != id };items.insert(previous,at:0);items.insert(next,at:0)
        guard items.count <= 100 else { throw DailyError.capacity }
        var ids = savedCaseIDs;if ids.contains(id) { ids.insert(next.id);try persist(drafts:drafts,cases:items,ids:ids) }
        cases = items;savedCaseIDs = ids;return next.id
    }
    func bulkFile(_ keys:Set<String>,filing:RecordFiling) throws {
        try applyFilingPreview(FilingChangePreview.make(keys:keys,replacement:filing,current:enhancements.filing))
    }
    func removeDrafts(_ ids:Set<UUID>) throws { try moveToTrash(draftIDs:ids,caseIDs:[]) }
    func removeArchivedCases(_ ids:Set<UUID>) throws {
        guard cases.filter({ids.contains($0.id)}).allSatisfy(\.isArchived) else { throw DailyError.invalid }
        try moveToTrash(draftIDs:[],caseIDs:ids)
    }
}

@MainActor extension WorkroomService {
    func cleanup(drafts ids:Set<UUID>,cases caseIDs:Set<UUID>) throws {
        guard cases.filter({caseIDs.contains($0.id)}).allSatisfy(\.isArchived) else { throw DailyError.invalid }
        try moveToTrash(draftIDs:ids,caseIDs:caseIDs)
    }

}

@MainActor extension WorkroomService {
    func stageVisual(_ visual:WorkroomVisualEvidence?,retain:Bool) throws {
        try visual?.validate();activeVisual = visual;active.visualID = retain ? visual?.id : nil
    }
    func visual(for id:UUID?) throws -> WorkroomVisualEvidence? {
        guard let id else { return nil }
        if activeVisual?.id == id { return activeVisual }
        return try WorkroomVisualStore(directory:store.directory).load(id)
    }
    private func writeActiveVisual(for drafts:[WorkroomDraft],cases:[WorkroomCase]) throws {
        guard let evidence = activeVisual,
              drafts.contains(where:{$0.visualID == evidence.id}) || cases.flatMap(\.documents).contains(where:{$0.visualID == evidence.id}) else { return }
        if !writtenVisualIDs.contains(evidence.id) { try WorkroomVisualStore(directory:store.directory).save(evidence);writtenVisualIDs.insert(evidence.id) }
    }
    func attach(_ document:CaseDocument,to id:UUID) throws {
        guard var item = cases.first(where:{$0.id == id}) else { throw DailyError.stale }
        guard item.isActive else { throw WorkspaceUpgradeError.inactive }
        guard item.demonstration == document.demonstration else { throw WorkroomError.mixedSource }
        guard !item.documents.contains(where:{$0.key == document.key}) else { throw WorkspaceUpgradeError.duplicateSource }
        item.sources = item.documents+[document]
        try putCase(item,saveLocally:savedCaseIDs.contains(id))
    }
    func removeDocument(_ documentID:UUID,from id:UUID) throws {
        guard var item = cases.first(where:{$0.id == id}),item.isActive else { throw DailyError.stale }
        guard !item.confirmedFacts.contains(where:{$0.documentID == documentID}),!(item.updates ?? []).contains(where:{$0.documentID == documentID}) else { throw WorkspaceUpgradeError.protectedSource }
        item.sources = item.documents.filter { $0.id != documentID };try putCase(item,saveLocally:savedCaseIDs.contains(id))
    }
    func recordFollowUp(_ id:UUID,note:String,resume:Bool,nextDate:Date?,at now:Date = Date()) throws {
        guard var item = cases.first(where:{$0.id == id}),item.isActive else { throw DailyError.stale }
        var flow = item.workflow;var rows = flow.followUps ?? []
        rows.append(.init(date:now,note:note.trimmingCharacters(in:.whitespacesAndNewlines),resumed:resume));flow.followUps = rows
        flow.followUpAt = nextDate
        if resume { flow.disposition = .ready;flow.waitingSince = nil }
        else if flow.disposition == .waiting && flow.waitingSince == nil { flow.waitingSince = now }
        item.flow = flow;try putCase(item,saveLocally:savedCaseIDs.contains(id))
    }
    func applyUpdate(caseID:UUID,fingerprint:String,document:CaseDocument,candidates:[CaseChangeCandidate],generator:String,
                     changeDue:Bool,dueAt:Date?,changeReminder:Bool,reminderAt:Date?,saveLocally:Bool,at now:Date = Date(),confirmed:Bool = false,materials:[CaseMaterialSuggestion] = []) throws {
        guard confirmed else { throw WorkroomError.reviewRequired }
        guard var item = cases.first(where:{$0.id == caseID}),try item.reviewFingerprint() == fingerprint else { throw WorkspaceUpgradeError.staleReview }
        guard item.isActive else { throw WorkspaceUpgradeError.inactive }
        guard item.demonstration == document.demonstration else { throw WorkroomError.mixedSource }
        guard candidates.count <= 3,Set(candidates.map(\.kind)).count == candidates.count,
              !generator.isEmpty,generator.count <= 80,candidates.allSatisfy({ !$0.value.isEmpty && $0.value.count <= 160 && !$0.quote.isEmpty && $0.quote.count <= 200 && document.text.contains($0.quote) }) else { throw DailyError.invalid }
        guard materials.count <= 10,Set(materials.map(\.title)).count == materials.count,
              materials.allSatisfy({ !$0.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.title.count <= 100 && $0.quote.count <= 200 && !$0.quote.isEmpty && $0.quote.contains($0.title) && document.text.contains($0.quote) }) else { throw DailyError.invalid }
        let allowedMaterials = CaseUpdateComparison.materialSuggestions(source:document,existing:item.materials)
        guard materials.allSatisfy({ allowedMaterials.contains($0) }) else { throw DailyError.invalid }
        if changeReminder,let reminderAt { guard reminderAt > now,saveLocally,!item.demonstration else { throw DailyError.consent } }
        let beforeValues = Dictionary(uniqueKeysWithValues:ArrangementKind.allCases.map { ($0,item.priorValue(for:$0,excluding:document.id)) })
        if !item.documents.contains(where:{$0.id == document.id}) {
            guard !item.documents.contains(where:{$0.key == document.key}) else { throw WorkspaceUpgradeError.duplicateSource }
            item.sources = item.documents+[document]
        }
        var facts = item.confirmedFacts,descriptions:[String] = []
        for candidate in candidates {
            if item.confirmedFacts.contains(where:{$0.kind == candidate.kind && $0.value == candidate.value}) { continue }
            let previous = beforeValues[candidate.kind] ?? "尚未确认"
            descriptions.append(previous == candidate.value ? "核对确认"+candidate.kind.title+"："+candidate.value : candidate.kind.title+"："+previous+" → "+candidate.value)
            facts.removeAll { $0.kind == candidate.kind };facts.append(.init(kind:candidate.kind,value:candidate.value,documentID:document.id,quote:candidate.quote,confirmedAt:now))
        }
        item.arrangements = facts
        if !materials.isEmpty {
            for material in materials { item.materials.append(.init(title:material.title,sourceQuote:material.quote,sourceLabel:document.title+" · 第 \(document.revision) 版")) }
            let names = materials.map(\.title).joined(separator:"、")
            descriptions.append("新增 \(materials.count) 项材料："+String(names.prefix(340))+(names.count > 340 ? "…" : ""))
        }
        if changeDue { item.dueAt = dueAt;descriptions.append("已单独确认事务截止时间") }
        if changeReminder { item.reminderAt = reminderAt;descriptions.append("已单独确认提醒时间") }
        guard !descriptions.isEmpty else { throw WorkroomError.reviewRequired }
        var receipts = item.updates ?? [];receipts.append(.init(date:now,documentID:document.id,generator:generator,changes:descriptions));item.updates = Array(receipts.suffix(20))
        try putCase(item,saveLocally:saveLocally)
    }
}

@MainActor extension WorkroomService {
    func addToInbox(_ draft:WorkroomDraft,visual:WorkroomVisualEvidence?) throws {
        if drafts.contains(where:{$0.id == draft.id}) { try addToInbox(draft);return }
        if let visual,draft.visualID == visual.id { try WorkroomVisualStore(directory:store.directory).save(visual) }
        try addToInbox(draft)
    }
}

@MainActor extension WorkroomService {
    func forgetOriginal(_ id:UUID) throws {
        guard error == nil else { throw DailyError.invalid }
        var newDrafts = drafts,newCases = cases,newTrash = trash,extra = enhancements
        if extra.campus != nil {
            for i in extra.campus!.journeys.indices { for j in extra.campus!.journeys[i].documents.indices where extra.campus!.journeys[i].documents[j].visualID == id { extra.campus!.journeys[i].documents[j].visualID = nil } }
        }
        for i in newTrash.indices {
            if newTrash[i].draft?.visualID == id { newTrash[i].draft?.visualID = nil }
            if newTrash[i].project?.sources != nil { for j in newTrash[i].project!.sources!.indices where newTrash[i].project!.sources![j].visualID == id { newTrash[i].project!.sources![j].visualID = nil } }
        }
        for i in newDrafts.indices where newDrafts[i].visualID == id { newDrafts[i].visualID = nil }
        for i in newCases.indices {
            if newCases[i].sources != nil { for j in newCases[i].sources!.indices where newCases[i].sources![j].visualID == id { newCases[i].sources![j].visualID = nil } }
        }
        try store.save(WorkroomArchive(drafts:newDrafts,cases:newCases.filter { savedCaseIDs.contains($0.id) },enhancements:extra,trash:newTrash.filter(\.savedLocally),filingUndo:filingUndo))
        drafts = newDrafts;cases = newCases;trash = newTrash;enhancements = extra
        if active.visualID == id { active.visualID = nil }
        if activeVisual?.id == id { activeVisual = nil };writtenVisualIDs.remove(id)
        let url = store.directory.appendingPathComponent("Visuals").appendingPathComponent(id.uuidString+".json")
        if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
    }
}

@MainActor extension WorkroomService {
    private func pruneOriginals(drafts:[WorkroomDraft],cases:[WorkroomCase],ids:Set<UUID>) {
        let journeyVisuals = campus.journeys.flatMap(\.documents).compactMap(\.visualID)
        let retained = Set(drafts.compactMap(\.visualID)+cases.filter { ids.contains($0.id) }.flatMap(\.documents).compactMap(\.visualID)+trash.filter(\.savedLocally).flatMap(\.visualIDs)+journeyVisuals)
        WorkroomVisualStore(directory:store.directory).removeUnreferenced(keeping:retained);writtenVisualIDs.formIntersection(retained)
    }
}

@MainActor extension WorkroomService {
    func clearNotice() { notice = nil }
    private func saveRecoveryState(drafts nextDrafts:[WorkroomDraft],cases nextCases:[WorkroomCase],ids:Set<UUID>,extra:WorkroomEnhancements,trash nextTrash:[WorkroomTrashEntry],undo:FilingUndo?) throws {
        guard error == nil else { throw DailyError.invalid }
        guard nextTrash.count <= 50 else { throw RecoveryExperienceError.full }
        try writeActiveVisual(for:nextDrafts,cases:nextCases)
        try store.save(WorkroomArchive(drafts:nextDrafts,cases:nextCases.filter { ids.contains($0.id) },enhancements:extra,trash:nextTrash.filter(\.savedLocally),filingUndo:undo))
        drafts = nextDrafts;cases = nextCases;savedCaseIDs = ids;enhancements = extra;trash = nextTrash;filingUndo = undo
        pruneOriginals(drafts:nextDrafts,cases:nextCases,ids:ids)
    }
    func moveToTrash(draftIDs:Set<UUID>,caseIDs:Set<UUID>,at now:Date = Date()) throws {
        let selectedDrafts = drafts.filter { draftIDs.contains($0.id) },selectedCases = cases.filter { caseIDs.contains($0.id) }
        guard selectedDrafts.count == draftIDs.count,selectedCases.count == caseIDs.count,!draftIDs.isEmpty || !caseIDs.isEmpty else { throw RecoveryExperienceError.missing }
        var deleted = selectedDrafts.map { WorkroomTrashEntry(deletedAt:now,draft:$0,savedLocally:true,filing:enhancements.filing["草稿:\($0.id)"]) }
        deleted += selectedCases.map { WorkroomTrashEntry(deletedAt:now,project:$0,savedLocally:savedCaseIDs.contains($0.id),filing:enhancements.filing["事务:\($0.id)"]) }
        var extra = enhancements
        for row in deleted { extra.filing.removeValue(forKey:row.key) }
        if let id = extra.lastDraftID,draftIDs.contains(id) { extra.lastDraftID = nil };if let id = extra.lastCaseID,caseIDs.contains(id) { extra.lastCaseID = nil }
        try saveRecoveryState(drafts:drafts.filter { !draftIDs.contains($0.id) },cases:cases.filter { !caseIDs.contains($0.id) },ids:savedCaseIDs.subtracting(caseIDs),extra:extra,trash:deleted+trash,undo:filingUndo)
        notice = .init(text:"已移到最近删除 · \(deleted.count) 项",action:deleted.count == 1 ? .restore(deleted[0].id) : .recentlyDeleted)
    }
    func restoreDeleted(_ id:UUID) throws {
        guard let entry = trash.first(where:{$0.id == id}) else { throw RecoveryExperienceError.missing }
        var nextDrafts = drafts,nextCases = cases,ids = savedCaseIDs,extra = enhancements
        if let draft = entry.draft { guard !drafts.contains(where:{$0.id == draft.id}) else { throw RecoveryExperienceError.conflict };nextDrafts.insert(draft,at:0) }
        if var item = entry.project {
            guard !cases.contains(where:{$0.id == item.id}) else { throw RecoveryExperienceError.conflict }
            item.reminderAt = nil;nextCases.insert(item,at:0);if entry.savedLocally { ids.insert(item.id) }
        }
        if let filing = entry.filing,extra.filing[entry.key] == nil { extra.filing[entry.key] = filing }
        try saveRecoveryState(drafts:nextDrafts,cases:nextCases,ids:ids,extra:extra,trash:trash.filter { $0.id != id },undo:filingUndo)
        notice = .init(text:entry.project == nil ? "草稿已恢复" : "事务已按原状态恢复，旧提醒保持关闭")
    }
    func permanentlyRemoveDeleted(_ ids:Set<UUID>) throws {
        guard !ids.isEmpty,ids.isSubset(of:Set(trash.map(\.id))) else { throw RecoveryExperienceError.missing }
        try saveRecoveryState(drafts:drafts,cases:cases,ids:savedCaseIDs,extra:enhancements,trash:trash.filter { !ids.contains($0.id) },undo:filingUndo)
        notice = .init(text:"所选最近删除记录已永久清理")
    }
    func previewFiling(_ keys:Set<String>,filing:RecordFiling) throws -> FilingChangePreview {
        try FilingChangePreview.make(keys:keys,replacement:filing,current:enhancements.filing)
    }
    func applyFilingPreview(_ preview:FilingChangePreview) throws {
        let current = try previewFiling(preview.keys,filing:preview.replacement)
        guard current.fingerprint == preview.fingerprint else { throw RecoveryExperienceError.stale }
        var extra = enhancements;for key in preview.keys { extra.filing[key] = preview.replacement }
        let undo = FilingUndo(previous:preview.previous,previouslyAbsent:preview.absent,applied:Dictionary(uniqueKeysWithValues:preview.keys.map { ($0,preview.replacement) }))
        try saveRecoveryState(drafts:drafts,cases:cases,ids:savedCaseIDs,extra:extra,trash:trash,undo:undo)
        notice = .init(text:"已整理 \(preview.keys.count) 项资料",action:.undoFiling)
    }
    func undoLastFiling() throws {
        guard let undo = filingUndo else { throw RecoveryExperienceError.missing }
        guard undo.applied.allSatisfy({ enhancements.filing[$0.key] == $0.value }) else { throw RecoveryExperienceError.stale }
        var extra = enhancements
        for key in undo.previouslyAbsent { extra.filing.removeValue(forKey:key) };for (key,value) in undo.previous { extra.filing[key] = value }
        try saveRecoveryState(drafts:drafts,cases:cases,ids:savedCaseIDs,extra:extra,trash:trash,undo:nil)
        notice = .init(text:"已撤销最近一次分类调整")
    }
    func previewCleanup(draftIDs:Set<UUID>,caseIDs:Set<UUID>) throws -> CleanupChangePreview {
        try CleanupChangePreview.make(draftIDs:draftIDs,caseIDs:caseIDs,drafts:drafts,cases:cases,savedIDs:savedCaseIDs)
    }
    func applyCleanupPreview(_ preview:CleanupChangePreview) throws {
        let latest = try previewCleanup(draftIDs:preview.draftIDs,caseIDs:preview.caseIDs)
        guard latest.fingerprint == preview.fingerprint else { throw RecoveryExperienceError.stale }
        try moveToTrash(draftIDs:preview.draftIDs,caseIDs:preview.caseIDs)
    }
    @discardableResult func installExampleSources(includeProject:Bool) throws -> UUID? {
        let group = ExampleExperience.groupID
        let existing = cases.first(where:{$0.exampleGroup == group && $0.demonstration})
        var newDrafts = drafts
        if !drafts.contains(where:{$0.exampleGroup == group && $0.title == ExampleExperience.supplement().title}) { newDrafts.insert(ExampleExperience.supplement(),at:0) }
        var newCases = cases,ids = savedCaseIDs,id:UUID? = includeProject ? existing?.id : nil
        if includeProject && existing == nil { let item = ExampleExperience.project();id = item.id;newCases.insert(item,at:0);ids.insert(item.id) }
        try saveRecoveryState(drafts:newDrafts,cases:newCases,ids:ids,extra:enhancements,trash:trash,undo:filingUndo)
        return id
    }
    func clearExampleExperience() throws {
        let group = ExampleExperience.groupID
        let draftIDs = Set(drafts.filter { $0.exampleGroup == group && $0.demonstration }.map(\.id))
        let caseIDs = Set(cases.filter { $0.exampleGroup == group && $0.demonstration }.map(\.id))
        var extra = enhancements
        for id in draftIDs { extra.filing.removeValue(forKey:"草稿:\(id)") };for id in caseIDs { extra.filing.removeValue(forKey:"事务:\(id)") }
        if extra.lastDraftID.map(draftIDs.contains) == true { extra.lastDraftID = nil };if extra.lastCaseID.map(caseIDs.contains) == true { extra.lastCaseID = nil }
        try saveRecoveryState(drafts:drafts.filter { !draftIDs.contains($0.id) },cases:cases.filter { !caseIDs.contains($0.id) },ids:savedCaseIDs.subtracting(caseIDs),extra:extra,trash:trash.filter { $0.exampleGroup != group || !$0.demonstration },undo:filingUndo?.applied.keys.contains(where:{ key in draftIDs.contains(where:{key == "草稿:\($0)"}) || caseIDs.contains(where:{key == "事务:\($0)"}) }) == true ? nil : filingUndo)
        if active.exampleGroup == group && active.demonstration { newDraft() }
        notice = .init(text:"内置体验数据已清理")
    }
}

@MainActor extension WorkroomService {
    @discardableResult
    func createSplitCases(_ preview:NoticeSplitPreview,selected:Set<UUID>,confirmed:Bool,journeyID:UUID? = nil) throws -> [UUID] {
        guard confirmed,!selected.isEmpty else { throw CampusError.consent }
        guard preview.fingerprint == (try WatchAgendaCodec.fingerprint(active)),preview.source.draftID == active.id,preview.source.revision == active.revision,preview.source.text == active.text,preview.source.title == active.title,preview.source.origin == active.origin,preview.source.visualID == active.visualID else { throw CampusError.stale }
        guard selected.isSubset(of:Set(preview.parts.map(\.id))),Set(preview.parts.map(\.id)).count == preview.parts.count else { throw CampusError.invalid }
        let parts = preview.parts.filter { selected.contains($0.id) }
        guard parts.count <= 10,cases.count+parts.count <= 100,parts.allSatisfy({!$0.quote.isEmpty && preview.source.text.contains($0.quote) && !$0.title.isEmpty && $0.title.count <= 60}),cases.allSatisfy({!selected.contains($0.id)}) else { throw CampusError.limit }
        let added = parts.map { part -> WorkroomCase in
            var item = WorkroomCase();item.id = part.id;item.title = part.title;item.note = String(part.quote.prefix(500));item.demonstration = preview.source.demonstration;item.sources = [preview.source];item.dueAt = part.dueAt
            item.steps = [CaseStep(title:"核对办理要求",sourceQuote:String(part.quote.prefix(200)),sourceLabel:preview.source.title+" 第 \(preview.source.revision) 版")];return item
        }
        try added.forEach { try $0.validate() }
        var extra = enhancements
        if let journeyID {
            guard var ledger = extra.campus,let index = ledger.journeys.firstIndex(where:{$0.id == journeyID}),ledger.journeys[index].demonstration == preview.source.demonstration else { throw CampusError.missing }
            ledger.journeys[index].caseIDs += added.map(\.id)
            var versions = ledger.journeys[index].caseVersions ?? [:];for project in added { versions[project.id.uuidString] = try project.journeyVersion() };ledger.journeys[index].caseVersions = versions;ledger.journeys[index].revision += 1;ledger.journeys[index].updatedAt = Date();extra.campus = ledger
        }
        var ids = savedCaseIDs;ids.formUnion(added.map(\.id));let next = added+cases
        try writeActiveVisual(for:drafts,cases:next)
        try store.save(WorkroomArchive(drafts:drafts,cases:next.filter { ids.contains($0.id) },enhancements:extra,trash:trash.filter(\.savedLocally),filingUndo:filingUndo))
        cases = next;savedCaseIDs = ids;enhancements = extra;return added.map(\.id)
    }
    func recordJourneyOutcome(_ id:UUID,fingerprint:String,note:String,nextAction:String,reminder:Date?,finish:Bool) throws {
        guard var ledger = enhancements.campus,let index = ledger.journeys.firstIndex(where:{$0.id == id}),try ledger.journeys[index].fingerprint() == fingerprint else { throw CampusError.stale }
        let journey = ledger.journeys[index]
        guard !note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,note.count <= 500,nextAction.count <= 100,
              reminder == nil || (!journey.demonstration && !nextAction.isEmpty && reminder! > Date()) else { throw CampusError.invalid }
        var next = cases,ids = savedCaseIDs,outcome = JourneyOutcome(note:note,nextAction:nextAction)
        if !nextAction.isEmpty {
            var item = WorkroomCase();item.title = String(nextAction.prefix(60));item.note = String(note.prefix(500));item.demonstration = journey.demonstration
            item.steps = [CaseStep(title:nextAction)];item.reminderAt = reminder;outcome.followUpCaseID = item.id
            try item.validate();next.insert(item,at:0);ids.insert(item.id);ledger.journeys[index].caseIDs.append(item.id);var versions = ledger.journeys[index].caseVersions ?? [:];versions[item.id.uuidString] = try item.journeyVersion();ledger.journeys[index].caseVersions = versions
        }
        ledger.journeys[index].outcomes.append(outcome);ledger.journeys[index].stage = finish ? .finished : .followUp
        ledger.journeys[index].revision += 1;ledger.journeys[index].updatedAt = Date()
        var extra = enhancements;extra.campus = ledger
        try store.save(WorkroomArchive(drafts:drafts,cases:next.filter { ids.contains($0.id) },enhancements:extra,trash:trash.filter(\.savedLocally),filingUndo:filingUndo))
        cases = next;savedCaseIDs = ids;enhancements = extra
    }
}
