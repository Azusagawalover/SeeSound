import Foundation
import Combine

@MainActor
final class RoutineService: ObservableObject {
    @Published private(set) var items: [RoutineItem] = []
    @Published private(set) var savedIDs: Set<UUID> = []
    @Published private(set) var error: String?
    private let store: RoutineStore
    init(store: RoutineStore = RoutineStore()) {
        self.store = store
        do { items = try store.load(); savedIDs = Set(items.map(\.id)) }
        catch { self.error = "本地待办未能读取，原文件已保留：\(error.localizedDescription)" }
    }
    func put(_ draft: RoutineItem, saveLocally: Bool) throws {
        let original = items.first { $0.id == draft.id }
        let item = original.map { draft.preservingSource(from: $0) } ?? draft
        try commit(item, saveLocally: saveLocally)
    }
    private func commit(_ item: RoutineItem, saveLocally: Bool) throws {
        try item.validate()
        guard items.contains(where: { $0.id == item.id }) || items.count < 80 else { throw DailyError.capacity }
        if let source = item.sourceCardID, !item.completed,
           items.contains(where: { $0.id != item.id && !$0.completed && $0.sourceCardID == source && $0.sourceRevision == item.sourceRevision }) { throw RoutineError.duplicate }
        var ids = savedIDs; if saveLocally { ids.insert(item.id) } else { ids.remove(item.id) }
        var next = items.filter { $0.id != item.id }; next.insert(item, at: 0)
        if saveLocally || savedIDs.contains(item.id) { try store.save(next.filter { ids.contains($0.id) }, consent: true) }
        items = next; savedIDs = ids
    }
    func complete(_ id: UUID, completed: Bool, now: Date = Date()) throws {
        guard var item = items.first(where: { $0.id == id }) else { throw DailyError.stale }
        item.completedAt = completed ? max(now, item.createdAt) : nil
        try commit(item, saveLocally: savedIDs.contains(id))
    }
    func refreshSource(_ id: UUID, card: InformationCard) throws {
        guard var item = items.first(where: { $0.id == id }) else { throw DailyError.stale }
        try item.refreshSource(card); try commit(item, saveLocally: savedIDs.contains(id))
    }
    func remove(_ id: UUID) throws {
        let next = items.filter { $0.id != id }
        if savedIDs.contains(id) { try store.save(next.filter { savedIDs.contains($0.id) }, consent: true) }
        items = next; savedIDs.remove(id)
    }
    func reloadFromDisk() throws {
        let restored = try store.load();let ids = Set(restored.map(\.id))
        let unsaved = items.filter { !savedIDs.contains($0.id) && !ids.contains($0.id) }
        guard restored.count+unsaved.count <= 80 else { throw DailyError.capacity }
        items = restored+unsaved;savedIDs = ids;error = nil
    }
    func reset() throws { try store.reset(); items.removeAll(); savedIDs.removeAll(); error = nil }
    func discardUnsavedDemonstrations() { items.removeAll { $0.isDemonstration && !savedIDs.contains($0.id) } }
}


enum AgendaAuthorization { case allowed, denied, notDetermined }
struct AgendaRequestState { var id: String; var plannedAt: Double? }
@MainActor
protocol AgendaNotificationClient: AnyObject {
    func authorization() async -> AgendaAuthorization
    func requestPermission() async throws
    func pending() async -> [AgendaRequestState]
    func delivered() async -> [AgendaRequestState]
    func removePending(_ ids:[String])
    func removeDelivered(_ ids:[String])
    func add(_ notice:ScheduledNotice) async throws
}

@MainActor
final class AppointmentReminderService: ObservableObject {
    @Published private(set) var status = "只提醒你手动设置且保存到本机的事项。"
    @Published private(set) var permission = "尚未检查通知权限"
    @Published private(set) var scheduledIDs: Set<String> = []
    @Published private(set) var deferredCount = 0
    @Published private(set) var authorizationState:AgendaAuthorization = .notDetermined
    @Published private(set) var deliveredIDs:Set<String> = []
    @Published private(set) var failedIDs:Set<String> = []
    private let client: AgendaNotificationClient
    init(client: AgendaNotificationClient) { self.client = client }
    private var latest: [ScheduledNotice] = []
    private var suspended = false
    private var revision = UUID()
    private(set) var reconciling = false

