import SwiftUI
import Combine

@MainActor final class CampusEvaluationRunner:ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var latest:CampusEvaluationRecord?
    @Published private(set) var records:[CampusEvaluationRecord] = []
    @Published private(set) var status = ""
    private let store = CampusEvaluationStore()
    private var readFailed = false
    private var task:Task<Void,Never>?
    private var generation = UUID()
    init() { do { records = try store.load() } catch { readFailed = true;status = "复查记录读取失败，已暂停写入，原文件保留："+error.localizedDescription } }
    static var samples:[CampusEvaluationSample] {
        var samples = CampusEvaluationSample.notices
        if let url = Bundle.main.url(forResource:"samples",withExtension:"json",subdirectory:"CampusEvaluation"),let data = try? Data(contentsOf:url),let audio = try? JSONDecoder().decode([CampusEvaluationSample].self,from:data) { samples += audio }
        return samples
    }
    static func noticeImage(_ sample:CampusEvaluationSample) -> Data? {
        let size = CGSize(width:1440,height:1920)
        let format = UIGraphicsImageRendererFormat();format.scale = 1
        let image = UIGraphicsImageRenderer(size:size,format:format).image { context in
            UIColor.white.setFill();context.fill(CGRect(origin:.zero,size:size))
            let style = NSMutableParagraphStyle();style.lineSpacing = 26
            (sample.reference as NSString).draw(in:CGRect(x:100,y:120,width:1240,height:1600),withAttributes:[.font:UIFont.systemFont(ofSize:sample.id == "notice-activity" ? 40 : 50),.foregroundColor:UIColor.black,.paragraphStyle:style])
        }
        return image.pngData()
    }
    func run(_ sample:CampusEvaluationSample,speech:OfflineSpeechBridge) {
        guard !busy,!speech.isBusy else { status = "请先等当前文件转写结束。";return }
        let token = UUID();generation = token;busy = true;latest = nil;status = "正在运行本机模型…"
        task = Task {
            let start = Date()
            do {
                let output:String,model:String
                if sample.kind == .ocr {
                    guard let image = Self.noticeImage(sample) else { throw WorkroomError.unreadable }
                    output = try await Task.detached(priority:.userInitiated) { try WorkroomImport.image(image) }.value
                    model = "Vision accurate · 分区复核"
                } else {
                    guard let filename = sample.filename,let url = Bundle.main.resourceURL?.appendingPathComponent("CampusEvaluation/"+filename),FileManager.default.fileExists(atPath:url.path) else { throw WorkroomError.unreadable }
                    speech.selectModel(.base)
                    if !speech.isReady { speech.prepare(allowDownload:false);try await wait(speech,timeout:180) }
                    guard speech.isReady else { throw EvaluationRunError.message(speech.status) }
                    speech.transcribe(url,language:"zh");try await wait(speech,timeout:180)
                    guard speech.resultModel != nil,!speech.text.isEmpty else { throw EvaluationRunError.message(speech.status) }
                    output = speech.text;model = speech.resultModel ?? "Whisper Base"
                }
                try Task.checkCancellation();guard generation == token else { return }
                latest = .init(sampleID:sample.id,title:sample.title,kind:sample.kind,model:model,reference:sample.reference,observed:output,elapsed:Date().timeIntervalSince(start),keywords:sample.keywords)
                status = "本次实际运行结束，尚未保存。样本数少，结果只用于逐条复查。"
            } catch {
                guard generation == token,!Task.isCancelled else { return }
                latest = .init(sampleID:sample.id,title:sample.title,kind:sample.kind,model:sample.kind == .ocr ? "Vision accurate" : "Whisper Base",reference:sample.reference,observed:"",elapsed:Date().timeIntervalSince(start),failure:String(error.localizedDescription.prefix(500)),keywords:sample.keywords)
                status = "本次未完成，可以保留失败记录再排查；未生成识别结论。"
            }
            if generation == token { busy = false }
        }
    }
    private func wait(_ speech:OfflineSpeechBridge,timeout:TimeInterval) async throws {
        let start = Date()
        while speech.isBusy {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(start) < timeout else { speech.cancel();throw EvaluationRunError.message("本次评测等待超时，已停止。") }
            try await Task.sleep(nanoseconds:100_000_000)
        }
    }
    func cancel(speech:OfflineSpeechBridge) { guard busy else { return };generation = UUID();task?.cancel();task = nil;speech.cancel();busy = false;status = "评测已取消，没有保存记录。" }
    func save(_ record:CampusEvaluationRecord,consent:Bool) throws {
        guard consent,!readFailed else { throw CampusError.consent };try record.validate()
        var next = records.filter{$0.id != record.id};next.insert(record,at:0);try store.save(next);records = next;status = "本次记录已保存在本机，不进入旅程备份或接力文件。"
    }
    func update(_ record:CampusEvaluationRecord,baseline:CampusEvaluationRecord) throws {
        guard !readFailed,records.first(where:{$0.id == record.id}) == baseline else { throw CampusError.stale }
        try save(record,consent:true)
    }
    func remove(_ id:UUID) throws { guard !readFailed else { throw CampusError.stale };let next = records.filter{$0.id != id};try store.save(next);records = next }
}
enum EvaluationRunError:LocalizedError {
    case message(String)
    var errorDescription:String? { switch self { case .message(let value):return value } }
}
struct CampusEvaluationPage:View {
    @ObservedObject var speech:OfflineSpeechBridge
    @StateObject private var runner = CampusEvaluationRunner()
    @State private var onlyProblems = false
    @State private var deleting:CampusEvaluationRecord?
    @State private var error:String?
    var body:some View {
        List {
            Section { CampusHero(title:"让效果有迹可查",detail:"用固定中文录音和原创公告逐条运行。参考文本来自样本来源或人工校对，不使用模型自己的结论充当答案。",symbol:"text.magnifyingglass") }
            Section("固定评测包") {
                ForEach(CampusEvaluationRunner.samples) { item in NavigationLink { CampusEvaluationSamplePage(speech:speech,runner:runner,sample:item) } label: { VStack(alignment:.leading,spacing:7) { Label(item.title,systemImage:item.kind == .ocr ? "doc.text.viewfinder" : "waveform");Text(item.kind.title+" · "+item.license).font(.caption).foregroundStyle(.secondary) } }.accessibilityIdentifier("evaluation.sample."+item.id) }
                Text("文件转写固定使用内置Base；运行会替换文件转写页的当前转写结果。公告图像由固定文字本机生成，不访问相册。").font(.caption).foregroundStyle(.secondary)
            }
            Section("已自愿保存的复查记录") {
                Toggle("只看失败或存在字符差异的记录",isOn:$onlyProblems)
                ForEach(runner.records.filter{!onlyProblems || $0.failure != nil || ($0.score?.edits ?? 0)>0}) { record in
                    NavigationLink { CampusEvaluationReviewPage(runner:runner,record:record) } label: { VStack(alignment:.leading,spacing:6) { Text(record.title).font(.headline);Text(record.failure != nil ? "运行失败" : record.reviewed ? "已人工复查" : "待人工复查").font(.caption).foregroundStyle(record.failure != nil ? .orange : .secondary);Text(record.date,format:.dateTime.month().day().hour().minute()).font(.caption) } }.swipeActions { Button("删除",role:.destructive) { deleting = record } }
                }
                if runner.records.isEmpty { Text("没有保存任何评测记录。运行后的结果也需要你主动同意才会留下。").font(.subheadline).foregroundStyle(.secondary) }
            }
            if !runner.status.isEmpty { Text(runner.status).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("中文评测与复查")
            .confirmationDialog("删除这条本机评测记录？",isPresented:Binding(get:{deleting != nil},set:{if !$0 { deleting = nil }}),titleVisibility:.visible) { Button("删除记录",role:.destructive) { do { if let deleting { try runner.remove(deleting.id) };self.deleting = nil } catch { self.error = error.localizedDescription } } }.modifier(WorkroomPrivacy())
    }
}
struct CampusEvaluationSamplePage:View {
    @ObservedObject var speech:OfflineSpeechBridge
    @ObservedObject var runner:CampusEvaluationRunner
    let sample:CampusEvaluationSample
    @State private var consent = false
    @State private var error:String?
    private var result:CampusEvaluationRecord? { runner.latest?.sampleID == sample.id ? runner.latest : nil }
    var body:some View {
        List {
            Section { Text(sample.title).font(.title2.bold());Text(sample.source).font(.subheadline);Text(sample.license).font(.caption);Text(sample.note).font(.caption).foregroundStyle(.secondary) }
            Section("固定参考文本") { Text(sample.reference).textSelection(.enabled) }
            if sample.kind == .ocr,let data = CampusEvaluationRunner.noticeImage(sample),let image = UIImage(data:data) { Section("实际识字的图像") { Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:400) } }
            Section {
                Button(runner.busy ? "正在运行…" : "运行这个样本") { consent = false;runner.run(sample,speech:speech) }.disabled(runner.busy || speech.isBusy).accessibilityIdentifier("evaluation.run")
                if runner.busy { ProgressView();Button("取消本次评测") { runner.cancel(speech:speech) } }
                Text(runner.status).font(.caption).foregroundStyle(.secondary)
            }
            if let result {
                EvaluationResultSections(record:result)
                Section("保存选择") {
                    Toggle("我同意在本机保存本次输入参考、实际结果和失败信息",isOn:$consent)
                    Button("保存这条复查记录") { do { try runner.save(result,consent:consent);error = nil } catch { self.error = error.localizedDescription } }.disabled(!consent)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("逐条评测").onDisappear{runner.cancel(speech:speech)}.modifier(WorkroomPrivacy())
    }
}
struct EvaluationResultSections:View {
    let record:CampusEvaluationRecord
    var body:some View {
        Section("本次实际结果") {
            Text(record.model).font(.caption)
            if let failure = record.failure { Label("未完成",systemImage:"exclamationmark.circle").foregroundStyle(.orange);Text(failure) }
            else { Text(record.observed).textSelection(.enabled).accessibilityIdentifier("evaluation.output");if let score = record.score { Text("字符编辑距离 \(score.edits) / 参考字符 \(score.referenceCount) · CER \(String(format:"%.1f",score.rate*100))%").font(.caption).accessibilityIdentifier("evaluation.score") } }
            Text("本次处理用时 \(String(format:"%.2f",record.elapsed)) 秒").font(.caption)
            Text("字符比较忽略空白和标点，保留字母及数字；不等于关键信息已正确，也不代表整体识别准确率。").font(.caption).foregroundStyle(.secondary)
        }
        if let keywords = record.keywords,!keywords.isEmpty,record.failure == nil {
            Section("关键字面复查") {
                ForEach(keywords,id:\.self) { word in
                    let matched = CharacterEvaluation.normalize(record.observed).contains(CharacterEvaluation.normalize(word))
                    Label(word+(matched ? " · 字面命中" : " · 未命中，待核对"),systemImage:matched ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(matched ? Color.seeAccent : .orange)
                }
                Text("字面命中仍需检查属于哪一件事、是否为旧安排。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct CampusEvaluationReviewPage:View {
    @ObservedObject var runner:CampusEvaluationRunner
    let record:CampusEvaluationRecord
    @State private var correction = ""
    @State private var note = ""
    @State private var reviewed = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        Form {
            Section("固定参考") { Text(record.reference).textSelection(.enabled) }
            EvaluationResultSections(record:record)
            Section("人工复查") {
                TextField("你修改后的文字（原模型输出保留）",text:$correction,axis:.vertical).lineLimit(4...12)
                TextField("错误位置、可能原因或复查备注",text:$note,axis:.vertical)
                Toggle("我已经人工复查这一条",isOn:$reviewed)
                Button("保存人工复查") { do { var next = record;next.correction = correction;next.note = note;next.reviewed = reviewed;try runner.update(next,baseline:record);dismiss() } catch { self.error = error.localizedDescription } }
                Text("人工修改单独保存，不覆盖原模型输出或重新包装原始得分。").font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink("预览并分享这条结果") { SharePreviewPage(original:[record.title,record.model,"参考："+record.reference,"实际输出："+record.observed,"人工复查："+correction,"备注："+note].joined(separator:"\n")) }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("错误与复查记录").onAppear{correction = record.correction;note = record.note;reviewed = record.reviewed}.modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
    }
}
