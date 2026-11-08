import Foundation

enum SceneTemplate: String, CaseIterable, Identifiable {
    case dormitory, library, counter, journey
    var id: String { rawValue }
    var title: String { switch self { case .dormitory: return "宿舍"; case .library: return "图书馆"; case .counter: return "服务窗口"; case .journey: return "出行" } }
    var detail: String {
        switch self {
        case .dormitory: return "关注敲门与门铃，准备来访回应"
        case .library: return "保留门铃，减少重复打扰"
        case .counter: return "准备文字交流、核对时间与金额"
        case .journey: return "准备地点、时间和问路短句"
        }
    }
    func makeProfile(title: String? = nil) -> SceneProfile {
        var settings = AppPreferences()
        settings.apply(self == .dormitory ? .home : self == .library ? .study : .conversation)
        settings.sounds = self == .dormitory ? [.knock, .doorbell] : self == .library ? [.doorbell] : [.clapping]
        settings.sensitivity = self == .library ? .cautious : .balanced
        var profile = SceneProfile(title: title ?? self.title, preferences: settings)
        profile.symbol = self == .dormitory ? "bed.double" : self == .library ? "book" : self == .counter ? "building.2" : "bubble.left.and.bubble.right"
        for key in SceneProfile.categories {
            var rule = ReminderRule(); rule.cooldownSeconds = self == .library ? 60 : 30
            profile.reminderRules[key] = rule
        }
        if self == .dormitory { profile.responses = ["knock": ["请稍等，我来开门。"], "doorbell": ["我已看到，请告诉我来意。"]] }
        else if self == .library { profile.responses = ["doorbell": ["请稍等，我正在学习。"], "wave": ["我看到你了，请用文字告诉我。"]] }
        else if self == .counter { profile.responses = ["clapping": ["请把时间和金额写给我，我想核对一下。"], "wave": ["轮到我了吗？请用文字告诉我。"]] }
        else { profile.responses = ["clapping": ["请告诉我具体地点和出发时间。"], "wave": ["请把路线写给我，谢谢。"]] }
        return profile
    }
}

enum InformationSelection: String, CaseIterable, Identifiable {
    case all, unreviewed, pinned, demonstration
    var id: String { rawValue }
    var title: String { switch self { case .all: return "全部"; case .unreviewed: return "待核对"; case .pinned: return "置顶"; case .demonstration: return "演示" } }
}
extension InformationCard {
    var isPinned: Bool { pinned == true }
    static func select(_ cards: [InformationCard], query: String, kind: InformationKind?, selection: InformationSelection) -> [InformationCard] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return cards.filter { card in
            (kind == nil || card.kind == kind)
            && (selection == .all || selection == .unreviewed && !card.reviewed || selection == .pinned && card.isPinned || selection == .demonstration && card.origin == .demonstration)
            && (text.isEmpty || [card.displayValue, card.note, card.sourceQuote, card.kind.title].contains { $0.localizedCaseInsensitiveContains(text) })
        }.sorted { a, b in a.isPinned != b.isPinned ? a.isPinned : a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id.uuidString < b.id.uuidString }
    }
}

enum RoutinePriority: String, Codable, CaseIterable, Identifiable {
    case ordinary, important
    var id: String { rawValue }
    var title: String { self == .ordinary ? "普通" : "重要" }
}
enum RoutineFilter: String, CaseIterable, Identifiable {
    case pending, today, overdue, completed, all
    var id: String { rawValue }
    var title: String { switch self { case .pending: return "待完成"; case .today: return "今天"; case .overdue: return "已到期"; case .completed: return "已完成"; case .all: return "全部" } }
}

