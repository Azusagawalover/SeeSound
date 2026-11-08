import SwiftUI
import UniformTypeIdentifiers

struct EnvironmentalPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var service: EnvironmentalService
    @State private var importingFile = false
    @State private var fileError:String?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        List {
            Section {
                SeeHero(title:"听见声音的不同",detail:"用公开录音查看两种模型的真实输出，不采集当前环境声音。",artwork:.headphone,eyebrow:"环境声音实验")
                Text("YAMNet（521类）与PANNs Cnn10（527类）在本机分析。实验不上传录音，也不生成正式提醒。").font(.caption).foregroundStyle(.secondary)
                Text("正式声音关注可在引擎设置中切换；新增引擎尚未验证居家准确率，不预设优于系统模型。").font(.caption).foregroundStyle(.secondary)
                Button("打开声音关注") { workspace.navigationRequest = .sound }
            }
            Section("选择公开录音") {
                Picker("分析模型",selection:Binding(get:{service.candidate},set:{service.selectCandidate($0)})) { ForEach(EnvironmentalCandidate.allCases) { Text($0.title).tag($0) } }.disabled(service.isBusy)
                Picker("样本", selection: Binding(get: { service.selectedID ?? "" }, set: { service.select($0) })) {
                    ForEach(service.clips) { clip in Text(clip.categoryTitle + " · " + clip.id).tag(clip.id) }
                }
                if let clip = service.clip {
                    Text("数据标注：" + clip.categoryTitle).font(.headline)
                    Text(clip.attribution).font(.caption).foregroundStyle(.secondary)
                    Text("ESC-50 第 5 折 · 公开录音 · 不使用当前麦克风").font(.caption).foregroundStyle(.secondary)
                }
                Button("在本机分析这段录音", systemImage: "cpu") { service.analyze() }.disabled(service.isBusy || service.clip == nil)
                if service.isBusy { ProgressView("正在分析"); Button("停止分析") { service.stop() } }
                Button("播放公开录音", systemImage: "play.circle") { workspace.audio.stopEverything(); workspace.hand.stop(); service.play() }.disabled(service.clip == nil)
                Button("停止播放") { service.stop() }
                Text(service.status).font(.footnote).foregroundStyle(.secondary)
            }
            Section("分析自己的短声音文件") {
                Button("选择本地声音文件",systemImage:"doc.badge.plus") { importingFile = true }.disabled(service.isBusy)
                Text("仅在你主动选择后读取。支持0.1–10秒、25MB以内的音频；在本机分析，原文件不进入样本库或备份。").font(.caption).foregroundStyle(.secondary)
                if let fileError { Text(fileError).foregroundStyle(.red) }
            }
            Section(service.candidate.title+" · 本段输出") {
                Text(service.inputTitle).font(.caption).foregroundStyle(.secondary)
                if service.scores.isEmpty { Text("分析后显示真实推理输出，不预填得分。").foregroundStyle(.secondary) }
                ForEach(service.scores) { score in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(score.title); Spacer(); Text(score.score, format: .number.precision(.fractionLength(3))).monospacedDigit() }
                        ProgressView(value: score.score)
                        if score.title != score.label { Text(score.label).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let elapsed = service.elapsedMS { Text("本次分析用时 \(elapsed, format: .number.precision(.fractionLength(0))) ms，包含必要加载和预处理；不是手机性能或节能基准。").font(.caption).foregroundStyle(.secondary) }
                Text("得分不是校准后的正确概率。YAMNet：16 kHz、约 0.975 秒窗口。PANNs：32 kHz、5 秒窗口、独立的功率谱与 mel 前处理；短片补零，长片分窗平均。").font(.caption).foregroundStyle(.secondary)
            }
            Section("重复检查 · 不采集声音") {
                Text("对目录前六段公开录音分别运行原始幅度与半幅输入，比较两种模型的输出与用时。不预填结果，不生成正式提醒。").font(.subheadline)
                Button("批量检查公开样本",systemImage:"checklist") { service.analyzeBatch() }.disabled(service.isBusy)
                if service.isBusy { Button("停止本次检查") { service.stop() } }
                ForEach(service.batchRows) { row in
                    VStack(alignment:.leading,spacing:6) {
                        Text(row.expected+" · "+row.condition).font(.headline)
                        Text(row.clipID).font(.caption).foregroundStyle(.secondary)
                        if let top = row.top { Text("最高输出：\(top.title) · 得分 \(top.score,format:.number.precision(.fractionLength(3)))") }
                        Text("本次 \(row.elapsedMS,format:.number.precision(.fractionLength(0))) ms").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("这里只改变数字幅度，不模拟真实房间噪声；模型类别与数据集标注也可能不同。记录用于排查与对照，不作为整体准确率或手机耗电结论。结果仅在本次运行保留。").font(.caption).foregroundStyle(.secondary)
            }
            Section("来源与范围") {
                Link("PANNs · 原始代码与模型",destination:URL(string:"https://github.com/qiuqiangkong/audioset_tagging_cnn")!)
                Text("PANNs 代码采用 MIT，权重采用 CC BY 4.0 许可，真实居家识别仍待验证。正式提醒保持现有轻量引擎，实验模型得分不会触发提醒。").font(.caption).foregroundStyle(.secondary)
                Link("Google YAMNet · 模型与预处理", destination: URL(string: "https://github.com/tensorflow/models/tree/master/research/audioset/yamnet")!)
                Link("Core ML 转换 · Yehor/YAMNet-CoreML", destination: URL(string: "https://huggingface.co/Yehor/YAMNet-CoreML/tree/9681162a6618cceb548ee2a94e83bcfb3a141066")!)
                Text("Apache-2.0 许可与模型版本记录保留在工程，公开声音继续遵循 ESC-50 的 CC BY-NC 3.0 署名要求。").font(.caption).foregroundStyle(.secondary)
            }
        }.seePageCanvas().navigationTitle("环境声音实验")
            .fileImporter(isPresented:$importingFile,allowedContentTypes:[.audio]) { result in
                switch result { case .success(let url):fileError = nil;service.analyzeFile(url);case .failure(let error):fileError = error.localizedDescription }
            }
            .onAppear { workspace.stop() }
            .onDisappear { service.stop() }
            .onChange(of: phase) { _, value in if value != .active { service.stop() } }
    }
}
