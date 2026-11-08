import Foundation

enum ListeningScene: String, Codable, CaseIterable, Identifiable {
    case home, study, conversation
    var id: String { rawValue }
    var title: String {
        switch self { case .home: return "居家"; case .study: return "学习"; case .conversation: return "沟通" }
    }
    var symbol: String {
        switch self { case .home: return "house"; case .study: return "book"; case .conversation: return "bubble.left.and.bubble.right" }
    }
    var detail: String {
        switch self {
        case .home: return "关注敲门、门铃与拍手"
        case .study: return "保留来访提醒，减少其他打扰"
        case .conversation: return "关注拍手；字幕需要手动开启"
        }
    }
    var sounds: Set<SoundKind> {
        switch self {
        case .home: return Set(SoundKind.allCases)
        case .study: return [.knock, .doorbell]
        case .conversation: return [.clapping]
        }
    }
}

struct AppPreferences: Codable, Equatable {
    var scene: ListeningScene = .home
    var sounds = Set(SoundKind.allCases)
    var sensitivity: DetectionSensitivity = .balanced
    var saveHistory = false
    var retentionDays = 7
    var phrases = ["请用文字告诉我。", "请再说一次，稍微慢一点。", "我已看到，谢谢。"]
    var phraseCategories: [String: PhraseCategory] = [:]
    var pinnedPhrases: [String] = []
    var recentPhrases: [String] = []
    var reminderRules: [String: ReminderRule] = [:]
    var corrections: [TextCorrection] = []
    var reading = ReadingPreferences()
    var hasFinishedIntro = false
    var profiles: [SceneProfile] = []
    var activeProfileID: UUID?
    var associationWindow = 5
    var soundEngine: EnvironmentalEngine = .apple

    init() {}

    enum CodingKeys: String, CodingKey {
        case scene, sounds, sensitivity, saveHistory, retentionDays, phrases, phraseCategories, pinnedPhrases
        case recentPhrases, reminderRules, corrections, reading, hasFinishedIntro
        case profiles, activeProfileID, associationWindow, soundEngine
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scene = try values.decodeIfPresent(ListeningScene.self, forKey: .scene) ?? scene
        sounds = try values.decodeIfPresent(Set<SoundKind>.self, forKey: .sounds) ?? sounds
        sensitivity = try values.decodeIfPresent(DetectionSensitivity.self, forKey: .sensitivity) ?? sensitivity
        saveHistory = try values.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? saveHistory
        retentionDays = try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? retentionDays
        phrases = try values.decodeIfPresent([String].self, forKey: .phrases) ?? phrases
        phraseCategories = try values.decodeIfPresent([String: PhraseCategory].self, forKey: .phraseCategories) ?? [:]
        phraseCategories = phraseCategories.filter { phrases.contains($0.key) }
        pinnedPhrases = try values.decodeIfPresent([String].self, forKey: .pinnedPhrases) ?? []
        pinnedPhrases = Array(NSOrderedSet(array: pinnedPhrases.filter { phrases.contains($0) })).compactMap { $0 as? String }
        recentPhrases = try values.decodeIfPresent([String].self, forKey: .recentPhrases) ?? []
        recentPhrases = Array(recentPhrases.filter { phrases.contains($0) }.prefix(8))
        reminderRules = try values.decodeIfPresent([String: ReminderRule].self, forKey: .reminderRules) ?? [:]
        corrections = try values.decodeIfPresent([TextCorrection].self, forKey: .corrections) ?? []
        reading = try values.decodeIfPresent(ReadingPreferences.self, forKey: .reading) ?? ReadingPreferences()
        hasFinishedIntro = try values.decodeIfPresent(Bool.self, forKey: .hasFinishedIntro) ?? false
        profiles = try values.decodeIfPresent([SceneProfile].self, forKey: .profiles) ?? []
        activeProfileID = try values.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        associationWindow = try values.decodeIfPresent(Int.self, forKey: .associationWindow) ?? 5
        soundEngine = try values.decodeIfPresent(EnvironmentalEngine.self, forKey: .soundEngine) ?? .apple
        guard profiles.count <= SceneProfile.limit, Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map { $0.title.lowercased() }).count == profiles.count,
              activeProfileID == nil || profiles.contains(where: { $0.id == activeProfileID }),
              [2, 5, 10].contains(associationWindow) else { throw JournalError.invalid }
        try profiles.forEach { try $0.validate() }
        guard reminderRules.count <= 4, Set(reminderRules.keys).isSubset(of: Set(SoundKind.allCases.map(\.rawValue) + ["wave"])),
              corrections.count <= 20, Set(corrections.map(\.id)).count == corrections.count else { throw JournalError.invalid }
        try reminderRules.values.forEach { try $0.validate() }
        try corrections.forEach { try $0.validate() }
    }

    func category(for phrase: String) -> PhraseCategory {
        if let category = phraseCategories[phrase] { return category }
        if phrase == "请用文字告诉我。" || phrase == "请再说一次，稍微慢一点。" { return .request }
        if phrase == "我已看到，谢谢。" { return .response }
        return .personal
    }

    func reminderRule(for category: String) -> ReminderRule { reminderRules[category] ?? ReminderRule() }

    mutating func apply(_ scene: ListeningScene) {
        activeProfileID = nil
        self.scene = scene
        sounds = scene.sounds
    }
}

