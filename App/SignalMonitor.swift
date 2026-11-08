import AVFoundation
import Foundation

enum SignalMonitor {
    /// Relative input amplitude only; this is not a calibrated sound pressure meter.
    static func amplitude(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        var count = 0
        for index in stride(from: 0, to: Int(buffer.frameLength), by: 16) {
            let sample = channel[index]
            if sample.isFinite { sum += sample * sample; count += 1 }
        }
        guard count > 0 else { return 0 }
        return min(1, max(0, sqrt(sum / Float(count)) * 6))
    }
}
