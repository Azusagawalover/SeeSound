import Foundation
import XCTest
@testable import SeeSoundData

final class AssistanceIntegrationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeeSoundAssistance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func event(_ category: String, at seconds: Double, source: EventSource = .sound) -> SenseEvent {
        SenseEvent(category: category, title: category, source: source, at: Date(timeIntervalSince1970: 1_750_000_000 + seconds))
    }
    private func card() -> InformationCard { var c = InformationCard(); c.kind = .place; c.value = "图书馆二楼"; return c }

    func testLegacyPreferencesAndJournalDecodeWithoutNewFields() throws {
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(prefs.profiles.isEmpty); XCTAssertNil(prefs.activeProfileID); XCTAssertEqual(prefs.associationWindow, 5)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(JournalArchive(events: [], annotations: [:]))) as? [String: Any])
        object["suppressedLinks"] = nil
        let archive = try JSONDecoder().decode(JournalArchive.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(archive.suppressedLinks.isEmpty)
    }
    func testProfileApplyDeleteAndTemporaryChanges() throws {
        var prefs = AppPreferences(); var profile = SceneProfile(title: "图书馆", preferences: prefs)
        profile.sounds = [.doorbell]; profile.sensitivity = .responsive
        profile.reminderRules["doorbell"] = ReminderRule(visual: true, haptic: true)
        profile.responses["doorbell"] = ["请稍等，我马上来。"]
        try prefs.saveProfile(profile); try prefs.applyProfile(profile.id)
        XCTAssertEqual(prefs.sounds, [.doorbell]); XCTAssertTrue(profile.matches(prefs))
        prefs.sounds.insert(.knock); XCTAssertFalse(profile.matches(prefs)); XCTAssertTrue(prefs.sceneTitle.contains("临时调整"))
        prefs.deleteProfile(profile.id); XCTAssertNil(prefs.activeProfileID); XCTAssertTrue(prefs.sounds.contains(.knock))
    }
    func testProfilesRejectDuplicateNamesCapacityAndBadResponses() throws {
        var prefs = AppPreferences()
        for i in 0..<12 { try prefs.saveProfile(SceneProfile(title: "场景\(i)", preferences: prefs)) }
        XCTAssertThrowsError(try prefs.saveProfile(SceneProfile(title: "更多", preferences: prefs)))
        var duplicate = prefs.profiles[1]; duplicate.title = prefs.profiles[0].title
        XCTAssertThrowsError(try prefs.saveProfile(duplicate))
        var invalid = prefs.profiles[0]; invalid.responses["wave"] = Array(repeating: "x", count: 5)
        XCTAssertThrowsError(try invalid.validate())
        invalid = prefs.profiles[0]; invalid.reminderRules["unknown"] = ReminderRule()
        XCTAssertThrowsError(try invalid.validate())
    }
    func testProfilePreferencesRoundTripAndBadSelectionRejected() throws {
        var prefs = AppPreferences(); let p = SceneProfile(title: "宿舍", preferences: prefs)
        try prefs.saveProfile(p); try prefs.applyProfile(p.id)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs)), prefs)
        prefs.activeProfileID = UUID()
        XCTAssertThrowsError(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs)))
    }
    func testInformationValidationForAllFourKinds() throws {
        var c = card(); try c.validate(); c.value = "  "; XCTAssertThrowsError(try c.validate())
        c.kind = .phone
        for value in ["+86 138-0000-0000", "(010) 12345678", "123"] { c.value = value; XCTAssertNoThrow(try c.validate()) }
        for value in ["12", "+86+123", "123call", "123+456", String(repeating: "1", count: 21)] { c.value = value; XCTAssertThrowsError(try c.validate()) }
        c.kind = .amount
        for value in ["0", "28.50", "999999999999.99"] { c.value = value; XCTAssertNoThrow(try c.validate()) }
        for value in ["-1", "01", "NaN", "1.234", "1e4", "100元", "1,000"] { c.value = value; XCTAssertThrowsError(try c.validate()) }
        c.kind = .time; c.value = ""; try c.validate()
        c.dateValue = Date(timeIntervalSince1970: .infinity); XCTAssertThrowsError(try c.validate())
    }
    func testEditingInvalidatesReviewAndCannotRemoveDemoSource() throws {
        var original = card(); original.origin = .demonstration; original.sourceQuote = "演示原文"; original.markReviewed(true)
        let same = try original.replacing(with: original); XCTAssertTrue(same.reviewed)
        var draft = original; draft.value = "三楼"; draft.origin = .typed; draft.sourceQuote = "伪造来源"
        var updated = try original.replacing(with: draft)
        XCTAssertFalse(updated.reviewed); XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.origin, .demonstration); XCTAssertEqual(updated.sourceQuote, "演示原文")
        updated.markReviewed(true); XCTAssertTrue(updated.reviewed)
        XCTAssertTrue(updated.exportText.contains("演示")); XCTAssertTrue(updated.exportText.contains("用户标记"))
    }
    func testIndependentStoreRequiresConsentAndPreservesCorruptFile() throws {
        let store = InformationCardStore(directory: try directory()); let c = card()
        XCTAssertThrowsError(try store.save([c], consent: false)); XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        try store.save([c], consent: true); XCTAssertEqual(try store.load(), [c])
        let corrupt = Data("broken-json".utf8); try corrupt.write(to: store.url)
        XCTAssertThrowsError(try store.save([], consent: true)); XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
        try store.reset(); XCTAssertEqual(try store.load(), [])
    }
    @MainActor func testInformationServiceSavingEditingReviewAndUnsave() throws {
        let store = InformationCardStore(directory: try directory()); let service = InformationCardService(store: store)
        var c = card(); try service.put(c, saveLocally: false); XCTAssertEqual(try store.load(), [])
        try service.put(c, saveLocally: true); XCTAssertEqual(try store.load().count, 1)
        try service.review(c.id, reviewed: true); XCTAssertTrue(try XCTUnwrap(store.load().first).reviewed)
        c.value = "四楼"; try service.put(c, saveLocally: true)
        XCTAssertFalse(try XCTUnwrap(store.load().first).reviewed); XCTAssertEqual(service.cards.first?.revision, 2)
        try service.put(try XCTUnwrap(service.cards.first), saveLocally: false); XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(service.cards.count, 1); try service.remove(c.id); XCTAssertTrue(service.cards.isEmpty)
    }
    @MainActor func testDemoCleanupPreservesOnlyExplicitlySavedCards() throws {
        let store = InformationCardStore(directory: try directory()); let service = InformationCardService(store: store)
        var demo = card(); demo.origin = .demonstration; try service.put(demo, saveLocally: false)
        var saved = card(); saved.origin = .demonstration; try service.put(saved, saveLocally: true)
        let real = card(); try service.put(real, saveLocally: false)
        service.discardUnsavedDemonstrations()
        XCTAssertEqual(Set(service.cards.map(\.id)), Set([saved.id, real.id]))
    }
    func testAssociationsUseTotalSpanAndNeverChainAcrossWindow() {
        let a = event("knock", at: 0), b = event("doorbell", at: 4), c = event("wave", at: 8, source: .gesture)
        let groups = EventAssociation.group([c, b, a], window: 5, suppressed: [])
        XCTAssertEqual(groups.count, 2); XCTAssertEqual(Set(groups.flatMap(\.events).map(\.id)), Set([a.id,b.id,c.id]))
        XCTAssertTrue(groups.allSatisfy { ($0.events.map(\.lastSeen).max()!).timeIntervalSince($0.events.map(\.lastSeen).min()!) <= 5 })
        XCTAssertEqual(EventAssociation.group([a,b,c], window: 10, suppressed: []).count, 1)
    }
    func testAssociationsSeparateDemoAndSameCategoryAndHonorSplitPairs() {
        let a = event("knock", at: 0), b = event("doorbell", at: 1), c = event("demo-wave", at: 1, source: .demonstration)
        XCTAssertEqual(EventAssociation.group([a,b,c], window: 5, suppressed: []).count, 2)
        XCTAssertEqual(EventAssociation.group([a,b], window: 5, suppressed: [EventPair(a.id,b.id)]).count, 2)
        let another = event("knock", at: 2)
        XCTAssertEqual(EventAssociation.group([a,another], window: 5, suppressed: []).count, 2)
        XCTAssertEqual(EventPair(a.id,b.id), EventPair(b.id,a.id)); XCTAssertFalse(EventPair(a.id,a.id).valid)
    }
    func testAssociationSplitsPersistTransactionallyAndPruneWithOriginals() throws {
        let a = event("knock", at: 0), b = event("doorbell", at: 1); let link = EventPair(a.id,b.id)
        let db = try DatabaseJournal(url: try directory().appendingPathComponent("events.sqlite"))
        let archive = JournalArchive(events: [a,b], annotations: [:], suppressedLinks: [link])
        try db.save(archive); XCTAssertEqual(try db.load().suppressedLinks, [link])
        let pruned = try archive.validated(since: b.lastSeen, now: b.lastSeen); XCTAssertTrue(pruned.suppressedLinks.isEmpty)
        XCTAssertThrowsError(try db.save(JournalArchive(events: [a], annotations: [:], suppressedLinks: [link])))
        XCTAssertEqual(try db.load().events.count, 2); try db.close()
    }
    func testResponsePreservesEventContextAndDoesNotConfirmEvent() throws {
        let e = event("demo-doorbell", at: 0, source: .demonstration); let context = EventResponseContext(e)
        var conversation = ConversationSession()
        XCTAssertTrue(conversation.reply("我马上来", origin: context.demonstration ? .demonstration : .typed, replyEventTitle: context.title))
        let saved = SavedConversationTurn(try XCTUnwrap(conversation.turns.first))
        XCTAssertEqual(saved.origin, .demonstration); XCTAssertEqual(saved.replyEventTitle, e.title); XCTAssertEqual(e.status, .pending)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]); object["replyEventTitle"] = nil
        XCTAssertNil(try JSONDecoder().decode(SavedConversationTurn.self, from: JSONSerialization.data(withJSONObject: object)).replyEventTitle)
    }
}
