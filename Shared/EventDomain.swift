import Foundation

enum EventSource: String, Codable {
    case sound, gesture, demonstration
}

enum EventStatus: String, Codable {
    case pending, confirmed
}

struct SenseEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var category: String
    var title: String
    var source: EventSource
    var firstSeen: Date
    var lastSeen: Date
    var count: Int
    var status: EventStatus
    var isDemonstration: Bool { source == .demonstration }

    init(category: String, title: String, source: EventSource, at date: Date = Date()) {
        id = UUID()
        self.category = category
        self.title = title
        self.source = source
        firstSeen = date
        lastSeen = date
        count = 1
        status = .pending
    }
}

struct EventLedger: Codable {
    private(set) var events: [SenseEvent] = []

    init(events: [SenseEvent] = []) {
        var seen = Set<UUID>()
        self.events = Array(events.sorted { $0.lastSeen > $1.lastSeen }
            .filter { seen.insert($0.id).inserted }.prefix(40))
    }

    @discardableResult
    mutating func register(category: String, title: String, source: EventSource,
                           at date: Date = Date()) -> SenseEvent {
        if let index = events.firstIndex(where: {
            $0.category == category && $0.source == source && $0.status == .pending
                && date.timeIntervalSince($0.lastSeen) >= 0
                && date.timeIntervalSince($0.lastSeen) <= 4
        }) {
            events[index].lastSeen = date
            events[index].count = min(10_000, events[index].count + 1)
            let updated = events.remove(at: index)
            events.insert(updated, at: 0)
            return updated
        }
        let event = SenseEvent(category: category, title: title, source: source, at: date)
        events.insert(event, at: 0)
        if events.count > 40 { events.removeLast(events.count - 40) }
        return event
    }

    @discardableResult
    mutating func confirm(_ id: UUID) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return false }
        events[index].status = .confirmed
        return true
    }

    mutating func clear() { events.removeAll() }

    mutating func remove(_ id: UUID) { events.removeAll { $0.id == id } }

    mutating func retain(since date: Date) { events.removeAll { $0.lastSeen < date } }
}

enum SoundKind: String, Codable, CaseIterable, Identifiable {
    case knock, doorbell, clapping
    var id: String { rawValue }
    var title: String {
        switch self { case .knock: return "敲门"; case .doorbell: return "门铃"; case .clapping: return "拍手" }
    }
    var symbol: String {
        switch self { case .knock: return "door.left.hand.closed"; case .doorbell: return "bell"; case .clapping: return "hands.clap" }
    }
    static func matching(_ label: String) -> SoundKind? {
        switch label {
        case "knock", "knocking": return .knock
        case "door_bell", "doorbell": return .doorbell
        case "clapping": return .clapping
        default: return nil
        }
    }
}

enum DetectionSensitivity: String, Codable, CaseIterable, Identifiable {
    case cautious, balanced, responsive
    var id: String { rawValue }
    var title: String {
        switch self { case .cautious: return "减少打扰"; case .balanced: return "标准"; case .responsive: return "积极关注" }
    }
    var threshold: Double {
        switch self { case .cautious: return 0.75; case .balanced: return 0.65; case .responsive: return 0.55 }
    }
    var windows: Int { self == .cautious ? 3 : 2 }
}

/// Configurable evidence gate; thresholds are provisional, not measured accuracy.
struct SoundEvidenceGate {
    var enabled: Set<SoundKind> = Set(SoundKind.allCases)
    var sensitivity: DetectionSensitivity = .balanced
    private var candidate: SoundKind?
    private var count = 0
    private var lastInput: Date?
    private var lastEvent: Date?

    init(enabled: Set<SoundKind> = Set(SoundKind.allCases), sensitivity: DetectionSensitivity = .balanced) {
        self.enabled = enabled
        self.sensitivity = sensitivity
    }

    mutating func accept(label: String, score: Double, at now: Date = Date()) -> SoundKind? {
        if let lastInput, now < lastInput || now.timeIntervalSince(lastInput) > 3 {
            candidate = nil; count = 0; lastEvent = nil
        }
        lastInput = now
        guard score.isFinite, score >= sensitivity.threshold, score <= 1,
              let kind = SoundKind.matching(label), enabled.contains(kind) else {
            candidate = nil; count = 0
            return nil
        }
        count = candidate == kind ? min(count + 1, sensitivity.windows) : 1
        candidate = kind
        guard count >= sensitivity.windows,
              lastEvent.map({ now.timeIntervalSince($0) >= 2 }) ?? true else { return nil }
        lastEvent = now
        return kind
    }

    mutating func reset() { candidate = nil; count = 0; lastInput = nil; lastEvent = nil }
}

enum PacketKind: String, Codable {
    case event, receipt, confirmation, quickReply
}

enum WatchQuickReply: String, Codable, CaseIterable, Identifiable {
    case wait, coming
    var id: String { rawValue }
    var title: String { self == .wait ? "请等一下" : "我马上来" }
}

struct WatchPacket: Codable {
    var version = 1
    var kind: PacketKind
    var event: SenseEvent?
    var reference: UUID
    var sentAt: Date
    var isConfirmed: Bool? = nil
    var quickReply: WatchQuickReply? = nil

