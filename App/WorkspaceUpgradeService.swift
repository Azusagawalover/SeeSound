import Foundation

final class WorkroomVisualStore {
    let directory: URL
    init(directory:URL) { self.directory = directory.appendingPathComponent("Visuals") }
    func load(_ id:UUID) throws -> WorkroomVisualEvidence? {
        let url = directory.appendingPathComponent(id.uuidString+".json")
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 8_500_000 else { throw DailyError.invalid }
        let value = try JSONDecoder().decode(WorkroomVisualEvidence.self,from:Data(contentsOf:url));try value.validate()
        guard value.id == id else { throw DailyError.invalid };return value
    }
    func save(_ evidence:WorkroomVisualEvidence) throws {
        try evidence.validate();let url = directory.appendingPathComponent(evidence.id.uuidString+".json")
        let existing = (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey])) ?? []
        let size = existing.filter { $0 != url }.reduce(0) { $0+((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
        let bytes = try JSONEncoder().encode(evidence);guard size+bytes.count <= 120_000_000 else { throw WorkspaceUpgradeError.visualCapacity }
        try LibraryRepository.protectedWrite(bytes,to:url)
    }
    func removeUnreferenced(keeping:Set<UUID>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) else { return }
        for url in urls where url.pathExtension == "json" {
            if let id = UUID(uuidString:url.deletingPathExtension().lastPathComponent),!keeping.contains(id) { try? FileManager.default.removeItem(at:url) }
        }
    }
}
