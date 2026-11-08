import Foundation
import XCTest
import AppKit
@testable import SeeSoundData

final class ModelUpgradeTests:XCTestCase {
    private var root:URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private struct Reference:Decodable { var features:[Float];var scores:[Double] }
    private func waveform() -> [Float] {
        var state:UInt32 = 13
        return (0..<160000).map { i in
            state = 1664525 &* state &+ 1013904223
            let noise = (Double(state >> 8)/16777216-0.5)*0.002
            return Float(0.08*sin(2 * .pi * 440*Double(i)/32000)+noise)
        }
    }
    private func model() throws -> PANNsModel { try .init(modelURL:root.appendingPathComponent("Resources/PANNsCnn10.mlpackage"),labelsURL:root.appendingPathComponent("Resources/PANNs-Labels.csv"),melURL:root.appendingPathComponent("Resources/PANNs-Mel.json"),cpuOnly:true) }
    private func reference() throws -> Reference {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"PANNsReference",withExtension:"json",subdirectory:"Fixtures"));return try JSONDecoder().decode(Reference.self,from:Data(contentsOf:url))
    }
    func testPANNsFrontendMatchesOriginalTorchlibrosaPowerMelAndReflection() throws {
        let model = try model(),expected = try reference().features,actual = try PANNsFeatures.extract(waveform(),weights:model.weights)
        XCTAssertEqual(actual.count,expected.count)
        let error = zip(actual,expected).map { abs(Double($0-$1)) }.max() ?? .infinity
        print("PANNs native frontend maximum absolute error vs torchlibrosa: \(error)")
        XCTAssertLessThan(error,0.05)
    }
    func testPANNsNativeCoreMLPipelineMatchesPublishedCheckpoint() throws {
        let output = try model().analyze(samples:waveform()),expected = try reference().scores
        XCTAssertEqual(output.count,527)
        let error = output.map { abs($0.score-expected[$0.index]) }.max() ?? .infinity
        print("PANNs native Core ML maximum absolute score error vs PyTorch: \(error)")
        XCTAssertLessThan(error,0.025)
        XCTAssertEqual(output.first?.index,expected.indices.max(by:{expected[$0] < expected[$1]}))
    }
    func testPANNsRejectsBrokenFrontendInputs() throws {
        let weights = try model().weights
        XCTAssertThrowsError(try PANNsFeatures.extract([],weights:weights))
        XCTAssertThrowsError(try PANNsFeatures.extract([.nan],weights:weights))
        XCTAssertThrowsError(try PANNsFeatures.extract([0],weights:[]))
        XCTAssertThrowsError(try PANNsFeatures.extract([Float](repeating:0,count:160001),weights:weights))
    }
    func testEnhancedOCRRecognizesHighResolutionNoticeWithoutDuplicateRows() throws {
        let image = NSImage(size:NSSize(width:1800,height:2400));image.lockFocus()
        NSColor.white.setFill();NSRect(x:0,y:0,width:1800,height:2400).fill()
        let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:45),.foregroundColor:NSColor.black]
        ("Campus Service 123" as NSString).draw(at:NSPoint(x:120,y:2100),withAttributes:attributes)
        ("Bring your student card" as NSString).draw(at:NSPoint(x:120,y:1000),withAttributes:attributes)
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation),bitmap = try XCTUnwrap(NSBitmapImageRep(data:tiff)),data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:])),result = try WorkroomImport.imageEvidence(data)
        XCTAssertTrue(result.text.contains("Campus Service 123"),result.text)
        XCTAssertTrue(result.text.contains("Bring your student card"),result.text)
        let rows = try XCTUnwrap(result.visual?.regions);try result.visual?.validate()
        XCTAssertEqual(rows.filter{$0.text.contains("Campus Service")}.count,1)
        XCTAssertTrue(rows.allSatisfy{$0.confidence != nil})
    }
    func testDecoderFormatGuardRejectsRepeatedSymbolsAndPreservesReadableSpeech() {
        XCTAssertFalse(SpeechTranscriptPolicy.hasReadableContent("[ []] [] [] []"))
        XCTAssertFalse(SpeechTranscriptPolicy.hasReadableContent(" \n"))
        XCTAssertTrue(SpeechTranscriptPolicy.hasReadableContent("请带学生证"))
        XCTAssertTrue(SpeechTranscriptPolicy.hasReadableContent("啊啊啊啊"));XCTAssertTrue(SpeechTranscriptPolicy.hasReadableContent("好"));XCTAssertTrue(SpeechTranscriptPolicy.hasReadableContent("7"))
        XCTAssertTrue(SpeechTranscriptPolicy.hasReadableContent("Please bring your student card."))
    }
    func testLegacyOCRRegionsDecodeAndNewConfidenceIsValidated() throws {
        let old = "{\"id\":\"\(UUID())\",\"text\":\"原文\",\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.1}"
        var row = try JSONDecoder().decode(OCRTextRegion.self,from:Data(old.utf8));try row.validate();XCTAssertNil(row.confidence)
        row.confidence = 2;XCTAssertThrowsError(try row.validate())
    }
    @MainActor func testIdenticalNewImportsHaveDistinctReceiptsAndCancelClearsBoth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("notice.txt");try "材料：学生证".write(to:url,atomically:true,encoding:.utf8)
        let importer = WorkroomImporter();importer.load(file:url)
        for _ in 0..<200 { if !importer.isBusy { break };try await Task.sleep(for:.milliseconds(10)) }
        let first = try XCTUnwrap(importer.resultID);XCTAssertEqual(importer.result,"材料：学生证")
        importer.load(file:url)
        for _ in 0..<200 { if !importer.isBusy { break };try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotEqual(first,try XCTUnwrap(importer.resultID));XCTAssertEqual(importer.result,"材料：学生证")
        importer.cancel();XCTAssertNil(importer.resultID);XCTAssertNil(importer.result)
    }

}