    func update(routines: [RoutineItem], savedRoutineIDs: Set<UUID>, cases: [WorkroomCase], savedCaseIDs: Set<UUID>) {
        latest = AgendaPlanner.notices(routines: routines, savedRoutineIDs: savedRoutineIDs, cases: cases, savedCaseIDs: savedCaseIDs, now: .distantPast)
        revision = UUID()
        reconcile()
    }
    func suspend() { suspended = true;revision = UUID();reconcile() }
    func resume() { suspended = false;revision = UUID();reconcile() }
    func refresh() { revision = UUID(); reconcile() }
    func requestPermission() async {
        do { try await client.requestPermission(); refresh() }
        catch { status = "通知授权未完成，请重试或在系统设置中检查。" }
    }
    func isScheduled(_ kind: ScheduledDestination.Kind, id: UUID) -> Bool {
        scheduledIDs.contains(ScheduledNotice(destination: .init(kind: kind, recordID: id), date: .now).id)
    }
    private func reconcile() {
        guard !reconciling else { return }
        reconciling = true
        Task {
            while true {
                let token = revision, all = latest
                let authorization = await client.authorization()
                if revision != token { continue }
                authorizationState = authorization
                let allowed = authorization == .allowed
                permission = allowed ? "系统通知已允许" : authorization == .denied ? "通知已关闭，请到系统设置开启" : "尚未允许系统通知"
                let upcoming = all.filter { $0.date > Date() }
                let desired = allowed && !suspended ? Array(upcoming.prefix(AgendaPlanner.limit)) : []
                deferredCount = max(0, upcoming.count - AgendaPlanner.limit)
                let keep = Dictionary(uniqueKeysWithValues: desired.map { ($0.id,$0) })
                let valid = Dictionary(uniqueKeysWithValues: all.map { ($0.id,$0) })
                let pending = await client.pending()
                if revision != token { continue }
                let obsolete = pending.filter { request in
                    guard request.id.hasPrefix("seesound-agenda-") else { return false }
                    guard let notice = keep[request.id] else { return true }
                    return (request.plannedAt) != notice.date.timeIntervalSince1970
                }.map(\.id)
                client.removePending(obsolete)
                let delivered = await client.delivered()
                if revision != token { continue }
                client.removeDelivered(delivered.compactMap { request in
                    guard request.id.hasPrefix("seesound-agenda-") else { return nil }
                    guard let notice = valid[request.id], (request.plannedAt) == notice.date.timeIntervalSince1970 else { return request.id }
                    return nil
                })
                var failed = false
                var failures:Set<String> = []
                let existing = Set(pending.filter { request in
                    guard let notice = keep[request.id] else { return false }
                    return (request.plannedAt) == notice.date.timeIntervalSince1970
                }.map(\.id))
                for notice in desired where !existing.contains(notice.id) {
                    if revision != token { break }
                    guard notice.date > Date() else { continue }
                    do { try await client.add(notice) }
                    catch { failed = true;failures.insert(notice.id) }
                }
                if revision != token { continue }
                let actual = await client.pending()
                if revision != token { continue }
                failedIDs = failures
                deliveredIDs = Set(delivered.filter { request in guard let notice = valid[request.id] else { return false };return notice.date.timeIntervalSince1970 == request.plannedAt }.map(\.id))
                scheduledIDs = Set(actual.map(\.id).filter { keep[$0] != nil })
                status = !allowed ? "授权后才会安排；已保存的时间仍保留。" : failed ? "部分提醒未能安排，请检查系统设置后重试。" : "已安排 \(scheduledIDs.count) 条提醒" + (deferredCount > 0 ? "，其余 \(deferredCount) 条待下次打开应用补排。" : "。")
                reconciling = false
                return
            }
        }
    }
}
