import AVFoundation
import Speech
import SwiftUI

struct SceneDashboard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var audio: AudioProbes
    @ObservedObject var hand: HandProbe
    @ObservedObject var bridge: ConnectivityBridge
    @ObservedObject var samples: SoundSampleLibrary
    let open: (ProbePage) -> Void
    private var scene: ListeningScene { workspace.preferences.scene }
    private var active: Bool { audio.mode != .idle || audio.isStarting || audio.isSpeaking || hand.isRunning || hand.isStarting || samples.isBusy }
    private var subtitle: String {
        switch scene {
        case .home: return "有人来访，也能安心留意。"
        case .study: return "专注手上的事，留意重要动静。"
        case .conversation: return "把对方的话看清楚，把想法说出来。"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("见声 SEESOUND", systemImage: "ear.badge.waveform").font(.caption.weight(.bold)).tracking(1.5)
                Spacer()
                Text("\(workspace.ledger.events.filter { $0.status == .pending }.count) 条待确认")
                    .font(.caption).padding(8).background(SeePalette.rose, in: Capsule())
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(scene == .home ? "在家，安心一点。" : scene == .study ? "给专注留些空间。" : "让沟通顺畅一点。")
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Text(subtitle).font(.subheadline).foregroundStyle(SeePalette.secondary)
                }
                Spacer(minLength: 4)
                SeeArtworkView(artwork:scene == .conversation ? .speech : scene == .study ? .books : .headphone,size:70)
            }
            ViewThatFits {
                HStack(spacing: 10) { sceneButtons }
                VStack(alignment: .leading, spacing: 10) { sceneButtons }
            }
            Button { open(.profiles) } label: {
                Label(workspace.preferences.sceneTitle + " · 管理场景", systemImage: "slider.horizontal.3").font(.subheadline)
            }.buttonStyle(.plain).frame(minHeight: 44)
            Text(workspace.preferences.sounds.isEmpty ? "当前没有关注声音，可在“我的”选择。" : "当前关注：" + workspace.preferences.sounds.sorted { $0.rawValue < $1.rawValue }.map { $0.title }.joined(separator: "、"))
                .font(.caption).foregroundStyle(SeePalette.secondary)
            Button {
                if active { workspace.stopCapture() }
                else {
                    workspace.stopCapture()
                    Task {
                        guard UIApplication.shared.applicationState == .active else { return }
                        if scene == .conversation { await audio.startCaptions() }
                        else { await audio.startSounds() }
                    }
                }
            } label: {
                Label(active ? "停止采集与朗读" : scene == .conversation ? "开始端侧字幕" : "开始关注声音", systemImage: active ? "stop.fill" : "play.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                    .foregroundStyle(SeePalette.ink)
                    .background(SeePalette.rose, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain)
            Text(samples.isBusy ? samples.status : audio.status).font(.caption).foregroundStyle(SeePalette.secondary)
                .accessibilityLabel("采集状态：\(samples.isBusy ? samples.status : audio.status)")
        }.padding(22).foregroundStyle(SeePalette.ink)
            .background(SeePalette.surface,in:RoundedRectangle(cornerRadius:22))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 12) {
            statusTile("麦克风", value: samples.isRecording ? "个人样本录制中" : audio.isStarting ? "准备中" : audio.mode == .idle ? "未采集" : audio.mode == .sound ? "声音分析中" : "字幕采集中", symbol: "mic") { open(.sound) }
            statusTile("摄像头", value: hand.isStarting ? "准备中" : hand.isRunning ? "手部检测中" : "未开启", symbol: "camera") { open(.hand) }
            statusTile("Apple Watch", value: bridge.reachable ? "当前可达" : "查看连接状态", symbol: "applewatch") { open(.watch) }
            statusTile("声音实验", value: "公开样本 · 不用录音", symbol: "waveform.path") { open(.lab) }
        }
        HStack(spacing: 12) {
            Image(systemName: scene == .conversation ? "bubble.left.and.text.bubble.right" : "checklist").font(.title2).foregroundStyle(Color.seeAccent)
            VStack(alignment: .leading, spacing: 5) {
                Text(scene == .conversation ? "打开沟通工具" : "检查你的设备").font(.headline)
                Text(scene == .conversation ? "搜索卡片、组合回应、大字阅读" : "从权限到手表确认，逐项走通一次")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开") { open(scene == .conversation ? .captions : .deviceCheck) }.buttonStyle(.bordered)
        }.padding(18).background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 20))
    }
    @ViewBuilder private var sceneButtons: some View {
        ForEach(ListeningScene.allCases) { option in
            Button { workspace.applyScene(option) } label: {
                Label(option.title, systemImage: option.symbol).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(scene == option && workspace.preferences.activeProfileID == nil ? SeePalette.rose : SeePalette.canvas.opacity(0.5), in: Capsule())
                    .overlay(Capsule().stroke(Color.seeAccent.opacity(scene == option && workspace.preferences.activeProfileID == nil ? 0.5 : 0), lineWidth: 1))
            }.buttonStyle(.plain).accessibilityAddTraits(scene == option && workspace.preferences.activeProfileID == nil ? .isSelected : [])
        }
    }
    private func statusTile(_ title: String, value: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}

