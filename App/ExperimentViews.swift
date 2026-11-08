import Charts
import SwiftUI
import UniformTypeIdentifiers

struct ExperimentJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SoundSamplePage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var library: SoundSampleLibrary
    @State private var recordConsent = false
    @State private var importFile = false
    @State private var exportFile = false
    @State private var document = ExperimentJSONDocument(data: Data())
    @State private var label: SoundSampleLabel = .other
    @State private var note = ""
    @State private var keepAudio = false
    @State private var deletion: SoundSample?
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Label("把熟悉的声音，变成自己的样本", systemImage: "waveform.badge.plus").font(.headline)
                Text("先采集，再由你标注。样本用于后续实验，不会自动改变正式声音识别。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(library.status).font(.footnote)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("采集 · 0.5–5 秒") {
                if library.isRecording {
                    Label("录制中，最多 5 秒", systemImage: "record.circle").foregroundStyle(.red)
                    Button("结束录制，进入核对") { library.finishRecording() }
                    Button("取消并丢弃", role: .destructive) { library.cancelCapture() }
                } else {
                    Button("录制一个声音样本", systemImage: "mic.badge.plus") { recordConsent = true }.disabled(library.isBusy)
                    Button("从文件导入短音频", systemImage: "doc.badge.plus") { importFile = true }.disabled(library.isBusy)
                }
                if library.isBusy && !library.isRecording { ProgressView("处理音频") }
                Text("录制或导入后会暂存音频供试听；未保存的音频在离开页面或停止时丢弃。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let pending = library.pending {
                Section("保存前核对") {
                    LabeledContent("时长", value: String(format: "%.2f 秒", pending.sample.duration))
                    Button("试听这段音频", systemImage: "play.circle") { workspace.audio.stopEverything(); library.play() }
                    Picker("我确认的声音", selection: $label) { ForEach(SoundSampleLabel.allCases) { Text($0.title).tag($0) } }
                    TextField("备注（可选）", text: $note).onChange(of: note) { _, value in note = String(value.prefix(120)) }
                    Toggle("同时保留原音频，方便以后复核", isOn: $keepAudio)
                    Text("默认只保存特征和人工标签。打开后原音频也会保存在这台设备，删除样本时一起移除。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("确认标签并保存", systemImage: "checkmark.circle") {
                        library.save(label: label, note: note, keepAudio: keepAudio)
                        if library.pending == nil { note = ""; keepAudio = false }
                    }.disabled(library.samples.count >= 100)
                    Button("丢弃这段", role: .destructive) { library.discardPending() }
                }
            }
            Section("我的样本 · \(library.samples.count) / 100") {
                ForEach(SoundSampleLabel.allCases) { item in
                    LabeledContent(item.title, value: "\(library.samples.filter { $0.label == item }.count) 段")
                }
                LabeledContent("当前采集批次", value: String(library.batch.uuidString.prefix(8)))
                Button("开始新的采集批次") { library.newBatch() }.disabled(library.isBusy || library.pending != nil)
                Text("同一次采集的样本留在同一批次。请换时段、距离或房间后另开批次，训练与测试才有独立性。")
                    .font(.caption).foregroundStyle(.secondary)
                if library.samples.isEmpty { Text("还没有保存样本。先采集不同类别，再进行模型训练。").foregroundStyle(.secondary) }
                ForEach(library.samples) { sample in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(sample.label.title).font(.headline)
                            Spacer(); Text(String(format: "%.1f 秒", sample.duration)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(sample.createdAt.formatted(date: .abbreviated, time: .shortened)) · 批次 \(sample.batch.uuidString.prefix(8))")
                            .font(.caption).foregroundStyle(.secondary)
                        if !sample.note.isEmpty { Text(sample.note).font(.caption) }
                        HStack {
                            if sample.keepsAudio { Button("试听") { workspace.audio.stopEverything(); library.play(sample) } }
                            Menu("修改人工标签") {
                                ForEach(SoundSampleLabel.allCases) { item in Button(item.title) { library.relabel(sample, as: item) } }
                            }
                            Spacer(); Button("删除", role: .destructive) { deletion = sample }
                        }.font(.caption)
                    }.padding(.vertical, 6)
                }
            }
            Section("用于电脑实验") {
                Button("导出已标注的特征数据", systemImage: "square.and.arrow.up") {
                    do { document = ExperimentJSONDocument(data: try library.export()); exportFile = true }
                    catch { self.error = error.localizedDescription }
                }.disabled(library.samples.isEmpty || library.isBusy)
                Text("导出包含标签、批次、特征和样本标识，不含原音频及备注。文件由你选择保存或分享；不会自动上传。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.seePageCanvas().navigationTitle("个人声音样本")
            .onAppear { workspace.audio.stopEverything(); workspace.hand.stop(); workspace.offlineSpeech.cancel() }
            .onDisappear { library.cancelCapture() }
            .confirmationDialog("录制个人声音样本？", isPresented: $recordConsent, titleVisibility: .visible) {
                Button("开始录制，最多 5 秒") { workspace.stop(); Task { await library.startRecording() } }
            } message: { Text("会使用麦克风并暂存一段音频供试听。确认保存前不会进入样本库，也不会上传。请避免录入旁人的私密谈话。") }
            .confirmationDialog("删除这段样本及保留的音频？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
                Button("删除样本", role: .destructive) { if let deletion { library.delete(deletion) }; deletion = nil }
            }
            .fileImporter(isPresented: $importFile, allowedContentTypes: [.audio]) { result in
                switch result { case .success(let url): Task { await library.prepare(url) }; case .failure(let error): self.error = error.localizedDescription }
            }
            .fileExporter(isPresented: $exportFile, document: document, contentType: .json, defaultFilename: "SeeSound-Dataset") { result in
                if case .failure(let error) = result { self.error = error.localizedDescription }
            }
    }
}
