import Combine
import Foundation
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit
import Vision

enum WorkroomImport {
    static func image(_ data:Data) throws -> String { try imageEvidence(data).text }
    static func imageEvidence(_ data:Data) throws -> WorkroomReadResult {
        guard !data.isEmpty,data.count <= 20*1024*1024 else { throw WorkroomError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:3200,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { throw WorkroomError.unreadable }
        let regions = try recognizeRegions(image),text = try bounded(regions.map(\.text).joined(separator:"\n"))
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded,"public.jpeg" as CFString,1,nil) else { throw WorkroomError.unreadable }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw WorkroomError.unreadable }
        let evidence = WorkroomVisualEvidence(image:encoded as Data,regions:regions,originalText:text);try evidence.validate()
        return .init(text:text,visual:evidence)
    }
    static func recognizeRegions(_ image:CGImage) throws -> [OCRTextRegion] {
        let full = CGRect(x:0,y:0,width:image.width,height:image.height)
        var rows = try pass(image,rect:full,full:full,label:"原图准确模式")
        // A separate contrast pass can recover dim strokes; original evidence is unchanged.
        if rows.isEmpty || rows.contains(where:{ ($0.confidence ?? 1) < 0.65 }) {
            let filter = CIFilter.colorControls();filter.inputImage = CIImage(cgImage:image);filter.contrast = 1.15;filter.saturation = 0
            if let output = filter.outputImage,let adjusted = CIContext(options:[.cacheIntermediates:false]).createCGImage(output,from:output.extent) { merge(try pass(adjusted,rect:full,full:full,label:"对比度复核"),into:&rows) }
        }
        // High-resolution overlapping tiles recover small text on long notices.
        if image.height > 1400 || image.width > 1800 {
            let vertical = image.height >= image.width
            for offset in [0.0,0.44] {
                try Task.checkCancellation()
                let rect = vertical ? CGRect(x:0,y:Double(image.height)*offset,width:Double(image.width),height:Double(image.height)*0.56).integral.intersection(full) : CGRect(x:Double(image.width)*offset,y:0,width:Double(image.width)*0.56,height:Double(image.height)).integral.intersection(full)
                guard let crop = image.cropping(to:rect) else { continue }
                merge(try pass(crop,rect:rect,full:full,label:"分区小字复核"),into:&rows)
            }
        }
        // Keep a deterministic row-major order; multi-column text still needs manual review.
        return rows.sorted { a,b in abs(a.y-b.y) < min(a.height,b.height)*0.45 ? a.x < b.x : a.y > b.y }
    }
    private static func pass(_ image:CGImage,rect:CGRect,full:CGRect,label:String) throws -> [OCRTextRegion] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest();request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans","en-US"];request.usesLanguageCorrection = true;request.minimumTextHeight = 0.003
        request.customWords = ["学生证","校园卡","补办","教务处","学工处","服务中心"]
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request]);try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            let candidates = observation.topCandidates(3)
            guard let first = candidates.first,!first.string.isEmpty else { return nil }
            let box = observation.boundingBox
            return OCRTextRegion(text:first.string,confidence:Double(first.confidence),alternatives:Array(candidates.dropFirst().map(\.string)),recognitionPass:label,x:(rect.minX+box.minX*rect.width)/full.width,y:1-(rect.minY+rect.height)/full.height+box.minY*rect.height/full.height,width:box.width*rect.width/full.width,height:box.height*rect.height/full.height)
        }
    }
    private static func merge(_ incoming:[OCRTextRegion],into rows:inout [OCRTextRegion]) {
        for candidate in incoming {
            let box = CGRect(x:candidate.x,y:candidate.y,width:candidate.width,height:candidate.height)
            if let index = rows.firstIndex(where:{ row in
                let old = CGRect(x:row.x,y:row.y,width:row.width,height:row.height),overlap = old.intersection(box)
                return !overlap.isNull && overlap.width*overlap.height/max(0.000001,min(old.width*old.height,box.width*box.height)) > 0.65
            }) {
                if (candidate.confidence ?? 0) > (rows[index].confidence ?? 0)+0.03 && candidate.text.count >= rows[index].text.count { rows[index] = candidate }
            } else { rows.append(candidate) }
        }
    }
    static func recognize(_ image: CGImage) throws -> String {
        return try bounded(recognizeRegions(image).map(\.text).joined(separator:"\n"))
    }
    static func file(_ url: URL, selectedPages: [Int]? = nil) throws -> String {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL else { throw WorkroomError.unreadable }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 20*1024*1024 else { throw WorkroomError.tooLarge }
        switch url.pathExtension.lowercased() {
        case "txt": return try bounded(String(contentsOf: url, encoding: .utf8))
        case "pdf":
            guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { throw WorkroomError.unreadable }
            let selected = selectedPages ?? Array(0..<document.pageCount)
            guard !selected.isEmpty, selected.count <= 12, Set(selected).count == selected.count, selected.allSatisfy({ (0..<document.pageCount).contains($0) }) else { throw WorkroomError.tooLarge }
            var pages: [String] = []
            for index in selected.sorted() {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { throw WorkroomError.unreadable }
                let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !embedded.isEmpty { pages.append("【第 \(index+1) 页】\n"+embedded) }
                else {
                    let bounds = page.bounds(for: .mediaBox)
                    guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { throw WorkroomError.unreadable }
                    let scale = min(2, 2000 / max(bounds.width, bounds.height))
                    guard let context = CGContext(data: nil, width: max(1,Int(bounds.width*scale)), height: max(1,Int(bounds.height*scale)), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WorkroomError.unreadable }
                    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: bounds.width*scale, height: bounds.height*scale))
                    context.scaleBy(x: scale, y: scale); context.translateBy(x: -bounds.minX, y: -bounds.minY); page.draw(with: .mediaBox, to: context)
                    guard let image = context.makeImage() else { throw WorkroomError.unreadable }
                    pages.append("【第 \(index+1) 页】\n"+(try recognize(image)))
                }
                if pages.joined(separator: "\n").count > 12000 { throw WorkroomError.tooLarge }
            }
            return try bounded(pages.joined(separator: "\n\n"))
        default: return try image(Data(contentsOf: url))
        }
    }
    private static func bounded(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WorkroomError.empty }; guard text.count <= 12000 else { throw WorkroomError.tooLarge }; return text
    }
}

