import Foundation
import Combine

final class QualityStore {
    let directory:URL
    var url:URL { directory.appendingPathComponent("quality.json") }
    init(directory:URL? = nil) { self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("SeeSoundQuality") }
    func load() throws -> QualityArchive {
        guard FileManager.default.fileExists(atPath:url.path) else { return QualityArchive() }
        guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 800_000 else { throw LibraryError.capacity }
        let value = try JSONDecoder().decode(QualityArchive.self,from:Data(contentsOf:url));try value.validate();return value
    }
    func save(_ archive:QualityArchive) throws { try archive.validate();try LibraryRepository.protectedWrite(JSONEncoder().encode(archive),to:url) }
}
@MainActor final class QualityService:ObservableObject {
    @Published private(set) var archive = QualityArchive()
    @Published private(set) var error:String?
    private let store = QualityStore()
    init() { reload() }
    func reload() { do { archive = try store.load();error = nil } catch { self.error = "验证记录读取失败，原文件已保留。" } }
    func record(_ record:VerificationRecord) throws { guard error == nil else { throw LibraryError.recovery };try record.validate();var next = archive;next.records.insert(record,at:0);try store.save(next);archive = next }
    func report(_ report:RecognitionReport) throws { guard error == nil else { throw LibraryError.recovery };try report.validate();var next = archive;next.reports.insert(report,at:0);try store.save(next);archive = next }
}

final class LibraryRepository {
    let base:URL
    private var journal:LocalJournal { LocalJournal(directory:base.appendingPathComponent("SeeSound")) }
    private var workroom:WorkroomStore { WorkroomStore(directory:base.appendingPathComponent("SeeSoundWorkroom")) }
    private var cards:InformationCardStore { InformationCardStore(directory:base.appendingPathComponent("SeeSoundInformationCards")) }
    private var routines:RoutineStore { RoutineStore(directory:base.appendingPathComponent("SeeSoundRoutines")) }
    private var conversations:ConversationArchiveStore { ConversationArchiveStore(directory:base.appendingPathComponent("SeeSoundConversations")) }
    private var quality:QualityStore { QualityStore(directory:base.appendingPathComponent("SeeSoundQuality")) }
    private var recoveryURL:URL { base.appendingPathComponent("SeeSoundRecovery/pending.json") }
    var afterWrite:((Int) throws -> Void)?
    init(base:URL? = nil) { self.base = base ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0] }
    static func protectedWrite(_ data:Data,to url:URL) throws {
        let files = FileManager.default;var parent = url.deletingLastPathComponent()
        try files.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var values = URLResourceValues();values.isExcludedFromBackup = true;try parent.setResourceValues(values)
        #if os(iOS)
        try data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to:url,options:.atomic)
        #endif
        try files.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func read() throws -> LibrarySnapshot {
        let journal = self.journal;defer { try? journal.closeDatabase() }
        var result = LibrarySnapshot();result.preferences = try journal.loadPreferences();result.history = try journal.loadHistory(preferences:result.preferences)
        result.workroom = try workroom.load();result.cards = try cards.load();result.routines = try routines.load();result.conversations = try conversations.load();result.quality = try quality.load()
        try result.validate();return result
    }
    private struct Recovery:Codable { var version = 1;var before:LibrarySnapshot }
    func recover() throws -> Bool {
        guard FileManager.default.fileExists(atPath:recoveryURL.path) else { return false }
        guard try recoveryURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 20_000_000 else { throw LibraryError.recovery }
        let value = try JSONDecoder().decode(Recovery.self,from:Data(contentsOf:recoveryURL))
        guard value.version == 1 else { throw LibraryError.recovery };try value.before.validate()
        try writeAll(value.before,inject:false)
        try FileManager.default.removeItem(at:recoveryURL);return true
    }
    static func recoverDefault() -> String? {
        do { _ = try LibraryRepository().recover();return nil }
        catch { return "上次资料恢复未完成，自动回退也未完成。已保留恢复日志，请在备份中心重试；不要继续覆盖资料。" }
    }
    func commit(_ preview:LibraryRestorePreview) throws {
        guard !FileManager.default.fileExists(atPath:recoveryURL.path) else { throw LibraryError.recovery }
        let before = try read();guard try before.fingerprint() == preview.localFingerprint else { throw LibraryError.stale }
        try preview.target.validate()
        try Self.protectedWrite(JSONEncoder().encode(Recovery(before:before)),to:recoveryURL)
        do { try writeAll(preview.target,inject:true);try FileManager.default.removeItem(at:recoveryURL) }
        catch {
            do { _ = try recover() } catch { throw LibraryError.recovery }
            throw error
        }
    }
    private func writeAll(_ value:LibrarySnapshot,inject:Bool) throws {
        try value.validate()
        // Each file is atomic. The recovery journal rolls back the whole logical library after a crash.
        try workroom.save(value.workroom);if inject { try afterWrite?(1) }
        try cards.save(value.cards,consent:true);if inject { try afterWrite?(2) }
        try routines.save(value.routines,consent:true);if inject { try afterWrite?(3) }
        try conversations.replaceAll(value.conversations);if inject { try afterWrite?(4) }
        try quality.save(value.quality);if inject { try afterWrite?(5) }
        let journal = self.journal;defer { try? journal.closeDatabase() }
        try journal.savePreferences(value.preferences)
        if value.preferences.saveHistory { try journal.saveHistory(value.history) } else { try journal.deleteHistory() }
        if inject { try afterWrite?(6) }
    }
}
