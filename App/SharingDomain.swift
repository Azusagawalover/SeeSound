import Foundation

enum SharedTextKind: String, Codable { case snapshot, acknowledgement, ended, heartbeat }

struct SharedTextPacket: Codable, Equatable {
    var format = "SeeSoundLiveText"
    var version = 1
    var session: UUID
    var revision: Int
    var kind: SharedTextKind
    var sentAt = Date()
    var turns: [SavedConversationTurn] = []
}

enum SharedTextCodec {
    static func encode(_ packet: SharedTextPacket) throws -> Data {
        try validate(packet, now: Date())
        let data = try JSONEncoder().encode(packet)
        guard data.count <= 65_536 else { throw DailyError.invalid }
        return data
    }
    static func decode(_ data: Data, now: Date = Date()) throws -> SharedTextPacket {
        guard data.count <= 65_536 else { throw DailyError.invalid }
        let packet = try JSONDecoder().decode(SharedTextPacket.self, from: data)
        try validate(packet, now: now); return packet
    }
    private static func validate(_ packet: SharedTextPacket, now: Date) throws {
        let age = now.timeIntervalSince(packet.sentAt)
        guard packet.format == "SeeSoundLiveText", packet.version == 1, (0...1_000_000).contains(packet.revision),
              age.isFinite, (-60...120).contains(age), packet.turns.count <= 20,
              Set(packet.turns.map(\.id)).count == packet.turns.count,
              packet.kind == .snapshot || packet.turns.isEmpty else { throw DailyError.invalid }
        try packet.turns.forEach { try $0.validate() }
    }
}

struct SharedTextCursor {
    private(set) var session: UUID?
    private(set) var revision = -1
    mutating func begin(_ id: UUID) { session = id; revision = -1 }
    mutating func accept(_ packet: SharedTextPacket) -> Bool {
        guard packet.session == session, packet.kind == .snapshot, packet.revision > revision else { return false }
        revision = packet.revision; return true
    }
    mutating func clear() { session = nil; revision = -1 }
}

struct SharedReadState {
    private(set) var acknowledgedRevision = -1
    mutating func accept(_ packet: SharedTextPacket, currentRevision: Int, session: UUID) -> Bool {
        guard packet.session == session, packet.kind == .acknowledgement,
              currentRevision >= 0, (0...currentRevision).contains(packet.revision) else { return false }
        acknowledgedRevision = max(acknowledgedRevision, packet.revision); return true
    }
    func hasRead(_ revision: Int) -> Bool { revision >= 0 && acknowledgedRevision == revision }
    mutating func clear() { acknowledgedRevision = -1 }
}

struct ShareInvitation: Codable {
    var version = 1
    var session: UUID
    var code: String
    func matches(session: UUID, code: String) -> Bool {
        version == 1 && self.session == session && self.code == code && code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Local receive times, independent of caption updates and read acknowledgements.
struct SharedTextLiveness {
    private(set) var lastContact: Date?
    mutating func begin(at now: Date = Date()) { lastContact = now }
    mutating func receive(at now: Date = Date()) {
        guard lastContact.map({ now >= $0 }) ?? true else { return }
        lastContact = now
    }
    func expired(at now: Date = Date()) -> Bool {
        guard let lastContact else { return true }
        return now < lastContact || now.timeIntervalSince(lastContact) >= 45
    }
    mutating func clear() { lastContact = nil }
}