enum EventVerdict: String, Codable, CaseIterable, Identifiable {
    case unreviewed, plausible, falseAlarm, uncertain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unreviewed: return "未复核"
        case .plausible: return "与实际相符"
        case .falseAlarm: return "误报"
        case .uncertain: return "无法确定"
        }
    }
}

struct EventAnnotation: Codable, Equatable {
    var verdict: EventVerdict = .unreviewed
    var note = ""
}

struct JournalArchive: Codable {
    var version = 1
    var events: [SenseEvent]
    var annotations: [UUID: EventAnnotation]
    var suppressedLinks: [EventPair] = []

    init(events: [SenseEvent], annotations: [UUID: EventAnnotation], suppressedLinks: [EventPair] = []) {
        self.events = events; self.annotations = annotations; self.suppressedLinks = suppressedLinks
    }
    enum CodingKeys: String, CodingKey { case version, events, annotations, suppressedLinks }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        events = try values.decode([SenseEvent].self, forKey: .events)
        annotations = try values.decode([UUID: EventAnnotation].self, forKey: .annotations)
        suppressedLinks = try values.decodeIfPresent([EventPair].self, forKey: .suppressedLinks) ?? []
    }

    func validated(since cutoff: Date, now: Date = Date()) throws -> JournalArchive {
        guard version == 1, events.count <= 40, annotations.count <= 40,
              Set(events.map(\.id)).count == events.count else { throw JournalError.invalid }
        for event in events {
            guard !event.title.isEmpty, event.title.count <= 80,
                  !event.category.isEmpty, event.category.count <= 80,
                  (1...10_000).contains(event.count),
                  event.firstSeen.timeIntervalSince1970.isFinite,
                  event.lastSeen.timeIntervalSince1970.isFinite,
                  event.firstSeen <= event.lastSeen,
                  event.lastSeen <= now.addingTimeInterval(60) else { throw JournalError.invalid }
        }
        guard annotations.values.allSatisfy({ $0.note.count <= 500 }) else { throw JournalError.invalid }
        let allIDs = Set(events.map(\.id))
        guard suppressedLinks.count <= 1024, Set(suppressedLinks).count == suppressedLinks.count,
              suppressedLinks.allSatisfy({ $0.valid && allIDs.contains($0.first) && allIDs.contains($0.second) }) else { throw JournalError.invalid }
        let kept = events.filter { $0.lastSeen >= cutoff }
        let ids = Set(kept.map(\.id))
        return JournalArchive(events: kept, annotations: annotations.filter { ids.contains($0.key) },
                              suppressedLinks: suppressedLinks.filter { ids.contains($0.first) && ids.contains($0.second) })
    }
}

enum JournalError: LocalizedError {
    case invalid, oversized
    var errorDescription: String? {
        switch self { case .invalid: return "记录格式不兼容或内容不完整"; case .oversized: return "记录文件超出读取上限" }
    }
}

