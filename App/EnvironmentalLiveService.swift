import AVFoundation
import Foundation

@MainActor
final class EnvironmentalLiveService {
    private var engine: AVAudioEngine?
    private var processor: Processor?
    private var generation = UUID()
    func start(onScores: @escaping ([EnvironmentalScore], Bool) -> Void,
               onLevel: @escaping (Float) -> Void, onFailure: @escaping (Error) -> Void) async throws {
        stop(); let token = generation
        let model = try await Task.detached(priority: .userInitiated) { try YAMNetModel.bundled() }.value
        guard generation == token, !Task.isCancelled else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default); try session.setActive(true)
        let engine = AVAudioEngine(), input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ExperimentError.audio }
        let processor = Processor(model: model, onScores: { [weak self] scores, reset in
            Task { @MainActor [weak self] in guard self?.generation == token else { return }; onScores(scores, reset) }
        }, onFailure: { [weak self] error in
            Task { @MainActor [weak self] in guard self?.generation == token else { return }; onFailure(error) }
        })
        self.processor = processor; self.engine = engine
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let level = SignalMonitor.amplitude(buffer)
            Task { @MainActor [weak self] in if self?.generation == token { onLevel(level) } }
            processor.enqueue(buffer)
        }
        do { try engine.start() } catch { stop(); throw error }
    }
    func stop() {
        generation = UUID()
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil; processor = nil
    }
}

/// Owns copied buffers; one in-flight analysis bounds work. Dropped chunks reset continuity.
private final class Processor {
    private let queue = DispatchQueue(label: "SeeSound.YAMNet.Analysis", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = false
    private var gap = false
    private let model: YAMNetModel
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private let onScores: ([EnvironmentalScore],Bool)->Void
    private let onFailure: (Error)->Void
    init(model: YAMNetModel, onScores: @escaping ([EnvironmentalScore],Bool)->Void, onFailure: @escaping (Error)->Void) {
        self.model = model; self.onScores = onScores; self.onFailure = onFailure
    }
    func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if pending { gap = true; lock.unlock(); return }
        pending = true; let reset = gap; gap = false; lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            lock.lock(); pending = false; gap = true; lock.unlock(); return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            guard let src = source[index].mData, let dst = target[index].mData else { continue }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        queue.async { [self] in
            defer { lock.lock(); pending = false; lock.unlock() }
            do {
                if reset { samples.removeAll(); converter?.reset() }
                if format != copy.format || converter == nil {
                    let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                    converter = AVAudioConverter(from: copy.format, to: output); format = copy.format; samples.removeAll()
                }
                guard let converter, let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                    frameCapacity: AVAudioFrameCount(ceil(Double(copy.frameLength)*16000/copy.format.sampleRate)+256)) else { throw ExperimentError.audio }
                var supplied = false, failure: NSError?
                let state = converter.convert(to: output, error: &failure) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return copy
                }
                guard state != .error, failure == nil else { throw ExperimentError.audio }
                if let channel = output.floatChannelData?[0] { samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength))) }
                if reset { onScores([], true) }
                while samples.count >= YAMNetFeatures.patchSamples {
                    let window = Array(samples.prefix(YAMNetFeatures.patchSamples))
                    let scores = try model.analyze(samples: window)
                    onScores(Array(scores.prefix(8)), false); samples.removeFirst(YAMNetFeatures.hopSamples)
                }
            } catch { samples.removeAll(); onFailure(error) }
        }
    }
}
