import Foundation
import XCTest
import GRDB
import AVFoundation
import CryptoKit
@testable import SeeSoundData

final class DataIntegrationTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func publicClips() throws -> [PublicSoundClip] {
        let url = projectRoot.appendingPathComponent("Resources/ESC50-Catalog.json")
        let catalog = try JSONDecoder().decode(PublicSoundCatalog.self, from: Data(contentsOf: url))
        try catalog.validate()
        return catalog.clips
    }

    func testPublicCatalogRejectsAudioTraversalAndIncorrectLabels() throws {
        let clips = try publicClips()
        XCTAssertEqual(clips.count, 24)
        var invalid = clips[0]; invalid.id = "../private.wav"
        XCTAssertThrowsError(try invalid.validate())
        invalid = clips[0]; invalid.fold = 1
        XCTAssertThrowsError(try invalid.validate())
        invalid = clips[0]; invalid.label = .doorbell
        XCTAssertThrowsError(try invalid.validate())
        invalid = clips[0]; invalid.features[0][0] = .nan
        XCTAssertThrowsError(try invalid.validate())
        invalid = clips[0]; invalid.attribution = ""
        XCTAssertThrowsError(try invalid.validate())
    }

    func testPublicAudioFilesHaveDeclaredDurationAndAllAttributions() throws {
        let clips = try publicClips()
        let folder = projectRoot.appendingPathComponent("Resources/PublicAudio")
        for clip in clips {
            let url = folder.appendingPathComponent(clip.id)
            let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, clip.sha256)
            let audio = try AVAudioFile(forReading: url)
            XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 5, accuracy: 0.0001)
            XCTAssertTrue(clip.attribution.contains(clip.sourceFile))
        }
    }

    func testAudioImportConvertsToMono16kAndExtractsDeterministicFeatures() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)); buffer.frameLength = 48_000
        for index in 0..<48_000 {
            let value = Float(sin(Double(index) * 2 * .pi * 500 / 48_000) * 0.1)
            buffer.floatChannelData?[0][index] = value; buffer.floatChannelData?[1][index] = value
        }
        let url = directory.appendingPathComponent("generated-tone.caf")
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let batch = UUID()
        let draft = try SampleAudioReader.prepare(url: url, batch: batch)
        defer { try? FileManager.default.removeItem(at: draft.url) }
        XCTAssertEqual(draft.sample.batch, batch); XCTAssertEqual(draft.sample.duration, 1, accuracy: 0.001)
        XCTAssertFalse(draft.sample.keepsAudio)
        XCTAssertTrue(AudioFeatureCodec.validate(draft.sample.features))
        let canonical = try AVAudioFile(forReading: draft.url)
        XCTAssertEqual(canonical.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(canonical.processingFormat.channelCount, 1)
        let again = try SampleAudioReader.prepare(url: url, batch: UUID())
        defer { try? FileManager.default.removeItem(at: again.url) }
        XCTAssertEqual(draft.sample.fingerprint, again.sample.fingerprint)
        XCTAssertEqual(draft.sample.features, again.sample.features)
        XCTAssertEqual(draft.sample.features[10][2], 0.0625, accuracy: 0.01)
    }

    func testAudioImportRejectsFilesOutsideDurationLimit() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)); buffer.frameLength = 1_600
        for index in 0..<1_600 { buffer.floatChannelData?[0][index] = 0 }
        let url = directory.appendingPathComponent("too-short.caf")
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        XCTAssertThrowsError(try SampleAudioReader.prepare(url: url, batch: UUID()))
    }

    func testPinnedPhraseMigrationSearchAndComposition() throws {
        let old = Data("{\"phrases\":[\"请写下来\",\"谢谢\"]}".utf8)
        var preferences = try JSONDecoder().decode(AppPreferences.self, from: old)
        XCTAssertTrue(preferences.pinnedPhrases.isEmpty)
        preferences.pinnedPhrases = ["谢谢"]
        XCTAssertEqual(PhraseComposer.visible(preferences: preferences, category: nil, query: ""), ["谢谢", "请写下来"])
        XCTAssertEqual(PhraseComposer.visible(preferences: preferences, category: nil, query: "写"), ["请写下来"])
        XCTAssertEqual(PhraseComposer.append("谢谢", to: "请写下来"), "请写下来 谢谢")
        XCTAssertEqual(PhraseComposer.append(String(repeating: "字", count: 80), to: String(repeating: "字", count: 490)).count, 500)
    }

    func testSampleFeaturesRejectNonFiniteAudio() throws {
        let audio = (0..<16_000).map { Float(sin(Double($0) * 0.1) * 0.1) }
        XCTAssertTrue(AudioFeatureCodec.validate(try AudioFeatureCodec.extract(audio)))
        XCTAssertThrowsError(try AudioFeatureCodec.extract([Float](repeating: .infinity, count: 512)))
    }

    func testSampleStoreCommitsOnlyValidUniqueSamplesAndDeletesAudio() throws {
        let store = SoundSampleStore(directory: directory.appendingPathComponent("Samples"))
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        let features = [[Double]](repeating: [0.1, 0.2, 0.3, 0.4], count: 64)
        let sample = SoundSample(id: UUID(), batch: UUID(), createdAt: Date(), label: .knock, note: "人工标签", duration: 1,
                                 fingerprint: String(repeating: "a", count: 64), keepsAudio: false, features: features)
        try store.save(sample, audio: nil)
        XCTAssertEqual(try store.load(), [sample])
        XCTAssertNil(store.audioURL(for: sample))
        var duplicate = sample; duplicate.id = UUID()
        XCTAssertThrowsError(try store.save(duplicate, audio: nil))
        var invalid = sample; invalid.id = UUID(); invalid.features = []
        XCTAssertThrowsError(try store.save(invalid, audio: nil))
        XCTAssertEqual(try store.load(), [sample])
        var relabeled = sample; relabeled.label = .doorbell
        try store.relabel(relabeled)
        XCTAssertEqual(try store.load().first?.label, .doorbell)
        let audio = directory.appendingPathComponent("mock.caf"); try Data([1, 2, 3]).write(to: audio)
        var kept = sample; kept.id = UUID(); kept.fingerprint = String(repeating: "b", count: 64); kept.keepsAudio = true
        try store.save(kept, audio: audio)
        let keptURL = try XCTUnwrap(store.audioURL(for: kept))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path))
        try store.delete(kept.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keptURL.path))
        XCTAssertEqual(try store.load().count, 1)
    }

    func testSampleStoreDoesNotCommitWhenRequiredAudioIsMissing() throws {
        let store = SoundSampleStore(directory: directory.appendingPathComponent("Samples"))
        let sample = SoundSample(id: UUID(), batch: UUID(), createdAt: Date(), label: .other, note: "", duration: 1,
                                 fingerprint: String(repeating: "c", count: 64), keepsAudio: true,
                                 features: [[Double]](repeating: [0, 0, 0, 0], count: 64))
        XCTAssertThrowsError(try store.save(sample, audio: nil))
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testDatasetRejectsDuplicateRecordingsAndUnsupportedFeatures() throws {
        let sample = SoundSample(id: UUID(), batch: UUID(), createdAt: Date(), label: .other, note: "", duration: 1,
                                 fingerprint: String(repeating: "d", count: 64), keepsAudio: false,
                                 features: [[Double]](repeating: [0, 0, 0, 0], count: 64))
        XCTAssertNoThrow(try SoundDataset(samples: [sample]).validated())
        var copy = sample; copy.id = UUID()
        XCTAssertThrowsError(try SoundDataset(samples: [sample, copy]).validated())
        var dataset = SoundDataset(samples: [sample]); dataset.featureSchema = "unknown"
        XCTAssertThrowsError(try dataset.validated())
    }

    func testLegacyEventChecks() throws { try CoreChecks.main() }
    func testLegacyJournalChecks() throws { try JournalChecks.main() }
    func testLegacyWatchChecks() throws { try WatchLinkChecks.main() }
    func testLegacyConversationChecks() throws { try ConversationChecks.main() }
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeeSoundIntegration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testLegacyHistoryMigratesOnlyAfterValidTransaction() throws {
        let event = SenseEvent(category: "knock", title: "敲门", source: .sound)
        let annotation = EventAnnotation(verdict: .uncertain, note: "迁移备注")
        let archive = JournalArchive(events: [event], annotations: [event.id: annotation])
        let legacy = directory.appendingPathComponent("events.json")
        try JSONEncoder().encode(archive).write(to: legacy)
        var prefs = AppPreferences(); prefs.saveHistory = true
        let store = LocalJournal(directory: directory)
        let restored = try store.loadHistory(preferences: prefs)
        XCTAssertEqual(restored.events, [event])
        XCTAssertEqual(restored.annotations[event.id], annotation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.sqlite").path))
        let reopened = try LocalJournal(directory: directory).loadHistory(preferences: prefs)
        XCTAssertEqual(reopened.events, [event])
    }

    func testCorruptLegacyIsRetainedAndCanBeRetried() throws {
        let legacy = directory.appendingPathComponent("events.json")
        let bad = Data("broken-json".utf8); try bad.write(to: legacy)
        var prefs = AppPreferences(); prefs.saveHistory = true
        XCTAssertThrowsError(try LocalJournal(directory: directory).loadHistory(preferences: prefs))
        XCTAssertEqual(try Data(contentsOf: legacy), bad)
        let event = SenseEvent(category: "test", title: "演示", source: .demonstration)
        try JSONEncoder().encode(JournalArchive(events: [event], annotations: [:])).write(to: legacy)
        let restored = try LocalJournal(directory: directory).loadHistory(preferences: prefs)
        XCTAssertEqual(restored.events, [event])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testInvalidSnapshotCannotReplaceExistingData() throws {
        let store = LocalJournal(directory: directory)
        let event = SenseEvent(category: "test", title: "保留记录", source: .demonstration)
        try store.saveHistory(JournalArchive(events: [event], annotations: [:]))
        var invalid = event; invalid.count = 0
        XCTAssertThrowsError(try store.saveHistory(JournalArchive(events: [invalid], annotations: [:])))
        var prefs = AppPreferences(); prefs.saveHistory = true
        XCTAssertEqual(try store.loadHistory(preferences: prefs).events, [event])
    }

    func testOptOutDeletesDatabaseSidecarsAndLeavesPreferences() throws {
        let store = LocalJournal(directory: directory)
        var prefs = AppPreferences(); prefs.phrases.append("我的卡片")
        try store.savePreferences(prefs)
        try store.saveHistory(JournalArchive(events: [SenseEvent(category: "test", title: "测试", source: .demonstration)], annotations: [:]))
        _ = try store.loadHistory(preferences: prefs)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.sqlite" + suffix).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("preferences.json").path))
        XCTAssertEqual(try store.loadPreferences().phrases, prefs.phrases)
    }

    func testNoDatabaseIsCreatedBeforeOptIn() throws {
        let store = LocalJournal(directory: directory)
        XCTAssertTrue(try store.loadHistory(preferences: AppPreferences()).events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.sqlite").path))
    }

    func testRetentionAndAnnotationsRemainConsistent() throws {
        let now = Date()
        let recent = SenseEvent(category: "test", title: "最近", source: .demonstration, at: now)
        let old = SenseEvent(category: "test", title: "过期", source: .demonstration, at: now.addingTimeInterval(-8 * 86_400))
        let store = LocalJournal(directory: directory)
        try store.saveHistory(JournalArchive(events: [recent, old], annotations: [old.id: EventAnnotation(note: "过期备注")]))
        var prefs = AppPreferences(); prefs.saveHistory = true
        let restored = try store.loadHistory(preferences: prefs, now: now)
        XCTAssertEqual(restored.events, [recent]); XCTAssertNil(restored.annotations[old.id])
    }

    func testSQLiteCorruptionIsReportedWithoutOverwriting() throws {
        let store = LocalJournal(directory: directory)
        try store.saveHistory(JournalArchive(events: [SenseEvent(category: "test", title: "测试", source: .demonstration)], annotations: [:]))
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("events.sqlite").path)
        try queue.write { db in try db.execute(sql: "UPDATE eventRecord SET payload = ?", arguments: [Data("broken".utf8)]) }
        try queue.close()
        var prefs = AppPreferences(); prefs.saveHistory = true
        XCTAssertThrowsError(try store.loadHistory(preferences: prefs))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.sqlite").path))
    }

    func testCardTransferRoundTrip() throws {
        let phrases = [SharedPhrase(text: "请写下来。", category: .request), SharedPhrase(text: "谢谢。", category: .response)]
        XCTAssertEqual(try PhraseTransferCodec.decode(PhraseTransferCodec.encode(phrases)).phrases, phrases)
    }

    func testCardTransferRejectsExecutableLinksWrongSchemaAndOversize() throws {
        XCTAssertThrowsError(try PhraseTransferCodec.decode("https://example.com/anything"))
        XCTAssertThrowsError(try PhraseTransferCodec.decode("{\"format\":\"OtherApp\",\"version\":1,\"phrases\":[]}"))
        XCTAssertThrowsError(try PhraseTransferCodec.decode(String(repeating: "a", count: 4097)))
        XCTAssertThrowsError(try PhraseTransferCodec.encode([]))
        XCTAssertThrowsError(try PhraseTransferCodec.encode((0..<9).map { SharedPhrase(text: "短语 \($0)", category: .personal) }))
    }

    func testCardTransferRejectsBlankDuplicateAndLongPhrases() throws {
        XCTAssertThrowsError(try PhraseTransferCodec.encode([SharedPhrase(text: " ", category: .personal)]))
        XCTAssertThrowsError(try PhraseTransferCodec.encode([SharedPhrase(text: String(repeating: "字", count: 81), category: .personal)]))
        XCTAssertThrowsError(try PhraseTransferCodec.encode([SharedPhrase(text: "同一句", category: .personal), SharedPhrase(text: "同一句", category: .request)]))
    }

    func testOldPreferencesRetainChoices() throws {
        var prefs = AppPreferences(); prefs.saveHistory = true; prefs.sensitivity = .cautious
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as! [String: Any]
        json.removeValue(forKey: "phraseCategories")
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("preferences.json"))
        let migrated = try LocalJournal(directory: directory).loadPreferences()
        XCTAssertEqual(migrated.phrases, prefs.phrases); XCTAssertTrue(migrated.saveHistory)
        XCTAssertEqual(migrated.sensitivity, .cautious)
    }

    func testImportedTextRetainsFileOriginWhenEdited() {
        var session = ConversationSession()
        let active = session.beginCapture()
        session.addFileTranscript(String(repeating: "字", count: 600))
        let imported = session.turns.last!
        XCTAssertEqual(imported.origin, .fileTranscription)
        XCTAssertEqual(imported.speaker, .partner)
        XCTAssertEqual(imported.state, .completed)
        XCTAssertEqual(imported.text.count, 500)
        XCTAssertEqual(session.activeCapture, active)
        XCTAssertTrue(session.edit(imported.id, text: "人工核对后的文字"))
        XCTAssertEqual(session.turns.last?.origin, .fileTranscription)
        XCTAssertEqual(session.turns.last?.isEdited, true)
    }

    func testBundledVocableCatalogHasCompleteProvenanceAndUniquePhrases() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(VocableCatalog.self,
            from: Data(contentsOf: root.appendingPathComponent("Resources/VocablePhrases.json")))
        XCTAssertEqual(catalog.sourceCommit, "58ba45a978e1ebaeae71d9e88509703a9bd67bd6")
        XCTAssertEqual(catalog.phrases.count, 62)
        XCTAssertEqual(Set(catalog.phrases.map(\.id)).count, 62)
        XCTAssertTrue(catalog.phrases.allSatisfy { !$0.text.isEmpty && $0.text.count <= 80 && !$0.english.isEmpty && !$0.group.isEmpty })
    }

    func testExpandedFavoritesCapacityRemainsBounded() throws {
        var preferences = AppPreferences()
        preferences.phrases = (0..<PhraseCollection.limit).map { "短语 \($0)" }
        let store = LocalJournal(directory: directory)
        try store.savePreferences(preferences)
        XCTAssertEqual(try store.loadPreferences().phrases.count, PhraseCollection.limit)
        preferences.phrases.append("超出上限")
        try store.savePreferences(preferences)
        XCTAssertThrowsError(try store.loadPreferences())
    }
}
