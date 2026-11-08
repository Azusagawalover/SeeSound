import AVFoundation
import Combine
import Foundation

@MainActor
final class EnvironmentalService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var batchRows:[PublicProbeResult] = []
    @Published private(set) var clips: [PublicSoundClip] = []
    @Published private(set) var scores: [EnvironmentalScore] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var inputTitle = "尚未分析"
    @Published private(set) var isBusy = false
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsedMS: Double?
    @Published private(set) var status = "公开样本只用于检查模型，不生成正式提醒。"
    @Published private(set) var candidate:EnvironmentalCandidate = .panns
    private let runner = EnvironmentRunner()
    private var operation: Task<Void,Never>?
    private var generation = UUID()
    private var player: AVAudioPlayer?
    override init() {
        super.init()
        do {
            guard let url = Bundle.main.url(forResource: "ESC50-Catalog", withExtension: "json") else { throw EnvironmentalError.assets }
            let catalog = try JSONDecoder().decode(PublicSoundCatalog.self, from: Data(contentsOf: url))
            try catalog.validate(); clips = catalog.clips; selectedID = clips.first?.id
        } catch { status = "公开样本目录未能读取：\(error.localizedDescription)" }
    }
    func selectCandidate(_ value:EnvironmentalCandidate) { guard !isBusy,value != candidate else { return };stop();candidate = value;scores = [];elapsedMS = nil }
    var clip: PublicSoundClip? { clips.first { $0.id == selectedID } }
    func select(_ id: String) { guard clips.contains(where: { $0.id == id }) else { return }; stop(); selectedID = id; scores = []; elapsedMS = nil }
    private func url() throws -> URL {
        guard let clip, let url = Bundle.main.url(forResource: clip.id, withExtension: nil, subdirectory: "PublicAudio") else { throw ExperimentError.audio }
        return url
    }
    func analyze() {
        stop(); scores = []; elapsedMS = nil;inputTitle = clip.map { "公开样本 · "+$0.categoryTitle } ?? "公开样本"
        let token = generation; isBusy = true; status = "正在本机运行所选声音模型；不使用麦克风。"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try self.url(), start = CFAbsoluteTimeGetCurrent()
                let output = try await self.runner.analyze(url: url,candidate:self.candidate)
                guard self.generation == token, !Task.isCancelled else { return }
                self.scores = Array(output.prefix(8)); self.elapsedMS = (CFAbsoluteTimeGetCurrent()-start)*1000
                self.status = "本段公开录音分析完成。显示模型得分，不是校准后的正确概率。"
            } catch { if self.generation == token { self.status = "分析未完成：\(error.localizedDescription)" } }
            if self.generation == token { self.isBusy = false }
        }
    }
    func analyzeFile(_ url:URL) {
        guard !isBusy else { return };stop();scores = [];elapsedMS = nil;inputTitle = "本地文件 · "+String(url.lastPathComponent.prefix(80))
        let token = generation,candidate = candidate;isBusy = true;status = "在本机分析所选文件，不上传、不保存原音频。"
        operation = Task { [weak self] in
            guard let self else { return }
            let access = url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.isFileURL,let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size > 0,size <= 25000000 else { throw ExperimentError.audio }
                let start = CFAbsoluteTimeGetCurrent(),output = try await self.runner.analyze(url:url,candidate:candidate)
                guard self.generation == token,!Task.isCancelled else { return }
                self.scores = Array(output.prefix(8));self.elapsedMS = (CFAbsoluteTimeGetCurrent()-start)*1000
                self.status = "文件分析完成。结果仅本次运行，不形成提醒；模型可能判断错误。"
            } catch { if self.generation == token { self.status = "文件分析未完成："+error.localizedDescription } }
            if self.generation == token { self.isBusy = false }
        }
    }
    func analyzeBatch() {
        stop();batchRows = [];let token = generation;isBusy = true
        let selected = Array(clips.prefix(6))
        status = "正在检查公开样本的原始输入与半幅输入，不使用麦克风。"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                for clip in selected {
                    guard let url = Bundle.main.url(forResource:clip.id,withExtension:nil,subdirectory:"PublicAudio") else { throw ExperimentError.audio }
                    for gain:Float in [1,0.5] {
                        for candidate in EnvironmentalCandidate.allCases {
                        guard self.generation == token,!Task.isCancelled else { return }
                        let start = CFAbsoluteTimeGetCurrent()
                        let result = try await self.runner.analyze(url:url,gain:gain,candidate:candidate)
                        guard self.generation == token,!Task.isCancelled else { return }
                        self.batchRows.append(.init(clipID:clip.id,expected:clip.categoryTitle,condition:candidate.title+" · "+(gain == 1 ? "原始幅度" : "半幅输入（约 -6 dB）"),top:result.first,elapsedMS:(CFAbsoluteTimeGetCurrent()-start)*1000))
                    }
                }
                }
                self.status = "公开样本批量检查完成，\(self.batchRows.count) 次实际推理；不代表真实环境准确率。"
            } catch { if self.generation == token { self.status = "批量检查中止，已完成结果保留："+error.localizedDescription } }
            if self.generation == token { self.isBusy = false }
        }
    }
    func play() {
        player?.stop(); isPlaying = false
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default); try session.setActive(true)
            #endif
            let player = try AVAudioPlayer(contentsOf: url()); player.delegate = self
            guard player.play() else { throw ExperimentError.audio }
            self.player = player; isPlaying = true
        }
        catch { status = "公开录音未能播放：\(error.localizedDescription)" }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.isPlaying = false; self.player = nil
            if !flag { self.status = "公开录音播放未完成，请手动重试。" }
        }
    }
    func stop() { generation = UUID(); operation?.cancel(); operation = nil; if isBusy || isPlaying { status = "声音实验已停止，已有结果保留。" }; isBusy = false; player?.stop(); player = nil; isPlaying = false }
}


struct PublicProbeResult:Identifiable {
    var id = UUID()
    var clipID:String
    var expected:String
    var condition:String
    var top:EnvironmentalScore?
    var elapsedMS:Double
}
