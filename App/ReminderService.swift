import Combine
import UIKit
import UserNotifications

@MainActor
final class ReminderService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var queue = ReminderQueue()
    @Published private var preview: QueuedReminder?
    var activeEvent: SenseEvent? { preview?.event ?? (queue.isCollapsed ? nil : queue.current()?.event) }
    var activePriority: ReminderPriority { preview?.priority ?? queue.current()?.priority ?? .normal }
    var hasPreview: Bool { preview != nil }
    @Published private(set) var permission = "尚未检查通知权限"
    @Published private(set) var status = "提醒规则只作用于已产生的事件，不提供后台持续识别。"
    var onOpenScheduled: ((ScheduledDestination) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var gate = ReminderGate()
    private var requestIDs: [UUID: [String]] = [:]
    private var generations: [UUID: UUID] = [:]
    private var order: [UUID] = []
    private var trackedCategories: [UUID: String] = [:]
    private var wakeTask: Task<Void, Never>?
    private var wakeID = UUID()
    override init() { super.init(); center.delegate = self }

    func refreshPermission() async {
        let settings = await center.notificationSettings()
        permission = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional ? "系统通知已允许" : settings.authorizationStatus == .denied ? "系统通知已拒绝" : "系统通知尚未授权"
    }
    func requestPermission() async {
        do { _ = try await center.requestAuthorization(options: [.alert]); await refreshPermission() }
        catch { status = "通知权限未完成：\(error.localizedDescription)" }
    }
    func deliver(_ event: SenseEvent, rule: ReminderRule, preview: Bool = false) {
        queue.update(event)
        guard preview || gate.allows(event, rule: rule) else { return }
        if rule.visual {
            if preview { self.preview = QueuedReminder(event: event, priority: rule.priority) }
            else { queue.enqueue(event, priority: rule.priority) }
        }
        if rule.haptic && UIDevice.current.userInterfaceIdiom == .phone {
            let generator = UINotificationFeedbackGenerator(); generator.prepare()
            generator.notificationOccurred(ReminderGate.category(for: event) == "clapping" ? .success : .warning)
        }
        if rule.notifications {
            cancelRequests(event.id)
            let generation = UUID()
            generations[event.id] = generation
            trackedCategories[event.id] = ReminderQueue.categoryKey(for: event)
            order.append(event.id)
            requestIDs[event.id] = (0...rule.repeatCount).map { "seesound-reminder-\(event.id.uuidString)-\(generation.uuidString)-\($0)" }
            // At most 30 event requests, leaving room for 24 explicitly scheduled reminders.
            while order.count > 10 { cancelRequests(order[0]) }
            Task { await schedule(event, rule: rule, generation: generation) }
        }
        status = preview ? "这是明确标注的提醒预览，不是识别结果。" : "已按此类规则提醒；冷却与暂缓期间仍保留事件记录。"
    }
    func deliverDemonstration(_ event: SenseEvent) {
        guard event.isDemonstration else { return }
        queue.enqueue(event, priority: .normal)
        status = "场景演示只进入应用内队列，不触发通知或触觉。"
    }
    private func schedule(_ event: SenseEvent, rule: ReminderRule, generation: UUID, delay: TimeInterval = 1) async {
        let settings = await center.notificationSettings()
        guard generations[event.id] == generation else { return }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            permission = "系统通知未允许，请在提醒设置主动授权"; return
        }
        for index in 0...rule.repeatCount {
            guard generations[event.id] == generation else { return }
            let id = "seesound-reminder-\(event.id.uuidString)-\(generation.uuidString)-\(index)"
            let content = UNMutableNotificationContent()
            content.title = event.isDemonstration ? "演示提醒 · \(event.title)" : event.title
            content.body = index == 0 ? "打开见声查看并确认。" : "这条事件仍待确认。"
            content.userInfo = ["seesound": true, "eventID": event.id.uuidString]
            let request = UNNotificationRequest(identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay + Double(index * rule.repeatInterval), repeats: false))
            do {
                try await center.add(request)
                if generations[event.id] != generation {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                    center.removeDeliveredNotifications(withIdentifiers: [id]); return
                }
            }
            catch { status = "通知安排失败：\(error.localizedDescription)" }
        }
    }
    func confirm(_ id: UUID) { cancel(id) }
    func dismiss() { if preview != nil { preview = nil } else { queue.collapse() } }
    func show(_ id: UUID) { preview = nil; queue.select(id) }
    func restoreQueue() { preview = nil; queue.restore() }
    func next() { preview = nil; queue.next() }
    func cancel(_ id: UUID) {
        queue.remove(id); if preview?.id == id { preview = nil }
        cancelRequests(id); armWake()
    }
    private func cancelRequests(_ id: UUID) {
        generations[id] = nil; order.removeAll { $0 == id }
        trackedCategories[id] = nil
        let ids = requestIDs.removeValue(forKey: id) ?? (0...2).map { "seesound-reminder-\(id.uuidString)-\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        Task {
            let prefix = "seesound-reminder-\(id.uuidString)-"
            let pending = await center.pendingNotificationRequests()
            let keep = Set(requestIDs[id] ?? [])
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) && !keep.contains($0) })
            let delivered = await center.deliveredNotifications()
            let current = Set(requestIDs[id] ?? [])
            center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) && !current.contains($0) })
        }
    }
    func snooze(_ event: SenseEvent) {
        let category = ReminderQueue.categoryKey(for: event)
        let until = Date().addingTimeInterval(300)
        if !event.isDemonstration { gate.snooze(category, until: until) }
        queue.snooze(category, until: until)
        for id in trackedCategories.filter({ $0.value == category }).map(\.key) { cancelRequests(id) }
        if preview?.id == event.id { preview = nil }
        armWake()
        status = "这一类已暂缓 5 分钟，事件仍在列表中。"
    }
    func resume(_ category: String) { gate.resume(category); queue.resume(category); armWake(); status = "已恢复这一类提醒。" }
    func rulesChanged(_ category: String, hideVisual: Bool, priority: ReminderPriority) {
        for id in trackedCategories.filter({ $0.value == category || $0.value == "demo:" + category }).map(\.key) { cancelRequests(id) }
        if hideVisual {
            queue.removeCategory(category)
            if let preview, ReminderGate.category(for: preview.event) == category { self.preview = nil }
        } else { queue.setPriority(priority, category: category) }
        armWake()
    }
    func retain(_ ids: Set<UUID>) {
        queue.retain(ids)
        for id in Array(requestIDs.keys) where !ids.contains(id) { cancel(id) }
        armWake()
    }
    func cancelAll() {
        for id in Array(requestIDs.keys) { cancel(id) }
        queue = ReminderQueue(); preview = nil; wakeTask?.cancel(); wakeTask = nil; wakeID = UUID()
        Task {
            let pending = await center.pendingNotificationRequests()
            let keep = Set(requestIDs.values.flatMap { $0 })
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("seesound-reminder-") && !keep.contains($0) })
            let delivered = await center.deliveredNotifications()
            let current = Set(requestIDs.values.flatMap { $0 })
            center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix("seesound-reminder-") && !current.contains($0) })
        }
    }
    func refreshQueue() { queue.refresh(); armWake() }
    private func armWake() {
        wakeTask?.cancel(); wakeTask = nil; wakeID = UUID()
        let now = Date()
        guard let date = queue.entries.compactMap(\.snoozedUntil).filter({ $0 > now }).min() else { return }
        let token = wakeID
        wakeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(300, max(0, date.timeIntervalSinceNow)) * 1_000_000_000)) } catch { return }
            guard let self, self.wakeID == token else { return }; self.queue.refresh(); self.armWake()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let destination = ScheduledDestination.parse(kind: info["agendaKind"] as? String, id: info["recordID"] as? String)
        Task { @MainActor in
            if let destination { self.onOpenScheduled?(destination) }
            completionHandler()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.content.userInfo["eventID"] as? String
        Task { @MainActor in completionHandler(ReminderForegroundPolicy.suppress(eventID:id,activeEventID:self.activeEvent?.id) ? [] : [.banner, .list]) }
    }
}

