import AVFoundation
import Combine
import SoundAnalysis
import Speech
import UIKit

@MainActor
final class AudioProbes: NSObject, ObservableObject {
    enum Mode { case idle, sound, captions }
    @Published private(set) var mode: Mode = .idle
    @Published private(set) var captureStartedAt:Date?
    @Published private(set) var lastInputAt:Date?
    @Published private(set) var lastResultAt:Date?
    @Published private(set) var processingGaps = 0
    @Published private(set) var isStarting = false
    @Published private(set) var status = "尚未使用麦克风"
    @Published private(set) var soundResults: [(label: String, score: Double)] = []
    @Published private(set) var soundEngine: EnvironmentalEngine = .apple
    private let environmentalLive = EnvironmentalLiveService()
    @Published private(set) var transcript = ""
    @Published private(set) var isFinal = false
    @Published private(set) var conversation = ConversationSession()
    @Published private(set) var isScenarioDemo = false
    @Published private(set) var conversationEpoch = UUID()
    private var scenarioBackup = ConversationScenarioBackup()
    @Published private(set) var isSpeaking = false
    @Published private(set) var speechStatus = "朗读未开始"
    @Published private(set) var supportedSounds: [String] = []
    @Published private(set) var levels: [Float] = []
    @Published private(set) var continuousMode = false
    @Published private(set) var continuousActive = false
    @Published var selectedSpeakerName = "对方"
    private var captionPolicy = CaptionRunPolicy()
    private var nextSegment: Task<Void, Never>?
    private var captionDeadline: Task<Void, Never>?
    private var lastLevelAt: TimeInterval = 0
    var onSoundEvent: ((String, String) -> Void)?

    private var run = UUID()
    private var subscription: AnyCancellable?
    private var subject: PassthroughSubject<SNClassificationResult, Error>?
    private var speechEngine: AVAudioEngine?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var evidenceGate = SoundEvidenceGate()
    private var interruptionToken: NSObjectProtocol?

