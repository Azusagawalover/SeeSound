import Foundation

#if SWIFT_PACKAGE
@testable import SeeSoundData
#endif

#if !SWIFT_PACKAGE
@main
#endif
struct WatchLinkChecks {
    static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        guard condition() else { fatalError("Check failed: \(label)") }
    }

    static func main() throws {
        var tracker = DeliveryTracker()
        let id = UUID()
        let first = tracker.begin(id, message: "sending")!
        expect(tracker.records[id]?.phase == .sending, "send starts pending")
        expect(tracker.begin(id, message: "duplicate") == nil, "double tap blocked")
        expect(!tracker.finish(id, token: UUID(), phase: .received, message: "wrong attempt"), "unknown attempt cannot acknowledge")
        expect(tracker.finish(id, token: first, phase: .failed, message: "timeout"), "timeout terminates pending state")
        let retry = tracker.begin(id, message: "retry")!
        expect(retry != first, "retry has new identity")
        expect(!tracker.finish(id, token: first, phase: .received, message: "late reply"), "old reply cannot overwrite retry")
        expect(!tracker.finish(id, token: first, phase: .failed, message: "late failure"), "old error cannot overwrite retry")
        expect(tracker.finish(id, token: retry, phase: .received, message: "delivered"), "retry receives acknowledgement")
        expect(!tracker.finish(id, token: retry, phase: .failed, message: "late timeout"), "timeout cannot undo delivery")
        let confirmation = tracker.begin(id, message: "confirming")!
        expect(tracker.finish(id, token: confirmation, phase: .confirmed, message: "confirmed"), "confirmation can follow delivery")
        expect(tracker.begin(id, message: "repeat") == nil, "confirmed event is terminal")
        expect(!tracker.finish(id, token: retry, phase: .received, message: "late ack"), "old receipt cannot undo confirmation")

        let race = UUID()
        let token = tracker.begin(race, message: "sending")!
        tracker.confirm(race, message: "human confirmed before receipt")
        expect(!tracker.finish(race, token: token, phase: .received, message: "receipt"), "human confirmation wins receipt race")
        expect(!tracker.finish(race, token: token, phase: .failed, message: "timeout"), "human confirmation wins timeout race")
        expect(tracker.records[race]?.message == "human confirmed before receipt", "confirmation explanation retained")
        let unrelated = UUID()
        let unrelatedToken = tracker.begin(unrelated, message: "unrelated")!
        expect(!tracker.finish(race, token: unrelatedToken, phase: .failed, message: "wrong event"), "tokens bound to event IDs")
        expect(tracker.finish(unrelated, token: unrelatedToken, phase: .failed, message: "failed"), "one event failure remains independent")
        expect(tracker.records[race]?.phase == .confirmed, "other event cannot undo confirmation")
        for _ in 0..<150 { _ = tracker.begin(UUID(), message: "bounded") }
        expect(tracker.records.count == 100, "transfer history bounded")

        let now = Date()
        let event = SenseEvent(category: "watch-test", title: "通信测试", source: .demonstration, at: now)
        let receipt = WatchPacket.response(.receipt, to: event.id, at: now, isConfirmed: true)
        let decoded = try PacketCodec.decode(PacketCodec.encode(receipt), now: now)
        expect(decoded.isConfirmed == true, "receipt can restore a lost confirmation")
        expect(decoded.reference == event.id, "confirmed receipt remains event-bound")
        var invalid = WatchPacket.event(event, at: now)
        invalid.isConfirmed = true
        do { _ = try PacketCodec.decode(PacketCodec.encode(invalid), now: now); expect(false, "event carries reply state") }
        catch { expect(true, "events cannot invent confirmed receipt state") }
        invalid = WatchPacket.response(.confirmation, to: event.id, at: now, isConfirmed: true)
        do { _ = try PacketCodec.decode(PacketCodec.encode(invalid), now: now); expect(false, "confirmation carries reply state") }
        catch { expect(true, "only receipts can carry confirmed flag") }
        let legacy = WatchPacket.response(.receipt, to: event.id, at: now)
        let legacyDecoded = try PacketCodec.decode(PacketCodec.encode(legacy), now: now)
        expect(legacyDecoded.isConfirmed == nil, "old receipt remains compatible")
        let eventDecoded = try PacketCodec.decode(PacketCodec.encode(.event(event, at: now)), now: now)
        expect(eventDecoded.event?.isDemonstration == true, "demo survives transfer")
        print("PASS: \(count) Watch transfer state checks. Network delivery and haptics require separate checks.")
    }
}
