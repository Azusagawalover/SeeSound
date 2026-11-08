import Foundation

struct SceneProfile: Codable, Identifiable, Equatable {
    static let limit = 12
    static let symbols = ["house", "book", "bubble.left.and.bubble.right", "cup.and.saucer", "bed.double", "building.2"]
    static let categories = ["knock", "doorbell", "clapping", "wave"]
    var id = UUID()
    var title: String
    var symbol: String
    var scene: ListeningScene
    var sounds: Set<SoundKind>
    var sensitivity: DetectionSensitivity
    var reminderRules: [String: ReminderRule]
    var responses: [String: [String]] = [:]

    init(title: String, preferences: AppPreferences) {
        self.title = title; symbol = preferences.scene.symbol; scene = preferences.scene
        sounds = preferences.sounds; sensitivity = preferences.sensitivity
        reminderRules = preferences.reminderRules
    }
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 24,
              Self.symbols.contains(symbol), reminderRules.count <= 4, responses.count <= 4,
              Set(reminderRules.keys).isSubset(of: Set(Self.categories)),
              Set(responses.keys).isSubset(of: Set(Self.categories)) else { throw DailyError.invalid }
        try reminderRules.values.forEach { try $0.validate() }
        for phrases in responses.values {
            guard phrases.count <= 4, Set(phrases).count == phrases.count,
                  phrases.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 80 }) else { throw DailyError.invalid }
        }
    }
    func matches(_ preferences: AppPreferences) -> Bool {
        scene == preferences.scene && sounds == preferences.sounds && sensitivity == preferences.sensitivity
            && Self.categories.allSatisfy { (reminderRules[$0] ?? ReminderRule()) == preferences.reminderRule(for: $0) }
    }
}

extension AppPreferences {
    var activeProfile: SceneProfile? { profiles.first { $0.id == activeProfileID } }
    var sceneTitle: String { activeProfile.map { $0.title + ($0.matches(self) ? "" : " · 临时调整") } ?? scene.title }
    mutating func saveProfile(_ profile: SceneProfile) throws {
        try profile.validate()
        guard !profiles.contains(where: { $0.id != profile.id && $0.title.caseInsensitiveCompare(profile.title) == .orderedSame }) else { throw DailyError.invalid }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { guard profiles.count < SceneProfile.limit else { throw DailyError.capacity }; profiles.append(profile) }
    }
    mutating func applyProfile(_ id: UUID) throws {
        guard let profile = profiles.first(where: { $0.id == id }) else { throw DailyError.stale }
        try profile.validate()
        scene = profile.scene; sounds = profile.sounds; sensitivity = profile.sensitivity
        reminderRules = profile.reminderRules; activeProfileID = id
    }
    mutating func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }; if activeProfileID == id { activeProfileID = nil }
    }
}

struct EventResponseContext: Equatable {
    var eventID: UUID
    var title: String
    var demonstration: Bool
    init(_ event: SenseEvent) { eventID = event.id; title = event.title; demonstration = event.isDemonstration }
    static func suggestions(for event: SenseEvent, profile: SceneProfile?) -> [String] {
        let key = ReminderGate.category(for: event)
        let defaults: [String]
        switch key {
        case "knock", "doorbell": defaults = ["我已看到，请稍等。", "我马上来。", "请用文字告诉我来意。"]
        case "wave": defaults = ["我看到你了。", "请到我面前，用文字交流。", "请稍等一下。"]
        default: defaults = ["我已看到，谢谢。", "请用文字告诉我。", "请稍等一下。"]
        }
        var seen = Set<String>()
        return ((profile?.responses[key] ?? []) + defaults).filter { seen.insert($0).inserted }
    }
}

enum InformationKind: String, Codable, CaseIterable, Identifiable {
    case time, place, amount, phone
    var id: String { rawValue }
    var title: String { switch self { case .time: return "时间"; case .place: return "地点"; case .amount: return "金额"; case .phone: return "电话" } }
    var symbol: String { switch self { case .time: return "calendar.badge.clock"; case .place: return "mappin.and.ellipse"; case .amount: return "banknote"; case .phone: return "phone" } }
}

extension ConversationOrigin {
    var informationSource: String {
        switch self { case .speech: return "端侧字幕，可能有误"; case .typed: return "手动输入"; case .demonstration: return "演示文字，非真实信息"; case .fileTranscription: return "文件转写，可能有误"; case .imageText: return "图片识字，需核对"; case .documentText: return "导入文档，需核对" }
    }
}

