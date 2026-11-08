import Foundation

#if SWIFT_PACKAGE
@testable import SeeSoundData
#endif

#if !SWIFT_PACKAGE
@main
#endif
struct CoreChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard condition() else { fatalError("Check failed: \(label)") }
    }

    static func rejects(_ packet: WatchPacket, now: Date) -> Bool {
        do { _ = try PacketCodec.decode(PacketCodec.encode(packet), now: now); return false }
        catch { return true }
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        var ledger = EventLedger()
        let first = ledger.register(category: "knock", title: "敲门", source: .sound, at: now)
        let merged = ledger.register(category: "knock", title: "敲门", source: .sound, at: now.addingTimeInterval(2))
        expect(first.id == merged.id, "same event merged")
        expect(merged.count == 2, "window count updated")
        expect(ledger.events.count == 1, "no duplicate row")
        expect(ledger.confirm(first.id), "existing event confirmed")
        expect(!ledger.confirm(UUID()), "unknown confirmation rejected")
        let next = ledger.register(category: "knock", title: "敲门", source: .sound, at: now.addingTimeInterval(3))
        expect(next.id != first.id, "confirmed event is not reopened")
        let demo = ledger.register(category: "knock", title: "演示", source: .demonstration, at: now.addingTimeInterval(3))
        expect(demo.id != next.id && demo.isDemonstration, "simulation isolated")
        let later = ledger.register(category: "knock", title: "敲门", source: .sound, at: now.addingTimeInterval(10))
        expect(later.id != next.id, "outside merge window")
        let reverse = ledger.register(category: "knock", title: "敲门", source: .sound, at: now.addingTimeInterval(-1))
        expect(reverse.id != later.id, "clock reversal is not merged")
        for i in 0..<80 {
            ledger.register(category: "category-\(i)", title: "测试", source: .sound, at: now)
        }
        expect(ledger.events.count == 40, "bounded memory journal")
        let encodedLedger = try JSONEncoder().encode(ledger)
        let decodedLedger = try JSONDecoder().decode(EventLedger.self, from: encodedLedger)
        expect(decodedLedger.events == ledger.events, "journal round trip")
        ledger.clear()
        expect(ledger.events.isEmpty, "clear all session events")

        let event = SenseEvent(category: "test", title: "通信测试", source: .demonstration, at: now)
        let packet = WatchPacket.event(event, at: now)
        let roundTrip = try PacketCodec.decode(PacketCodec.encode(packet), now: now)
        expect(roundTrip.event == event, "event packet round trip")
        expect(roundTrip.event!.isDemonstration, "demo marker crosses transport")
        for kind in [PacketKind.receipt, .confirmation] {
            let response = WatchPacket.response(kind, to: event.id, at: now)
            let result = try PacketCodec.decode(PacketCodec.encode(response), now: now)
            expect(result.kind == kind && result.reference == event.id, "response round trip")
        }
        var invalid = packet
        invalid.version = 2
        expect(rejects(invalid, now: now), "unsupported schema")
        invalid = packet; invalid.reference = UUID()
        expect(rejects(invalid, now: now), "mismatched ID")
        invalid = packet; invalid.event = nil
        expect(rejects(invalid, now: now), "missing event")
        invalid = packet; invalid.sentAt = now.addingTimeInterval(-301)
        expect(rejects(invalid, now: now), "expired packet")
        invalid = packet; invalid.sentAt = now.addingTimeInterval(61)
        expect(rejects(invalid, now: now), "future packet")
        invalid = packet; invalid.event!.title = ""
        expect(rejects(invalid, now: now), "empty title")
        invalid = packet; invalid.event!.title = String(repeating: "字", count: 81)
        expect(rejects(invalid, now: now), "oversized title")
        invalid = packet; invalid.event!.category = ""
        expect(rejects(invalid, now: now), "empty category")
        invalid = packet; invalid.event!.count = 0
        expect(rejects(invalid, now: now), "zero windows")
        invalid = packet; invalid.event!.count = 10_001
        expect(rejects(invalid, now: now), "excessive windows")
        invalid = packet; invalid.event!.firstSeen = now.addingTimeInterval(1)
        expect(rejects(invalid, now: now), "reversed event timestamps")
        invalid = packet; invalid.event!.lastSeen = now.addingTimeInterval(61)
        expect(rejects(invalid, now: now), "future event")
        invalid = packet
        invalid.event!.firstSeen = now.addingTimeInterval(-302)
        invalid.event!.lastSeen = now.addingTimeInterval(-301)
        expect(rejects(invalid, now: now), "fresh packet cannot replay old event")
        invalid = packet; invalid.kind = .confirmation
        expect(rejects(invalid, now: now), "response cannot carry an event")
        do { _ = try PacketCodec.decode(Data(repeating: 0, count: 16_385), now: now); expect(false, "large packet") }
        catch { expect(true, "large packet rejected") }
        do { _ = try PacketCodec.decode(Data("not-json".utf8), now: now); expect(false, "malformed JSON") }
        catch { expect(true, "malformed JSON rejected") }
        let retained = try PacketCodec.decode(PacketCodec.encode(packet), now: now.addingTimeInterval(300))
        expect(retained.reference == event.id, "TTL boundary retained")

        var window = WaveWindow()
        var hits = 0
        for i in 0..<30 {
            if window.ingest(x: 0.5, palmWidth: 0.12, time: Double(i) * 0.1) { hits += 1 }
        }
        expect(hits == 0, "stationary palm is not waving")
        window.reset(); hits = 0
        for i in 0..<30 {
            let x = 0.5 + 0.005 * sin(Double(i) * 0.9)
            if window.ingest(x: x, palmWidth: 0.12, time: Double(i) * 0.1) { hits += 1 }
        }
        expect(hits == 0, "small jitter is not waving")
        window.reset(); hits = 0
        for i in 0..<30 {
            let x = 0.5 + 0.10 * sin(Double(i) * 0.7)
            if window.ingest(x: x, palmWidth: 0.12, time: Double(i) * 0.1) { hits += 1 }
        }
        expect(hits == 1, "synthetic wave and cooldown")
        expect(!window.ingest(x: .nan, palmWidth: 0.12, time: 4), "NaN rejected")
        expect(!window.ingest(x: 0.5, palmWidth: 0, time: 4.1), "invalid palm rejected")
        expect(!window.ingest(x: 2, palmWidth: 0.12, time: 4.2), "out of frame rejected")
        window.reset(); hits = 0
        for i in 0..<15 {
            if window.ingest(x: i % 2 == 0 ? 0.4 : 0.6, palmWidth: 0.12, time: Double(i)) { hits += 1 }
        }
        expect(hits == 0, "discontinuous frames reset evidence")
        print("PASS: \(checks) core checks. These do not validate camera, microphone, or real Watch delivery.")
    }
}
