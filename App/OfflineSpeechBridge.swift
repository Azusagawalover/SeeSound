import AVFoundation
import Combine
import CoreML
import Foundation
import WhisperKit

enum SpeechModelChoice: String, CaseIterable, Identifiable {
    case tiny, base, small
    var id:String { rawValue }
    var variant:String { "openai_whisper-"+rawValue }
    var title:String { switch self { case .tiny:return "Tiny · 轻量";case .base:return "Base · 内置均衡版";case .small:return "Small · 更大模型" } }
    var detail:String { switch self { case .tiny:return "约75 MB权重；速度优先，复杂中文可能漏错。";case .base:return "约145 MB权重；默认选项，仍需核对姓名和数字。";case .small:return "约485 MB权重；内存和准备时间更高，真机速度需检查。" } }
}
struct SpeechFileSegment: Identifiable {
    var id = UUID()
    var start:Float
    var end:Float
    var text:String
    var needsReview:Bool
}
@MainActor
final class OfflineSpeechBridge: ObservableObject {
    @Published private(set) var status = "先准备 Base 多语言模型，再导入音频。"
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var text = ""
    @Published private(set) var selectedModel:SpeechModelChoice = SpeechModelChoice(rawValue:UserDefaults.standard.string(forKey:"SeeSound.speechModel") ?? "base") ?? .base
    @Published private(set) var segments:[SpeechFileSegment] = []
    @Published private(set) var resultModel:String?
    private var engine: WhisperKit?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    private var cache: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeeSoundSpeech", isDirectory: true)
    }
    var hasBundledBase:Bool { selectedModel == .base && Bundle.main.url(forResource:"AudioEncoder",withExtension:"mlmodelc") != nil && Bundle.main.url(forResource:"TextDecoder",withExtension:"mlmodelc") != nil && Bundle.main.url(forResource:"MelSpectrogram",withExtension:"mlmodelc") != nil }
    private var modelFolder: URL {
        if hasBundledBase { return Bundle.main.resourceURL! }
        return cache.appendingPathComponent("models/argmaxinc/whisperkit-coreml/"+selectedModel.variant, isDirectory: true)
    }
    var hasCachedModel: Bool { ["AudioEncoder.mlmodelc","TextDecoder.mlmodelc","MelSpectrogram.mlmodelc"].allSatisfy { name in
        ["coremldata.bin","weights/weight.bin"].allSatisfy { path in ((try? modelFolder.appendingPathComponent(name+"/"+path).resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) > 0 }
    } }
    func selectModel(_ choice:SpeechModelChoice) {
        guard choice != selectedModel,!isBusy else { return }
        engine = nil;isReady = false;selectedModel = choice;UserDefaults.standard.set(choice.rawValue,forKey:"SeeSound.speechModel")
        status = "已选择 \(choice.title)，请准备该模型。已有转写保留其原模型标注。"
    }

    func prepare(allowDownload: Bool) {
        guard !isBusy else { return }
        let token = UUID(); generation = token
        let choice = selectedModel
        isBusy = true; progress = 0;isReady = false;engine = nil
        status = allowDownload ? "正在下载模型与分词器；此过程需要联网。" : "正在从本地缓存准备引擎；不会回退到网络。"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: self.cache, withIntermediateDirectories: true)
                var root = self.cache
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                let folder: URL
                if self.hasBundledBase { folder = self.modelFolder }
                else if allowDownload {
                    folder = try await WhisperKit.download(variant: choice.variant, downloadBase: self.cache,
                        useBackgroundSession: false) { [weak self] value in
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == token else { return }
                                self.progress = value.fractionCompleted
                            }
                        }
                } else {
                    guard self.hasCachedModel else { throw OfflineSpeechError.modelMissing }
                    folder = self.modelFolder
                }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.status = "正在载入 Core ML 模型；首次准备可能较慢。"
                var compute = ModelComputeOptions()
                // Core ML's CPU-only fp16 path produced degenerate decoder output
                // in numerical checks; use Metal for these fp16 networks.
                compute.melCompute = .cpuAndGPU;compute.audioEncoderCompute = .cpuAndGPU;compute.textDecoderCompute = .cpuAndGPU
                let loaded = try await WhisperKit(modelFolder: folder.path, tokenizerFolder: self.hasBundledBase ? Bundle.main.resourceURL!.appendingPathComponent("SpeechBaseTokenizer") : self.cache,computeOptions:compute,
                                                 verbose: false, prewarm: false, load: false, download: false)
                loaded.allowTokenizerDownload = allowDownload && !self.hasBundledBase
                try await loaded.loadModels()
                loaded.allowTokenizerDownload = false
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.engine = loaded
                self.isReady = true; self.isBusy = false; self.progress = 1
                self.status = "引擎已就绪；转写在本机进行，不上传音频。"
            } catch {
                guard self.generation == token else { return }
                self.isBusy = false
                self.status = "准备未完成：\(error.localizedDescription)"
            }
        }
    }

    func transcribe(_ url: URL, language: String? = "zh") {
        guard !isBusy, let engine else { status = "请先准备离线引擎。"; return }
        let token = UUID(); generation = token
        isBusy = true; text = "";segments = [];resultModel = nil
        status = "正在本机转写；原文件保持不变。"
        work = Task { [weak self] in
            guard let self else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.isFileURL else { throw OfflineSpeechError.file }
                let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard bytes > 0, bytes <= 100 * 1_024 * 1_024 else { throw OfflineSpeechError.file }
                let audio = try AVAudioFile(forReading: url)
                let seconds = Double(audio.length) / audio.fileFormat.sampleRate
                guard seconds.isFinite, seconds > 0, seconds <= 300 else { throw OfflineSpeechError.duration }
                let options = DecodingOptions(language: language, temperatureFallbackCount: 2,
                                              usePrefillPrompt: language != nil, detectLanguage: language == nil,
                                              skipSpecialTokens: true, withoutTimestamps: false,
                                              concurrentWorkerCount: 1)
                let samples = try await Task.detached(priority:.userInitiated) { try SpeechAudioReader.read(url) }.value
                try Task.checkCancellation()
                let results: [TranscriptionResult] = try await engine.transcribe(audioArray:samples,decodeOptions:options)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let result = results.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.isEmpty || SpeechTranscriptPolicy.hasReadableContent(result) else { throw OfflineSpeechError.unreliable }
                self.text = String(result.prefix(12_000))
                self.resultModel = self.selectedModel.title
                self.segments = Array(results.flatMap(\.segments).filter { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.prefix(300)).map { .init(start:$0.start,end:$0.end,text:$0.text,needsReview:$0.avgLogprob < -1 || $0.noSpeechProb > 0.5 || $0.compressionRatio > 2.4) }
                self.isBusy = false
                self.status = result.isEmpty ? "未获得文字；请检查音频内容。" : "转写完成，请先核对文字；结果最多显示12000字，分段时间与疑似低质量片段可展开核对。"
            } catch {
                guard self.generation == token else { return }
                self.isBusy = false
                self.status = "转写未完成：\(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        generation = UUID(); work?.cancel(); work = nil
        isBusy = false
        status = "已停止等待结果；下载过的模型文件可能仍在缓存中。"
    }

    func releaseMemory() {
        guard !isBusy else { return }
        engine = nil; isReady = false
        status = "已释放引擎；磁盘模型仍可供下次准备。"
    }
}

private enum OfflineSpeechError: LocalizedError {
    case modelMissing, file, duration, unreliable
    var errorDescription: String? {
        switch self {
        case .unreliable: return "解码未产生可读文字，已拒绝把重复符号当作转写。请尝试其他模型或更清晰的片段。"
        case .modelMissing: return "没有找到完整的本地模型，请使用联网准备。"
        case .file: return "请选择不超过100 MB 的本地音频文件。"
        case .duration: return "本轮支持 5分钟以内的音频，请先截取需要的片段。"
        }
    }
}


private enum SpeechAudioReader {
    static func read(_ url:URL) throws -> [Float] {
        let file = try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false)
        let duration = Double(file.length)/file.processingFormat.sampleRate
        guard duration.isFinite,duration > 0,duration <= 300,file.processingFormat.channelCount <= 8,
              let input = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false),
              let output = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(ceil(duration*16000)+64)),
              let converter = AVAudioConverter(from:file.processingFormat,to:format) else { throw OfflineSpeechError.file }
        try file.read(into:input)
        var supplied = false,failure:NSError?
        let result = converter.convert(to:output,error:&failure) { _,status in
            if supplied { status.pointee = .endOfStream;return nil }
            supplied = true;status.pointee = .haveData;return input
        }
        guard result != .error,failure == nil,output.frameLength > 0,let channel = output.floatChannelData?[0] else { throw OfflineSpeechError.file }
        let samples = Array(UnsafeBufferPointer(start:channel,count:Int(output.frameLength)))
        guard samples.allSatisfy(\.isFinite) else { throw OfflineSpeechError.file };return samples
    }
}
