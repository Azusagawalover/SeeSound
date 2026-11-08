import SwiftUI

struct DeviceContext {
    static var simulator:Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    static var label:String { "\(UIDevice.current.model) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }
}
struct ReliabilityPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var quality:QualityService
    @State private var adding = false
    var body:some View {
        List {
            Section("当前输入状态") { CaptureHealthPanel(audio:workspace.audio,hand:workspace.hand) }
            Section("人工复核 · 不换算准确率") {
                let notes = workspace.annotations.values
                LabeledContent("标记与实际相符",value:"\(notes.filter { $0.verdict == .plausible }.count)")
                LabeledContent("标记误报",value:"\(notes.filter { $0.verdict == .falseAlarm }.count)")
                LabeledContent("无法确定",value:"\(notes.filter { $0.verdict == .uncertain }.count)")
                Text("这里只统计当前保留事件的人工标记。没有完整真实事件总数，不能据此计算召回率或整体准确率。").font(.caption).foregroundStyle(.secondary)
            }
            Section("补记问题") {
                Button("记录一次漏报、误报或中断",systemImage:"plus.bubble") { adding = true }
                ForEach(quality.archive.reports.sorted { $0.date > $1.date }) { report in
                    VStack(alignment:.leading,spacing:7) {
                        Label(report.category+" · "+report.kind.title,systemImage:"exclamationmark.bubble").font(.headline)
                        Text(report.note).textSelection(.enabled)
                        if !report.environment.isEmpty { Text(report.environment).font(.caption).foregroundStyle(.secondary) }
                        Text(report.date,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if quality.archive.reports.isEmpty { Text("还没有补记。未检测到的事件也可以主动记下，方便以后复查。").foregroundStyle(.secondary) }
                if let error = quality.error { Text(error).foregroundStyle(.red) }
            }
            Section("排查入口") {
                NavigationLink("脱敏诊断报告导出") { DiagnosticExportPage(workspace:workspace) }
                NavigationLink("图文使用帮助") { ProductHelpPage() }
                NavigationLink("检查权限与设备") { DeviceCheckPage(workspace:workspace,bridge:workspace.bridge) }
                NavigationLink("使用公开样本检查声音模型") { EnvironmentalPage(workspace:workspace,service:workspace.environment) }
                NavigationLink("打开完整验收清单") { AcceptancePage(quality:quality) }
                Button("停止全部采集与朗读",systemImage:"stop.circle") { workspace.stopCapture() }
                Text("检查只处理本机状态，问题记录不保存音视频，不发送给模型，也不会自动作为训练标签。").font(.caption).foregroundStyle(.secondary)
            }
        }.seePageCanvas().navigationTitle("识别与可靠性").sheet(isPresented:$adding) { RecognitionReportEditor(quality:quality) }.modifier(WorkroomPrivacy())
    }
}
struct CaptureHealthPanel:View {
    @ObservedObject var audio:AudioProbes
    @ObservedObject var hand:HandProbe
    var body:some View {
        TimelineView(.periodic(from:.now,by:1)) { context in
            VStack(alignment:.leading,spacing:14) {
                healthRow("麦克风与声音 / 字幕",health:CaptureHealth.evaluate(active:audio.mode != .idle,starting:audio.isStarting,lastInput:audio.lastInputAt,lastResult:audio.lastResultAt,now:context.date,activeSince:audio.captureStartedAt))
                Text(audio.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                healthRow("摄像头与手部",health:CaptureHealth.evaluate(active:hand.isRunning,starting:hand.isStarting,lastInput:hand.lastFrameAt,lastResult:hand.lastHandAt,now:context.date,activeSince:hand.captureStartedAt))
                Text(hand.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if audio.processingGaps > 0 { Label("本次声音处理跳过 \(audio.processingGaps) 段输入，连续证据已重置",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                LabeledContent("系统温度状态",value:thermalLabel).font(.caption)
                if DeviceContext.simulator { Text("模拟器不进行真实麦克风或摄像头采集。").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func healthRow(_ title:String,health:CaptureHealth) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.subheadline.bold()).fixedSize(horizontal:false,vertical:true)
            Label(health.title,systemImage:health.state == .receiving ? "waveform.path" : health.state == .interrupted ? "exclamationmark.triangle" : "circle.dotted")
                .foregroundStyle(health.state == .interrupted ? Color.orange : Color.seeAccent)
            Text(health.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.accessibilityElement(children:.combine)
    }
    private var thermalLabel:String {
        switch ProcessInfo.processInfo.thermalState { case .nominal:return "正常";case .fair:return "略高";case .serious:return "较高，请减少同时运行的功能";case .critical:return "过高，建议停止采集让设备降温";@unknown default:return "未知" }
    }
}
private struct RecognitionReportEditor:View {
    @ObservedObject var quality:QualityService
    @State private var report = RecognitionReport()
    @State private var consent = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            Form {
                Picker("问题类型",selection:$report.kind) { ForEach(RecognitionIssueKind.allCases) { Text($0.title).tag($0) } }
                Picker("功能",selection:$report.category) { ForEach(["声音","动作","字幕","提醒","Watch"],id:\.self) { Text($0) } }
                TextField("当时环境（最多 120 字）",text:$report.environment)
                TextField("实际发生什么、应用显示什么（最多 500 字）",text:$report.note,axis:.vertical).lineLimit(4...8)
                Toggle("将这条问题记录保存在本机",isOn:$consent)
                Text("不附加原始音视频；记录由你填写，不会被当成已经验证的识别结论。").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                Button("保存问题") { do { try quality.report(report);dismiss() } catch { self.error = error.localizedDescription } }.disabled(!consent || report.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }.seePageCanvas().navigationTitle("补记问题").toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } } }
        }.modifier(WorkroomPrivacy())
    }
}
struct AcceptancePage:View {
    @ObservedObject var quality:QualityService
    @State private var editing:VerificationCheck?
    var body:some View {
        List {
            Section {
                Text(DeviceContext.label).font(.headline)
                if DeviceContext.simulator { Label("模拟器 · 硬件项目不能判通过",systemImage:"desktopcomputer").foregroundStyle(.orange) }
                Text("每项由你按步骤检查后记录。历史结果保留设备、时间与备注，不自动把编译成功当成验收通过。").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(VerificationCheck.all) { check in
                let record = quality.archive.records.filter { $0.checkID == check.id }.max { $0.date < $1.date }
                Button { editing = check } label: {
                    VStack(alignment:.leading,spacing:8) {
                        HStack { Text(check.title).font(.headline);Spacer();Text(record?.result.title ?? "未检查").font(.caption).foregroundStyle(record?.result == .passed ? Color.seeAccent : Color.secondary) }
                        Text(check.steps).font(.subheadline).foregroundStyle(.secondary)
                        if let record { Text(record.device+" · "+record.date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary);if !record.note.isEmpty { Text(record.note).font(.caption).foregroundStyle(.secondary) } }
                    }.padding(.vertical,6)
                }.buttonStyle(.plain)
            }
            Section("历史与导出") {
                LabeledContent("已存检查记录",value:"\(quality.archive.records.count) / 200")
                ShareLink("导出检查记录文字",item:export)
                Text("导出包含你填写的备注与设备说明，请自行选择接收方。").font(.caption).foregroundStyle(.secondary)
            }
        }.seePageCanvas().navigationTitle("使用验收清单").sheet(item:$editing) { VerificationEditor(quality:quality,check:$0) }.modifier(WorkroomPrivacy())
    }
    private var export:String {
        ["见声 · 用户检查记录", "结果由用户填写；模拟器不证明真实硬件可用。"].joined(separator:"\n")+"\n"+quality.archive.records.sorted { $0.date > $1.date }.map { record in
            let title = VerificationCheck.all.first { $0.id == record.checkID }?.title ?? record.checkID
            return "\(title) | \(record.result.title) | \(record.device) | \(record.simulator ? "模拟器" : "设备") | \(record.date.formatted())\n\(record.note)"
        }.joined(separator:"\n\n")
    }
}
private struct VerificationEditor:View {
    @ObservedObject var quality:QualityService
    let check:VerificationCheck
    @State private var result:VerificationResult = .notChecked
    @State private var note = ""
    @State private var confirmed = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            Form {
                Text(check.steps)
                Picker("本次结果",selection:$result) { ForEach(VerificationResult.allCases) { value in Text(value.title).tag(value).disabled(value == .passed && check.needsHardware && DeviceContext.simulator) } }
                if check.needsHardware && DeviceContext.simulator { Text("此项需要真实设备，当前只能记录未检查或需调整。").foregroundStyle(.orange) }
                TextField("操作过程与发现（最多 500 字）",text:$note,axis:.vertical).lineLimit(4...8)
                Toggle("按实际操作结果保存本次检查",isOn:$confirmed)
                Text("保留历史记录，不覆盖上一次检查。没有实际执行的项目请保留未检查。").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                Button("保存本次检查") {
                    do { try quality.record(.init(checkID:check.id,result:result,note:note,device:DeviceContext.label,simulator:DeviceContext.simulator));dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(!confirmed || note.count > 500)
            }.seePageCanvas().navigationTitle(check.title).toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } } }
        }.modifier(WorkroomPrivacy())
    }
}
