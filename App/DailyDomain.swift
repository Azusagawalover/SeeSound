import Foundation

enum ReadingTextSize: String, Codable, CaseIterable, Identifiable {
    case standard, large, extraLarge
    var id: String { rawValue }
    var title: String { self == .standard ? "跟随系统" : self == .large ? "较大" : "更大" }
}

struct ReadingPreferences: Codable, Equatable {
    var textSize: ReadingTextSize = .standard
    var highContrast = false
    var reduceMotion = false
    var leftHanded = false
}

struct TextCorrection: Codable, Equatable, Identifiable {
    var id = UUID()
    var from: String
    var to: String
    func validate() throws {
        guard !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, from.count <= 40,
              !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, to.count <= 80, from != to else { throw DailyError.invalid }
    }
    func apply(to text: String) -> String { String(text.replacingOccurrences(of: from, with: to).prefix(500)) }
}

enum ReminderPriority: String, Codable, CaseIterable, Identifiable {
    case normal, prominent
    var id: String { rawValue }
    var title: String { self == .normal ? "普通" : "醒目" }
}

struct ReminderRule: Codable, Equatable {
    var visual = true
    var haptic = false
    var notifications = false
    var cooldownSeconds = 30
    var repeatCount = 0
    var repeatInterval = 30
    var priority: ReminderPriority = .normal
    func validate() throws {
        guard [0, 10, 30, 60, 300].contains(cooldownSeconds), (0...2).contains(repeatCount),
              [15, 30, 60, 120].contains(repeatInterval) else { throw DailyError.invalid }
    }
}

struct ReminderGate {
    private var lastAlert: [String: Date] = [:]
    private(set) var snoozedUntil: [String: Date] = [:]
    static func category(for event: SenseEvent) -> String {
        event.category.hasPrefix("demo-") ? String(event.category.dropFirst(5)) : event.category
    }
    private func key(_ event: SenseEvent) -> String { "\(event.source.rawValue):\(Self.category(for: event))" }
    mutating func allows(_ event: SenseEvent, rule: ReminderRule, now: Date = Date()) -> Bool {
        let category = Self.category(for: event)
        if let until = snoozedUntil[category], until > now { return false }
        let key = key(event)
        if let previous = lastAlert[key], now >= previous, now.timeIntervalSince(previous) < Double(rule.cooldownSeconds) { return false }
        lastAlert[key] = now
        return true
    }
    mutating func snooze(_ category: String, until: Date) { snoozedUntil[category] = until }
    mutating func resume(_ category: String) { snoozedUntil[category] = nil }
}

struct CaptionRunPolicy {
    private(set) var id: UUID?
    private var started: Date?
    private(set) var segments = 0
    mutating func begin(at now: Date = Date()) -> UUID {
        let token = UUID(); id = token; started = now; segments = 0; return token
    }
    mutating func next(_ token: UUID, at now: Date = Date(), foreground: Bool) -> Bool {
        guard id == token, foreground, let started, now >= started,
              now.timeIntervalSince(started) < 1200, segments < 60 else { return false }
        segments += 1; return true
    }
    mutating func cancel() { id = nil; started = nil; segments = 0 }
}

enum DailyError: LocalizedError {
    case invalid, capacity, consent, stale
    var errorDescription: String? {
        switch self {
        case .invalid: return "内容格式或长度不符合要求。"
        case .capacity: return "已达到保存数量上限，请先整理已有内容。"
        case .consent: return "需要你确认后才保存会话。"
        case .stale: return "会话已经结束，或消息不是当前会话的更新。"
        }
    }
}

