import Foundation
import CryptoKit
import CommonCrypto

enum LibraryError: LocalizedError {
    case invalid, password, stale, historyConsent, recovery, capacity
    var errorDescription: String? {
        switch self {
        case .invalid: return "文件格式、版本或内容不符合要求，没有修改本机资料。"
        case .password: return "密码不正确，或文件已损坏。密码至少 8 个字符。"
        case .stale: return "本机资料已改变，请重新预览后再恢复。"
        case .historyConsent: return "请明确选择是否将事件摘要保存在本机。"
        case .recovery: return "恢复未完成，已保留恢复日志。请先重试恢复原资料。"
        case .capacity: return "合并后超过资料容量，请先减少所选内容。"
        }
    }
}
struct LibrarySnapshot: Codable {
    var version = 1
    var preferences = AppPreferences()
    var history = JournalArchive(events:[],annotations:[:])
    var workroom = WorkroomArchive()
    var cards: [InformationCard] = []
    var routines: [RoutineItem] = []
    var conversations: [SavedConversation] = []
    var quality = QualityArchive()
    func validate() throws {
        guard version == 1, cards.count <= 30, routines.count <= 80, conversations.count <= 30,
              Set(cards.map(\.id)).count == cards.count, Set(routines.map(\.id)).count == routines.count,
              Set(conversations.map(\.id)).count == conversations.count else { throw LibraryError.capacity }
        for item in workroom.cases {
            for link in item.links {
                if link.kind == .card,let card = cards.first(where:{$0.id == link.id}), (card.origin == .demonstration) != item.demonstration { throw WorkroomError.mixedSource }
                if link.kind == .routine,let task = routines.first(where:{$0.id == link.id}),task.isDemonstration != item.demonstration { throw WorkroomError.mixedSource }
            }
        }
        for journey in workroom.enhancements?.campus?.journeys ?? [] {
            for id in journey.caseIDs { if let item = workroom.cases.first(where:{$0.id == id}),item.demonstration != journey.demonstration { throw WorkroomError.mixedSource } }
            for row in journey.conversations { if let saved = conversations.first(where:{$0.id == row.conversationID}),saved.containsDemonstration != journey.demonstration { throw WorkroomError.mixedSource } }
        }
        for task in routines { if let card = cards.first(where:{$0.id == task.sourceCardID}),(card.origin == .demonstration) != task.isDemonstration { throw WorkroomError.mixedSource } }
        try workroom.validate();try cards.forEach { try $0.validate() };try routines.forEach { try $0.validate() };try conversations.forEach { try $0.validate() };try quality.validate()
        _ = try history.validated(since:.distantPast)
        guard preferences.saveHistory || history.events.isEmpty,
              [1,7,30].contains(preferences.retentionDays),preferences.phrases.count <= PhraseCollection.limit,
              preferences.phrases.allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else { throw LibraryError.invalid }
        _ = try JSONDecoder().decode(AppPreferences.self,from:JSONEncoder().encode(preferences))
        guard try JSONEncoder().encode(preferences).count <= 524_288,
              try JSONEncoder().encode(cards).count <= 200_000,
              try JSONEncoder().encode(routines).count <= 500_000,
              try JSONEncoder().encode(workroom).count <= 8_000_000,
              try conversations.allSatisfy({ try JSONEncoder().encode($0).count <= 200_000 }) else { throw LibraryError.capacity }
    }
    var counts: [(String,Int)] { [("办事旅程",workroom.enhancements?.campus?.journeys.count ?? 0),("事务",workroom.cases.count),("草稿",workroom.drafts.count),("信息卡",cards.count),("待办",routines.count),("会话",conversations.count),("事件摘要",history.events.count),("验证与复核",quality.records.count+quality.reports.count)] }
    func fingerprint() throws -> String {
        // Normalize unordered sets and UUID dictionaries; preserve checklist and history order.
        func normalize(_ object:Any) -> Any {
            if let array = object as? [Any] { return array.map(normalize) }
            if let dictionary = object as? [String:Any] {
                return dictionary.mapValues(normalize).reduce(into:[String:Any]()) { output,entry in
                    if entry.key == "sounds",let values = entry.value as? [String] { output[entry.key] = values.sorted() }
                    else if entry.key == "annotations",let values = entry.value as? [Any],values.count % 2 == 0 {
                        var pairs:[(String,Any)] = []
                        for index in stride(from:0,to:values.count,by:2) {
                            guard let key = values[index] as? String else { output[entry.key] = entry.value;return }
                            pairs.append((key,values[index+1]))
                        }
                        output[entry.key] = pairs.sorted { $0.0 < $1.0 }.map { [$0.0,$0.1] as [Any] }
                    } else { output[entry.key] = entry.value }
                }
            }
            return object
        }
        let json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(self))
        let data = try JSONSerialization.data(withJSONObject:normalize(json),options:[.sortedKeys])
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    func handoff(caseID:UUID) throws -> LibrarySnapshot {
        guard let item = workroom.cases.first(where:{$0.id == caseID}) else { throw LibraryError.invalid }
        var result = LibrarySnapshot();result.workroom.cases = [item]
        let routineIDs = Set(item.links.filter { $0.kind == .routine }.map(\.id))
        result.routines = routines.filter { routineIDs.contains($0.id) }
        let cardIDs = Set(item.links.filter { $0.kind == .card }.map(\.id) + result.routines.compactMap(\.sourceCardID))
        result.cards = cards.filter { cardIDs.contains($0.id) }
        if let id = item.preparation?.draftID { result.workroom.drafts = workroom.drafts.filter { $0.id == id } }
        let keys = Set(result.workroom.cases.map { "事务:\($0.id)" }+result.workroom.drafts.map { "草稿:\($0.id)" }+result.cards.map { "信息卡:\($0.id)" }+result.routines.map { "待办:\($0.id)" })
        var extra = WorkroomEnhancements();extra.filing = workroom.enhancements?.filing.filter { keys.contains($0.key) } ?? [:];result.workroom.enhancements = extra
        try result.validate();return result
    }
}
struct LibraryPackage: Codable {
    var format = "SeeSoundLibrary"
    var version = 1
    var id = UUID()
    var createdAt = Date()
    var purpose = "backup"
    var snapshot: LibrarySnapshot
    func validate() throws {
        guard format == "SeeSoundLibrary", version == 1,["backup","handoff"].contains(purpose),createdAt.timeIntervalSince1970.isFinite,createdAt <= Date().addingTimeInterval(300) else { throw LibraryError.invalid }
        try snapshot.validate()
    }
}
private struct EncryptedLibraryEnvelope: Codable {
    var format = "SeeSoundEncryptedLibrary"
    var version = 1
    var iterations = 200_000
    var salt: Data
    var sealed: Data
}
enum LibraryCryptography {
    static let maxSize = 24_000_000
    private static func key(password:String,salt:Data) throws -> SymmetricKey {
        guard (8...128).contains(password.count), salt.count == 16 else { throw LibraryError.password }
        let bytes = Array(password.utf8)
        var output = [UInt8](repeating:0,count:32)
        let status = bytes.withUnsafeBytes { pass in salt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),pass.bindMemory(to:Int8.self).baseAddress,bytes.count,salt.bindMemory(to:UInt8.self).baseAddress,salt.count,CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),200_000,&output,32)
        } }
        guard status == kCCSuccess else { throw LibraryError.password }
        return SymmetricKey(data:output)
    }
    static func seal(_ package:LibraryPackage,password:String) throws -> Data {
        try package.validate()
        var export = package
        export.snapshot.workroom.trash = nil;export.snapshot.workroom.filingUndo = nil;export.snapshot.workroom.enhancements?.campus?.recoveries = [];export.snapshot.workroom.enhancements?.campus?.recoverEdits = false
        export.snapshot.workroom.enhancements?.campus?.workspace = nil
        export.snapshot = export.snapshot.withoutLocalVisualReferences()
        let plain = try JSONEncoder().encode(export);guard plain.count <= 16_000_000 else { throw LibraryError.capacity }
        let salt = Data((0..<16).map { _ in UInt8.random(in:0...255) })
        let box = try AES.GCM.seal(plain,using:key(password:password,salt:salt),authenticating:Data("SeeSoundLibrary-v1".utf8))
        guard let combined = box.combined else { throw LibraryError.invalid }
        let result = try JSONEncoder().encode(EncryptedLibraryEnvelope(salt:salt,sealed:combined))
        guard result.count <= maxSize else { throw LibraryError.capacity };return result
    }
    static func open(_ data:Data,password:String) throws -> LibraryPackage {
        guard !data.isEmpty,data.count <= maxSize else { throw LibraryError.invalid }
        let envelope = try JSONDecoder().decode(EncryptedLibraryEnvelope.self,from:data)
        guard envelope.format == "SeeSoundEncryptedLibrary",envelope.version == 1,envelope.iterations == 200_000,envelope.salt.count == 16,envelope.sealed.count <= 16_000_028 else { throw LibraryError.invalid }
        let plain:Data
        do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined:envelope.sealed),using:key(password:password,salt:envelope.salt),authenticating:Data("SeeSoundLibrary-v1".utf8)) }
        catch { throw LibraryError.password }
        var result = try JSONDecoder().decode(LibraryPackage.self,from:plain);try result.validate();result.snapshot = result.snapshot.withoutLocalVisualReferences();return result
    }
}
struct LibraryRestoreOptions {
    var preferIncoming = false
    var includeSettings = false
    var includeHistory = false
    var rearmReminders = false
}
struct LibraryRestorePreview {
    var localFingerprint:String
    var package:LibraryPackage
    var target:LibrarySnapshot
    var conflicts:Int
    var missingLinks:Int
}
enum LibraryMerge {
    static func preview(local:LibrarySnapshot,package:LibraryPackage,options:LibraryRestoreOptions) throws -> LibraryRestorePreview {
        try local.validate();try package.validate()
        var incoming = package.snapshot.withoutLocalVisualReferences(), target = local
        for journey in incoming.workroom.enhancements?.campus?.journeys ?? [] {
            if let old = local.workroom.enhancements?.campus?.journeys.first(where:{$0.id == journey.id}),old.demonstration != journey.demonstration { throw WorkroomError.mixedSource }
        }
        for card in incoming.cards { if let old = local.cards.first(where:{$0.id == card.id}),old.origin != card.origin { throw WorkroomError.mixedSource } }
        for task in incoming.routines { if let old = local.routines.first(where:{$0.id == task.id}),old.origin != task.origin { throw WorkroomError.mixedSource } }
        for item in incoming.workroom.cases { if let old = local.workroom.cases.first(where:{$0.id == item.id}),old.demonstration != item.demonstration { throw WorkroomError.mixedSource } }
        for draft in incoming.workroom.drafts { if let old = local.workroom.drafts.first(where:{$0.id == draft.id}),old.origin != draft.origin { throw WorkroomError.mixedSource } }
        if !options.rearmReminders {
            for i in incoming.routines.indices { incoming.routines[i].reminderAt = nil }
            for i in incoming.workroom.cases.indices { incoming.workroom.cases[i].reminderAt = nil }
        }
        var conflicts = 0
        func merge<T:Identifiable & Codable>(_ current:[T],_ imported:[T]) throws -> [T] where T.ID == UUID {
            var result = current
            for item in imported {
                if let index = result.firstIndex(where:{$0.id == item.id}) {
                    let a = try JSONEncoder().encode(result[index]), b = try JSONEncoder().encode(item)
                    if a != b { conflicts += 1 }
                    if options.preferIncoming { result[index] = item }
                } else { result.append(item) }
            };return result
        }
        target.workroom.drafts = try merge(local.workroom.drafts,incoming.workroom.drafts)
        target.workroom.cases = try merge(local.workroom.cases,incoming.workroom.cases)
        var extra = local.workroom.enhancements ?? WorkroomEnhancements()
        if let importedExtra = incoming.workroom.enhancements {
            for (key,value) in importedExtra.filing where extra.filing[key] == nil || options.preferIncoming { extra.filing[key] = value }
            if options.includeSettings { extra.templates = try merge(extra.templates,importedExtra.templates) }
            if let importedLedger = importedExtra.campus {
                var ledger = extra.campus ?? CampusLedger()
                ledger.journeys = try merge(ledger.journeys,importedLedger.journeys)
                if options.includeSettings { ledger.listOptions = importedLedger.listOptions }
                extra.campus = ledger
            }
        }
        target.workroom.enhancements = extra
        target.cards = try merge(local.cards,incoming.cards);target.routines = try merge(local.routines,incoming.routines)
        target.conversations = try merge(local.conversations,incoming.conversations)
        target.quality.records = try merge(local.quality.records,incoming.quality.records)
        target.quality.reports = try merge(local.quality.reports,incoming.quality.reports)
        if options.includeSettings {
            target.preferences = incoming.preferences
            target.preferences.saveHistory = local.preferences.saveHistory
            target.preferences.hasFinishedIntro = local.preferences.hasFinishedIntro
        }
        if options.includeHistory {
            target.preferences.saveHistory = true
            target.history.events = try merge(local.history.events,incoming.history.events)
            target.history.annotations.merge(incoming.history.annotations) { a,b in options.preferIncoming ? b : a }
            target.history.suppressedLinks = Array(Set(local.history.suppressedLinks+incoming.history.suppressedLinks))
        }
        target.history = try target.history.validated(since:Date().addingTimeInterval(-Double(target.preferences.retentionDays)*86400))
        try target.validate()
        let cards = Set(target.cards.map(\.id)),tasks = Set(target.routines.map(\.id)),draftIDs = Set(target.workroom.drafts.map(\.id))
        let missingDrafts = target.workroom.cases.filter { $0.preparation.map { !draftIDs.contains($0.draftID) } == true }.count
        let journeyMissing = (target.workroom.enhancements?.campus?.journeys ?? []).flatMap(\.caseIDs).filter { id in !target.workroom.cases.contains(where:{$0.id == id}) }.count
        let missing = journeyMissing + missingDrafts + target.workroom.cases.flatMap(\.links).filter { $0.kind == .card ? !cards.contains($0.id) : !tasks.contains($0.id) }.count + target.routines.filter { $0.sourceCardID.map { !cards.contains($0) } == true }.count
        return .init(localFingerprint:try local.fingerprint(),package:package,target:target,conflicts:conflicts,missingLinks:missing)
    }
}

