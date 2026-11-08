import Foundation

enum PublicFeatureCodec {
    static let schema = "esc50-logmel16-v2"
    static let commit = "33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6"
    static func validate(_ features: [[Double]]) -> Bool {
        features.count == 64 && features.allSatisfy { $0.count == 16 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }
    }

}

struct PublicSoundClip: Codable, Identifiable {
    var id: String
    var label: SoundSampleLabel
    var category: String
    var fold: Int
    var sourceFile: String
    var duration: Double
    var sha256: String
    var features: [[Double]]
    var waveform: [Double]
    var attribution: String
    var categoryTitle: String {
        switch category {
        case "door_wood_knock": return "敲门"
        case "clapping": return "拍手"
        case "keyboard_typing": return "键盘声"
        case "vacuum_cleaner": return "吸尘器"
        default: return category
        }
    }
    var sourceURL: URL { URL(string: "https://freesound.org/s/\(sourceFile)/")! }
    func validate() throws {
        let mapping: [String: SoundSampleLabel] = ["door_wood_knock": .knock, "clapping": .clapping, "keyboard_typing": .other, "vacuum_cleaner": .other]
        guard id.count <= 80, id.hasSuffix(".wav"), id.hasPrefix("5-"),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
              mapping[category] == label, fold == 5, duration == 5,
              !sourceFile.isEmpty, sourceFile.count <= 20, sourceFile.allSatisfy(\.isNumber),
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }),
              waveform.count == 64, waveform.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              !attribution.isEmpty, attribution.count <= 1500,
              PublicFeatureCodec.validate(features) else { throw ExperimentError.invalid }
    }
}


/// Public audio provenance is independent of the removed neural experiment.
struct PublicSoundCatalog: Codable {
    var format: String
    var version: Int
    var commit: String
    var featureSchema: String
    var clips: [PublicSoundClip]
    func validate() throws {
        guard format == "SeeSoundPublicCatalog", version == 1, commit == PublicFeatureCodec.commit,
              featureSchema == PublicFeatureCodec.schema, clips.count == 24,
              Set(clips.map(\.id)).count == 24, Set(clips.map(\.sha256)).count == 24,
              [SoundSampleLabel.knock, .clapping, .other].allSatisfy({ label in clips.filter { $0.label == label }.count == 8 })
        else { throw ExperimentError.invalid }
        try clips.forEach { try $0.validate() }
    }
}
