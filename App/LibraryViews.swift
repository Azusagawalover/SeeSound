import CodeScanner
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

struct PhraseLibraryPage: View {
    @ObservedObject var workspace: Workspace
    @State private var catalog: [VocablePhrase] = []
    @State private var search = ""
    @State private var group = "全部"
    @State private var error: String?
    private var filtered: [VocablePhrase] {
        catalog.filter { (group == "全部" || $0.group == group)
            && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.english.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        List {
            Section {
                Label("中文沟通模板", systemImage: "square.grid.2x2").font(.title2.bold())
                Text("来自 Vocable AAC 的预置短语与中文译文。先挑选，再按自己的表达习惯修改；收藏后才加入你的常用卡片。")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("我的收藏", value: "\(workspace.preferences.phrases.count) / \(PhraseCollection.limit)")
                Picker("场景", selection: $group) {
                    Text("全部").tag("全部")
                    ForEach(Array(Set(catalog.map(\.group))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section("\(filtered.count) 句可选表达") {
                ForEach(filtered) { phrase in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(phrase.text).font(.headline)
                            Text(phrase.english).font(.caption).foregroundStyle(.secondary)
                            Text(phrase.group).font(.caption2).foregroundStyle(Color.seeAccent)
                        }
                        Spacer()
                        let saved = workspace.preferences.phrases.contains(phrase.text)
                        Button {
                            workspace.addPhrases([SharedPhrase(text: phrase.text, category: .personal)])
                        } label: {
                            Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                                .font(.title2).frame(width: 44, height: 44)
                        }.buttonStyle(.borderless)
                            .disabled(saved || workspace.preferences.phrases.count >= PhraseCollection.limit)
                            .accessibilityLabel(saved ? "已收藏：\(phrase.text)" : "收藏：\(phrase.text)")
                    }.padding(.vertical, 5)
                }
            }
        }.seePageCanvas().navigationTitle("沟通模板库").searchable(text: $search, prompt: "搜索中文或英文")
            .task {
                do { catalog = try VocableCatalog.load().phrases }
                catch { self.error = "模板未能载入：\(error.localizedDescription)" }
            }
    }
}

struct PhraseTransferPage: View {
    @ObservedObject var workspace: Workspace
    @State private var selected = Set<String>()
    @State private var paste = ""
    @State private var showScanner = false
    @State private var pendingScan: String?
    @State private var incoming: PhraseBundle?
    @State private var sharedCode: GeneratedPhraseCode?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("导入卡片") {
                Button("扫描见声分享码", systemImage: "qrcode.viewfinder") {
                    workspace.hand.stop(); showScanner = true
                }
                Text("只读取见声沟通卡格式；扫码后先显示预览，由你确认导入。不会打开二维码中的网址。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("也可以在这里粘贴分享内容", text: $paste, axis: .vertical).lineLimit(2...5)
                    .onChange(of: paste) { _, value in if value.utf8.count > 4096 { paste = String(value.prefix(4096)) } }
                Button("预览粘贴内容") { preview(paste) }.disabled(paste.isEmpty)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section("选择要分享的卡片 · 最多 8 句") {
                ForEach(workspace.preferences.phrases, id: \.self) { phrase in
                    Toggle(phrase, isOn: Binding(get: { selected.contains(phrase) }, set: { value in
                        if value { selected.insert(phrase) } else { selected.remove(phrase) }
                    })).disabled(selected.count >= 8 && !selected.contains(phrase))
                }
                Button("生成分享码", systemImage: "qrcode") {
                    do {
                        let phrases = workspace.preferences.phrases.filter { selected.contains($0) }
                            .map { SharedPhrase(text: $0, category: workspace.preferences.category(for: $0)) }
                        sharedCode = GeneratedPhraseCode(text: try PhraseTransferCodec.encode(phrases)); error = nil
                    } catch { self.error = error.localizedDescription }
                }.disabled(selected.isEmpty)
                Text("二维码直接包含所选文字，请只向你愿意分享的人展示。它不建立设备配对或身份认证。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.seePageCanvas().navigationTitle("卡片扫码与分享")
            .fullScreenCover(isPresented: $showScanner, onDismiss: {
                if let pendingScan { preview(pendingScan); self.pendingScan = nil }
            }) {
                ScannerPage { text in pendingScan = text; showScanner = false }
            }
            .sheet(item: $sharedCode) { code in ShareCodePage(text: code.text) }
            .sheet(item: $incoming) { bundle in
                NavigationStack {
                    List {
                        Section {
                            Text("来源尚未验证，请先核对文字。重复卡片会跳过，收藏上限为 \(PhraseCollection.limit) 句。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(bundle.phrases) { phrase in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(phrase.text)
                                Text(workspace.preferences.phrases.contains(phrase.text) ? "已在收藏中，将跳过" : phrase.category.title)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Section {
                            Button("确认导入 \(importCount(bundle)) 张") {
                                workspace.addPhrases(bundle.phrases)
                                if workspace.storageMessage == nil { incoming = nil }
                            }.disabled(importCount(bundle) == 0)
                            if let message = workspace.storageMessage { Text(message).foregroundStyle(.red) }
                        }
                    }.seePageCanvas().navigationTitle("核对导入内容").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("取消") { incoming = nil } }
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { showScanner = false } }
    }

    private func importCount(_ bundle: PhraseBundle) -> Int {
        min(max(0, PhraseCollection.limit - workspace.preferences.phrases.count),
            bundle.phrases.filter { !workspace.preferences.phrases.contains($0.text) }.count)
    }
    private func preview(_ value: String) {
        do { incoming = try PhraseTransferCodec.decode(value); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct GeneratedPhraseCode: Identifiable {
    let id = UUID()
    let text: String
}

private struct ScannerPage: View {
    let found: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                #if targetEnvironment(simulator)
                ContentUnavailableView("请在真机扫描", systemImage: "qrcode.viewfinder",
                                       description: Text("模拟器不提供真实扫码输入。可返回使用粘贴导入检查卡片格式。"))
                #else
                ZStack(alignment: .bottom) {
                    CodeScannerView(codeTypes: [.qr], showViewfinder: true, requiresPhotoOutput: false,
                                    shouldVibrateOnSuccess: false) { result in
                        switch result {
                        case .success(let value): found(value.string)
                        case .failure(let failure): error = "无法扫描：\(failure.localizedDescription)"
                        }
                    }
                    if let error { Text(error).padding().background(.regularMaterial).padding() }
                }
                #endif
            }.seePageCanvas().navigationTitle("扫描沟通卡").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("取消") { dismiss() } }
        }
    }
}

private struct ShareCodePage: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    private var code: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 4, y: 4)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if let code {
                        Image(uiImage: code).interpolation(.none).resizable().scaledToFit()
                            .padding(20).background(.white).frame(maxWidth: 480)
                            .accessibilityLabel("包含所选沟通卡的二维码")
                    } else { Text("二维码未能生成，请减少选择的内容。") }
                    Text("用另一台设备上的见声扫描，核对后再导入。")
                    Text("下方文字也可以手动复制；内容会离开这台设备，请先确认愿意分享。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(text).font(.caption.monospaced()).textSelection(.enabled)
                }.padding(24)
            }.seePageCanvas().navigationTitle("沟通卡分享码").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}

struct OfflineSpeechPage: View {
    @ObservedObject var service: OfflineSpeechBridge
    @ObservedObject var audio: AudioProbes
    @State private var downloadConsent = false
    @State private var chooseFile = false
    @State private var added = false
    @State private var language = "zh"
    @State private var fileError: String?
    var body: some View {
        Form {
            Section {
                Label("WhisperKit 本机转写", systemImage: "waveform.badge.magnifyingglass").font(.headline)
                Text("将自己有权处理的音频文件转成文字。Base 均衡模型已内置，可直接本机准备；Tiny、Small 需主动联网下载。音频不上传。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(service.status).accessibilityIdentifier("speech.status")
                if service.isBusy {
                    if service.isReady { ProgressView("正在本机转写…") } else { ProgressView(value:service.progress) }
                    Button("停止等待结果", role: .destructive) { service.cancel() }
                }
            }
            Section("识别引擎") {
                Picker("多语言模型",selection:Binding(get:{service.selectedModel},set:{service.selectModel($0)})) { ForEach(SpeechModelChoice.allCases) { Text($0.title).tag($0) } }.disabled(service.isBusy).accessibilityIdentifier("speech.model")
                Text(service.selectedModel.detail).font(.caption).foregroundStyle(.secondary)
                if !service.isReady {
                    if service.hasCachedModel { Button(service.hasBundledBase ? "准备内置 Base 模型" : "从本地缓存准备") { service.prepare(allowDownload: false) }.disabled(service.isBusy) }
                    if !service.hasBundledBase { Button(service.hasCachedModel ? "联网修复 / 重新准备模型" : "下载并准备所选多语言模型") { downloadConsent = true }.disabled(service.isBusy) }
                } else {
                    Label("已就绪", systemImage: "checkmark.circle")
                    Button("释放引擎内存") { service.releaseMemory() }.disabled(service.isBusy)
                }
                Text("模型缓存可能占用数百 MB。下载不会读取或上传你的音频；退出页面会停止等待，部分缓存可能保留。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("本地音频") {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--speech-fixture"),let url = Bundle.main.url(forResource:"ValidationSpeech",withExtension:"aiff") {
                    Button("验证用合成语音转写") { service.transcribe(url,language:"en") }.disabled(!service.isReady || service.isBusy).accessibilityIdentifier("speech.fixture")
                }
                #endif
                Picker("音频语言", selection: $language) {
                    Text("中文").tag("zh")
                    Text("英语").tag("en")
                    Text("自动检测").tag("auto")
                }.disabled(service.isBusy)
                Button("选择音频文件", systemImage: "doc.badge.plus") { chooseFile = true }
                    .disabled(!service.isReady || service.isBusy)
                Text("支持5分钟、100 MB以内的音频。结果可能出错，请人工核对。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let fileError { Text(fileError).font(.footnote).foregroundStyle(.red) }
            }
            if !service.text.isEmpty {
                Section("转写结果 · 尚未加入对话") {
                    if let model = service.resultModel { Text("本次模型："+model).font(.caption).foregroundStyle(.secondary) }
                    Text(service.text).textSelection(.enabled).accessibilityIdentifier("speech.result")
                    DisclosureGroup("按时间核对转写片段") { ForEach(service.segments) { row in VStack(alignment:.leading,spacing:6) { Text("\(row.start,format:.number.precision(.fractionLength(1)))–\(row.end,format:.number.precision(.fractionLength(1))) 秒").font(.caption).monospacedDigit();Text(row.text).textSelection(.enabled);if row.needsReview { Label("建议重点复核，不代表一定错误",systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange) } } } }
                    NavigationLink("预览并分享转写文字") { SharePreviewPage(original:service.text) }
                    Button(added ? "已加入本次沟通" : "加入本次沟通（最多 500 字）") {
                        audio.addFileTranscript(service.text); added = true
                    }.disabled(added)
                    Text("结果不会自动加入事件历史或上传；加入后会标注文件转写来源。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.seePageCanvas().navigationTitle("音频文件转写")
            .onAppear { audio.stopEverything() }
            .onDisappear { service.cancel() }
            .confirmationDialog("联网准备本机模型？", isPresented: $downloadConsent, titleVisibility: .visible) {
                Button("开始下载与准备") { service.prepare(allowDownload: true) }
            } message: { Text("将从 Hugging Face 下载所选模型与分词器。所选模型：\(service.selectedModel.title)。\(service.selectedModel.detail)此步骤不上传音频。") }
            .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        added = false; fileError = nil
                        service.transcribe(url, language: language == "auto" ? nil : language)
                    }
                case .failure(let failure): fileError = "未能打开文件：\(failure.localizedDescription)"
                }
            }
    }
}

struct FeedbackPreviewPage: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.seeReduceMotion) private var reduceMotion
    @State private var animate = false
    var body: some View {
        Form {
            Section("采集状态动效") {
                ListeningAnimation(active: animate && !reduceMotion).frame(height: 160)
                Toggle("播放动效预览", isOn: $animate)
                Text(reduceMotion ? "已开启减少动态效果，预览保持静态。" : "仅预览视觉效果，不会开启麦克风或摄像头。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("轻量提示") {
                Button("预览提示浮层") { workspace.notify("这是提醒样式预览") }
                Text("真实确认和卡片收藏也会使用这个提示样式。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.seePageCanvas().navigationTitle("动效与提示")
    }
}
