import AVFoundation
import Combine
import QuartzCore
import Vision

private final class CapturePermit {
    private let lock = NSLock()
    private var allowed = true
    var isAllowed: Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    func cancel() { lock.lock(); allowed = false; lock.unlock() }
}

/// Capture and keypoint handling adapted from Apple's Detecting Hand Poses sample.
/// WaveWindow is an experimental heuristic, not Apple's original pinch gesture.
final class HandProbe: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var status = "摄像头未开启"
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var points: [CGPoint] = []
    @Published private(set) var captureStartedAt:Date?
    @Published private(set) var lastFrameAt:Date?
    @Published private(set) var lastHandAt:Date?
    let session = AVCaptureSession()
    var onWave: (() -> Void)?

    private let captureQueue = DispatchQueue(label: "SeeSound.camera.capture")
    private let frameQueue = DispatchQueue(label: "SeeSound.camera.frames")
    private var generation = UUID()
    private var capturePermit = CapturePermit()
    private var framePermit = CapturePermit()
    private var frameTime = 0.0
    private var window = WaveWindow()
    private var interruptionToken: NSObjectProtocol?
    private var errorToken: NSObjectProtocol?
    private let poseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()

    override init() {
        super.init()
        interruptionToken = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
        ) { [weak self] _ in self?.stop(reason: "摄像头被中断，请回到前台后手动开启") }
        errorToken = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] _ in self?.stop(reason: "摄像头出现错误，请检查设备后重试") }
    }

    @MainActor func start() async {
        #if targetEnvironment(simulator)
        status = "模拟器没有可验证的摄像头输入，请在 iPhone 或 iPad 运行"
        return
        #else
        stop()
        let token = generation
        let permit = capturePermit
        isStarting = true
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard generation == token else { return }
        guard allowed else { isStarting = false; status = "摄像头未授权，可在系统设置中开启"; return }
        lastFrameAt = nil;lastHandAt = nil
        status = "正在准备前置摄像头"
        captureQueue.async { [weak self] in
            guard let self, permit.isAllowed else { return }
            do {
                try self.configureSession()
                guard permit.isAllowed else { return }
                self.frameQueue.sync { self.window.reset(); self.frameTime = 0; self.framePermit = permit }
                self.session.startRunning()
                DispatchQueue.main.async {
                    guard self.generation == token, permit.isAllowed else { return }
                    self.isStarting = false
                    self.isRunning = true;self.captureStartedAt = Date()
                    self.status = "摄像头开启；请将张开的手掌放入画面"
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.isStarting = false
                    self.status = "摄像头无法开始：\(error.localizedDescription)"
                }
            }
        }
        #endif
    }

    func stop(reason: String = "摄像头已停止") {
        assert(Thread.isMainThread)
        capturePermit.cancel()
        capturePermit = CapturePermit()
        generation = UUID()
        isRunning = false;captureStartedAt = nil
        isStarting = false
        points = []
        status = reason
        captureQueue.async { [weak self] in self?.session.stopRunning() }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .medium
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw NSError(domain: "SeeSound.Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "前置摄像头不可用"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "SeeSound.Camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法配置摄像头"])
        }
        session.addInput(input)
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        let permit = framePermit
        guard permit.isAllowed else { return }
        guard now - frameTime >= 0.10 else { return }
        frameTime = now
        do {
            try VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up).perform([poseRequest])
            guard let hand = poseRequest.results?.first else { publishMissing(); return }
            let all = try hand.recognizedPoints(.all)
            let needed: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexMCP, .littleMCP]
            guard needed.allSatisfy({ (all[$0]?.confidence ?? 0) >= 0.45 }),
                  let wrist = all[.wrist]?.location, let left = all[.indexMCP]?.location,
                  let right = all[.littleMCP]?.location else { publishMissing(); return }
            let width = hypot(left.x - right.x, left.y - right.y)
            let fingers: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
                (.indexTip, .indexMCP), (.middleTip, .middleMCP), (.ringTip, .ringMCP), (.littleTip, .littleMCP)]
            let extended = fingers.filter { tip, base in
                guard let t = all[tip], let b = all[base], t.confidence > 0.45, b.confidence > 0.45 else { return false }
                return hypot(t.location.x - wrist.x, t.location.y - wrist.y)
                    > 1.35 * hypot(b.location.x - wrist.x, b.location.y - wrist.y)
            }.count
            let wave: Bool
            if extended >= 3 {
                wave = window.ingest(x: Double(wrist.x), palmWidth: Double(width), time: now)
            } else { window.reset(); wave = false }
            let visible = all.values.filter { $0.confidence >= 0.45 }.map(\.location)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.capturePermit === permit, permit.isAllowed else { return }
                self.lastFrameAt = Date();self.lastHandAt = Date()
                self.points = visible
                self.status = extended >= 3 ? "检测到张开的手；尝试连续左右挥动" : "检测到手；请张开手掌"
                if wave { self.status = "检测到挥手样式（实验规则）"; self.onWave?() }
            }
        } catch { publishMissing() }
    }

    private func publishMissing() {
        let permit = framePermit
        window.reset()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, self.capturePermit === permit, permit.isAllowed else { return }
            self.lastFrameAt = Date()
            self.points = []
            self.status = "未获得清晰手部关键点；不代表没有人在场"
        }
    }
}