    static func event(_ event: SenseEvent, at date: Date = Date()) -> WatchPacket {
        WatchPacket(kind: .event, event: event, reference: event.id, sentAt: date)
    }

    static func response(_ kind: PacketKind, to id: UUID, at date: Date = Date(), isConfirmed: Bool? = nil, quickReply: WatchQuickReply? = nil) -> WatchPacket {
        WatchPacket(version: quickReply == nil ? 1 : 2, kind: kind, event: nil, reference: id, sentAt: date, isConfirmed: isConfirmed, quickReply: quickReply)
    }
}

enum PacketError: Error { case tooLarge, invalid, expired }

enum DeliveryPhase { case sending, received, confirmed, failed }

struct DeliveryAttempt {
    var token: UUID
    var phase: DeliveryPhase
    var message: String
}

/// Keeps late replies and duplicate taps from replacing newer or confirmed state.
struct DeliveryTracker {
    private(set) var records: [UUID: DeliveryAttempt] = [:]
    private var order: [UUID] = []

    mutating func begin(_ id: UUID, message: String) -> UUID? {
        guard records[id]?.phase != .sending, records[id]?.phase != .confirmed else { return nil }
        let token = UUID()
        records[id] = DeliveryAttempt(token: token, phase: .sending, message: message)
        remember(id)
        return token
    }

    @discardableResult
    mutating func finish(_ id: UUID, token: UUID, phase: DeliveryPhase, message: String) -> Bool {
        guard let record = records[id], record.token == token, record.phase == .sending,
              phase != .sending else { return false }
        records[id] = DeliveryAttempt(token: token, phase: phase, message: message)
        return true
    }

    mutating func confirm(_ id: UUID, message: String) {
        let token = records[id]?.token ?? UUID()
        records[id] = DeliveryAttempt(token: token, phase: .confirmed, message: message)
        remember(id)
    }

    private mutating func remember(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > 100 { records[order.removeFirst()] = nil }
    }
}

enum PacketCodec {
    static func encode(_ packet: WatchPacket) throws -> Data {
        let data = try JSONEncoder().encode(packet)
        guard data.count <= 16_384 else { throw PacketError.tooLarge }
        return data
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> WatchPacket {
        guard data.count <= 16_384 else { throw PacketError.tooLarge }
        let packet = try JSONDecoder().decode(WatchPacket.self, from: data)
        let age = now.timeIntervalSince(packet.sentAt)
        guard age.isFinite, age >= -60 else { throw PacketError.invalid }
        if packet.version == 1 {
            guard packet.quickReply == nil, packet.kind != .quickReply else { throw PacketError.invalid }
        } else if packet.version == 2 {
            guard packet.quickReply != nil, packet.kind == .quickReply || packet.kind == .receipt,
                  packet.isConfirmed == nil else { throw PacketError.invalid }
        } else { throw PacketError.invalid }
        guard age <= 300 else { throw PacketError.expired }
        guard packet.kind == .receipt || packet.isConfirmed == nil else { throw PacketError.invalid }
        if packet.kind == .event {
            guard let event = packet.event, event.id == packet.reference,
                  !event.title.isEmpty, event.title.count <= 80,
                  !event.category.isEmpty, event.category.count <= 80,
                  (1...10_000).contains(event.count),
                  event.lastSeen >= event.firstSeen,
                  event.lastSeen <= now.addingTimeInterval(60),
                  now.timeIntervalSince(event.lastSeen) <= 300 else { throw PacketError.invalid }
        } else if packet.event != nil {
            throw PacketError.invalid
        }
        return packet
    }
}

/// Prototype heuristic, not a trained gesture classifier or a detector of intent.
struct WaveWindow {
    private var samples: [(time: Double, x: Double, size: Double)] = []
    private var lastDetection = -Double.infinity

    mutating func reset() { samples.removeAll(); lastDetection = -.infinity }

    mutating func ingest(x: Double, palmWidth: Double, time: Double) -> Bool {
        guard x.isFinite, palmWidth.isFinite, time.isFinite,
              (0...1).contains(x), palmWidth >= 0.025, palmWidth <= 0.6 else {
            samples.removeAll()
            return false
        }
        if let last = samples.last, time <= last.time || time - last.time > 0.35 {
            samples.removeAll()
        }
        samples.append((time, x, palmWidth))
        samples.removeAll { time - $0.time > 1.5 }
        guard samples.count >= 8, time - lastDetection >= 3,
              let first = samples.first, time - first.time >= 0.65 else { return false }
        let width = samples.map(\.size).reduce(0, +) / Double(samples.count)
        let span = (samples.map(\.x).max()! - samples.map(\.x).min()!) / width
        guard span >= 0.9, span <= 5 else { return false }
        var turns = 0
        var previousDirection = 0
        var anchor = first.x
        for sample in samples.dropFirst() {
            let delta = sample.x - anchor
            guard abs(delta) >= width * 0.20 else { continue }
            let direction = delta > 0 ? 1 : -1
            if previousDirection != 0 && previousDirection != direction { turns += 1 }
            previousDirection = direction
            anchor = sample.x
        }
        if turns >= 2 {
            lastDetection = time
            samples.removeAll()
            return true
        }
        return false
    }
}
