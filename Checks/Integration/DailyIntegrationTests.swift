import Foundation
import XCTest
@testable import SeeSoundData

final class DailyIntegrationTests: XCTestCase {
    func testSharingLivenessExpiresWithoutInventingReadReceipts() {
        var health = SharedTextLiveness(); let start = Date()
        XCTAssertTrue(health.expired(at: start))
        health.begin(at: start); XCTAssertFalse(health.expired(at: start.addingTimeInterval(44)))
        XCTAssertTrue(health.expired(at: start.addingTimeInterval(45)))
        health.receive(at: start.addingTimeInterval(30))
        XCTAssertFalse(health.expired(at: start.addingTimeInterval(60)))
        health.receive(at: start.addingTimeInterval(1))
        XCTAssertEqual(health.lastContact, start.addingTimeInterval(30))
        XCTAssertTrue(health.expired(at: start.addingTimeInterval(29)))
        health.clear(); XCTAssertTrue(health.expired(at: start))
    }

    func testHeartbeatsCarryNoTextAndDoNotAdvanceTextCursor() throws {
        let id = UUID(); var packet = SharedTextPacket(session: id, revision: 8, kind: .heartbeat)
        let decoded = try SharedTextCodec.decode(SharedTextCodec.encode(packet))
        XCTAssertEqual(decoded.kind, .heartbeat); XCTAssertTrue(decoded.turns.isEmpty)
        var cursor = SharedTextCursor(); cursor.begin(id)
        XCTAssertFalse(cursor.accept(decoded)); XCTAssertEqual(cursor.revision, -1)
        var conversation = ConversationSession(); conversation.addDemonstration()
        packet.turns = conversation.turns.map(SavedConversationTurn.init)
        XCTAssertThrowsError(try SharedTextCodec.encode(packet))
    }
    func testOldPreferencesMigrateWithoutEnablingCaptureOrPersistence() throws {
        let data = Data("{\"saveHistory\":false,\"phrases\":[\"你好\"]}".utf8)
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertFalse(prefs.saveHistory); XCTAssertFalse(prefs.hasFinishedIntro)
        XCTAssertEqual(prefs.reading, ReadingPreferences())
        XCTAssertTrue(prefs.reminderRules.isEmpty); XCTAssertTrue(prefs.corrections.isEmpty)
        XCTAssertFalse(prefs.reminderRule(for: "knock").notifications)
        XCTAssertFalse(prefs.reminderRule(for: "knock").haptic)
        var bad = prefs; bad.reminderRules["unknown"] = ReminderRule()
        XCTAssertThrowsError(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(bad)))
        bad = prefs; var rule = ReminderRule(); rule.repeatCount = 3; bad.reminderRules["knock"] = rule
        XCTAssertThrowsError(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(bad)))
    }

    func testCaptionContinuationRequiresCurrentRunForegroundAndBounds() {
        var policy = CaptionRunPolicy(); let start = Date(); let token = policy.begin(at: start)
        XCTAssertFalse(policy.next(UUID(), at: start, foreground: true))
        XCTAssertFalse(policy.next(token, at: start, foreground: false))
        XCTAssertFalse(policy.next(token, at: start.addingTimeInterval(-1), foreground: true))
        for _ in 0..<60 { XCTAssertTrue(policy.next(token, at: start, foreground: true)) }
        XCTAssertFalse(policy.next(token, at: start, foreground: true))
        let newer = policy.begin(at: start)
        XCTAssertFalse(policy.next(newer, at: start.addingTimeInterval(1200), foreground: true))
        policy.cancel(); XCTAssertFalse(policy.next(newer, at: start, foreground: true))
    }

    func testReminderCooldownDoesNotConfuseDemoWithRealOrDeleteEvents() {
        var gate = ReminderGate(); var ledger = EventLedger(); let now = Date(); let rule = ReminderRule()
        let demo = ledger.register(category: "demo-knock", title: "演示", source: .demonstration, at: now)
        let real = ledger.register(category: "knock", title: "敲门", source: .sound, at: now)
        XCTAssertTrue(gate.allows(demo, rule: rule, now: now))
        XCTAssertTrue(gate.allows(real, rule: rule, now: now))
        XCTAssertFalse(gate.allows(real, rule: rule, now: now.addingTimeInterval(29)))
        XCTAssertTrue(gate.allows(real, rule: rule, now: now.addingTimeInterval(30)))
        gate.snooze("knock", until: now.addingTimeInterval(300))
        XCTAssertFalse(gate.allows(real, rule: rule, now: now.addingTimeInterval(60)))
        XCTAssertEqual(ledger.events.count, 2); XCTAssertEqual(real.status, .pending)
        gate.resume("knock"); XCTAssertTrue(gate.allows(real, rule: rule, now: now.addingTimeInterval(60)))
    }

    func testManualSpeakerLabelsPreserveOriginAndDoNotInventASR() throws {
        var session = ConversationSession(); session.addDemonstration()
        let id = try XCTUnwrap(session.turns.first?.id)
        XCTAssertTrue(session.labelSpeaker(id, name: "同学"))
        XCTAssertEqual(session.turns[0].speakerName, "同学")
        XCTAssertEqual(session.turns[0].origin, .demonstration); XCTAssertFalse(session.turns[0].isEdited)
        XCTAssertTrue(session.edit(id, text: "改过的演示文字")); XCTAssertTrue(session.turns[0].isEdited)
        XCTAssertEqual(session.turns[0].origin, .demonstration)
        let capture = session.beginCapture(speakerName: "说话者 B")
        XCTAssertTrue(session.receive("字幕", capture: capture, isFinal: false))
        XCTAssertFalse(session.labelSpeaker(capture, name: "改名"))
        session.pauseCapture(); XCTAssertTrue(session.labelSpeaker(capture, name: "改名"))
        XCTAssertFalse(session.receive("迟到回调", capture: capture, isFinal: true))
        XCTAssertEqual(session.turns.last?.state, .interrupted)
    }

    func testCorrectionsAreExplicitLiteralAndBounded() throws {
        let correction = TextCorrection(from: "张三", to: "张山")
        try correction.validate(); XCTAssertEqual(correction.apply(to: "张三在吗，张三？"), "张山在吗，张山？")
        XCTAssertEqual(TextCorrection(from: ".", to: "!").apply(to: "a.b"), "a!b")
        XCTAssertEqual(TextCorrection(from: "a", to: String(repeating: "b", count: 80)).apply(to: String(repeating: "a", count: 500)).count, 500)
        XCTAssertThrowsError(try TextCorrection(from: " ", to: "有效").validate())
        XCTAssertThrowsError(try TextCorrection(from: "相同", to: "相同").validate())
    }

    func testConversationArchiveRequiresConsentAndPreservesSourceOnExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationArchiveStore(directory: directory)
        XCTAssertTrue(try store.load().isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        var session = ConversationSession(); session.addDemonstration()
        XCTAssertTrue(session.edit(session.turns[0].id, text: "演示：改过的会议时间"))
        let item = SavedConversation(title: "会话", createdAt: Date(), turns: session.turns.map(SavedConversationTurn.init))
        XCTAssertThrowsError(try store.save(item, consent: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try store.save(item, consent: true)
        XCTAssertEqual(try store.load(), [item]); XCTAssertThrowsError(try store.save(item, consent: true))
        XCTAssertTrue(item.exportText.contains("演示文字")); XCTAssertTrue(item.exportText.contains("已人工修改"))
        XCTAssertTrue(item.matches("会议")); XCTAssertTrue(item.matches("说话者 B")); XCTAssertFalse(item.matches("找不到"))
        try store.delete(item.id); XCTAssertTrue(try store.load().isEmpty)
    }

    func testArchiveRefusesCorruptionWithoutOverwritingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".json")
        let invalid = Data("invalid".utf8); try invalid.write(to: file)
        let store = ConversationArchiveStore(directory: directory)
        XCTAssertThrowsError(try store.load())
        var session = ConversationSession(); session.addDemonstration()
        XCTAssertThrowsError(try store.save(SavedConversation(title: "新", createdAt: Date(), turns: session.turns.map(SavedConversationTurn.init)), consent: true))
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    func testArchiveCapacityDoesNotSilentlyEvictOldConversations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationArchiveStore(directory: directory)
        var session = ConversationSession(); session.addDemonstration()
        let turns = session.turns.map(SavedConversationTurn.init)
        for index in 0..<30 { try store.save(SavedConversation(title: "会话 \(index)", createdAt: Date(), turns: turns), consent: true) }
        XCTAssertThrowsError(try store.save(SavedConversation(title: "超出", createdAt: Date(), turns: turns), consent: true))
        XCTAssertEqual(try store.load().count, 30)
    }

    func testTextPacketsRejectExpiredOversizedAndMixedPayloads() throws {
        var conversation = ConversationSession(); conversation.addDemonstration()
        let now = Date()
        var packet = SharedTextPacket(session: UUID(), revision: 0, kind: .snapshot, sentAt: now, turns: conversation.turns.map(SavedConversationTurn.init))
        XCTAssertEqual(try SharedTextCodec.decode(SharedTextCodec.encode(packet), now: now), packet)
        XCTAssertThrowsError(try SharedTextCodec.decode(SharedTextCodec.encode(packet), now: now.addingTimeInterval(121)))
        XCTAssertThrowsError(try SharedTextCodec.decode(Data(repeating: 65, count: 65_537), now: now))
        packet.kind = .acknowledgement; XCTAssertThrowsError(try SharedTextCodec.encode(packet))
        packet.kind = .snapshot; packet.version = 2; XCTAssertThrowsError(try SharedTextCodec.encode(packet))
        packet.version = 1; packet.turns.append(packet.turns[0]); XCTAssertThrowsError(try SharedTextCodec.encode(packet))
        packet.turns = []; packet.revision = -1; XCTAssertThrowsError(try SharedTextCodec.encode(packet))
    }

    func testTextCursorRejectsReplaysAndOldRooms() {
        let room = UUID(); var cursor = SharedTextCursor(); cursor.begin(room)
        var packet = SharedTextPacket(session: room, revision: 1, kind: .snapshot)
        XCTAssertTrue(cursor.accept(packet)); XCTAssertFalse(cursor.accept(packet))
        packet.revision = 0; XCTAssertFalse(cursor.accept(packet))
        packet.revision = 2; packet.kind = .acknowledgement; XCTAssertFalse(cursor.accept(packet))
        packet.kind = .snapshot; packet.session = UUID(); XCTAssertFalse(cursor.accept(packet))
        packet.session = room; XCTAssertTrue(cursor.accept(packet))
        cursor.clear(); XCTAssertFalse(cursor.accept(packet))
    }

    func testInvitationRequiresCurrentRoomAndSixASCIIDigits() {
        let id = UUID(); let invite = ShareInvitation(session: id, code: "012345")
        XCTAssertTrue(invite.matches(session: id, code: "012345"))
        XCTAssertFalse(invite.matches(session: UUID(), code: "012345"))
        XCTAssertFalse(invite.matches(session: id, code: "123456"))
        XCTAssertFalse(ShareInvitation(session: id, code: "１２３４５６").matches(session: id, code: "１２３４５６"))
        XCTAssertFalse(ShareInvitation(version: 2, session: id, code: "012345").matches(session: id, code: "012345"))
    }

    func testWatchQuickRepliesUseSeparateVersionAndCannotConfirmEvents() throws {
        let id = UUID(); let now = Date()
        let packet = WatchPacket.response(.quickReply, to: id, at: now, quickReply: .wait)
        let decoded = try PacketCodec.decode(PacketCodec.encode(packet), now: now)
        XCTAssertEqual(decoded.version, 2); XCTAssertEqual(decoded.quickReply, .wait)
        XCTAssertNil(decoded.isConfirmed); XCTAssertNil(decoded.event)
        var bad = packet; bad.version = 1
        XCTAssertThrowsError(try PacketCodec.decode(PacketCodec.encode(bad), now: now))
        bad = packet; bad.kind = .confirmation
        XCTAssertThrowsError(try PacketCodec.decode(PacketCodec.encode(bad), now: now))
        bad = packet; bad.isConfirmed = true
        XCTAssertThrowsError(try PacketCodec.decode(PacketCodec.encode(bad), now: now))
        let legacy = try PacketCodec.decode(PacketCodec.encode(.response(.receipt, to: id, at: now)), now: now)
        XCTAssertEqual(legacy.version, 1); XCTAssertNil(legacy.quickReply)
        var tracker = DeliveryTracker(); let token = try XCTUnwrap(tracker.begin(id, message: "回应"))
        XCTAssertTrue(tracker.finish(id, token: token, phase: .received, message: "手机已接收回应"))
        XCTAssertEqual(tracker.records[id]?.phase, .received)
        XCTAssertNotNil(tracker.begin(id, message: "主动确认"))
        tracker.confirm(id, message: "已确认"); XCTAssertNil(tracker.begin(id, message: "再次回应"))
    }
}