    override init() {
        super.init()
        synthesizer.delegate = self
        supportedSounds = ((try? SystemAudioClassifier.getAllPossibleLabels()) ?? []).sorted()
        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopEverything(reason: "音频被系统中断，请手动重新开始") }
        }
    }

    private func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission {
                    continuation.resume(returning: $0)
                }
            }
        @unknown default: return false
        }
    }

    func startSounds() async {
        guard !isScenarioDemo else { status = "请先结束场景演示，再开启真实采集"; return }
        #if targetEnvironment(simulator)
        status = "模拟器仅用于界面检查；声音识别请在真机开启"
        return
        #else
        stop()
        guard !evidenceGate.enabled.isEmpty else { status = "未选择关注声音，请先在「我的」中设置"; return }
        let token = run
        lastInputAt = nil;lastResultAt = nil;processingGaps = 0
        isStarting = true
        status = "正在检查麦克风权限"
        let permitted = await microphoneAllowed()
        guard token == run else { return }
        isStarting = false
        guard permitted else { status = "麦克风未授权，可在系统设置中开启"; return }
        if soundEngine == .yamnet {
            stopSpeaking(); isStarting = true; mode = .sound;captureStartedAt = Date(); soundResults = []
            status = "正在准备 YAMNet 本机模型；不保存录音"
            do {
                try await environmentalLive.start(onScores: { [weak self] scores, reset in
                    guard let self, self.run == token, self.mode == .sound else { return }
                    self.lastResultAt = Date()
                    if reset { self.processingGaps += 1;self.evidenceGate.reset(); self.soundResults = []; self.status = "YAMNet 处理跳过部分输入，连续判断已重置；可切回系统模型。"; return }
                    self.soundResults = Array(scores.prefix(3)).map { ($0.title, $0.score) }
                    guard let first = scores.first, let label = first.reminderLabel,
                          let kind = self.evidenceGate.accept(label: label, score: first.score) else { return }
                    self.onSoundEvent?(kind.rawValue, Self.title(for: kind.rawValue))
                }, onLevel: { [weak self] level in
                    guard let self, self.run == token, self.mode == .sound else { return }; self.publishLevel(level)
                }, onFailure: { [weak self] error in
                    guard let self, self.run == token else { return }; self.stop(reason: "YAMNet 分析停止：\(error.localizedDescription)")
                })
                guard run == token else { return }
                isStarting = false; status = "YAMNet 本机分析中；实验引擎，正式提醒仅限选中的三类"
            } catch { if run == token { stop(reason: "YAMNet 未能开启：\(error.localizedDescription)") } }
            return
        }
        guard !supportedSounds.isEmpty else { status = "系统声音模型未能加载"; return }
        stopSpeaking()
        soundResults.removeAll()
        let stream = PassthroughSubject<SNClassificationResult, Error>()
        subject = stream
        subscription = stream.receive(on: DispatchQueue.main).sink(
            receiveCompletion: { [weak self] completion in
                guard let self, self.run == token else { return }
                if case .failure(let error) = completion {
                    self.stop(reason: "声音识别停止：\(error.localizedDescription)")
                }
            }, receiveValue: { [weak self] result in
                guard let self, self.run == token, self.mode == .sound else { return }
                self.acceptSound(result)
            })
        mode = .sound;captureStartedAt = Date()
        status = "正在本机分析声音；不保存录音"
        SystemAudioClassifier.singleton.startSoundClassification(
            subject: stream, inferenceWindowSize: 1.5, overlapFactor: 0.5) { [weak self] level in
                Task { @MainActor [weak self] in
                    guard let self, self.run == token, self.mode == .sound else { return }
                    self.publishLevel(level)
                }
            }
        #endif
    }

    private func acceptSound(_ result: SNClassificationResult) {
        lastResultAt = Date()
        soundResults = result.classifications.prefix(3).map { ($0.identifier, $0.confidence) }
        guard let match = result.classifications.first,
              let kind = evidenceGate.accept(label: match.identifier, score: match.confidence) else { return }
        onSoundEvent?(kind.rawValue, Self.title(for: kind.rawValue))
    }

    func configure(sounds: Set<SoundKind>, sensitivity: DetectionSensitivity, engine: EnvironmentalEngine = .apple) {
        let changed = soundEngine != engine
        if changed { stop(reason: "声音引擎已切换，请手动开启识别"); soundEngine = engine }
        guard changed || evidenceGate.enabled != sounds || evidenceGate.sensitivity != sensitivity else { return }
        evidenceGate = SoundEvidenceGate(enabled: sounds, sensitivity: sensitivity)
        if sounds.isEmpty && mode == .sound { stop(reason: "未选择关注声音，识别已停止") }
    }

    static func title(for identifier: String) -> String {
        switch identifier {
        case "knock", "knocking": return "可能的敲门声"
        case "door_bell", "doorbell": return "可能的门铃声"
        case "clapping": return "可能的拍手声"
        case "speech": return "讲话声"
        case "music": return "音乐"
        case "silence": return "安静"
        default: return identifier
        }
    }

    func startCaptions() async {
        guard !isScenarioDemo else { status = "请先结束场景演示，再开启真实字幕"; return }
        stopEverything(reason: "正在准备字幕")
        let session = captionPolicy.begin()
        continuousActive = continuousMode
        captionDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_200_000_000_000) } catch { return }
            guard let self, self.captionPolicy.id == session else { return }
            self.stop(reason: "本次字幕达到 20 分钟上限，请手动重新开始")
        }
        await startCaptionSegment(session: session)
    }

    func setContinuousMode(_ enabled: Bool) {
        continuousMode = enabled
        if enabled && captionPolicy.id != nil { continuousActive = true }
        if !enabled {
            continuousActive = false; nextSegment?.cancel(); nextSegment = nil
            if mode != .captions && !isStarting { captionPolicy.cancel(); captionDeadline?.cancel(); captionDeadline = nil }
        }
    }

    private func startCaptionSegment(session: UUID) async {
        #if targetEnvironment(simulator)
        captionPolicy.cancel(); continuousActive = false; captionDeadline?.cancel()
        status = "模拟器仅用于界面检查；端侧字幕请在真机开启"
        return
        #else
        guard captionPolicy.id == session else { return }
        guard captionPolicy.next(session, foreground: UIApplication.shared.applicationState == .active) else {
            stop(reason: "连续字幕已暂停，或已达到时长 / 分段上限，请手动重新开始"); return
        }
        stop(reason: "正在准备下一段字幕", preserveContinuous: true)
        let token = run
        isStarting = true
        let mic = await microphoneAllowed()
        guard token == run else { return }
        guard mic else { stop(reason: "麦克风未授权"); return }
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard token == run else { return }
        isStarting = false
        guard permission == .authorized else { stop(reason: "语音识别未授权"); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            stop(reason: "本机暂不支持中文端侧识别；未切换到云端，可继续使用文字沟通")
            return
        }
        stopSpeaking()
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: [])
            try audio.setActive(true)
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "SeeSound.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "音频输入不可用"])
            }
            speechEngine = engine
            speechRequest = request
            speechRecognizer = recognizer
            transcript = ""
            isFinal = false
            let capture = conversation.beginCapture(speakerName: selectedSpeakerName)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let level = SignalMonitor.amplitude(buffer)
                Task { @MainActor [weak self] in
                    guard let self, self.run == token, self.mode == .captions else { return }
                    self.publishLevel(level)
                }
            }
            mode = .captions;captureStartedAt = Date()
            speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, self.run == token else { return }
                    if let result {
                    self.lastResultAt = Date()
                        self.transcript = String(result.bestTranscription.formattedString.prefix(ConversationSession.textLimit))
                        self.isFinal = result.isFinal
                        self.conversation.receive(self.transcript, capture: capture, isFinal: result.isFinal)
                        if result.isFinal {
                            let again = self.continuousMode && self.captionPolicy.id == session
                            self.stop(reason: again ? "本段已结束，正在继续下一段" : "本段已结束并留在对话中；点击继续可开始下一段", preserveContinuous: again)
                            if again {
                                self.nextSegment = Task { @MainActor [weak self] in
                                    do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                                    guard let self, self.captionPolicy.id == session, self.continuousMode else { return }
                                    await self.startCaptionSegment(session: session)
                                }
                            }
                        }
                    }
                    if let error, self.run == token {
                        self.stop(reason: "字幕识别停止：\(error.localizedDescription)")
                    }
                }
            }
            engine.prepare()
            try engine.start()
            status = "正在本机生成字幕；未上传音频"
        } catch { stop(reason: "字幕无法开始：\(error.localizedDescription)") }
        #endif
    }

    func stop(reason: String = "麦克风已停止", preserveContinuous: Bool = false) {
        environmentalLive.stop()
        if !preserveContinuous {
            captionPolicy.cancel(); continuousActive = false
            nextSegment?.cancel(); nextSegment = nil; captionDeadline?.cancel(); captionDeadline = nil
        }
        run = UUID()
        conversation.pauseCapture()
        isStarting = false
        subscription?.cancel()
        subscription = nil
        subject = nil
        if mode == .sound { SystemAudioClassifier.singleton.stopSoundClassification() }
        if let engine = speechEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        speechRequest?.endAudio()
        speechTask?.cancel()
        speechTask = nil
        speechRequest = nil
        speechRecognizer = nil
        speechEngine = nil
        if mode != .idle { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        mode = .idle;captureStartedAt = nil;lastInputAt = nil;lastResultAt = nil;processingGaps = 0
        levels.removeAll(); lastLevelAt = 0
        evidenceGate.reset()
        status = reason
    }

    func speak(_ text: String) {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !text.isEmpty else { return }
        stop(reason: "正在朗读；声音识别和字幕已暂停，结束后请手动重启")
        stopSpeaking()
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio)
            try audio.setActive(true)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            currentUtterance = utterance
            isSpeaking = true
            speechStatus = "正在朗读；麦克风已暂停"
            synthesizer.speak(utterance)
        } catch { speechStatus = "朗读不可用：\(error.localizedDescription)"; status = "麦克风已停止，可继续使用文字沟通" }
    }

    func stopSpeaking() {
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speechStatus = "朗读已停止"
        if mode == .idle { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    func stopEverything(reason: String = "采集与朗读已停止") {
        stop(reason: reason)
        stopSpeaking()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func clearTranscript() {
        stopEverything()
        status = "已停止字幕与朗读，并清除本页文字"
        transcript = ""
        isFinal = false
        conversation.clear()
        conversationEpoch = UUID()
    }

    @discardableResult
    func respond(_ text: String, aloud: Bool, origin: ConversationOrigin? = nil, replyEventTitle: String? = nil, assistedBy: String? = nil) -> Bool {
        guard conversation.reply(text, origin: isScenarioDemo ? .demonstration : origin ?? .typed, replyEventTitle: replyEventTitle, assistedBy: assistedBy) else { return false }
        if aloud { speak(text) }
        return true
    }

    @discardableResult
    func editTurn(_ id: UUID, text: String) -> Bool { conversation.edit(id, text: text) }

    @discardableResult
    func removeTurn(_ id: UUID) -> Bool { conversation.remove(id) }

    func addFileTranscript(_ text: String) { conversation.addFileTranscript(text) }
    @discardableResult
    func labelSpeaker(_ id: UUID, name: String) -> Bool { conversation.labelSpeaker(id, name: name) }
    func addDemonstration() { stopEverything(); conversation.addDemonstration() }
    func beginScenario(_ scenario: DemoScenario) {
        stopEverything()
        conversation = scenarioBackup.begin(scenario, current: conversation); isScenarioDemo = true
        conversationEpoch = UUID(); status = "场景演示 · 麦克风关闭"
    }
    func endScenario() {
        guard isScenarioDemo else { return }
        stopEverything(); conversation = scenarioBackup.end() ?? ConversationSession()
        isScenarioDemo = false; conversationEpoch = UUID()
        status = "演示已结束，原来的对话已恢复；麦克风保持关闭"
    }

    private func publishLevel(_ level: Float) {
        lastInputAt = Date()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelAt >= 0.1 else { return }
        lastLevelAt = now
        levels.append(1 - min(1, max(0, level)))
        if levels.count > 90 { levels.removeFirst(levels.count - 90) }
    }
}

extension AudioProbes: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            self.speechStatus = "朗读已结束；麦克风保持关闭"
            self.status = "麦克风已停止，需要时请手动继续"
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            self.speechStatus = "朗读已取消；麦克风保持关闭"
        }
    }
}
