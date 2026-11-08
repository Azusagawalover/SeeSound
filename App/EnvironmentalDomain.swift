import Foundation
import Accelerate

enum EnvironmentalError: LocalizedError {
    case assets
    var errorDescription: String? { "声音模型、标签或前处理资源缺失或不兼容，未开始识别。" }
}

enum EnvironmentalEngine: String, Codable, CaseIterable, Identifiable {
    case apple, yamnet
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple 系统模型" : "YAMNet · 本机实验引擎" }
}
struct EnvironmentalScore: Codable, Equatable, Identifiable {
    var index: Int
    var label: String
    var score: Double
    var id: Int { index }
    var reminderLabel: String? {
        switch label { case "Knock": return "knock"; case "Doorbell", "Ding-dong": return "doorbell"; case "Clapping": return "clapping"; default: return nil }
    }
    var title: String {
        switch label {
        case "Knock": return "敲门"; case "Doorbell", "Ding-dong": return "门铃"; case "Clapping": return "拍手"
        case "Speech": return "讲话"; case "Music": return "音乐"; case "Silence": return "安静"
        case "Typing", "Typing on computer keyboard", "Computer keyboard": return "键盘声"
        case "Vacuum cleaner": return "吸尘器"; case "Dog", "Bark": return "犬吠"
        case "Siren": return "警笛"; case "Baby cry, infant cry": return "婴儿哭声"
        default: return label
        }
    }
}

/// TensorFlow YAMNet frontend: periodic Hann, magnitude STFT, HTK-mel triangles.
/// Input 16 kHz mono, 400-sample windows / 160 hop / 512 FFT; no per-clip normalization.
enum YAMNetFeatures {
    static let patchSamples = 15_600
    static let hopSamples = 7_680
    private static let window: [Double] = (0..<400).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / 400) }
    private static let weights: [[Double]] = {
        func mel(_ hertz: Double) -> Double { 1127 * log(1 + hertz / 700) }
        let low = mel(125), high = mel(7500)
        let edges = (0..<66).map { low + (high-low) * Double($0) / 65 }
        return (0..<64).map { band in
            (0..<257).map { bin in
                guard bin > 0 else { return 0.0 }
                let value = mel(Double(bin) * 16000 / 512)
                return max(0, min((value-edges[band])/(edges[band+1]-edges[band]), (edges[band+2]-value)/(edges[band+2]-edges[band+1])))
            }
        }
    }()
    static func patches(_ samples: [Float]) throws -> [[Float]] {
        guard !samples.isEmpty, samples.count <= 160_000, samples.allSatisfy({ $0.isFinite && abs($0) <= 4 }),
              let plan = vDSP_DFT_zop_CreateSetupD(nil, 512, .FORWARD) else { throw ExperimentError.audio }
        defer { vDSP_DFT_DestroySetupD(plan) }
        let hops = max(0, Int(ceil(Double(samples.count - patchSamples) / Double(hopSamples))))
        let padded = patchSamples + hops * hopSamples
        let frameCount = (padded-400)/160 + 1
        var melFrames = [[Float]](); melFrames.reserveCapacity(frameCount)
        let imaginary = [Double](repeating: 0, count: 512)
        for frame in 0..<frameCount {
            var real = [Double](repeating: 0, count: 512)
            for i in 0..<400 { let index = frame*160+i; if index < samples.count { real[i] = Double(samples[index]) * window[i] } }
            var re = [Double](repeating: 0, count: 512), im = re
            vDSP_DFT_ExecuteD(plan, real, imaginary, &re, &im)
            let magnitude = (0..<257).map { sqrt(re[$0]*re[$0] + im[$0]*im[$0]) }
            melFrames.append(weights.map { row in
                var energy = 0.0
                for bin in 0..<257 { energy += magnitude[bin] * row[bin] }
                return Float(log(energy + 0.001))
            })
        }
        return (0...hops).map { hop in Array(melFrames[(hop*48)..<(hop*48+96)].joined()) }
    }
}

/// The comparison engine never changes the engine used for live reminders.
enum EnvironmentalCandidate: String, CaseIterable, Identifiable {
    case yamnet, panns
    var id:String { rawValue }
    var title:String { self == .yamnet ? "YAMNet · 轻量基线" : "PANNs Cnn10 · 527 类" }
}
/// Matches torchlibrosa: centered reflect STFT, periodic Hann, POWER spectrum,
/// upstream Slaney mel weights and 10*log10(max(energy, 1e-10)). Not YAMNet features.
enum PANNsFeatures {
    static func extract(_ samples:[Float],weights:[[Double]]) throws -> [Float] {
        guard !samples.isEmpty,samples.count <= 160000,samples.allSatisfy({$0.isFinite && abs($0) <= 4}),weights.count == 64,weights.allSatisfy({$0.count == 513 && $0.allSatisfy(\.isFinite)}),let plan = vDSP_DFT_zop_CreateSetupD(nil,1024,.FORWARD) else { throw ExperimentError.invalid }
        defer { vDSP_DFT_DestroySetupD(plan) }
        let padded = samples+[Float](repeating:0,count:160000-samples.count)
        let window = (0..<1024).map { 0.5-0.5*cos(2 * .pi * Double($0)/1024) }
        let imaginary = [Double](repeating:0,count:1024)
        var output = [Float]();output.reserveCapacity(501*64)
        for frame in 0..<501 {
            if frame % 32 == 0 { try Task.checkCancellation() }
            var real = [Double](repeating:0,count:1024)
            for index in 0..<1024 {
                let position = frame*320+index-512
                let reflected = position < 0 ? -position : position >= padded.count ? 2*padded.count-2-position : position
                real[index] = Double(padded[reflected])*window[index]
            }
            var re = [Double](repeating:0,count:1024),im = re
            vDSP_DFT_ExecuteD(plan,real,imaginary,&re,&im)
            let power = (0..<513).map { re[$0]*re[$0]+im[$0]*im[$0] }
            for band in weights {
                var energy = 0.0
                for bin in 0..<513 { energy += power[bin]*band[bin] }
                output.append(Float(10*log10(max(energy,1e-10))))
            }
        }
        return output
    }
}