struct SavedConversationTurn: Codable, Identifiable, Equatable {
    var id: UUID
    var speaker: ConversationSpeaker
    var origin: ConversationOrigin
    var createdAt: Date
    var text: String
    var state: ConversationTurnState
    var recognitionRevision: Int?
    var isEdited: Bool
    var speakerName: String?
    var replyEventTitle: String?
    var assistedBy: String?
    init(_ turn: ConversationTurn) {
        id = turn.id; speaker = turn.speaker; origin = turn.origin; createdAt = turn.createdAt
        text = turn.text; state = turn.state; isEdited = turn.isEdited;recognitionRevision = turn.recognitionRevision; speakerName = turn.speakerName
        replyEventTitle = turn.replyEventTitle
        assistedBy = turn.assistedBy
    }
    var displayName: String { speaker == .me ? "我" : speakerName ?? "对方" }
    var sourceTitle: String { baseSourceTitle + (assistedBy.map { " · \($0) 整理建议" } ?? "") }
    private var baseSourceTitle: String {
        switch origin {
        case .speech: return "系统端侧字幕"
        case .typed: return "手动输入"
        case .demonstration: return "演示文字"
        case .fileTranscription: return "本机文件转写"
        case .imageText: return "图片识字"
        case .documentText: return "导入文档"
        }
    }
    func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500,
              (recognitionRevision ?? 0) >= 0, (speakerName?.count ?? 0) <= 20, (replyEventTitle?.count ?? 0) <= 80, (assistedBy?.count ?? 0) <= 80,
              createdAt.timeIntervalSince1970.isFinite else { throw DailyError.invalid }
    }
}

struct SavedConversation: Codable, Identifiable, Equatable {
    var version = 1
    var id = UUID()
    var title: String
    var createdAt: Date
    var turns: [SavedConversationTurn]
    func validate() throws {
        guard version == 1, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 60,
              (1...50).contains(turns.count), Set(turns.map(\.id)).count == turns.count,
              createdAt.timeIntervalSince1970.isFinite else { throw DailyError.invalid }
        try turns.forEach { try $0.validate() }
    }
    var containsDemonstration: Bool { turns.contains { $0.origin == .demonstration } }
    var exportText: String {
        let formatter = ISO8601DateFormatter()
        let rows = turns.map { turn in
            "[\(formatter.string(from: turn.createdAt))] \(turn.displayName)（\(turn.sourceTitle)\(turn.isEdited ? "，已人工修改" : "")\(turn.state == .interrupted ? "，未完成" : "")）\(turn.replyEventTitle.map { "〔回应事件：\($0)〕" } ?? "")：\(turn.text)"
        }
        return (["见声 · \(title)", containsDemonstration ? "含演示文字；不是真实识别验证。" : "由用户主动保存并导出；识别内容需核对。", ""] + rows).joined(separator: "\n")
    }
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedCaseInsensitiveContains(query) || turns.contains { $0.text.localizedCaseInsensitiveContains(query) || $0.displayName.localizedCaseInsensitiveContains(query) }
    }
}

/// Separate opt-in store; live ConversationSession remains non-Codable and ephemeral.
final class ConversationArchiveStore {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeeSoundConversations", isDirectory: true)
    }
    func load() throws -> [SavedConversation] {
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else { return [] }
        let urls = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        guard urls.count <= 30 else { throw DailyError.capacity }
        return try urls.map { url in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 200_000 else { throw DailyError.invalid }
            let item = try JSONDecoder().decode(SavedConversation.self, from: Data(contentsOf: url))
            try item.validate()
            guard item.id.uuidString == url.deletingPathExtension().lastPathComponent else { throw DailyError.invalid }
            return item
        }.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }
    func save(_ item: SavedConversation, consent: Bool) throws {
        guard consent else { throw DailyError.consent }
        try item.validate()
        let existing = try load()
        guard existing.count < 30, !existing.contains(where: { $0.id == item.id }) else { throw DailyError.capacity }
        let data = try JSONEncoder().encode(item)
        guard data.count <= 200_000 else { throw DailyError.invalid }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var root = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
        let url = directory.appendingPathComponent(item.id.uuidString + ".json")
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func replaceAll(_ items:[SavedConversation]) throws {
        guard items.count <= 30,Set(items.map(\.id)).count == items.count else { throw DailyError.capacity }
        try items.forEach { try $0.validate() }
        let encoded = try items.map { item -> (UUID,Data) in
            let data = try JSONEncoder().encode(item);guard data.count <= 200_000 else { throw DailyError.invalid };return (item.id,data)
        }
        let existing = try load()
        for (id,data) in encoded { try LibraryRepository.protectedWrite(data,to:directory.appendingPathComponent(id.uuidString+".json")) }
        let ids = Set(items.map(\.id))
        for item in existing where !ids.contains(item.id) { try delete(item.id) }
    }
    func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json")) }
}
