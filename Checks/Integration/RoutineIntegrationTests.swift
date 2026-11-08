import Foundation
import XCTest
@testable import SeeSoundData

final class RoutineIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeeSoundRoutine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func card(reviewed: Bool = true) -> InformationCard {
        var card = InformationCard(); card.kind = .place; card.value = "图书馆二楼"; card.origin = .demonstration; card.createdAt = now; card.markReviewed(reviewed); return card
    }
    private func item(_ title: String, due: Date? = nil) -> RoutineItem { var item = RoutineItem(); item.title = title; item.createdAt = now; item.dueAt = due; return item }

    func testTemplatesAreIndependentAndDoNotEnableSensorsOrNotificationRules() throws {
        XCTAssertEqual(SceneTemplate.allCases.count, 4)
        for template in SceneTemplate.allCases {
            let first = template.makeProfile(), second = template.makeProfile()
            try first.validate(); XCTAssertNotEqual(first.id, second.id)
            XCTAssertTrue(first.reminderRules.values.allSatisfy { !$0.notifications && !$0.haptic })
            var prefs = AppPreferences(); try prefs.saveProfile(first); try prefs.applyProfile(first.id)
            XCTAssertTrue(first.matches(prefs))
        }
        XCTAssertEqual(SceneTemplate.library.makeProfile().sounds, [.doorbell])
        XCTAssertEqual(SceneTemplate.library.makeProfile().sensitivity, .cautious)
    }
    func testLegacyInformationCardWithoutPinStillDecodes() throws {
        let original = card()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]); object["pinned"] = nil
        let decoded = try JSONDecoder().decode(InformationCard.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.isPinned); XCTAssertTrue(decoded.reviewed); XCTAssertEqual(decoded.revision, 1)
    }
    @MainActor func testPinningPreservesReviewAndNeverImplicitlySavesAnEphemeralCard() throws {
        let store = InformationCardStore(directory: try folder()); let service = InformationCardService(store: store); let c = card()
        try service.put(c, saveLocally: false); try service.togglePin(c.id)
        XCTAssertTrue(try XCTUnwrap(service.cards.first).isPinned); XCTAssertTrue(try XCTUnwrap(service.cards.first).reviewed)
        XCTAssertTrue(try store.load().isEmpty)
        try service.put(try XCTUnwrap(service.cards.first), saveLocally: true); try service.togglePin(c.id)
        XCTAssertFalse(try XCTUnwrap(store.load().first).isPinned); XCTAssertTrue(try XCTUnwrap(store.load().first).reviewed)
    }
    func testCardSearchCombinesKindReviewAndPinnedSelection() {
        var a = card(); a.pinned = true
        var b = card(reviewed: false); b.kind = .amount; b.value = "28.50"; b.note = "窗口费用"
        XCTAssertEqual(InformationCard.select([b,a], query: " 图书馆 ", kind: .place, selection: .pinned).map(\.id), [a.id])
        XCTAssertEqual(InformationCard.select([a,b], query: "窗口", kind: .amount, selection: .unreviewed).map(\.id), [b.id])
        XCTAssertTrue(InformationCard.select([a,b], query: "窗口", kind: .phone, selection: .all).isEmpty)
        XCTAssertEqual(InformationCard.select([b,a], query: "", kind: nil, selection: .all).first?.id, a.id)
    }
    func testRoutineRequiresUserReviewedCardAndKeepsDemoOrigin() throws {
        XCTAssertThrowsError(try RoutineItem(card: card(reviewed: false)))
        var c = card(); c.kind = .time; c.dateValue = now.addingTimeInterval(1800)
        let task = try RoutineItem(card: c); try task.validate()
        XCTAssertEqual(task.dueAt, c.dateValue); XCTAssertEqual(task.sourceCardID, c.id); XCTAssertEqual(task.sourceRevision, c.revision)
        XCTAssertTrue(task.isDemonstration); XCTAssertFalse(task.completed); XCTAssertTrue(task.exportText.contains("演示待办"))
    }
    func testEditingCannotReplaceOriginSourceIdentityOrCompletion() throws {
        let original = try RoutineItem(card: card()); var draft = original
        draft.id = UUID(); draft.origin = .typed; draft.sourceCardID = nil; draft.sourceRevision = nil; draft.sourceSnapshot = "假的来源"; draft.completedAt = now
        let kept = draft.preservingSource(from: original)
        XCTAssertEqual(kept.id, original.id); XCTAssertEqual(kept.origin, .demonstration); XCTAssertEqual(kept.sourceSnapshot, original.sourceSnapshot); XCTAssertNil(kept.completedAt)
    }
    func testChangedUnreviewedAndMissingSourceHaveDistinctWarnings() throws {
        var c = card(); let task = try RoutineItem(card: c)
        XCTAssertNil(task.sourceWarning(cards: [c])); XCTAssertNotNil(task.sourceWarning(cards: []))
        c.markReviewed(false); XCTAssertNotNil(task.sourceWarning(cards: [c])); c.markReviewed(true)
        var draft = c; draft.value = "三楼"; c = try c.replacing(with: draft)
        XCTAssertNotNil(task.sourceWarning(cards: [c])); XCTAssertFalse(c.reviewed)
    }
    func testRefreshingUsesReviewedLatestVersionAndRebuildsTitleAndDueDate() throws {
        var c = card(); var task = try RoutineItem(card: c); task.note = "保留备注"
        var draft = c; draft.kind = .time; draft.dateValue = now.addingTimeInterval(3600); c = try c.replacing(with: draft)
        XCTAssertThrowsError(try task.refreshSource(c)); c.markReviewed(true); try task.refreshSource(c)
        XCTAssertEqual(task.dueAt, c.dateValue); XCTAssertEqual(task.sourceRevision, 2); XCTAssertEqual(task.note, "保留备注")
        XCTAssertTrue(task.title.contains(c.displayValue)); XCTAssertNil(task.sourceWarning(cards: [c]))
        draft = c; draft.kind = .place; draft.value = "新地点"; c = try c.replacing(with: draft); c.markReviewed(true)
        try task.refreshSource(c); XCTAssertNil(task.dueAt); XCTAssertTrue(task.title.contains("新地点"))
    }
    func testRoutineStoreRequiresConsentAndNeverOverwritesCorruptFile() throws {
        let store = RoutineStore(directory: try folder()); let task = item("借书")
        XCTAssertThrowsError(try store.save([task], consent: false)); XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        try store.save([task], consent: true); XCTAssertEqual(try store.load(), [task])
        let broken = Data("broken".utf8); try broken.write(to: store.url)
        XCTAssertThrowsError(try store.save([], consent: true)); XCTAssertEqual(try Data(contentsOf: store.url), broken)
        try store.reset(); XCTAssertTrue(try store.load().isEmpty)
    }
    @MainActor func testRoutineCompleteReopenPersistenceAndUnsave() throws {
        let store = RoutineStore(directory: try folder()); let service = RoutineService(store: store)
        var task = item("整理资料"); try service.put(task, saveLocally: true)
        try service.complete(task.id, completed: true, now: now.addingTimeInterval(10)); XCTAssertTrue(try XCTUnwrap(store.load().first).completed)
        try service.complete(task.id, completed: false); XCTAssertFalse(try XCTUnwrap(store.load().first).completed)
        task.title = "整理新资料"; try service.put(task, saveLocally: false)
        XCTAssertTrue(try store.load().isEmpty); XCTAssertEqual(service.items.first?.title, "整理新资料")
    }
    @MainActor func testDuplicatePendingSourceIsRejectedButNewVersionAndCompletedOriginalAreAllowed() throws {
        let service = RoutineService(store: RoutineStore(directory: try folder())); var c = card()
        let first = try RoutineItem(card: c); try service.put(first, saveLocally: false)
        XCTAssertThrowsError(try service.put(RoutineItem(card: c), saveLocally: false))
        try service.complete(first.id, completed: true); try service.put(RoutineItem(card: c), saveLocally: false)
        var draft = c; draft.value = "三楼"; c = try c.replacing(with: draft); c.markReviewed(true)
        try service.put(RoutineItem(card: c), saveLocally: false); XCTAssertEqual(service.items.count, 3)
    }
    @MainActor func testCapacityAllowsEditsAndDemoCleanupKeepsExplicitSaves() throws {
        let service = RoutineService(store: RoutineStore(directory: try folder()))
        for index in 0..<80 { try service.put(item("待办\(index)"), saveLocally: false) }
        XCTAssertThrowsError(try service.put(item("更多"), saveLocally: false))
        var existing = try XCTUnwrap(service.items.first); existing.title = "修改已有"; try service.put(existing, saveLocally: false)
        try service.reset()
        var a = item("未保存演示"), b = item("保存演示"); a.origin = .demonstration; b.origin = .demonstration
        try service.put(a, saveLocally: false); try service.put(b, saveLocally: true); service.discardUnsavedDemonstrations()
        XCTAssertEqual(service.items.map(\.id), [b.id])
    }
    func testFiltersRespectDueBoundaryCalendarAndDemoExclusion() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let due = item("恰好到期", due: now); var demo = item("演示待办", due: now); demo.origin = .demonstration
        var done = item("已完成", due: now.addingTimeInterval(-100)); done.completedAt = now.addingTimeInterval(1)
        let later = item("明天", due: now.addingTimeInterval(86400))
        XCTAssertEqual(RoutineItem.select([due,demo,done,later], query: "", filter: .overdue, includeDemonstrations: false, now: now).map(\.id), [due.id])
        XCTAssertEqual(RoutineItem.select([due,demo,done,later], query: "", filter: .today, includeDemonstrations: false, now: now, calendar: calendar).map(\.id), [due.id])
        XCTAssertTrue(RoutineItem.select([due], query: "不存在", filter: .all, includeDemonstrations: true, now: now).isEmpty)
        XCTAssertTrue(TimelinePeriod.day.includes(now.addingTimeInterval(-86400), now: now)); XCTAssertFalse(TimelinePeriod.day.includes(now.addingTimeInterval(-86401), now: now))
        XCTAssertFalse(TimelinePeriod.week.includes(now.addingTimeInterval(1), now: now))
    }
    func testNewDemosProduceOnlyUnreviewedMarkedSamples() throws {
        for scenario in [DemoScenario.appointment, .counter, .journey] {
            let cards = scenario.informationCards(at: now); XCTAssertEqual(cards.count, 2)
            for card in cards { try card.validate(); XCTAssertFalse(card.reviewed); XCTAssertEqual(card.origin, .demonstration); XCTAssertTrue(card.sourceQuote.contains("演示")) }
        }
        XCTAssertTrue(DemoScenario.visitor.informationCards().isEmpty)
    }
}
