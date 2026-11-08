import Foundation
import XCTest
@testable import SeeSoundData

final class EnvironmentalIntegrationTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private struct Reference: Decodable {
        struct Signal: Decodable { var signal: String; var length: Int; var patches: [[Float]]; var meanScores: [Double] }
        var cases: [Signal]
    }
    private func reference() throws -> Reference {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "YAMNetReference", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }
    private func waveform(_ signal: Reference.Signal) -> [Float] {
        (0..<signal.length).map { index in
            let t = Double(index) / 16000
            switch signal.signal {
            case "tones": return Float(0.12 * sin(2 * .pi * 440 * t) + 0.07 * sin(2 * .pi * 1730 * t))
            case "sweep": return Float(0.2 * sin(2 * .pi * (150*t + 1800*t*t)) * exp(-2*t))
            default: return 0
            }
        }
    }
    func testFrontendMatchesGoogleTensorFlowPaddingHannMagnitudeAndMel() throws {
        var maximum = 0.0
        for signal in try reference().cases {
            let patches = try YAMNetFeatures.patches(waveform(signal))
            XCTAssertEqual(patches.count, signal.patches.count)
            for (actual, expected) in zip(patches, signal.patches) {
                XCTAssertEqual(actual.count, 6144)
                for (a, b) in zip(actual, expected) { maximum = max(maximum, abs(Double(a-b))) }
            }
        }
        print("YAMNet frontend maximum absolute error vs TensorFlow: \(maximum)")
        XCTAssertLessThan(maximum, 0.002)
    }
    func testCoreMLClassifierMatchesOfficialTensorFlowWeights() throws {
        let model = try YAMNetModel(modelURL: root.appendingPathComponent("Resources/YAMNet.mlpackage"), labelsURL: root.appendingPathComponent("Resources/YAMNet-Labels.csv"), cpuOnly: true)
        var maximum = 0.0
        for signal in try reference().cases {
            let output = try model.analyze(samples: waveform(signal))
            XCTAssertEqual(output.count, 521)
            for item in output { maximum = max(maximum, abs(item.score-signal.meanScores[item.index])) }
            XCTAssertEqual(output.first?.index, signal.meanScores.indices.max(by: { signal.meanScores[$0] < signal.meanScores[$1] }))
        }
        print("YAMNet Core ML maximum absolute score error vs TensorFlow: \(maximum)")
        XCTAssertLessThan(maximum, 0.025) // float16 model; this is numerical parity, not an accuracy benchmark.
    }
    func testPatchBoundariesRejectBadInputsAndCoverTail() throws {
        for (count, expected) in [(1,1),(15600,1),(15601,2),(23280,2),(23281,3),(160000,20)] {
            XCTAssertEqual(try YAMNetFeatures.patches([Float](repeating: 0, count: count)).count, expected)
        }
        XCTAssertThrowsError(try YAMNetFeatures.patches([]))
        XCTAssertThrowsError(try YAMNetFeatures.patches([.nan]))
        XCTAssertThrowsError(try YAMNetFeatures.patches([Float](repeating: 0, count: 160001)))
    }
    func testOnlySupportedLabelsMapToFormalReminderCategories() {
        XCTAssertEqual(EnvironmentalScore(index: 0, label: "Knock", score: 0.9).reminderLabel, "knock")
        XCTAssertEqual(EnvironmentalScore(index: 0, label: "Ding-dong", score: 0.9).reminderLabel, "doorbell")
        XCTAssertNil(EnvironmentalScore(index: 0, label: "Siren", score: 0.99).reminderLabel)
    }
}