@MainActor
final class ConversationArchiveService: ObservableObject {
    @Published private(set) var items: [SavedConversation] = []
    @Published private(set) var status: String?
    private let store = ConversationArchiveStore()
    init() { reload() }
    func reload() {
        do { items = try store.load(); status = nil }
        catch { status = "读取失败，原文件已保留：\(error.localizedDescription)" }
    }
    @discardableResult
    func save(title: String, turns: [ConversationTurn], consent: Bool) -> Bool {
        let item = SavedConversation(title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)), createdAt: Date(), turns: turns.map(SavedConversationTurn.init))
        do { try store.save(item, consent: consent); reload(); return true }
        catch { status = "保存未完成：\(error.localizedDescription)"; return false }
    }
    func delete(_ id: UUID) {
        do { try store.delete(id); reload() }
        catch { status = "删除未完成：\(error.localizedDescription)" }
    }
}


@MainActor
final class SystemAgendaNotificationClient: AgendaNotificationClient {
    private let center = UNUserNotificationCenter.current()
    func authorization() async -> AgendaAuthorization {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional { return .allowed }
        return settings.authorizationStatus == .denied ? .denied : .notDetermined
    }
    func requestPermission() async throws { _ = try await center.requestAuthorization(options:[.alert]) }
    func pending() async -> [AgendaRequestState] {
        await center.pendingNotificationRequests().map { .init(id:$0.identifier,plannedAt:$0.content.userInfo["plannedAt"] as? Double) }
    }
    func delivered() async -> [AgendaRequestState] {
        await center.deliveredNotifications().map { .init(id:$0.request.identifier,plannedAt:$0.request.content.userInfo["plannedAt"] as? Double) }
    }
    func removePending(_ ids:[String]) { center.removePendingNotificationRequests(withIdentifiers:ids) }
    func removeDelivered(_ ids:[String]) { center.removeDeliveredNotifications(withIdentifiers:ids) }
    func add(_ notice:ScheduledNotice) async throws {
        let content = UNMutableNotificationContent()
        content.title = notice.destination.kind == .routine ? "见声 · 待办提醒" : "见声 · 事务提醒"
        content.body = "你设置的提醒时间到了，打开见声查看。"
        content.userInfo = ["agendaKind":notice.destination.kind.rawValue,"recordID":notice.destination.recordID.uuidString,"plannedAt":notice.date.timeIntervalSince1970]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval:max(1,notice.date.timeIntervalSinceNow),repeats:false)
        try await center.add(UNNotificationRequest(identifier:notice.id,content:content,trigger:trigger))
    }
}