@MainActor
final class WorkroomImporter: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var result: String?
    @Published private(set) var resultID:UUID?
    @Published private(set) var visual:WorkroomVisualEvidence?
    @Published private(set) var failure:String?
    @Published private(set) var origin: ConversationOrigin = .documentText
    @Published private(set) var status = "导入后先核对文字；原图片和文件不长期保存在应用内。"
    private var generation = UUID()
    private var operation: Task<Void,Never>?
    private var retryOperation:(() throws -> WorkroomReadResult)?
    func load(file: URL) { run(origin: ["pdf","txt"].contains(file.pathExtension.lowercased()) ? .documentText : .imageText) { WorkroomReadResult(text:try WorkroomImport.file(file)) } }
    func load(pdf: Data, pages:[Int]) { run(origin:.documentText) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        defer { try? FileManager.default.removeItem(at:url) };try pdf.write(to:url,options:.atomic);return WorkroomReadResult(text:try WorkroomImport.file(url,selectedPages:pages))
    } }
    func load(image: Data) { run(origin: .imageText) { try WorkroomImport.imageEvidence(image) } }
    private func run(origin: ConversationOrigin, operation: @escaping () throws -> WorkroomReadResult) {
        cancel();retryOperation = operation; self.origin = origin; isBusy = true; let token = generation; status = "正在本机读取与识字，不发送到网络…"
        let worker = Task.detached(priority: .userInitiated) { try operation() }
        self.operation = Task { [weak self] in
            do {
                let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.visual = text.visual;self.resultID = token;self.result = text.text;self.failure = nil; self.isBusy = false; self.status = "读取完成，请检查姓名、数字和日期，再明确使用这些文字。";if let visual = text.visual { let weak = visual.regions.filter { ($0.confidence ?? 1) < 0.65 }.count;if weak > 0 { self.status += " 有 \(weak) 行识字置信度较低，可到原图对照中重点检查。" } }
            } catch { guard let self, self.generation == token else { return }; self.isBusy = false;self.failure = error.localizedDescription; self.status = error.localizedDescription }
        }
    }
    func retry() { guard let work = retryOperation else { return };run(origin:origin,operation:work) }
    func cancel() { retryOperation = nil;generation = UUID(); operation?.cancel(); operation = nil; isBusy = false;resultID = nil; result = nil;visual = nil;failure = nil }
}