struct AgendaEntry:Identifiable {
    enum State:String,CaseIterable,Identifiable {
        case scheduled, delivered, permission, deferred, failed, elapsed, unsaved, inactive, demonstration, pending
        var id:String { rawValue }
        var title:String {
            switch self { case .scheduled:return "已安排";case .delivered:return "系统记录已送达";case .permission:return "等待通知授权";case .deferred:return "等待补排";case .failed:return "安排失败";case .elapsed:return "时间已过 · 送达未知";case .unsaved:return "尚未保存";case .inactive:return "已停止提醒";case .demonstration:return "演示 · 不安排通知";case .pending:return "等待安排" }
        }
        var needsAttention:Bool { [.permission,.deferred,.failed,.unsaved,.pending].contains(self) }
    }
    var destination:ScheduledDestination
    var title:String
    var date:Date
    var state:State
    var id:String { ScheduledNotice(destination:destination,date:date).id }
}
enum AgendaOverview {
    static func rows(routines:[RoutineItem],savedRoutineIDs:Set<UUID>,cases:[WorkroomCase],savedCaseIDs:Set<UUID>,scheduled:Set<String>,delivered:Set<String>,failed:Set<String>,authorization:AgendaAuthorization,now:Date) -> [AgendaEntry] {
        let notices = AgendaPlanner.notices(routines:routines,savedRoutineIDs:savedRoutineIDs,cases:cases,savedCaseIDs:savedCaseIDs,now:now)
        let deferred = Set(notices.dropFirst(AgendaPlanner.limit).map(\.id))
        func row(kind:ScheduledDestination.Kind,id:UUID,title:String,date:Date,saved:Bool,demo:Bool,active:Bool) -> AgendaEntry {
            let destination = ScheduledDestination(kind:kind,recordID:id),key = ScheduledNotice(destination:.init(kind:kind,recordID:id),date:date).id
            let state:AgendaEntry.State
            if demo { state = .demonstration }
            else if !active { state = .inactive }
            else if !saved { state = .unsaved }
            else if delivered.contains(key) { state = .delivered }
            else if date <= now { state = .elapsed }
            else if authorization != .allowed { state = .permission }
            else if failed.contains(key) { state = .failed }
            else if scheduled.contains(key) { state = .scheduled }
            else if deferred.contains(key) { state = .deferred }
            else { state = .pending }
            return .init(destination:destination,title:title,date:date,state:state)
        }
        var result = routines.compactMap { item in item.reminderAt.map { row(kind:.routine,id:item.id,title:item.title,date:$0,saved:savedRoutineIDs.contains(item.id),demo:item.isDemonstration,active:!item.completed) } }
        result += cases.compactMap { item in item.reminderAt.map { row(kind:.project,id:item.id,title:item.title,date:$0,saved:savedCaseIDs.contains(item.id),demo:item.demonstration,active:item.isActive) } }
        return result.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
    }
}
struct WatchCaseVersion:Encodable { var item:WorkroomCase;var linked:[RoutineItem] }
extension WorkroomCase {
    func watchViewVersion(routines:[RoutineItem]) throws -> String {
        var copy = self;copy.watchSeenAt = nil;copy.watchSeenVersion = nil
        return try WatchAgendaCodec.fingerprint(WatchCaseVersion(item:copy,linked:routines.filter { row in links.contains { $0.kind == .routine && $0.id == row.id } }.sorted{$0.id.uuidString < $1.id.uuidString}))
    }
    func watchSummary(routines:[RoutineItem]) throws -> WatchAgendaItem {
        let viewedVersion = try watchViewVersion(routines:routines)
        return .init(id:id,kind:.project,title:title,next:String((nextAction(routines:routines) ?? "所列事项已处理").prefix(120)),dueAt:dueAt,fingerprint:try WatchAgendaCodec.fingerprint(WatchCaseVersion(item:self,linked:routines.filter { row in links.contains { $0.kind == .routine && $0.id == row.id } }.sorted { $0.id.uuidString < $1.id.uuidString })),demonstration:demonstration,completed:isCompleted,seen:watchSeenAt != nil && watchSeenVersion == viewedVersion)
    }
}
extension RoutineItem {
    func watchSummary() throws -> WatchAgendaItem {
        .init(id:id,kind:.routine,title:title,next:"在手表确认会标记此待办完成",dueAt:dueAt,fingerprint:try WatchAgendaCodec.fingerprint(self),demonstration:isDemonstration,completed:completed)
    }
}
