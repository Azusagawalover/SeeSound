import Foundation
import CryptoKit

enum WatchAgendaKind:String,Codable { case routine, project, journey }
struct WatchAgendaItem:Codable,Identifiable,Equatable {
    var id:UUID
    var kind:WatchAgendaKind
    var title:String
    var next:String
    var dueAt:Date?
    var fingerprint:String
    var demonstration:Bool
    var completed:Bool
    var seen:Bool = false
    var outdated:Bool?
    func validate() throws {
        guard !title.isEmpty,title.count <= 100,next.count <= 120,fingerprint.count == 64,fingerprint.allSatisfy({ $0.isHexDigit }),dueAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw WatchAgendaError.invalid }
    }
}
enum WatchAgendaAction:String,Codable { case seen, complete }
struct WatchAgendaPacket:Codable {
    enum Kind:String,Codable { case snapshot, action, receipt }
    var version = 1
    var id = UUID()
    var kind:Kind
    var date = Date()
    var items:[WatchAgendaItem] = []
    var recordID:UUID?
    var fingerprint:String?
    var action:WatchAgendaAction?
    var accepted:Bool?
    var message:String?
    func validate(now:Date = Date()) throws {
        guard version == 1,date.timeIntervalSince1970.isFinite,date <= now.addingTimeInterval(60),now.timeIntervalSince(date) <= 600,items.count <= 5,Set(items.map(\.id)).count == items.count,(message?.count ?? 0) <= 150 else { throw WatchAgendaError.invalid }
        try items.forEach { try $0.validate() }
        switch kind {
        case .snapshot:guard recordID == nil,fingerprint == nil,action == nil,accepted == nil,message == nil else { throw WatchAgendaError.invalid }
        case .action:guard items.isEmpty,recordID != nil,let fingerprint,fingerprint.count == 64,fingerprint.allSatisfy({$0.isHexDigit}),action != nil,accepted == nil,message == nil else { throw WatchAgendaError.invalid }
        case .receipt:guard recordID != nil,fingerprint != nil,action != nil,accepted != nil,items.count <= 1 else { throw WatchAgendaError.invalid }
        }
    }
}
enum WatchAgendaError:Error { case invalid }
enum WatchAgendaCodec {
    static func encode(_ packet:WatchAgendaPacket,now:Date = Date()) throws -> Data {
        try packet.validate(now:now);let data = try JSONEncoder().encode(packet);guard data.count <= 24_000 else { throw WatchAgendaError.invalid };return data
    }
    static func decode(_ data:Data,now:Date = Date()) throws -> WatchAgendaPacket {
        guard data.count <= 24_000 else { throw WatchAgendaError.invalid };let packet = try JSONDecoder().decode(WatchAgendaPacket.self,from:data);try packet.validate(now:now);return packet
    }
    static func fingerprint<T:Encodable>(_ value:T) throws -> String {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data:try encoder.encode(value)).map { String(format:"%02x",$0) }.joined()
    }
}

struct WatchAgendaResolution {
    var accepted:Bool
    var message:String
    var item:WatchAgendaItem?
}

struct AgendaReplyCache {
    private struct Entry { var signature:String;var receipt:Data }
    private var entries:[UUID:Entry] = [:]
    private var order:[UUID] = []
    func receipt(for request:WatchAgendaPacket,now:Date = Date()) -> Data? {
        guard request.kind == .action,(try? request.validate(now:now)) != nil,
              let entry = entries[request.id],entry.signature == (try? WatchAgendaCodec.fingerprint(request)),
              (try? WatchAgendaCodec.decode(entry.receipt,now:now)) != nil else { return nil }
        return entry.receipt
    }
    mutating func remember(request:WatchAgendaPacket,response:WatchAgendaPacket) throws {
        guard request.kind == .action,response.kind == .receipt,request.id == response.id,request.recordID == response.recordID,
              request.fingerprint == response.fingerprint,request.action == response.action,
              response.items.allSatisfy({ $0.id == request.recordID }) else { throw WatchAgendaError.invalid }
        let data = try WatchAgendaCodec.encode(response)
        entries[request.id] = .init(signature:try WatchAgendaCodec.fingerprint(request),receipt:data)
        order.removeAll { $0 == request.id };order.append(request.id)
        while order.count > 100 { entries[order.removeFirst()] = nil }
    }
}
enum WatchAgendaActionPolicy {
    static func rejection(item:WatchAgendaItem,fingerprint:String,action:WatchAgendaAction) -> String? {
        guard item.fingerprint == fingerprint else { return "手机资料已更新，请重新发送摘要。" }
        guard !item.completed else { return "手机记录已经完成，请重新发送摘要。" }
        guard item.kind == .routine && action == .complete || (item.kind == .project || item.kind == .journey) && action == .seen else { return "这类摘要不支持此操作。" }
        return nil
    }
}

struct WatchVersionNotice: Codable {
    var date = Date()
    var fingerprints: [String:String]
    func validate(now:Date = Date()) throws {
        guard fingerprints.count <= 5,date.timeIntervalSince1970.isFinite,date <= now.addingTimeInterval(60),fingerprints.allSatisfy({UUID(uuidString:$0.key) != nil && ($0.value.isEmpty || $0.value.count == 64 && $0.value.allSatisfy(\.isHexDigit))}) else { throw WatchAgendaError.invalid }
    }
    func invalidates(_ item:WatchAgendaItem,snapshotDate:Date?) -> Bool {
        guard snapshotDate.map({date >= $0}) ?? false,let current = fingerprints[item.id.uuidString] else { return false }
        return current != item.fingerprint
    }
}
