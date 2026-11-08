import AVFoundation
import CryptoKit
import Foundation

struct PreparedSound: Identifiable {
    var sample: SoundSample
    var url: URL
    var id: UUID { sample.id }
}

enum SampleAudioReader {
    static func prepare(url: URL, batch: UUID) throws -> PreparedSound {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard url.isFileURL, size > 0, size <= 10 * 1_024 * 1_024 else { throw ExperimentError.audio }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard (0.5...5).contains(duration), (8_000...192_000).contains(file.processingFormat.sampleRate),
              (1...8).contains(file.processingFormat.channelCount),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let target = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(duration * 16_000) + 64)),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw ExperimentError.audio }
        try file.read(into: source)
        var supplied = false, error: NSError?
        let result = converter.convert(to: target, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        guard error == nil, result != .error, let values = target.floatChannelData?[0], target.frameLength >= 8_000 else { throw ExperimentError.audio }
        let samples = Array(UnsafeBufferPointer(start: values, count: Int(target.frameLength)))
        let features = try AudioFeatureCodec.extract(samples)
        let fingerprint = samples.withUnsafeBytes { bytes in SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }
        let id = UUID(), output = FileManager.default.temporaryDirectory.appendingPathComponent("SeeSoundSample-\(id.uuidString).caf")
        do {
            let destination = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try destination.write(from: target)
        } catch { try? FileManager.default.removeItem(at: output); throw error }
        return PreparedSound(sample: SoundSample(id: id, batch: batch, createdAt: Date(), label: .other, note: "",
                                                duration: duration, fingerprint: fingerprint, keepsAudio: false, features: features), url: output)
    }
}