/// Stores event summaries only. Captions, images and audio never enter this store.
final class LocalJournal {
    private let directory: URL
    private let files: FileManager
    private var settingsURL: URL { directory.appendingPathComponent("preferences.json") }
    private var historyURL: URL { directory.appendingPathComponent("events.json") }
    private var databaseURL: URL { directory.appendingPathComponent("events.sqlite") }
    private var database: DatabaseJournal?

    init(directory: URL? = nil, files: FileManager = .default) {
        self.files = files
        self.directory = directory ?? files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeeSound", isDirectory: true)
    }

    func loadPreferences() throws -> AppPreferences {
        guard files.fileExists(atPath: settingsURL.path) else { return AppPreferences() }
        let result = try JSONDecoder().decode(AppPreferences.self, from: read(settingsURL))
        guard [1, 7, 30].contains(result.retentionDays), result.phrases.count <= PhraseCollection.limit,
              result.phrases.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 80 })
        else { throw JournalError.invalid }
        return result
    }

    func loadHistory(preferences: AppPreferences, now: Date = Date()) throws -> JournalArchive {
        guard preferences.saveHistory else {
            try deleteHistory()
            return JournalArchive(events: [], annotations: [:])
        }
        let db = try eventDatabase()
        let cutoff = now.addingTimeInterval(-Double(preferences.retentionDays) * 86_400)
        if try !db.hasSnapshot(), files.fileExists(atPath: historyURL.path) {
            let legacy = try JSONDecoder().decode(JournalArchive.self, from: read(historyURL))
            let validated = try legacy.validated(since: cutoff, now: now)
            try db.save(validated)
        }
        let archive = try db.load().validated(since: cutoff, now: now)
        if files.fileExists(atPath: historyURL.path) { try files.removeItem(at: historyURL) }
        try protectDatabaseFiles()
        return archive
    }

    func savePreferences(_ preferences: AppPreferences) throws {
        try write(JSONEncoder().encode(preferences), to: settingsURL)
    }

    func saveHistory(_ archive: JournalArchive) throws {
        try eventDatabase().save(archive)
        if files.fileExists(atPath: historyURL.path) { try files.removeItem(at: historyURL) }
        try protectDatabaseFiles()
    }

    func closeDatabase() throws { try database?.close();database = nil }

    func deleteHistory() throws {
        try database?.close()
        database = nil
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        }
        if files.fileExists(atPath: historyURL.path) { try files.removeItem(at: historyURL) }
    }

    private func eventDatabase() throws -> DatabaseJournal {
        if let database { return database }
        try prepareDirectory()
        let opened = try DatabaseJournal(url: databaseURL)
        database = opened
        try protectDatabaseFiles()
        return opened
    }

    private func protectDatabaseFiles() throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = databaseURL.path + suffix
            guard files.fileExists(atPath: path) else { continue }
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try files.setAttributes(attributes, ofItemAtPath: path)
        }
    }

    private func prepareDirectory() throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
    }

    private func read(_ url: URL) throws -> Data {
        let size = (try files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 524_288 else { throw JournalError.oversized }
        return try Data(contentsOf: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        guard data.count <= 524_288 else { throw JournalError.oversized }
        try prepareDirectory()
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum JournalExport {
    /// An explicit user export; no internal IDs, free-text notes or original media.
    static func summary(events: [SenseEvent], annotations: [UUID: EventAnnotation]) -> String {
        let formatter = ISO8601DateFormatter()
        var rows = ["见声 · 事件摘要", "由用户主动导出；演示、模型判断与人工复核分别标注。", "不包含原始音视频、字幕、备注或内部标识。", ""]
        for event in events {
            let source = event.isDemonstration ? "演示" : event.source == .sound ? "声音模型" : "动作规则"
            let verdict = annotations[event.id]?.verdict.title ?? EventVerdict.unreviewed.title
            rows.append("\(formatter.string(from: event.lastSeen)) | \(source) | \(event.title) | \(event.status == .confirmed ? "已确认" : "待确认") | 复核：\(verdict) | 检测窗口：\(event.count)")
        }
        return rows.joined(separator: "\n")
    }
}
