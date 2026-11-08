import Foundation
import XCTest
@testable import SeeSoundData

final class ContinuityTests:XCTestCase {
    private func snapshot() -> LibrarySnapshot {
        var result = LibrarySnapshot()
        var card = InformationCard();card.kind = .place;card.value = "图书馆";card.markReviewed(true)
        var task = RoutineItem();task.title = "报名";task.reminderAt = Date().addingTimeInterval(3600)
        var item = WorkroomCase();item.title = "读书会";item.materials = [.init(title:"学生证")];item.links = [.init(id:card.id,kind:.card,snapshot:card.value,revision:card.revision),.init(id:task.id,kind:.routine,snapshot:task.title)]
        result.cards = [card];result.routines = [task];result.workroom.cases = [item];return result
    }
    func testEncryptedRoundTripRejectsWrongPasswordTamperAndOversizedInput() throws {
        let package = LibraryPackage(snapshot:snapshot())
        let data = try LibraryCryptography.seal(package,password:"local-test-pass")
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("图书馆"))
        if let directory = ProcessInfo.processInfo.environment["SEESOUND_UI_FIXTURES"] {
            var demo = snapshot();demo.cards[0].origin = .demonstration;demo.routines[0].origin = .demonstration
            demo.workroom.cases[0].demonstration = true;demo.workroom.cases[0].title = "演示 · 接力读书会"
            for i in demo.workroom.cases[0].links.indices { demo.workroom.cases[0].links[i].demonstration = true }
            let url = URL(fileURLWithPath:directory).appendingPathComponent("Validation.seesoundbackup")
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try LibraryCryptography.seal(.init(purpose:"handoff",snapshot:demo),password:"SeeSound-UI-16").write(to:url,options:.atomic)
        }
        let decoded = try LibraryCryptography.open(data,password:"local-test-pass")
        XCTAssertEqual(decoded.snapshot.workroom.cases.first?.id,package.snapshot.workroom.cases.first?.id)
        XCTAssertThrowsError(try LibraryCryptography.open(data,password:"wrong-pass"))
        XCTAssertThrowsError(try LibraryCryptography.seal(package,password:"short"))
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);envelope["iterations"] = 1
        XCTAssertThrowsError(try LibraryCryptography.open(JSONSerialization.data(withJSONObject:envelope),password:"local-test-pass"))
    }
    func testActualCiphertextTamperAndFutureEnvelopeVersionAreRejected() throws {
        let data = try LibraryCryptography.seal(.init(snapshot:snapshot()),password:"test-password")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        var cipher = try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(json["sealed"] as? String)))
        cipher[cipher.count-1] ^= 1;json["sealed"] = cipher.base64EncodedString()
        XCTAssertThrowsError(try LibraryCryptography.open(JSONSerialization.data(withJSONObject:json),password:"test-password"))
        json["version"] = 2
        XCTAssertThrowsError(try LibraryCryptography.open(JSONSerialization.data(withJSONObject:json),password:"test-password"))
    }
    func testCrashJournalRecoversBeforeNextLibraryRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let repo = LibraryRepository(base:directory),before = try repo.read()
        struct Pending:Encodable { var version = 1;var before:LibrarySnapshot }
        try LibraryRepository.protectedWrite(JSONEncoder().encode(Pending(before:before)),to:directory.appendingPathComponent("SeeSoundRecovery/pending.json"))
        try WorkroomStore(directory:directory.appendingPathComponent("SeeSoundWorkroom")).save(snapshot().workroom)
        XCTAssertTrue(try repo.recover());XCTAssertTrue(try repo.read().workroom.cases.isEmpty)
    }
    func testMergeRejectsProvenanceChangesAndCapacityOverflow() throws {
        let local = snapshot();var incoming = local;incoming.cards[0].origin = .demonstration
        XCTAssertThrowsError(try LibraryMerge.preview(local:local,package:.init(snapshot:incoming),options:.init()))
        incoming = local;incoming.workroom.cases = (0..<100).map { i in var item = WorkroomCase();item.title = "事务\(i)";return item }
        XCTAssertThrowsError(try LibraryMerge.preview(local:local,package:.init(snapshot:incoming),options:.init()))
    }
    func testReminderOverviewDoesNotGuessDeliveryAndPrioritizesInactiveState() {
        var task = RoutineItem();task.title = "提醒检查";task.reminderAt = Date().addingTimeInterval(-60)
        let id = ScheduledNotice(destination:.init(kind:.routine,recordID:task.id),date:task.reminderAt!).id
        func row(_ task:RoutineItem,_ delivered:Set<String> = []) -> AgendaEntry? {
            AgendaOverview.rows(routines:[task],savedRoutineIDs:[task.id],cases:[],savedCaseIDs:[],scheduled:[],delivered:delivered,failed:[],authorization:.allowed,now:.now).first
        }
        XCTAssertEqual(row(task)?.state,.elapsed);XCTAssertEqual(row(task,[id])?.state,.delivered)
        task.completedAt = .now;XCTAssertEqual(row(task,[id])?.state,.inactive)
        task.completedAt = nil;task.reminderAt = Date().addingTimeInterval(300)
        let blocked = AgendaOverview.rows(routines:[task],savedRoutineIDs:[task.id],cases:[],savedCaseIDs:[],scheduled:[],delivered:[],failed:[],authorization:.denied,now:.now)
        XCTAssertEqual(blocked.first?.state,.permission)
    }
    func testHandoffContainsOnlySelectedCaseAndReferencedRecords() throws {
        var all = snapshot();var extra = WorkroomCase();extra.title = "私有的其他事务";all.workroom.cases.append(extra)
        var card = InformationCard();card.kind = .place;card.value = "别处";all.cards.append(card)
        let packet = try all.handoff(caseID:all.workroom.cases[0].id)
        XCTAssertEqual(packet.workroom.cases.count,1);XCTAssertEqual(packet.cards.count,1);XCTAssertEqual(packet.routines.count,1)
        XCTAssertTrue(packet.history.events.isEmpty);XCTAssertTrue(packet.conversations.isEmpty)
    }
    func testMergeKeepsLocalConflictsAndDisarmsOnlyIncomingRemindersByDefault() throws {
        let imported = snapshot();var local = imported
        local.workroom.cases[0].title = "本机名称"
        let preview = try LibraryMerge.preview(local:local,package:.init(snapshot:imported),options:.init())
        XCTAssertEqual(preview.target.workroom.cases[0].title,"本机名称")
        XCTAssertNotNil(preview.target.routines[0].reminderAt)
        let empty = try LibraryMerge.preview(local:LibrarySnapshot(),package:.init(snapshot:imported),options:.init())
        XCTAssertNil(empty.target.routines[0].reminderAt);XCTAssertEqual(empty.missingLinks,0)
        var options = LibraryRestoreOptions();options.preferIncoming = true;options.rearmReminders = true
        let overwrite = try LibraryMerge.preview(local:local,package:.init(snapshot:imported),options:options)
        XCTAssertEqual(overwrite.target.workroom.cases[0].title,"读书会");XCTAssertNotNil(overwrite.target.routines[0].reminderAt)
    }
    func testChecklistOrderChangesFingerprintBecauseItChangesNextAction() throws {
        var a = snapshot();a.workroom.cases[0].steps = [.init(title:"先核对"),.init(title:"后报名")]
        var b = a;b.workroom.cases[0].steps.reverse()
        XCTAssertNotEqual(try a.fingerprint(),try b.fingerprint())
    }
    func testCrossRecordDemonstrationLabelsCannotDisagree() throws {
        var value = snapshot();value.cards[0].origin = .demonstration
        XCTAssertThrowsError(try value.validate())
        value = snapshot();value.routines[0].origin = .demonstration
        XCTAssertThrowsError(try value.validate())
    }
    func testFingerprintIsOrderIndependentAndChangesWhenMeaningChanges() throws {
        var a = snapshot(), b = a
        a.preferences.sounds = [.knock,.doorbell];b.preferences.sounds = [.doorbell,.knock]
        XCTAssertEqual(try a.fingerprint(),try b.fingerprint())
        b.workroom.cases[0].materials[0].done = true
        XCTAssertNotEqual(try a.fingerprint(),try b.fingerprint())
    }
    func testAtomicLibraryRollbackAndStalePreviewProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let repo = LibraryRepository(base:directory)
        let first = try LibraryMerge.preview(local:repo.read(),package:.init(snapshot:snapshot()),options:.init())
        repo.afterWrite = { if $0 == 2 { throw LibraryError.invalid } }
        XCTAssertThrowsError(try repo.commit(first))
        XCTAssertTrue(try repo.read().workroom.cases.isEmpty)
        repo.afterWrite = nil;try repo.commit(first)
        XCTAssertEqual(try repo.read().workroom.cases.count,1)
        XCTAssertThrowsError(try repo.commit(first))
        XCTAssertFalse(try repo.recover())
    }
    func testMissingReferencesRemainVisibleRatherThanPretendingTheyWereRestored() throws {
        var imported = snapshot();imported.cards = []
        let preview = try LibraryMerge.preview(local:LibrarySnapshot(),package:.init(snapshot:imported),options:.init())
        XCTAssertEqual(preview.missingLinks,1);XCTAssertEqual(preview.target.workroom.cases[0].links.count,2)
    }
    func testHardwareChecksCannotBeMarkedPassedOnSimulator() throws {
        let record = VerificationRecord(checkID:"watch-haptic",result:.passed,note:"",device:"Simulator",simulator:true)
        XCTAssertThrowsError(try record.validate())
        var allowed = record;allowed.result = .notChecked;XCTAssertNoThrow(try allowed.validate())
        allowed.simulator = false;allowed.result = .passed;XCTAssertNoThrow(try allowed.validate())
    }
    func testHealthDoesNotInterpretSilenceOrMissingInputAsNoEvents() {
        let now = Date()
        XCTAssertEqual(CaptureHealth.evaluate(active:false,starting:false,lastInput:nil,lastResult:nil,now:now).state,.off)
        XCTAssertEqual(CaptureHealth.evaluate(active:true,starting:false,lastInput:nil,lastResult:nil,now:now).state,.waiting)
        XCTAssertEqual(CaptureHealth.evaluate(active:true,starting:false,lastInput:nil,lastResult:nil,now:now,activeSince:now.addingTimeInterval(-9)).state,.interrupted)
        XCTAssertEqual(CaptureHealth.evaluate(active:true,starting:false,lastInput:now.addingTimeInterval(-10),lastResult:now,now:now).state,.interrupted)
        XCTAssertEqual(CaptureHealth.evaluate(active:true,starting:false,lastInput:now,lastResult:now,now:now).state,.receiving)
    }
    func testWatchActionRequiresMatchingCurrentVersionAndCorrectAction() throws {
        let item = try snapshot().routines[0].watchSummary()
        XCTAssertNil(WatchAgendaActionPolicy.rejection(item:item,fingerprint:item.fingerprint,action:.complete))
        XCTAssertNotNil(WatchAgendaActionPolicy.rejection(item:item,fingerprint:String(repeating:"b",count:64),action:.complete))
        XCTAssertNotNil(WatchAgendaActionPolicy.rejection(item:item,fingerprint:item.fingerprint,action:.seen))
        var done = item;done.completed = true
        XCTAssertNotNil(WatchAgendaActionPolicy.rejection(item:done,fingerprint:done.fingerprint,action:.complete))
    }
    func testLostWatchReceiptCanBeRetriedButChangedPayloadCannotReuseReceipt() throws {
        let item = try snapshot().routines[0].watchSummary()
        var request = WatchAgendaPacket(kind:.action,recordID:item.id,fingerprint:item.fingerprint,action:.complete)
        let response = WatchAgendaPacket(id:request.id,kind:.receipt,recordID:item.id,fingerprint:item.fingerprint,action:.complete,accepted:true,message:"已保存")
        var cache = AgendaReplyCache();try cache.remember(request:request,response:response)
        XCTAssertNotNil(cache.receipt(for:request));XCTAssertNil(cache.receipt(for:request,now:Date().addingTimeInterval(601)))
        request.action = .seen;XCTAssertNil(cache.receipt(for:request))
        XCTAssertThrowsError(try cache.remember(request:request,response:response))
    }
    func testWatchAgendaProtocolRejectsExpiredDuplicateAndMalformedItems() throws {
        let item = WatchAgendaItem(id:UUID(),kind:.routine,title:"演示",next:"",fingerprint:String(repeating:"a",count:64),demonstration:true,completed:false)
        var packet = WatchAgendaPacket(kind:.snapshot,items:[item])
        XCTAssertEqual(try WatchAgendaCodec.decode(WatchAgendaCodec.encode(packet)).items,[item])
        packet.items.append(item);XCTAssertThrowsError(try WatchAgendaCodec.encode(packet))
        packet.items = [item];packet.date = .now.addingTimeInterval(-601);XCTAssertThrowsError(try WatchAgendaCodec.encode(packet))
        packet.date = .now;packet.kind = .action;XCTAssertThrowsError(try WatchAgendaCodec.encode(packet))
    }
}