struct RoutineItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var note = ""
    var createdAt = Date()
    var dueAt: Date?
    var reminderAt: Date?
    var completedAt: Date?
    var priority: RoutinePriority = .ordinary
    var origin: ConversationOrigin = .typed
    var assistedBy: String?
    var sourceCardID: UUID?
    var sourceRevision: Int?
    var sourceSnapshot = ""
    var completed: Bool { completedAt != nil }
    var isDemonstration: Bool { origin == .demonstration }
    func overdue(at now: Date) -> Bool { !completed && dueAt.map { $0 <= now } == true }
    init() {}
    init(card: InformationCard) throws {
        try card.validate(); guard card.reviewed else { throw RoutineError.reviewRequired }
        title = String(("约定：" + card.kind.title + " · " + card.displayValue).prefix(100))
        origin = card.origin; sourceCardID = card.id; sourceRevision = card.revision
        assistedBy = card.assistedBy
        sourceSnapshot = String((card.kind.title + "：" + card.displayValue).prefix(200))
        if card.kind == .time { dueAt = card.dateValue }
    }
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 100,
              note.count <= 200, sourceSnapshot.count <= 200, (assistedBy?.count ?? 0) <= 80, createdAt.timeIntervalSince1970.isFinite,
              (sourceCardID == nil) == (sourceRevision == nil), sourceRevision.map({ (1...1_000_000).contains($0) }) ?? true,
              sourceCardID == nil || !sourceSnapshot.isEmpty else { throw DailyError.invalid }
        for date in [dueAt, reminderAt, completedAt].compactMap({ $0 }) {
            guard date.timeIntervalSince1970.isFinite, (1900...2200).contains(Calendar.current.component(.year, from: date)) else { throw DailyError.invalid }
        }
        if let completedAt, completedAt < createdAt { throw DailyError.invalid }
    }
    func sourceWarning(cards: [InformationCard]) -> String? {
        guard let sourceCardID else { return nil }
        guard let card = cards.first(where: { $0.id == sourceCardID }) else { return "原信息卡当前不可用，请按保留的摘录核对。" }
        if card.revision != sourceRevision { return "原信息卡已更新，当前待办仍保留旧版摘录。" }
        if !card.reviewed { return "原信息卡当前没有核对标记，请重新核对。" }
        return nil
    }
    func preservingSource(from original: RoutineItem) -> RoutineItem {
        var copy = self; copy.id = original.id; copy.createdAt = original.createdAt; copy.origin = original.origin
        copy.assistedBy = original.assistedBy
        copy.sourceCardID = original.sourceCardID; copy.sourceRevision = original.sourceRevision; copy.sourceSnapshot = original.sourceSnapshot
        copy.completedAt = original.completedAt; return copy
    }
    mutating func refreshSource(_ card: InformationCard) throws {
        guard sourceCardID == card.id else { throw DailyError.stale }
        try card.validate(); guard card.reviewed else { throw RoutineError.reviewRequired }
        sourceRevision = card.revision; sourceSnapshot = String((card.kind.title + "：" + card.displayValue).prefix(200))
        title = String(("约定：" + card.kind.title + " · " + card.displayValue).prefix(100))
        if card.origin == .demonstration { origin = .demonstration }
        assistedBy = card.assistedBy
        dueAt = card.kind == .time ? card.dateValue : nil
        reminderAt = nil; completedAt = nil; try validate()
    }
    var exportText: String {
        [isDemonstration ? "【演示待办】" : "见声 · 我的待办", title, "优先级：\(priority.title)",
         "状态：\(completed ? "用户标记已完成" : "待完成")", dueAt.map { "约定时间：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "未设时间",
         reminderAt.map { "手动设置的提醒时间：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "未设置系统提醒",
         "来源：\(origin.informationSource)", sourceCardID == nil ? "" : "用户从标记已核对的第 \(sourceRevision ?? 1) 版卡片建立；不保证原卡当前仍一致。",
         assistedBy.map { "整理建议：\($0)，请自行核对内容" } ?? "",
         sourceSnapshot.isEmpty ? "" : "建立时摘录：\(sourceSnapshot)", note.isEmpty ? "" : "备注：\(note)"].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    static func select(_ items: [RoutineItem], query: String, filter: RoutineFilter, includeDemonstrations: Bool, now: Date, calendar: Calendar = .current) -> [RoutineItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            (includeDemonstrations || !item.isDemonstration)
            && (text.isEmpty || [item.title,item.note,item.sourceSnapshot].contains { $0.localizedCaseInsensitiveContains(text) })
            && (filter == .all || filter == .pending && !item.completed || filter == .overdue && item.overdue(at: now)
                || filter == .completed && item.completed || filter == .today && !item.completed && item.dueAt.map { calendar.isDate($0, inSameDayAs: now) } == true)
        }.sorted { a,b in
            if a.completed != b.completed { return !a.completed }
            if a.overdue(at: now) != b.overdue(at: now) { return a.overdue(at: now) }
            if a.priority != b.priority { return a.priority == .important }
            if a.dueAt != b.dueAt { return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture) }
            return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id.uuidString < b.id.uuidString
        }
    }
}

enum RoutineError: LocalizedError {
    case reviewRequired, duplicate
    var errorDescription: String? { self == .reviewRequired ? "请先与对方核对信息卡，再建立或更新待办。" : "同一版本的信息卡已有未完成待办，请先查看已有记录。" }
}

final class RoutineStore {
    let directory: URL
    var url: URL { directory.appendingPathComponent("items.json") }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SeeSoundRoutines", isDirectory: true)
    }
    func load() throws -> [RoutineItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 500_000 else { throw JournalError.oversized }
        let items = try JSONDecoder().decode([RoutineItem].self, from: Data(contentsOf: url)); try validate(items); return items
    }
    func save(_ items: [RoutineItem], consent: Bool) throws {
        guard consent else { throw DailyError.consent }
        _ = try load(); try validate(items)
        let data = try JSONEncoder().encode(items); guard data.count <= 500_000 else { throw JournalError.oversized }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var root = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func reset() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
    private func validate(_ items: [RoutineItem]) throws {
        guard items.count <= 80, Set(items.map(\.id)).count == items.count else { throw DailyError.capacity }
        try items.forEach { try $0.validate() }
    }
}

enum TimelinePeriod: String, CaseIterable, Identifiable {
    case all, day, week
    var id: String { rawValue }
    var title: String { self == .all ? "全部时间" : self == .day ? "近 24 小时" : "近 7 天" }
    func includes(_ date: Date, now: Date) -> Bool { self == .all || date >= now.addingTimeInterval(self == .day ? -86400 : -604800) && date <= now }
}
