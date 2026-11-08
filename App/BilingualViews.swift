import AVFoundation
import SwiftUI

@MainActor
private final class TranslationSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var status = "朗读尚未开始"
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ text: String, language: TranslationLanguage) {
        stop()
        guard let voice = AVSpeechSynthesisVoice(language: language.voice) else { status = "本机没有对应语言的声音，可在系统设置准备语音。"; return }
        do {
            let session = AVAudioSession.sharedInstance(); try session.setCategory(.playback, mode: .spokenAudio); try session.setActive(true)
            let utterance = AVSpeechUtterance(string: text); utterance.voice = voice; current = utterance; synthesizer.speak(utterance); status = "正在本机朗读译文"
        } catch { status = "朗读未开始：\(error.localizedDescription)" }
    }
    func stop() { current = nil; synthesizer.stopSpeaking(at: .immediate); status = "朗读已停止" }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor [weak self] in if self?.current === utterance { self?.current = nil; self?.status = "朗读完成" } } }
}

struct BilingualPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var api: IntelligenceService
    @StateObject private var speaker = TranslationSpeaker()
    @State private var text = ""
    @State private var target: TranslationLanguage = .english
    @State private var origin: ConversationOrigin = .typed
    @State private var consent = false
    @State private var configuration = false
    @State private var facing = false
    @State private var large = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("原文和译文，一起看清楚", systemImage: "character.bubble").font(.title2.bold())
                Text("主动发送这段文字到 DeepSeek 翻译；保留原文，不覆盖对话。译文不自动保存、发送或朗读。").foregroundStyle(.secondary)
                Button("服务配置") { configuration = true }
                TextEditor(text: $text).frame(minHeight: 160).padding(8).background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("待翻译原文")
                HStack { Text("\(text.count) / 1500 字"); Spacer(); Text(origin.informationSource) }.font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("使用工作室当前文字") { origin = workspace.workroom.active.origin; text = workspace.workroom.active.text }.disabled(workspace.workroom.active.text.isEmpty || workspace.workroom.active.text.count > 1500)
                    Button("演示句") { origin = .demonstration; text = "【演示】您好，我听不清楚。请把地点和时间写下来，谢谢。" }
                }.buttonStyle(.bordered)
                Picker("译为", selection: $target) { ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Toggle("同意将上面的原文发送到 DeepSeek 翻译", isOn: $consent)
                Button("生成译文", systemImage: "character.bubble.fill") { api.translate(TranslationRequest(text: text, target: target, origin: origin)) }
                    .buttonStyle(.borderedProminent).tint(SeePalette.button).disabled(!consent || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 1500 || api.isBusy)
                if api.isBusy { ProgressView("正在翻译"); Button("取消") { api.cancel() } }
                Text(api.status).font(.footnote).foregroundStyle(.secondary)
                if let translation = api.translation, let source = api.translationSource, source.text == text, source.target == target, source.origin == origin {
                    Toggle("面对面展示时翻转译文", isOn: $facing)
                    Toggle("更大文字", isOn: $large)
                    VStack(alignment: .leading, spacing: 12) { Text("原文").font(.caption).foregroundStyle(.secondary); Text(source.text).font(large ? .largeTitle : .title2).textSelection(.enabled) }.translationPanel()
                    VStack(alignment: .leading, spacing: 12) { Text(target.title).font(.caption).foregroundStyle(.secondary); Text(translation.text).font(large ? .largeTitle : .title2).textSelection(.enabled) }.translationPanel().rotationEffect(.degrees(facing ? 180 : 0))
                    Button("朗读译文", systemImage: "speaker.wave.2") { workspace.audio.stopEverything(); speaker.speak(translation.text, language: target) }.buttonStyle(.bordered)
                    Button("停止朗读") { speaker.stop() }
                    Text(speaker.status).font(.caption).foregroundStyle(.secondary)
                    ShareLink("主动导出原文与译文", item: (origin == .demonstration ? "【演示翻译】\n" : "") + "原文：\n" + source.text + "\n\n" + target.title + "（DeepSeek，需核对）：\n" + translation.text)
                    Text("请特别核对姓名、金额、日期与语气；译文不能代替专业口译。修改原文或目标语言会清除旧译文。").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(SeePalette.canvas).seePageCanvas().navigationTitle("双语沟通")
            .sheet(isPresented: $configuration) { IntelligenceConfiguration(service: api, onConfigure: workspace.configureIntelligence) }
            .onAppear { workspace.stopCapture() }
            .onChange(of: text) { _, _ in api.cancel(); speaker.stop(); consent = false }
            .onChange(of: target) { _, _ in api.cancel(); speaker.stop(); consent = false }
            .onChange(of: origin) { _, _ in api.cancel(); speaker.stop(); consent = false }
            .onChange(of: phase) { _, value in if value != .active { api.cancel(); speaker.stop(); consent = false } }
            .onDisappear { api.cancel(); speaker.stop(); consent = false }
            .overlay { if phase != .active { DailyPrivacyCover() } }
    }
}

private extension View {
    func translationPanel() -> some View { padding(20).frame(maxWidth: .infinity, minHeight: 140, alignment: .leading).background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 20)) }
}