struct DeviceCheckPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var bridge: ConnectivityBridge
    @State private var checks: [Int: String] = [:]
    @State private var revision = 0
    private let instructions = ["声音关注：允许麦克风，用真实敲门与背景声音检查事件；误报请人工复核。",
                                "动作：允许摄像头，对比挥手、普通活动、遮挡和离开画面。",
                                "沟通：检查端侧字幕；朗读时麦克风停止，结束后不自动恢复。",
                                "文件：选择一段已知内容音频转写，核对文字；再扫描一张沟通卡分享码。",
                                "手表：两端打开，发送通信测试卡；分别从手表和手机确认，检查两端状态。",
                                "停止：切到后台后返回，麦克风和摄像头应保持停止；再手动开启。"]
    var body: some View {
        Form {
            Section("此设备") {
                Text("\(UIDevice.current.model) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                #if targetEnvironment(simulator)
                Label("当前是模拟器，不能代替真实硬件验证", systemImage: "desktopcomputer").foregroundStyle(.orange)
                #else
                Label("当前为真实设备", systemImage: "iphone")
                #endif
                LabeledContent("麦克风", value: micPermission)
                LabeledContent("摄像头", value: cameraPermission)
                LabeledContent("语音权限", value: speechPermission)
                LabeledContent("中文端侧能力", value: SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.supportsOnDeviceRecognition == true ? "系统报告支持，效果待检查" : "暂不支持 / 未就绪")
                Button("刷新权限与连接") { revision += 1; bridge.refresh() }
            }.id(revision)
            Section("Watch 连接") {
                Text(bridge.status)
                Button("激活 / 检查通信") { bridge.activate() }
                NavigationLink("进入腕上回应") { WatchPage(bridge: bridge, workspace: workspace) }
            }
            Section("手动检查 · 不自动判为通过") {
                ForEach(instructions.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(index + 1). \(instructions[index])").font(.subheadline)
                        Picker("检查结果", selection: Binding(get: { checks[index] ?? "未检查" }, set: { checks[index] = $0 })) {
                            ForEach(["未检查", "通过", "需调整"], id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.segmented)
                    }.padding(.vertical, 5)
                }
                Text("这些选择只记录本页本次检查，不构成识别准确率或后台可用性结论。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.seePageCanvas().navigationTitle("设备检查")
    }
    private var micPermission: String {
        switch AVAudioApplication.shared.recordPermission { case .granted: return "已允许"; case .denied: return "已拒绝"; default: return "尚未请求" }
    }
    private var cameraPermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) { case .authorized: return "已允许"; case .denied, .restricted: return "未允许"; default: return "尚未请求" }
    }
    private var speechPermission: String {
        switch SFSpeechRecognizer.authorizationStatus() { case .authorized: return "已允许"; case .denied, .restricted: return "未允许"; default: return "尚未请求" }
    }
}


struct TodayFocusPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var studio: WorkroomService
    @ObservedObject var routines: RoutineService
    var body: some View {
        TimelineView(.periodic(from:.now,by:30)) { context in
            VStack(alignment:.leading,spacing:16) {
                HStack {
                    VStack(alignment:.leading,spacing:5) {
                        Text(context.date,format:.dateTime.month().day().weekday()).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text("接着把事情办好").font(.title2.bold())
                    }
                    Spacer()
                    Button { workspace.navigationRequest = .search } label: { Image(systemName:"magnifyingglass").font(.title3).frame(width:44,height:44).background(Color.seeAccent.opacity(0.08),in:Circle()) }.accessibilityLabel("搜索所有记录")
                }
                let projects = WorkroomCase.select(studio.cases,query:"",filter:.active,includeDemonstrations:false,now:context.date)
                let tasks = RoutineItem.select(routines.items,query:"",filter:.pending,includeDemonstrations:false,now:context.date)
                if projects.isEmpty && tasks.isEmpty {
                    Text("把通知、截图或文字带进来，整理成能逐项处理的事务。").font(.subheadline).foregroundStyle(.secondary)
                    Button("整理一份材料",systemImage:"text.viewfinder") { workspace.navigationRequest = .workroom }.buttonStyle(.borderedProminent).tint(SeePalette.button)
                }
                ForEach(projects.prefix(2)) { item in
                    NavigationLink { WorkroomCaseDetail(workspace:workspace,studio:studio,cards:workspace.information,routines:routines,itemID:item.id) } label: {
                        HStack(alignment:.top) {
                            VStack(alignment:.leading,spacing:6) {
                                Label(item.title,systemImage:item.overdue(at:context.date) ? "clock.badge.exclamationmark" : "list.bullet.clipboard").font(.headline)
                                Text(item.nextAction(routines:routines.items) ?? "所有项目已处理，打开完成事务").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                if let due = item.dueAt { Text(due,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(item.overdue(at:context.date) ? Color.orange : Color.secondary) }
                            }
                            Spacer(); Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(14).background(Color.seeAccent.opacity(0.06),in:RoundedRectangle(cornerRadius:16))
                    }.buttonStyle(.plain)
                }
                if let next = tasks.first {
                    NavigationLink { RoutineDetail(workspace:workspace,service:routines,information:workspace.information,itemID:next.id) } label: {
                        HStack { Label(next.title,systemImage:"checklist").font(.subheadline); Spacer(); Image(systemName:"chevron.right").font(.caption) }.frame(minHeight:44)
                    }.buttonStyle(.plain)
                }
                HStack {
                    Button("进行中事务 · \(projects.count)") { workspace.navigationRequest = .cases }
                    Spacer()
                    if !projects.isEmpty || !tasks.isEmpty { Button("文字工作室",systemImage:"plus") { workspace.navigationRequest = .workroom } }
                }.font(.subheadline)
            }.padding(20).background(SeePalette.surface,in:RoundedRectangle(cornerRadius:24))
        }
    }
}
