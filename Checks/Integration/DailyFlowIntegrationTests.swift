import Foundation
import XCTest
@testable import SeeSoundData

final class DailyFlowIntegrationTests: XCTestCase {
    private func event(_ category: String = "knock", source: EventSource = .sound, at date: Date = Date()) -> SenseEvent {
        SenseEvent(category: category, title: "事件 \(category)", source: source, at: date)
    }
    func testNewRemindersNeverReplaceTheSelectedCard() {
        let now = Date(); var queue = ReminderQueue()
        let first = event(at: now), second = event("doorbell", at: now), third = event("clapping", at: now)
        queue.enqueue(first, priority: .normal, at: now)
        queue.enqueue(second, priority: .prominent, at: now)
        queue.enqueue(third, priority: .normal, at: now)
        XCTAssertEqual(queue.current(at: now)?.id, first.id)
        XCTAssertEqual(queue.entries.count, 3)
        queue.remove(first.id, at: now)
        XCTAssertEqual(queue.current(at: now)?.id, second.id)
        XCTAssertTrue(queue.entries.allSatisfy { $0.event.status == .pending })
    }
    func testQueueNextAndCollapseDoNotConfirmOrLoseEvents() {
        let now = Date(); var queue = ReminderQueue()
        let a = event(), b = event("doorbell")
        queue.enqueue(a, priority: .normal, at: now); queue.enqueue(b, priority: .normal, at: now)
        queue.next(at: now); XCTAssertEqual(queue.current(at: now)?.id, b.id)
        queue.next(at: now); XCTAssertEqual(queue.current(at: now)?.id, a.id)
        queue.collapse(); XCTAssertTrue(queue.isCollapsed)
        queue.enqueue(a, priority: .normal, at: now); XCTAssertTrue(queue.isCollapsed)
        queue.restore(at: now); XCTAssertFalse(queue.isCollapsed)
        XCTAssertEqual(queue.entries.count, 2); XCTAssertTrue(queue.entries.allSatisfy { $0.event.status == .pending })
    }
    func testMergedReminderUpdatesInPlaceAndRemovalSelectsNext() {
        var queue = ReminderQueue(); var a = event(); let b = event("doorbell")
        queue.enqueue(a, priority: .normal); queue.enqueue(b, priority: .normal)
        a.count = 4; a.lastSeen = Date(); queue.update(a)
        XCTAssertEqual(queue.entries.count, 2); XCTAssertEqual(queue.current()?.event.count, 4)
        queue.remove(a.id); XCTAssertEqual(queue.current()?.id, b.id)
        queue.remove(a.id); XCTAssertEqual(queue.entries.count, 1)
        queue.remove(b.id); XCTAssertNil(queue.current())
    }
    func testSnoozeReturnsExistingPendingReminderAfterFiveMinutes() {
        let now = Date(); var queue = ReminderQueue(); let a = event(at: now), b = event("doorbell", at: now)
        queue.enqueue(a, priority: .normal, at: now); queue.enqueue(b, priority: .normal, at: now)
        queue.snooze("knock", until: now.addingTimeInterval(300), at: now)
        XCTAssertEqual(queue.current(at: now)?.id, b.id); XCTAssertEqual(queue.entries.count, 2)
        queue.remove(b.id, at: now); XCTAssertNil(queue.current(at: now))
        queue.refresh(at: now.addingTimeInterval(299)); XCTAssertNil(queue.current(at: now.addingTimeInterval(299)))
        queue.refresh(at: now.addingTimeInterval(300))
        XCTAssertEqual(queue.current(at: now.addingTimeInterval(300))?.id, a.id)
        XCTAssertEqual(queue.current(at: now.addingTimeInterval(300))?.event.status, .pending)
    }
    func testDemoSnoozeCannotHideRealReminderOfSameCategory() {
        let now = Date(); var queue = ReminderQueue()
        let real = event(at: now), demo = event("demo-knock", source: .demonstration, at: now)
        queue.enqueue(real, priority: .normal, at: now); queue.enqueue(demo, priority: .normal, at: now)
        queue.snooze(ReminderQueue.categoryKey(for: demo), until: now.addingTimeInterval(300), at: now)
        XCTAssertEqual(queue.available(at: now).map(\.id), [real.id])
        queue.resume(ReminderQueue.categoryKey(for: demo), at: now); XCTAssertEqual(queue.available(at: now).count, 2)
        queue.snooze("knock", until: now.addingTimeInterval(300), at: now)
        XCTAssertEqual(queue.available(at: now).map(\.id), [demo.id])
    }
    func testQueueRetainsLiveIDsAndHasBoundedSpaceForScenarioEvents() {
        var queue = ReminderQueue()
        for _ in 0..<70 { queue.enqueue(event(), priority: .normal) }
        XCTAssertEqual(queue.entries.count, 48)
        let survivor = queue.entries[20].id
        queue.select(survivor); queue.retain([survivor])
        XCTAssertEqual(queue.current()?.id, survivor); XCTAssertEqual(queue.entries.count, 1)
        queue.retain([]); XCTAssertNil(queue.current())
        var confirmed = event(); confirmed.status = .confirmed; queue.enqueue(confirmed, priority: .normal)
        XCTAssertTrue(queue.entries.isEmpty)
    }
    func testChangingOneRuleDoesNotDropOtherQueuedEvents() {
        var queue = ReminderQueue(); let a = event(), b = event("doorbell")
        queue.enqueue(a, priority: .normal); queue.enqueue(b, priority: .normal)
        queue.setPriority(.prominent, category: "doorbell")
        XCTAssertEqual(queue.current()?.id, a.id)
        queue.removeCategory("knock")
        XCTAssertEqual(queue.current()?.id, b.id); XCTAssertEqual(queue.current()?.priority, .prominent)
    }
    func testScenarioTurnsAndTypedResponsesRetainDemonstrationOrigin() {
        for scenario in DemoScenario.allCases {
            var session = ConversationSession(); session.addScenario(scenario)
            XCTAssertFalse(session.turns.isEmpty)
            XCTAssertTrue(session.turns.allSatisfy { $0.origin == .demonstration && $0.text.hasPrefix("演示：") })
            XCTAssertTrue(session.reply(scenario.suggestedReply, origin: .demonstration))
            XCTAssertEqual(session.turns.last?.origin, .demonstration)
            XCTAssertEqual(session.turns.last?.speaker, .me)
            let original = session.turns.last!.origin
            XCTAssertTrue(session.edit(session.turns.last!.id, text: "改过的演示回应"))
            XCTAssertEqual(session.turns.last?.origin, original)
        }
    }
    func testScenarioSwitchingRestoresOriginalConversationAndInvalidatesOldCapture() throws {
        var original = ConversationSession(); XCTAssertTrue(original.reply("需要保留的原对话"))
        let capture = original.beginCapture(speakerName: "同学")
        XCTAssertTrue(original.receive("未完成的真实字幕", capture: capture, isFinal: false))
        let before = original.turns
        var backup = ConversationScenarioBackup()
        var first = backup.begin(.visitor, current: original)
        XCTAssertTrue(first.reply("演示回应", origin: .demonstration)); first.clear()
        let second = backup.begin(.conversation, current: first)
        XCTAssertTrue(second.turns.allSatisfy { $0.origin == .demonstration })
        var restored = try XCTUnwrap(backup.end())
        XCTAssertEqual(restored.turns.map(\.id), before.map(\.id))
        XCTAssertEqual(restored.turns.map(\.text), before.map(\.text))
        XCTAssertEqual(restored.turns.last?.state, .interrupted); XCTAssertNil(restored.activeCapture)
        XCTAssertFalse(restored.receive("迟到的真实字幕", capture: capture, isFinal: true))
        XCTAssertNil(backup.end())
    }
    func testTextRoundTripAndFrozenOldReadCannotConfirmNewVersion() throws {
        let room = UUID(); var source = ConversationSession(); source.addScenario(.conversation)
        var cursor = SharedTextCursor(); cursor.begin(room); var read = SharedReadState()
        let packet = SharedTextPacket(session: room, revision: 0, kind: .snapshot, turns: source.turns.map(SavedConversationTurn.init))
        let received = try SharedTextCodec.decode(SharedTextCodec.encode(packet))
        XCTAssertTrue(cursor.accept(received)); XCTAssertEqual(received.turns.map(\.text), source.turns.map(\.text))
        let frozenVersion = received.revision
        source.reply("我已了解", origin: .demonstration)
        let next = SharedTextPacket(session: room, revision: 1, kind: .snapshot, turns: source.turns.map(SavedConversationTurn.init))
        XCTAssertTrue(cursor.accept(try SharedTextCodec.decode(SharedTextCodec.encode(next))))
        let oldAck = SharedTextPacket(session: room, revision: frozenVersion, kind: .acknowledgement)
        XCTAssertTrue(read.accept(try SharedTextCodec.decode(SharedTextCodec.encode(oldAck)), currentRevision: 1, session: room))
        XCTAssertFalse(read.hasRead(1))
        let currentAck = SharedTextPacket(session: room, revision: 1, kind: .acknowledgement)
        XCTAssertTrue(read.accept(try SharedTextCodec.decode(SharedTextCodec.encode(currentAck)), currentRevision: 1, session: room))
        XCTAssertTrue(read.hasRead(1))
        XCTAssertTrue(read.accept(oldAck, currentRevision: 1, session: room)); XCTAssertTrue(read.hasRead(1))
        XCTAssertFalse(read.accept(currentAck, currentRevision: 1, session: UUID()))
        var invalid = currentAck; invalid.revision = 2
        XCTAssertFalse(read.accept(invalid, currentRevision: 1, session: room))
        cursor.clear(); read.clear(); XCTAssertFalse(cursor.accept(next)); XCTAssertFalse(read.hasRead(1))
    }
    func testWatchScenarioReplyDoesNotBecomeAConfirmation() throws {
        let now = Date(); var ledger = EventLedger()
        let event = ledger.register(category: "demo-doorbell", title: "演示：有人按门铃", source: .demonstration, at: now)
        let watchEvent = try PacketCodec.decode(PacketCodec.encode(.event(event, at: now)), now: now)
        XCTAssertEqual(watchEvent.event?.source, .demonstration)
        let reply = try PacketCodec.decode(PacketCodec.encode(.response(.quickReply, to: event.id, at: now, quickReply: .coming)), now: now)
        XCTAssertEqual(reply.quickReply, .coming); XCTAssertNil(reply.isConfirmed)
        let receipt = try PacketCodec.decode(PacketCodec.encode(.response(.receipt, to: event.id, at: now, quickReply: reply.quickReply)), now: now)
        XCTAssertEqual(receipt.kind, .receipt); XCTAssertEqual(ledger.events.first?.status, .pending)
        let confirmation = try PacketCodec.decode(PacketCodec.encode(.response(.confirmation, to: event.id, at: now)), now: now)
        XCTAssertEqual(confirmation.kind, .confirmation); XCTAssertTrue(ledger.confirm(confirmation.reference))
        XCTAssertEqual(ledger.events.first?.status, .confirmed)
    }
}