struct InformationCard: Codable, Identifiable, Equatable {
    var id = UUID()
    var pinned: Bool?
    var assistedBy: String?
    var kind: InformationKind = .time
    var value = ""
    var dateValue = Date()
    var currency = "CNY"
    var note = ""
    var sourceQuote = ""
    var origin: ConversationOrigin = .typed
    var createdAt = Date()
    private(set) var revision = 1
    private(set) var reviewedRevision: Int?
    var reviewed: Bool { reviewedRevision == revision }
    var displayValue: String {
        kind == .time ? dateValue.formatted(date: .abbreviated, time: .shortened) : kind == .amount ? "\(currency) \(value)" : value
    }
    var exportText: String {
        ["\(origin == .demonstration ? "【演示】" : "")\(kind.title)：\(displayValue)",
         "核对状态：\(reviewed ? "用户标记已与对方核对" : "尚未核对")", "来源：\(origin.informationSource)",
         assistedBy.map { "整理建议：\($0)，内容需人工核对" } ?? "",
         note.isEmpty ? "" : "备注：\(note)", sourceQuote.isEmpty ? "" : "原文：\(sourceQuote)"].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    func validate() throws {
        guard (1...1_000_000).contains(revision), reviewedRevision == nil || reviewedRevision == revision,
              value.count <= 120, note.count <= 120, sourceQuote.count <= 500, (assistedBy?.count ?? 0) <= 80,
              createdAt.timeIntervalSince1970.isFinite, dateValue.timeIntervalSince1970.isFinite,
              (1900...2200).contains(Calendar.current.component(.year, from: dateValue)),
              ["CNY", "USD", "EUR", "JPY", "HKD"].contains(currency) else { throw DailyError.invalid }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .time: break
        case .place: guard !clean.isEmpty else { throw DailyError.invalid }
        case .phone:
            let digits = clean.filter { $0.isASCII && $0.isNumber }
            guard (3...20).contains(digits.count), clean.count <= 40,
                  clean.allSatisfy({ "0123456789+()- ".contains($0) }),
                  clean.filter({ $0 == "+" }).count <= 1, !clean.contains("+") || clean.first == "+" else { throw DailyError.invalid }
        case .amount:
            guard clean.range(of: #"^(0|[1-9][0-9]{0,11})(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else { throw DailyError.invalid }
        }
    }
    /// Editing never carries forward an earlier review; demo provenance is immutable.
    func replacing(with draft: InformationCard) throws -> InformationCard {
        var result = draft
        result.id = id; result.createdAt = createdAt; result.origin = origin; result.sourceQuote = sourceQuote
        result.assistedBy = assistedBy
        let changed = kind != result.kind || value != result.value || dateValue != result.dateValue || currency != result.currency || note != result.note
        guard !changed || revision < 1_000_000 else { throw DailyError.capacity }
        result.revision = revision + (changed ? 1 : 0)
        result.reviewedRevision = changed ? nil : reviewedRevision
        try result.validate(); return result
    }
    mutating func markReviewed(_ value: Bool) { reviewedRevision = value ? revision : nil }
}

/// Independent, opt-in store. Read errors never overwrite an existing file.
final class InformationCardStore {
    let directory: URL
    var url: URL { directory.appendingPathComponent("cards.json") }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SeeSoundInformationCards", isDirectory: true)
    }
    func load() throws -> [InformationCard] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 300_000 else { throw JournalError.oversized }
        let cards = try JSONDecoder().decode([InformationCard].self, from: Data(contentsOf: url))
        try validate(cards); return cards
    }
    func save(_ cards: [InformationCard], consent: Bool) throws {
        guard consent else { throw DailyError.consent }
        _ = try load()
        try validate(cards)
        let data = try JSONEncoder().encode(cards)
        guard data.count <= 300_000 else { throw JournalError.oversized }
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
    private func validate(_ cards: [InformationCard]) throws {
        guard cards.count <= 30, Set(cards.map(\.id)).count == cards.count else { throw DailyError.capacity }
        try cards.forEach { try $0.validate() }
    }
}

struct EventPair: Codable, Hashable {
    let first: UUID
    let second: UUID
    init(_ a: UUID, _ b: UUID) {
        if a.uuidString < b.uuidString { first = a; second = b } else { first = b; second = a }
    }
    var valid: Bool { first.uuidString < second.uuidString }
    func contains(_ id: UUID) -> Bool { first == id || second == id }
}

struct EventAssociation: Identifiable {
    var events: [SenseEvent]
    var id: String { events.map { $0.id.uuidString }.sorted().joined(separator: ":") }
    var date: Date { events.map(\.lastSeen).max() ?? .distantPast }
    var title: String { events.map { event in
        let category = ReminderGate.category(for: event)
        return category == "wave" ? "挥手" : SoundKind(rawValue: category)?.title ?? event.title
    }.joined(separator: " ＋ ") }
    static func group(_ events: [SenseEvent], window: Int, suppressed: Set<EventPair>) -> [EventAssociation] {
        let span = Double([2, 5, 10].contains(window) ? window : 5)
        var groups: [EventAssociation] = []
        for event in events.sorted(by: { $0.lastSeen == $1.lastSeen ? $0.id.uuidString < $1.id.uuidString : $0.lastSeen < $1.lastSeen }) {
            if let index = groups.indices.reversed().first(where: { index in
                let members = groups[index].events
                guard let first = members.first, event.isDemonstration == first.isDemonstration,
                      event.lastSeen.timeIntervalSince(first.lastSeen) <= span else { return false }
                return members.contains { ReminderGate.category(for: $0) != ReminderGate.category(for: event) || $0.source != event.source }
                    && members.allSatisfy { !suppressed.contains(EventPair($0.id, event.id)) }
            }) { groups[index].events.append(event) }
            else { groups.append(EventAssociation(events: [event])) }
        }
        return groups.sorted { $0.date > $1.date }
    }
}
