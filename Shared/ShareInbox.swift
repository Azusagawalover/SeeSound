import Foundation
import Darwin

struct SharePacket: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var text = ""
    var image:Data?
    func validate() throws {
        guard createdAt.timeIntervalSince1970.isFinite,createdAt <= Date().addingTimeInterval(300),text.count <= 12000,
              image.map({ !$0.isEmpty && $0.count <= 20*1024*1024 }) != false,
              image != nil || !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ShareInboxError.invalid }
    }
}
enum ShareInboxError:LocalizedError {
    case unavailable, invalid, full
    var errorDescription:String? {
        switch self { case .unavailable:return "共享收件箱不可用。请检查 App Group 签名配置，或先从应用内导入。";case .invalid:return "只接收最多 12000 字文字或 20 MB 图片，请减少内容后重试。";case .full:return "共享收件箱最多暂存 10 项，请先打开见声整理。" }
    }
}
final class ShareInboxStore {
    static let group = "group.com.azusagawalover.SeeSound"
    let directory:URL?
    init(directory:URL? = nil) {
        #if os(iOS)
        self.directory = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:Self.group)?.appendingPathComponent("SharedInbox")
        #else
        self.directory = directory
        #endif
    }
    func load() throws -> [SharePacket] {
        guard let directory else { throw ShareInboxError.unavailable }
        guard FileManager.default.fileExists(atPath:directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey]).filter { $0.pathExtension == "json" }
        guard files.count <= 10 else { throw ShareInboxError.full }
        return try files.map { url in
            guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 29_000_000 else { throw ShareInboxError.invalid }
            let packet = try JSONDecoder().decode(SharePacket.self,from:Data(contentsOf:url));try packet.validate();guard url.deletingPathExtension().lastPathComponent == packet.id.uuidString else { throw ShareInboxError.invalid };return packet
        }.sorted { $0.createdAt > $1.createdAt }
    }
    func save(_ packet:SharePacket) throws {
        try packet.validate();guard let directory else { throw ShareInboxError.unavailable }
        // Each accepted item is stored atomically under its own unique identifier.
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor = open(directory.appendingPathComponent(".writer-lock").path,O_CREAT|O_RDWR,0o600)
        guard descriptor >= 0 else { throw ShareInboxError.unavailable }
        defer { flock(descriptor,LOCK_UN);close(descriptor) }
        guard flock(descriptor,LOCK_EX) == 0 else { throw ShareInboxError.unavailable }
        guard try load().count < 10 else { throw ShareInboxError.full }
        let url = directory.appendingPathComponent(packet.id.uuidString+".json"), data = try JSONEncoder().encode(packet)
        #if os(iOS)
        try data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to:url,options:.atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        var root = directory;var values = URLResourceValues();values.isExcludedFromBackup = true;try root.setResourceValues(values)
    }
    func remove(_ id:UUID) throws { guard let directory else { throw ShareInboxError.unavailable };let url = directory.appendingPathComponent(id.uuidString+".json");if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
}
