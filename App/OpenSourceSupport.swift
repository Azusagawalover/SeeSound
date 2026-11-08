import AVFoundation
import DSWaveformImage
import DSWaveformImageViews
import Lottie
import SwiftUI

struct ListeningAnimation: UIViewRepresentable {
    let active: Bool
    func makeUIView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView(name: "ListeningPulse")
        view.loopMode = .loop
        view.contentMode = .scaleAspectFit
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: LottieAnimationView, context: Context) {
        if active {
            if !view.isAnimationPlaying { view.play() }
        } else { view.stop(); view.currentProgress = 0.3 }
    }
}

struct InputSignalView: View {
    @ObservedObject var audio: AudioProbes
    @Environment(\.seeReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if audio.mode != .idle && !reduceMotion {
                    ListeningAnimation(active: true).frame(width: 40, height: 40)
                } else { Image(systemName: "waveform").foregroundStyle(Color.seeAccent).frame(width: 40, height: 40) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("输入波形").font(.headline)
                    Text(audio.mode == .idle ? "等待你开启麦克风" : "当前相对幅度 · 不保存录音")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if audio.levels.isEmpty {
                RoundedRectangle(cornerRadius: 2).fill(Color.seeAccent.opacity(0.15)).frame(height: 2).padding(.vertical, 25)
            } else {
                WaveformLiveCanvas(samples: audio.levels,
                    configuration: Waveform.Configuration(style: .striped(.init(color: .systemTeal, width: 3, spacing: 2))),
                    shouldDrawSilencePadding: true).frame(height: 52)
            }
        }.accessibilityElement(children: .combine)
            .accessibilityLabel(audio.mode == .idle ? "输入波形，麦克风关闭" : "输入波形，麦克风采集中；这是相对幅度，不是校准分贝")
    }
}

struct AdoptedLibrary: Identifiable {
    let name: String
    let version: String
    let purpose: String
    let url: String
    var id: String { name }
    static let all: [AdoptedLibrary] = [
        .init(name:"PANNs Cnn10",version:"Zenodo 3987831",purpose:"527类公开声音对照；代码MIT、权重CC BY 4.0；原作者Qiuqiang Kong等，本项目转换为Core ML并实现Swift前处理",url:"https://zenodo.org/records/3987831"),
        .init(name: "YAMNet", version: "Core ML 9681162", purpose: "本机 521 类环境声音分析，来源 Google 模型及 Yehor 的 Core ML 转换", url: "https://huggingface.co/Yehor/YAMNet-CoreML/tree/9681162a6618cceb548ee2a94e83bcfb3a141066"),
        .init(name: "SwiftUI-Flow", version: "3.1.1", purpose: "场景和事件行动卡中的自适应换行按钮布局", url: "https://github.com/tevelee/SwiftUI-Flow"),
        .init(name: "GRDB", version: "6.29.3", purpose: "事件数据库、事务与旧 JSON 迁移", url: "https://github.com/groue/GRDB.swift"),
        .init(name: "DSWaveformImage", version: "14.2.2", purpose: "真实麦克风输入的相对幅度波形", url: "https://github.com/dmrschmidt/DSWaveformImage"),
        .init(name: "Lottie", version: "4.4.3", purpose: "采集时的脉冲动画；动画素材由本项目制作", url: "https://github.com/airbnb/lottie-ios"),
        .init(name: "PopupView", version: "3.0.1", purpose: "确认、收藏和导入后的轻量反馈", url: "https://github.com/exyte/PopupView"),
        .init(name: "CodeScanner", version: "2.5.2", purpose: "扫码导入沟通卡，先预览再确认", url: "https://github.com/twostraws/CodeScanner"),
        .init(name:"Whisper Base",version:"pinned Core ML / portable I/O",purpose:"内置多语言文件转写；OpenAI预训练权重，Argmax转换，本项目适配Core ML边界与文件读取；MIT",url:"https://github.com/openai/whisper"),
        .init(name: "WhisperKit", version: "0.8.0", purpose: "可选的本机音频文件转写；模型需另行准备", url: "https://github.com/argmaxinc/argmax-oss-swift"),
        .init(name: "Vocable AAC", version: "58ba45a", purpose: "复用其中文预置短语与分类资源", url: "https://github.com/willowtreeapps/vocable-ios"),
        .init(name: "swift-transformers", version: "0.1.7", purpose: "WhisperKit 的分词器与模型资源支持", url: "https://github.com/huggingface/swift-transformers"),
        .init(name: "SwiftUI Introspect", version: "1.3.0", purpose: "PopupView 的界面支持依赖", url: "https://github.com/siteline/swiftui-introspect"),
    ]
}
