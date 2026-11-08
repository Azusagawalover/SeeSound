import Foundation

#if SWIFT_PACKAGE
@testable import SeeSoundData
#endif

#if !SWIFT_PACKAGE
@main
#endif
struct ConversationChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard condition() else { fatalError("Check failed: \(label)") }
    }

    static func main() throws {
        var session = ConversationSession()
        let first = session.beginCapture()
        expect(session.turns.isEmpty, "starting does not create empty text")
        expect(session.receive("你好", capture: first, isFinal: false), "accept active partial")
        expect(session.receive("你好，请问", capture: first, isFinal: false), "update partial")
        expect(session.turns.count == 1 && session.turns[0].text == "你好，请问", "partial updates do not duplicate rows")
        expect(!session.edit(first, text: "edit"), "live text cannot be edited")
        expect(!session.remove(first), "live text cannot be removed")
        expect(session.receive("你好，请问几点？", capture: first, isFinal: true), "final accepted")
        expect(session.activeCapture == nil && session.turns[0].state == .completed, "final ends active capture")
        expect(!session.receive("迟到回调", capture: first, isFinal: false), "completed capture rejects late partial")
        expect(session.edit(first, text: "  请问现在几点？  "), "finished text can be corrected")
        expect(session.turns[0].isEdited && session.turns[0].origin == .speech, "correction preserves source with edit label")
        expect(session.turns[0].text == "请问现在几点？", "correction trims whitespace")
        expect(!session.edit(first, text: " \n "), "empty correction rejected")
        let second = session.beginCapture()
        session.receive("尚未说完", capture: second, isFinal: false)
        session.pauseCapture()
        expect(session.turns.last?.state == .interrupted, "manual pause preserves unfinished text")
        expect(!session.receive("停止后回调", capture: second, isFinal: true), "pause rejects late final")
        let third = session.beginCapture()
        session.receive("下一段", capture: third, isFinal: false)
        let fourth = session.beginCapture()
        expect(session.turns.last?.state == .interrupted, "starting next capture pauses previous")
        expect(!session.receive("错误的段落", capture: third, isFinal: true), "old capture cannot alter new capture")
        expect(session.receive("   ", capture: fourth, isFinal: true), "empty final closes capture")
        expect(session.turns.count == 3, "empty capture leaves no empty row")
        expect(!session.reply(" \n "), "blank reply rejected")
        expect(session.reply("  请写下来。  "), "typed reply accepted")
        expect(session.turns.last?.speaker == .me && session.turns.last?.origin == .typed, "typed response never claims speech origin")
        session.reply(String(repeating: "好", count: 600))
        expect(session.turns.last?.text.count == 500, "reply length bounded")
        let unicode = String(repeating: "👩🏽‍💻", count: 501)
        session.reply(unicode)
        expect(session.turns.last?.text.count == 500, "length clipping preserves grapheme clusters")
        let removable = session.turns.last!.id
        expect(session.remove(removable), "finished response removable")
        expect(!session.remove(removable), "repeat removal is harmless")
        session.clear()
        expect(session.turns.isEmpty && session.activeCapture == nil, "clear removes session and capture identity")
        expect(!session.receive("清空后的回调", capture: first, isFinal: true), "clear cannot be undone by late callback")
        let live = session.beginCapture()
        session.receive("当前句子", capture: live, isFinal: false)
        for index in 0..<80 { session.reply("回应 \(index)") }
        expect(session.turns.count == 50, "session capped at fifty turns")
        expect(session.turns.contains { $0.id == live }, "active caption survives history trimming")
        session.receive("当前句子继续", capture: live, isFinal: true)
        expect(session.turns.filter { $0.id == live }.count == 1, "trimmed history does not duplicate live sentence")

        var preferences = AppPreferences()
        preferences.saveHistory = true
        preferences.sensitivity = .cautious
        preferences.retentionDays = 30
        let phrase = "我需要一点帮助。"
        preferences.phrases.append(phrase)
        preferences.phraseCategories[phrase] = .request
        let encoded = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: encoded)
        expect(decoded == preferences, "new preference fields round trip")
        expect(decoded.category(for: phrase) == .request, "chosen phrase category preserved")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "phraseCategories")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let migrated = try JSONDecoder().decode(AppPreferences.self, from: legacyData)
        expect(migrated.phrases == preferences.phrases, "old phrases retained on migration")
        expect(migrated.saveHistory && migrated.retentionDays == 30 && migrated.sensitivity == .cautious, "migration preserves unrelated choices")
        expect(migrated.category(for: "请用文字告诉我。") == .request, "built in request category")
        expect(migrated.category(for: "我已看到，谢谢。") == .response, "built in response category")
        expect(migrated.category(for: phrase) == .personal, "old custom phrases get neutral category")
        preferences.phraseCategories["已删除的短语"] = .everyday
        let cleaned = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        expect(cleaned.phraseCategories["已删除的短语"] == nil, "deleted phrase metadata removed on load")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConversationChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try legacyData.write(to: directory.appendingPathComponent("preferences.json"))
        let store = LocalJournal(directory: directory)
        let diskMigrated = try store.loadPreferences()
        expect(diskMigrated.phrases == preferences.phrases, "existing disk preferences remain loadable")
        expect(diskMigrated.phraseCategories.isEmpty, "missing categories do not corrupt old settings")
        print("PASS: \(checks) conversation and migration checks. No claim of real speech accuracy or microphone testing.")
    }
}
