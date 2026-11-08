import Foundation

#if SWIFT_PACKAGE
@testable import SeeSoundData
#endif

#if !SWIFT_PACKAGE
@main
#endif
struct JournalChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("Check failed: \(message)") }
    }

    static func main() throws {
        let now = Date()
        var gate = SoundEvidenceGate(enabled: [.knock])
        expect(gate.accept(label: "door_bell", score: 0.99, at: now) == nil, "disabled category ignored")
        expect(gate.accept(label: "knock", score: .nan, at: now) == nil, "nonfinite score ignored")
        expect(gate.accept(label: "knock", score: 1.1, at: now) == nil, "out of range score ignored")
        expect(gate.accept(label: "knock", score: 0.8, at: now) == nil, "requires consecutive evidence")
        expect(gate.accept(label: "knocking", score: 0.8, at: now.addingTimeInterval(0.75)) == .knock, "aliases share evidence")
        expect(gate.accept(label: "knock", score: 0.8, at: now.addingTimeInterval(1.5)) == nil, "cooldown suppresses duplicate")
        expect(gate.accept(label: "knock", score: 0.8, at: now.addingTimeInterval(3)) == .knock, "cooldown expires")
        expect(gate.accept(label: "knock", score: 0.8, at: now.addingTimeInterval(10)) == nil, "gap resets evidence")
        expect(gate.accept(label: "knock", score: 0.8, at: now.addingTimeInterval(-1)) == nil, "clock reversal resets")
        gate = SoundEvidenceGate(sensitivity: .cautious)
        expect(gate.accept(label: "knock", score: 0.7, at: now) == nil, "cautious threshold")
        for i in 0..<2 { expect(gate.accept(label: "knock", score: 0.8, at: now.addingTimeInterval(Double(i))) == nil, "three windows required") }
        expect(gate.accept(label: "knock", score: 0.8, at: now.addingTimeInterval(2)) == .knock, "third window triggers")
        gate.reset()
        expect(gate.accept(label: "knock", score: 0.8, at: now.addingTimeInterval(3)) == nil, "reset discards evidence")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeeSoundChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalJournal(directory: directory)
        var preferences = try store.loadPreferences()
        expect(!preferences.saveHistory, "history requires opt in")
        preferences.apply(.study)
        expect(preferences.sounds == [.knock, .doorbell], "study preset categories")
        preferences.phrases.append("测试短语")
        try store.savePreferences(preferences)
        let restoredPreferences = try store.loadPreferences()
        expect(restoredPreferences == preferences, "preferences round trip")

        let event = SenseEvent(category: "knock", title: "可能的敲门声", source: .sound, at: now)
        let old = SenseEvent(category: "knock", title: "过期记录", source: .sound, at: now.addingTimeInterval(-8 * 86_400))
        let demo = SenseEvent(category: "demo", title: "演示提醒", source: .demonstration, at: now)
        let annotation = EventAnnotation(verdict: .falseAlarm, note: "PRIVATE_NOTE_SENTINEL")
        let archive = JournalArchive(events: [event, old, demo], annotations: [event.id: annotation, old.id: annotation])
        preferences.saveHistory = true
        try store.savePreferences(preferences)
        try store.saveHistory(archive)
        let restored = try store.loadHistory(preferences: preferences, now: now)
        expect(restored.events.count == 2, "expired history filtered")
        expect(restored.annotations[old.id] == nil, "expired annotations removed")
        expect(restored.annotations[event.id] == annotation, "human correction preserved")
        expect(restored.events.contains { $0.isDemonstration }, "demo remains explicit in history")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("events.sqlite").path)
        expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history file owner-only")
        let export = JournalExport.summary(events: restored.events, annotations: restored.annotations)
        expect(!export.contains("PRIVATE_NOTE_SENTINEL") && !export.contains(event.id.uuidString), "export excludes notes and IDs")
        expect(export.contains("演示") && export.contains("误报"), "export distinguishes source and human verdict")
        preferences.saveHistory = false
        let optedOut = try store.loadHistory(preferences: preferences, now: now)
        expect(optedOut.events.isEmpty, "opt out does not restore history")
        expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.sqlite").path), "opt out removes disk history")
        expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("preferences.json").path), "opt out retains separate preferences")
        try store.deleteHistory()
        expect(true, "repeat deletion succeeds")

        var bad = archive
        bad.version = 99
        do { _ = try bad.validated(since: now.addingTimeInterval(-86_400), now: now); expect(false, "invalid version") }
        catch { expect(true, "unsupported archive rejected") }
        bad = archive; bad.events[0].count = 0
        do { _ = try bad.validated(since: now.addingTimeInterval(-86_400), now: now); expect(false, "invalid count") }
        catch { expect(true, "invalid event count rejected") }
        try Data("broken-json".utf8).write(to: directory.appendingPathComponent("events.json"))
        preferences.saveHistory = true
        do { _ = try store.loadHistory(preferences: preferences, now: now); expect(false, "broken file") }
        catch { expect(true, "corrupt archive is reported") }

        var ledger = EventLedger(events: [event, event, demo])
        expect(ledger.events.count == 2, "restoration deduplicates IDs")
        ledger.remove(event.id)
        expect(ledger.events.map(\.id) == [demo.id], "delete selected event")
        ledger.retain(since: now.addingTimeInterval(1))
        expect(ledger.events.isEmpty, "retention removes expired events")
        ledger = EventLedger()
        let older = ledger.register(category: "knock", title: "敲门", source: .sound, at: now)
        ledger.register(category: "clapping", title: "拍手", source: .sound, at: now.addingTimeInterval(1))
        let merged = ledger.register(category: "knock", title: "敲门", source: .sound, at: now.addingTimeInterval(2))
        expect(merged.id == older.id && ledger.events.first?.id == older.id, "merged event returns and moves to newest position")
        print("PASS: \(checks) journal and policy checks. No claim of real detection or device delivery.")
    }
}
