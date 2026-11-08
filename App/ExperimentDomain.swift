import Foundation

enum SoundSampleLabel: String, Codable, CaseIterable, Identifiable {
    case knock, doorbell, clapping, other
    var id: String { rawValue }
    var title: String {
        switch self { case .knock: return "敲门"; case .doorbell: return "门铃"; case .clapping: return "拍手"; case .other: return "其他 / 背景" }
    }
}

enum ExperimentError: LocalizedError {
    case invalid, duplicate, limit, audio
    var errorDescription: String? {
        switch self {
        case .invalid: return "实验文件格式、参数或校验不符合要求。"
        case .duplicate: return "已经保存过这份音频，请换一段独立录音。"
        case .limit: return "样本库最多保存 100 段，请先整理已有样本。"
        case .audio: return "请选择 0.5–5 秒、10 MB 以内的有效音频。"
        }
    }
}

/// audio-envelope-v1: 64 temporal frames, each [log-RMS, peak, zero-crossing, mean absolute difference].
/// These compact exploratory features are not a replacement for a validated acoustic representation.
enum AudioFeatureCodec {
    static let schema = "audio-envelope-v1"
    static let frames = 64
    static let step = 0.08
    static func extract(_ samples: [Float]) throws -> [[Double]] {
        guard samples.count >= 64 * 8, samples.allSatisfy({ $0.isFinite }) else { throw ExperimentError.audio }
        return (0..<frames).map { frame in
            let start = frame * samples.count / frames
            let end = (frame + 1) * samples.count / frames
            var square = 0.0, peak = 0.0, crossings = 0.0, difference = 0.0
            for index in start..<end {
                let value = Double(samples[index]); square += value * value; peak = max(peak, abs(value))
                if index > start {
                    let before = Double(samples[index - 1])
                    if (value >= 0) != (before >= 0) { crossings += 1 }
                    difference += abs(value - before)
                }
            }
            let count = Double(end - start)
            let logRMS = (20 * log10(max(0.000_001, sqrt(square / count))) + 60) / 60
            return [min(1, max(0, logRMS)), min(1, peak), crossings / max(1, count - 1), min(1, difference / max(1, count - 1))]
        }
    }
    static func validate(_ values: [[Double]]) -> Bool {
        values.count == frames && values.allSatisfy { $0.count == 4 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }
    }

}

struct SoundSample: Codable, Identifiable, Equatable {
    var id: UUID
    var batch: UUID
    var createdAt: Date
    var label: SoundSampleLabel
    var note: String
    var duration: Double
    var fingerprint: String
    var keepsAudio: Bool
    var features: [[Double]]
    func validate() throws {
        guard AudioFeatureCodec.validate(features), (0.5...5).contains(duration), note.count <= 120,
              fingerprint.count == 64, fingerprint.allSatisfy({ $0.isHexDigit }),
              createdAt.timeIntervalSince1970.isFinite else { throw ExperimentError.invalid }
    }
}

struct SoundDataset: Codable {
    var format = "SeeSoundDataset"
    var version = 1
    var featureSchema = AudioFeatureCodec.schema
    var encodingStep = AudioFeatureCodec.step
    var samples: [SoundSample]
    func validated() throws -> SoundDataset {
        guard format == "SeeSoundDataset", version == 1, featureSchema == AudioFeatureCodec.schema,
              encodingStep == AudioFeatureCodec.step, samples.count <= 100,
              Set(samples.map(\.id)).count == samples.count,
              Set(samples.map(\.fingerprint)).count == samples.count else { throw ExperimentError.invalid }
        try samples.forEach { try $0.validate() }; return self
    }
}


/// One directory per confirmed sample: staging + atomic rename avoid partially committed entries.
final class SoundSampleStore {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeeSoundSamples", isDirectory: true)
    }
    func load() throws -> [SoundSample] {
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else { return [] }
        let folders = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        guard folders.count <= 100 else { throw ExperimentError.limit }
        return try folders.map { folder in
            let url = folder.appendingPathComponent("record.json")
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size < 100_000 else { throw ExperimentError.invalid }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let sample = try JSONDecoder().decode(SoundSample.self, from: data)
            try sample.validate()
            guard sample.id.uuidString == folder.lastPathComponent else { throw ExperimentError.invalid }
            return sample
        }.sorted { $0.createdAt > $1.createdAt }
    }
    func save(_ sample: SoundSample, audio: URL?) throws {
        try sample.validate()
        let current = try load()
        guard current.count < 100 else { throw ExperimentError.limit }
        guard !current.contains(where: { $0.fingerprint == sample.fingerprint }) else { throw ExperimentError.duplicate }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var root = directory; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try root.setResourceValues(flags)
        let staging = directory.appendingPathComponent("staging-\(sample.id.uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        if sample.keepsAudio {
            guard let audio else { throw ExperimentError.audio }
            try files.copyItem(at: audio, to: staging.appendingPathComponent("audio.caf"))
        }
        try JSONEncoder().encode(sample).write(to: staging.appendingPathComponent("record.json"), options: .atomic)
        for url in try files.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try files.setAttributes(attributes, ofItemAtPath: url.path)
        }
        try files.moveItem(at: staging, to: directory.appendingPathComponent(sample.id.uuidString))
    }
    func relabel(_ sample: SoundSample) throws {
        try sample.validate()
        guard try load().contains(where: { $0.id == sample.id }) else { throw ExperimentError.invalid }
        let url = directory.appendingPathComponent(sample.id.uuidString).appendingPathComponent("record.json")
        #if os(iOS)
        try JSONEncoder().encode(sample).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(sample).write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString)) }
    func audioURL(for sample: SoundSample) -> URL? {
        sample.keepsAudio ? directory.appendingPathComponent(sample.id.uuidString).appendingPathComponent("audio.caf") : nil
    }
}
