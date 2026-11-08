import Foundation

struct QueuedReminder: Identifiable, Equatable {
    var event: SenseEvent
    var priority: ReminderPriority
    var snoozedUntil: Date?
    var id: UUID { event.id }
    func available(at now: Date) -> Bool { snoozedUntil.map { $0 <= now } ?? true }
}

/// Holds the current card steady while new reminders arrive. Ledger remains independent.
struct ReminderQueue {
    static func categoryKey(for event: SenseEvent) -> String {
        (event.isDemonstration ? "demo:" : "") + ReminderGate.category(for: event)
    }
    private(set) var entries: [QueuedReminder] = []
    private(set) var selectedID: UUID?
    private(set) var isCollapsed = false
    func available(at now: Date = Date()) -> [QueuedReminder] {
        entries.enumerated().filter { $0.element.available(at: now) }.sorted {
            if $0.element.priority != $1.element.priority { return $0.element.priority == .prominent }
            return $0.offset < $1.offset
        }.map(\.element)
    }
    func current(at now: Date = Date()) -> QueuedReminder? {
        let items = available(at: now)
        return items.first { $0.id == selectedID } ?? items.first
    }
    mutating func enqueue(_ event: SenseEvent, priority: ReminderPriority, at now: Date = Date()) {
        guard event.status == .pending else { return }
        if let index = entries.firstIndex(where: { $0.id == event.id }) {
            entries[index].event = event; entries[index].priority = priority
        } else {
            // Reserve room beyond the 40 real ledger entries for transient scenario events.
            guard entries.count < 48 else { return }
            entries.append(QueuedReminder(event: event, priority: priority)); isCollapsed = false
        }
        refresh(at: now)
    }
    mutating func update(_ event: SenseEvent) {
        if let index = entries.firstIndex(where: { $0.id == event.id }) { entries[index].event = event }
    }
    mutating func refresh(at now: Date = Date()) {
        for index in entries.indices where entries[index].snoozedUntil.map({ $0 <= now }) == true {
            entries[index].snoozedUntil = nil; isCollapsed = false
        }
        if !available(at: now).contains(where: { $0.id == selectedID }) { selectedID = available(at: now).first?.id }
    }
    mutating func select(_ id: UUID, at now: Date = Date()) {
        guard available(at: now).contains(where: { $0.id == id }) else { return }
        selectedID = id; isCollapsed = false
    }
    mutating func next(at now: Date = Date()) {
        let items = available(at: now)
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == current(at: now)?.id } ?? 0
        selectedID = items[(index + 1) % items.count].id; isCollapsed = false
    }
    mutating func collapse() { isCollapsed = true }
    mutating func restore(at now: Date = Date()) { refresh(at: now); isCollapsed = false }
    mutating func remove(_ id: UUID, at now: Date = Date()) {
        entries.removeAll { $0.id == id }; refresh(at: now)
    }
    mutating func retain(_ ids: Set<UUID>, at now: Date = Date()) {
        entries.removeAll { !ids.contains($0.id) }; refresh(at: now)
    }
    mutating func removeCategory(_ category: String, at now: Date = Date()) {
        entries.removeAll { ReminderGate.category(for: $0.event) == category }; refresh(at: now)
    }
    mutating func setPriority(_ priority: ReminderPriority, category: String) {
        for index in entries.indices where ReminderGate.category(for: entries[index].event) == category { entries[index].priority = priority }
    }
    mutating func snooze(_ category: String, until: Date, at now: Date = Date()) {
        for index in entries.indices where Self.categoryKey(for: entries[index].event) == category { entries[index].snoozedUntil = until }
        refresh(at: now)
    }
    mutating func resume(_ category: String, at now: Date = Date()) {
        for index in entries.indices where Self.categoryKey(for: entries[index].event) == category { entries[index].snoozedUntil = nil }
        refresh(at: now); isCollapsed = false
    }
}

enum DemoScenario: String, CaseIterable, Identifiable {
    case visitor, conversation, appointment, counter, journey
    var id: String { rawValue }
    var title: String { switch self { case .visitor: return "有人来访"; case .conversation: return "面对面交流"; case .appointment: return "约好一件事"; case .counter: return "窗口办事"; case .journey: return "出行问路" } }
    var symbol: String { switch self { case .visitor: return "door.left.hand.open"; case .conversation: return "bubble.left.and.bubble.right"; case .appointment: return "calendar"; case .counter: return "building.2"; case .journey: return "map" } }
    var detail: String {
        switch self {
        case .visitor: return "门铃、敲门、挥手 → 沟通卡 → 手表回应 → 确认"
        case .conversation: return "演示对话 → 专注阅读 → iPad 文字屏 → 主动已读"
        case .appointment: return "约时间地点 → 信息卡核对 → 留成待办 → 标记完成"
        case .counter: return "核对金额与窗口 → 大字展示 → 留下处理事项"
        case .journey: return "核对目的地与联络方式 → 置顶信息 → 留成待办"
        }
    }
    var partnerLines: [(String, String)] {
        switch self {
        case .visitor: return [("演示：你好，我在门口。", "来访者")]
        case .conversation: return [("演示：请问会议几点开始？", "说话者 A"), ("演示：下午三点，在二楼。", "说话者 B")]
        case .appointment: return [("演示：半小时后，在图书馆二楼一起讨论。", "同学"), ("演示：请把时间和地点再核对一遍。", "同学")]
        case .counter: return [("演示：请到三号窗口办理，费用是人民币 28.50 元。", "工作人员"), ("演示：这是界面样例，不是真实收费。", "工作人员")]
        case .journey: return [("演示：目的地是博物馆东门。", "同行者"), ("演示：联络号码用 010-00000000 占位，不要拨打。", "同行者")]
        }
    }
    var suggestedReply: String {
        switch self { case .visitor: return "请等一下，我马上来。"; case .conversation: return "好的，下午三点见。"; case .appointment: return "我想再核对一下时间和地点。"; case .counter: return "请让我确认一下金额和窗口。"; case .journey: return "请把目的地和联络方式写给我。" }
    }
    func informationCards(at now: Date = Date()) -> [InformationCard] {
        let examples: [(InformationKind, String)]
        switch self {
        case .appointment: examples = [(.time, ""), (.place, "图书馆二楼")]
        case .counter: examples = [(.amount, "28.50"), (.place, "三号窗口")]
        case .journey: examples = [(.place, "博物馆东门"), (.phone, "010-00000000")]
        default: return []
        }
        return examples.map { kind, value in
            var card = InformationCard(); card.kind = kind; card.value = value; card.origin = .demonstration
            card.createdAt = now; card.dateValue = now.addingTimeInterval(1800)
            card.sourceQuote = partnerLines.map { $0.0 }.joined(separator: "\n"); return card
        }
    }
}

struct DemoRun: Identifiable {
    let id = UUID()
    let scenario: DemoScenario
    var eventIDs: [UUID] = []
    var turnIDs: [UUID] = []
    var informationIDs: [UUID] = []
    let startedAt = Date()
}

struct ConversationScenarioBackup {
    private var original: ConversationSession?
    mutating func begin(_ scenario: DemoScenario, current: ConversationSession) -> ConversationSession {
        if original == nil {
            var saved = current; saved.pauseCapture(); original = saved
        }
        var demo = ConversationSession(); demo.addScenario(scenario); return demo
    }
    mutating func end() -> ConversationSession? {
        defer { original = nil }; return original
    }
}

enum ConversationPanel: String, CaseIterable, Identifiable {
    case reading, response
    var id: String { rawValue }
    var title: String { self == .reading ? "阅读" : "回应" }
}
