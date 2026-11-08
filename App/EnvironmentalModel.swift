import AVFoundation
import CoreML
import Foundation

final class YAMNetModel {
    private let model: MLModel
    let labels: [String]
    init(modelURL: URL, labelsURL: URL, cpuOnly: Bool = false) throws {
        let settings = MLModelConfiguration(); settings.computeUnits = cpuOnly ? .cpuOnly : .all
        let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        model = try MLModel(contentsOf: compiled, configuration: settings)
        // CSV names may contain commas; the third column is a quoted display name.
        let lines = try String(contentsOf: labelsURL, encoding: .utf8).components(separatedBy: .newlines).dropFirst().filter { !$0.isEmpty }
        labels = try lines.enumerated().map { index, row in
            let columns = row.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3, Int(columns[0]) == index else { throw ExperimentError.invalid }
            return String(columns[2]).trimmingCharacters(in: CharacterSet(charactersIn: "\"\r"))
        }
        guard labels.count == 521,
              model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,96,64],
              (model.modelDescription.outputDescriptionsByName["Identity"] != nil || model.modelDescription.outputDescriptionsByName["Identity_to_fp32"] != nil) else { throw ExperimentError.invalid }
    }
    static func bundled() throws -> YAMNetModel {
        guard let model = Bundle.main.url(forResource: "YAMNet", withExtension: "mlmodelc"),
              let labels = Bundle.main.url(forResource: "YAMNet-Labels", withExtension: "csv") else { throw EnvironmentalError.assets }
        return try YAMNetModel(modelURL: model, labelsURL: labels)
    }
    func scores(patch: [Float]) throws -> [Double] {
        guard patch.count == 6144, patch.allSatisfy(\.isFinite) else { throw ExperimentError.invalid }
        let array = try MLMultiArray(shape: [1,96,64], dataType: model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint?.dataType ?? .float32)
        for index in patch.indices { array[index] = NSNumber(value: patch[index]) }
        let input = try MLDictionaryFeatureProvider(dictionary: ["features": MLFeatureValue(multiArray: array)])
        let output = try model.prediction(from: input)
        guard let scores = (output.featureValue(for: "Identity") ?? output.featureValue(for:"Identity_to_fp32"))?.multiArrayValue, scores.count == 521 else { throw ExperimentError.invalid }
        let result = (0..<521).map { scores[$0].doubleValue }
        guard result.contains(where:{$0 > 0}),result.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ExperimentError.invalid }
        return result
    }
    func analyze(samples: [Float]) throws -> [EnvironmentalScore] {
        let patches = try YAMNetFeatures.patches(samples)
        var mean = [Double](repeating: 0, count: 521)
        for patch in patches {
            try Task.checkCancellation()
            let scores = try scores(patch: patch)
            for index in mean.indices { mean[index] += scores[index] / Double(patches.count) }
        }
        return mean.indices.map { EnvironmentalScore(index: $0, label: labels[$0], score: mean[$0]) }.sorted { $0.score > $1.score }
    }
    static func readAudio(_ url: URL,sampleRate:Double = 16000) throws -> [Float] {
        guard url.isFileURL else { throw ExperimentError.audio }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard (0.1...10).contains(duration), (8_000...192_000).contains(file.processingFormat.sampleRate),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(duration*sampleRate)+64)),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw ExperimentError.audio }
        try file.read(into: input)
        var supplied = false, failure: NSError?
        let state = converter.convert(to: output, error: &failure) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard state != .error, failure == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { throw ExperimentError.audio }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

actor EnvironmentRunner {
    private var model: YAMNetModel?
    private var panns:PANNsModel?
    func analyze(url: URL,gain:Float = 1,candidate:EnvironmentalCandidate = .yamnet) throws -> [EnvironmentalScore] {
        guard gain == 1 || gain == 0.5 else { throw ExperimentError.invalid }
        if candidate == .panns { if panns == nil { panns = try PANNsModel.bundled() };return try panns!.analyze(samples:YAMNetModel.readAudio(url,sampleRate:32000).map { $0*gain }) }
        if model == nil { model = try YAMNetModel.bundled() }
        return try model!.analyze(samples: YAMNetModel.readAudio(url).map { $0*gain })
    }
}

final class PANNsModel {
    private let model:MLModel
    let labels:[String]
    let weights:[[Double]]
    init(modelURL:URL,labelsURL:URL,melURL:URL,cpuOnly:Bool = false) throws {
        let config = MLModelConfiguration();config.computeUnits = cpuOnly ? .cpuOnly : .all
        let url = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at:modelURL)
        model = try MLModel(contentsOf:url,configuration:config)
        labels = try String(contentsOf:labelsURL,encoding:.utf8).components(separatedBy:.newlines).dropFirst().filter{!$0.isEmpty}.enumerated().map { index,line in
            let fields = line.split(separator:",",maxSplits:2,omittingEmptySubsequences:false)
            guard fields.count == 3,Int(fields[0]) == index else { throw ExperimentError.invalid }
            return String(fields[2]).trimmingCharacters(in:CharacterSet(charactersIn:"\"\r"))
        }
        weights = try JSONDecoder().decode([[Double]].self,from:Data(contentsOf:melURL))
        guard labels.count == 527,weights.count == 64,weights.allSatisfy({$0.count == 513}),model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,1,501,64] else { throw ExperimentError.invalid }
    }
    static func bundled() throws -> PANNsModel {
        guard let url = Bundle.main.url(forResource:"PANNsCnn10",withExtension:"mlmodelc"),let labels = Bundle.main.url(forResource:"PANNs-Labels",withExtension:"csv"),let mel = Bundle.main.url(forResource:"PANNs-Mel",withExtension:"json") else { throw EnvironmentalError.assets }
        return try PANNsModel(modelURL:url,labelsURL:labels,melURL:mel)
    }
    func analyze(samples:[Float]) throws -> [EnvironmentalScore] {
        guard !samples.isEmpty,samples.count <= 320000 else { throw ExperimentError.audio }
        var mean = [Double](repeating:0,count:527),windows = 0
        for start in stride(from:0,to:samples.count,by:160000) {
            try Task.checkCancellation()
            let features = try PANNsFeatures.extract(Array(samples[start..<min(start+160000,samples.count)]),weights:weights)
            let array = try MLMultiArray(shape:[1,1,501,64],dataType:.float32)
            for i in features.indices { array[i] = NSNumber(value:features[i]) }
            let result = try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["features":MLFeatureValue(multiArray:array)]))
            guard let scores = result.featureValue(for:"scores")?.multiArrayValue,scores.count == 527 else { throw ExperimentError.invalid }
            for i in mean.indices { let value = scores[i].doubleValue;guard value.isFinite,(0...1).contains(value) else { throw ExperimentError.invalid };mean[i] += value }
            windows += 1
        }
        guard mean.contains(where:{$0 > 0}) else { throw ExperimentError.invalid }
        return mean.indices.map { EnvironmentalScore(index:$0,label:labels[$0],score:mean[$0]/Double(windows)) }.sorted { $0.score > $1.score }
    }
}
