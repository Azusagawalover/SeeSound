import AVFoundation
import SwiftUI
import PopupView

extension Color {
    static let seeAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.97, green: 0.73, blue: 0.81, alpha: 1)
            : UIColor(red: 0.56, green: 0.28, blue: 0.40, alpha: 1)
    })
}

enum ProbePage: String, Hashable, CaseIterable {
    case campus, recentlyDeleted, experience, inbox, organizer, calendar, templates, cleanup, help, diagnostics, agenda, backup, continuity, reliability, acceptance, sound, hand, captions, watch, library, transfer, offline, feedback, samples, lab, deviceCheck, sharing, saved, reminders, reading, demo, profiles, information, timeline, workbench, routines, intelligence, workroom, cases, bilingual, search
    var title: String {
        switch self { case .demo: return "场景演示"; case .sound: return "声音关注"; case .hand: return "挥手检测"
        case .campus:return "校园办事";case .recentlyDeleted:return "最近删除";case .experience:return "完整体验"
        case .inbox:return "待整理收件箱";case .organizer:return "我的资料";case .calendar:return "事务日历";case .templates:return "事务模板";case .cleanup:return "资料清理";case .help:return "使用帮助";case .diagnostics:return "脱敏诊断报告"
        case .agenda:return "提醒中心";case .backup:return "备份与恢复";case .continuity:return "设备接力";case .reliability:return "识别与可靠性";case .acceptance:return "使用验收清单"
        case .workroom: return "文字工作室"; case .cases: return "事务清单"; case .bilingual: return "双语沟通"; case .search: return "全局搜索"
        case .profiles: return "我的场景"; case .information: return "重要信息核对"; case .timeline: return "联合事件时间线"
        case .workbench: return "今日工作台"; case .routines: return "约定与待办"
        case .intelligence: return "DeepSeek 智能整理"
        case .captions: return "面对面沟通"; case .watch: return "腕上回应"
        case .library: return "沟通模板"; case .transfer: return "卡片互传"
        case .offline: return "文件转写"; case .feedback: return "效果预览"
        case .sharing: return "临时文字共享"; case .saved: return "已保存会话"; case .reminders: return "提醒规则"; case .reading: return "阅读与操作"
        case .samples: return "声音样本"; case .lab: return "环境声音实验"; case .deviceCheck: return "设备检查" }
    }
    var symbol: String {
        switch self { case .demo: return "play.rectangle"; case .sound: return "waveform"; case .hand: return "hand.wave"
        case .campus:return "point.topleft.down.to.point.bottomright.curvepath";case .recentlyDeleted:return "trash";case .experience:return "play.rectangle"
        case .inbox:return "tray";case .organizer:return "folder";case .calendar:return "calendar";case .templates:return "square.on.square";case .cleanup:return "archivebox";case .help:return "questionmark.circle";case .diagnostics:return "lock.shield"
        case .agenda:return "bell.badge";case .backup:return "lock.doc";case .continuity:return "ipad.and.iphone";case .reliability:return "waveform.path.ecg";case .acceptance:return "checkmark.seal"
        case .workroom: return "text.viewfinder"; case .cases: return "list.bullet.clipboard"; case .bilingual: return "character.bubble"; case .search: return "magnifyingglass"
        case .profiles: return "square.stack.3d.up"; case .information: return "rectangle.on.rectangle"; case .timeline: return "timeline.selection"
        case .workbench: return "sun.max"; case .routines: return "checklist"
        case .intelligence: return "sparkles"
        case .captions: return "captions.bubble"; case .watch: return "applewatch"
        case .library: return "square.grid.2x2"; case .transfer: return "qrcode"
        case .offline: return "doc.text"; case .feedback: return "sparkles"
        case .sharing: return "ipad.and.iphone"; case .saved: return "text.bubble"; case .reminders: return "bell.badge"; case .reading: return "textformat.size"
        case .samples: return "waveform.badge.plus"; case .lab: return "point.3.connected.trianglepath.dotted"; case .deviceCheck: return "checklist" }
    }
    var detail: String {
        switch self {
        case .campus:return "从材料、沟通到核对与办理结果";case .recentlyDeleted:return "恢复误删内容、撤销分类调整";case .experience:return "从示例通知到完成，走通完整流程"
        case .inbox:return "先收下材料，再按你的节奏整理";case .organizer:return "文件夹、标签、搜索与反向关联";case .calendar:return "按日期查看截止事务";case .templates:return "从材料与步骤模板开始";case .cleanup:return "选择后清理草稿与归档事务";case .help:return "导入、推进、沟通与备份的图文指引";case .diagnostics:return "预览白名单状态后导出报告"
        case .agenda:return "查看安排状态、改期和取消提醒";case .backup:return "密码加密、预览合并与中断回退";case .continuity:return "事务文件接力与 Watch 摘要";case .reliability:return "输入状态、问题补记与排查";case .acceptance:return "按设备记录真实操作结果"
        case .workroom: return "截图识字、导入文档、离线整理与补问"
        case .cases: return "材料、步骤、核对卡与待办放在一起"
        case .bilingual: return "保留原文的四种语言翻译与大字展示"
        case .search: return "一次搜索本机已留下的内容"
        case .intelligence: return "主动整理选中的文字，核对后再采用"
        case .workbench: return "把待看提醒、待核对信息和待办放在一起"
        case .routines: return "留下核对好的约定，逐项处理"
        case .profiles: return "保存声音、提醒和专用回应，一键切换"
        case .information: return "把时间、地点、金额和电话放大核对"
        case .timeline: return "声音与动作按时间整理，保留原事件"
        case .demo: return "不录音，先体验来访与面对面交流"
        case .sound: return "选择想留意的声音，让提醒出现在眼前"
        case .hand: return "留意画面内的挥手样式，辅助发现招呼"
        case .captions: return "端侧字幕、文字朗读和快捷表达"
        case .watch: return "配对 iPhone 与 Watch 的接收和确认"
        case .library: return "从 62 句中文模板中挑选常用表达"
        case .transfer: return "扫码或粘贴导入，核对后收藏"
        case .offline: return "准备模型，将短音频转为本机文字"
        case .feedback: return "预览脉冲动画和提醒提示"
        case .samples: return "录制、试听、标注自己的环境声音"
        case .lab: return "用公开录音检查 YAMNet 本机声音模型"
        case .deviceCheck: return "核对权限、识别与手表确认流程"
        case .sharing: return "让 iPad 成为前台大字阅读屏"
        case .saved: return "主动保存、搜索和导出这次交流"
        case .reminders: return "分类型设置提醒与减少重复打扰"
        case .reading: return "文字大小、对比度与操作偏好"
        }
    }
}

private struct ProbeRoute: Hashable {
    let id = UUID()
    let page: ProbePage
    let startWithReply: Bool
    init(_ page: ProbePage, startWithReply: Bool = false) { self.page = page;self.startWithReply = startWithReply }
}

struct RootView: View {
    @ObservedObject var workspace: Workspace
    @State private var path: [ProbeRoute]
    @State private var showCredits = false
    @State private var confirmClear = false
    @State private var selectedTab = 0
    @State private var showIntro = false
    @Environment(\.seeReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(workspace: Workspace) {
        self.workspace = workspace
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--page"), args.indices.contains(index + 1),
           let page = ProbePage(rawValue: args[index + 1]) {
            if page == .cases { _path = State(initialValue:[]);_selectedTab = State(initialValue:3) }
            else { _path = State(initialValue: [ProbeRoute(page)]) }
        } else { _path = State(initialValue: []) }
        if args.contains("--journal") { _selectedTab = State(initialValue: 1) }
        if args.contains("--settings") { _selectedTab = State(initialValue: 2) }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            home.seeTabCanvas().tabItem { Label("沟通", systemImage: "captions.bubble") }.tag(0)
            EventCenter(workspace: workspace).seeTabCanvas()
                .tabItem { Label("提醒", systemImage: "bell.badge") }.tag(1)
            WorkroomCasesPage(workspace:workspace,studio:workspace.workroom,cards:workspace.information,routines:workspace.routines).seeTabCanvas().tabItem { Label("办事",systemImage:"list.bullet.clipboard") }.tag(3)
            PreferencesPage(workspace: workspace).seeTabCanvas()
                .tabItem { Label("我的", systemImage: "slider.horizontal.3") }.tag(2)
        }.tint(.seeAccent).environmentObject(workspace.agenda)
            .scrollContentBackground(.hidden).background(SeePalette.canvas)
            .safeAreaInset(edge:.bottom,spacing:0) { WorkroomNoticeBanner(workspace:workspace,studio:workspace.workroom) }
            .onChange(of: workspace.navigationRequest) { _, page in
                if let page { selectedTab = page == .cases ? 3 : 0; path = page == .cases ? [] : [ProbeRoute(page)]; workspace.navigationRequest = nil }
            }
            .sheet(item: $workspace.scheduledDestination) { destination in
                NavigationStack {
                    Group {
                        if destination.kind == .project {
                            WorkroomCaseDetail(workspace: workspace, studio: workspace.workroom, cards: workspace.information, routines: workspace.routines, itemID: destination.recordID)
                        } else {
                            RoutineDetail(workspace: workspace, service: workspace.routines, information: workspace.information, itemID: destination.recordID)
                        }
                    }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { workspace.scheduledDestination = nil } } }
                }.environmentObject(workspace.agenda)
            }
            .fullScreenCover(isPresented: $showIntro) { IntroPage(workspace: workspace) }
            .onAppear {
                if !workspace.preferences.hasFinishedIntro && !ProcessInfo.processInfo.arguments.contains("--skip-intro") { showIntro = true }
            }
            .popup(item: $workspace.feedback) { message in
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 16).accessibilityElement(children: .combine)
            } customize: { $0.type(.floater()).position(.top).autohideIn(3).closeOnTap(true)
                    .animation(reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.25)) }
    }

    private var home: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    WorkspaceHomePanel(workspace:workspace,studio:workspace.workroom,routines:workspace.routines,showReply:{ path.append(ProbeRoute(.captions,startWithReply:true)) }) { path.append(ProbeRoute($0)) }
                    DisclosureGroup("场景与设备设置") {
                        SceneDashboard(workspace:workspace,audio:workspace.audio,hand:workspace.hand,bridge:workspace.bridge,samples:workspace.samples) { path.append(ProbeRoute($0)) }
                    }.modifier(WorkspaceSurface())
                    DisclosureGroup("信息卡与待办概览") { DailyWorkbench(workspace:workspace,information:workspace.information,routines:workspace.routines) }.modifier(WorkspaceSurface())
                    recentEvents
                    Text("更多沟通工具").font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                        ForEach(primaryPages, id: \.self) { page in
                            NavigationLink(value: ProbeRoute(page)) {
                                VStack(alignment: .leading, spacing: 14) {
                                    SeeArtworkView(artwork:SeeArtwork.forSymbol(page.symbol),size:58)
                                    HStack {
                                        Text(page.title).font(.headline)
                                        Spacer()
                                        Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                                    }
                                    Text(page.detail).font(.subheadline).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .modifier(WorkspaceSurface())
                            }.buttonStyle(.plain)
                        }
                    }
                    DisclosureGroup("更多工具与实验") {
                        VStack(spacing: 14) {
                            ForEach(ProbePage.allCases.filter { !primaryPages.contains($0) }, id: \.self) { page in
                                NavigationLink(value: ProbeRoute(page)) { Label(page.title, systemImage: page.symbol).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7) }
                            }
                        }.padding(.top, 12)
                    }.padding(18).background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 20))
                    if let message = workspace.storageMessage { Notice(text: message) }
                    Notice(text:"字幕和声音提醒需要手动开启。识别可能有误，重要的时间、地点和金额请与对方核对。")
                }.frame(maxWidth: 1000).padding(20).frame(maxWidth: .infinity)
            }
            .background(SeePalette.canvas)
            .safeAreaInset(edge: .top) { WorkflowStatusArea(workspace: workspace) }
            .seePageCanvas().navigationTitle("沟通").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.principal) { Text("沟通").font(.headline).foregroundStyle(SeePalette.ink) }
                ToolbarItem(placement: .topBarLeading) {
                    Button { workspace.stop() } label: {
                        HStack(spacing:5) { Image(systemName:"stop.circle");Text("停止") }.font(.subheadline.weight(.medium))
                    }.accessibilityLabel("停止采集与共享")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink("待整理收件箱") { InboxPage(workspace:workspace,studio:workspace.workroom) }
                        NavigationLink("我的资料与分类") { LibraryOrganizerPage(workspace:workspace,studio:workspace.workroom) }
                        NavigationLink("完整体验") { ExampleExperiencePage(workspace:workspace,studio:workspace.workroom) }
                        NavigationLink("最近删除") { RecentlyDeletedPage(studio:workspace.workroom) }
                        NavigationLink("使用帮助") { ProductHelpPage() }
                        ForEach([ProbePage.agenda, .backup, .continuity, .reliability, .acceptance, .workroom, .cases, .bilingual, .search, .workbench, .intelligence, .lab, .routines, .demo, .profiles, .timeline, .information, .captions, .sharing, .saved, .reminders, .reading], id: \.self) { page in
                            Button(page.title, systemImage: page.symbol) { path.append(ProbeRoute(page)) }
                        }
                        Button("来源与许可", systemImage: "info.circle") { showCredits = true }
                    } label: { HStack(spacing:5) { Image(systemName:"ellipsis.circle");Text("工具") }.font(.subheadline.weight(.medium)) }.accessibilityLabel("常用工具")
                }
            }
            .sheet(isPresented: $showCredits) { CreditsView() }
            .confirmationDialog("清空本次会话的事件？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { workspace.clear() }
            }
            .navigationDestination(for: ProbeRoute.self) { route in
                let page = route.page
                Group {
                switch page {
                case .campus: CampusJourneyPage(workspace:workspace,studio:workspace.workroom)
                case .recentlyDeleted: RecentlyDeletedPage(studio:workspace.workroom)
                case .experience: ExampleExperiencePage(workspace:workspace,studio:workspace.workroom)
                case .inbox: InboxPage(workspace:workspace,studio:workspace.workroom)
                case .organizer: LibraryOrganizerPage(workspace:workspace,studio:workspace.workroom)
                case .calendar: CaseCalendarPage(workspace:workspace,studio:workspace.workroom)
                case .templates: CaseTemplatesPage(studio:workspace.workroom)
                case .cleanup: LibraryCleanupPage(studio:workspace.workroom)
                case .help: ProductHelpPage()
                case .diagnostics: DiagnosticExportPage(workspace:workspace)
                case .agenda: AgendaCenterPage(workspace:workspace,studio:workspace.workroom,routines:workspace.routines,agenda:workspace.agenda)
                case .backup: LibraryBackupPage(workspace:workspace)
                case .continuity: DeviceContinuityPage(workspace:workspace,bridge:workspace.bridge,studio:workspace.workroom,routines:workspace.routines)
                case .reliability: ReliabilityPage(workspace:workspace,quality:workspace.quality)
                case .acceptance: AcceptancePage(quality:workspace.quality)
                case .workroom: WorkroomPage(workspace: workspace, studio: workspace.workroom, api: workspace.workroomAPI, importer: workspace.workroomImporter)
                case .cases: Color.clear.task { selectedTab = 3;path = [] }
                case .bilingual: BilingualPage(workspace: workspace, api: workspace.translationAPI)
                case .search: GlobalSearchPage(workspace: workspace, studio: workspace.workroom, cards: workspace.information, routines: workspace.routines, conversations: workspace.conversations)
                case .intelligence: IntelligencePage(workspace: workspace, audio: workspace.audio, service: workspace.intelligence)
                case .workbench: WorkbenchPage(workspace: workspace, information: workspace.information, routines: workspace.routines)
                case .routines: RoutinePage(workspace: workspace, service: workspace.routines, information: workspace.information)
                case .profiles: SceneProfilesPage(workspace: workspace)
                case .information: InformationCardsPage(workspace: workspace, service: workspace.information)
                case .timeline: AssociationTimelinePage(workspace: workspace)
                case .demo: ScenarioDemoPage(workspace: workspace, audio: workspace.audio, sharing: workspace.textSharing, bridge: workspace.bridge)
                case .sound: SoundPage(audio: workspace.audio, workspace: workspace)
                case .hand: HandPage(hand: workspace.hand)
                case .captions: ConversationPage(audio: workspace.audio, workspace: workspace,startWithReply:route.startWithReply)
                case .watch: WatchPage(bridge: workspace.bridge, workspace: workspace)
                case .library: PhraseLibraryPage(workspace: workspace)
                case .transfer: PhraseTransferPage(workspace: workspace)
                case .offline: OfflineSpeechPage(service: workspace.offlineSpeech, audio: workspace.audio)
                case .feedback: FeedbackPreviewPage(workspace: workspace)
                case .samples: SoundSamplePage(workspace: workspace, library: workspace.samples)
                case .lab: EnvironmentalPage(workspace: workspace, service: workspace.environment)
                case .deviceCheck: DeviceCheckPage(workspace: workspace, bridge: workspace.bridge)
                case .sharing: TextSharingPage(service: workspace.textSharing, audio: workspace.audio, workspace: workspace)
                case .saved: SavedConversationsPage(service: workspace.conversations)
                case .reminders: ReminderSettingsPage(workspace: workspace, service: workspace.reminders)
                case .reading: ReadingSettingsPage(workspace: workspace)
                }
                }.safeAreaInset(edge: .top) {
                    if ![ProbePage.captions, .demo, .sharing].contains(page) { WorkflowStatusArea(workspace: workspace) }
                }
            }
            .navigationDestination(for: UUID.self) { id in EventDetail(workspace: workspace, eventID: id).safeAreaInset(edge: .top) { WorkflowStatusArea(workspace: workspace) } }
        }
    }

    private var primaryPages: [ProbePage] {
        [.library,.hand,.saved,.reading]
    }
    private var recentEvents: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近的提醒").font(.title3.bold())
                Spacer(); Button("全部提醒") { selectedTab = 1 }
            }
            if workspace.ledger.events.isEmpty {
                Text("还没有提醒。你可以主动开启声音关注或挥手检测。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                ForEach(workspace.ledger.events.prefix(2)) { event in
                    NavigationLink(value: event.id) { EventTile(event:event,bridge:workspace.bridge) }.buttonStyle(.plain)
                }
            }
            Text(workspace.preferences.saveHistory ? "本地记录 · 最多 40 条 · 保留 \(workspace.preferences.retentionDays) 天" : "历史保存未开启 · 提醒记录只留在本次运行中")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PrivacyStatus: View {
    @ObservedObject var audio: AudioProbes
    @ObservedObject var hand: HandProbe
    let stop: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(audio.mode != .idle || hand.isRunning ? Color.orange : Color.seeAccent).frame(width: 8, height: 8)
                Text(audio.mode != .idle || hand.isRunning ? "正在感知" : "由你决定何时开始").font(.headline)
                Spacer()
                Button("停止", role: .destructive, action: stop).buttonStyle(.bordered)
                    .accessibilityLabel("停止采集与朗读")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { captureLabels }
                VStack(alignment: .leading, spacing: 8) { captureLabels }
            }.font(.caption)
        }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(Color.seeAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var captureLabels: some View {
        Label(audio.isStarting ? "正在准备麦克风" : audio.mode == .idle ? "麦克风未采集" : audio.mode == .sound ? "声音分析中" : "字幕生成中", systemImage: "mic")
        Label(hand.isStarting ? "正在准备摄像头" : hand.isRunning ? "摄像头已开启" : "摄像头未开启", systemImage: "camera")
    }
}

struct Notice: View {
    let text: String
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) }
            icon: { Image(systemName: "info.circle") }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct EventRow: View {
    let event: SenseEvent
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title).font(.headline)
                    Text(event.isDemonstration ? "演示事件 · 非识别结果" : event.source == .sound ? "声音检测" : "实验性动作规则")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(event.lastSeen, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            Text("合并 \(event.count) 次检测窗口；不是物理敲击次数")
                .font(.caption).foregroundStyle(.secondary)
            if event.status == .confirmed { Label("已确认", systemImage: "checkmark.circle").font(.subheadline) }
            else { Button("我已看到", action: confirm).buttonStyle(.bordered) }
        }.padding(16).background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct SoundPage: View {
    @ObservedObject var audio: AudioProbes
    @ObservedObject var workspace: Workspace
    var body: some View {
        Form {
            Section("本机声音识别") {
                Picker("声音引擎", selection: Binding(get: { workspace.preferences.soundEngine }, set: { engine in workspace.updatePreferences { $0.soundEngine = engine } })) {
                    ForEach(EnvironmentalEngine.allCases) { Text($0.title).tag($0) }
                }
                Text("切换会停止采集，之后手动开启。YAMNet 可输出 521 类得分；正式提醒仍仅使用已关注的敲门、门铃和拍手，阈值需真机校准。").font(.caption).foregroundStyle(.secondary)
                NavigationLink("用公开录音检查 YAMNet") { EnvironmentalPage(workspace: workspace, service: workspace.environment) }
                InputSignalView(audio: audio)
                Text(audio.status)
                Button(audio.mode == .sound ? "停止声音识别" : "开始声音识别") {
                    if audio.mode == .sound { audio.stop() }
                    else { Task { await audio.startSounds() } }
                }.disabled(audio.isStarting || workspace.preferences.sounds.isEmpty)
                if audio.isStarting { ProgressView("正在准备") }
                if workspace.preferences.sounds.isEmpty { Text("请在「我的」中至少选择一种关注声音。").foregroundStyle(.secondary) }
            }
            Section("当前引擎的最近输出") {
                if audio.soundResults.isEmpty { Text("等待真实输入；这里不会填充模拟模型得分").foregroundStyle(.secondary) }
                ForEach(audio.soundResults, id: \.label) { item in
                    HStack {
                        Text(AudioProbes.title(for: item.label))
                        Spacer()
                        Text(item.score, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }
                }
                Text("模型得分未经本项目真人场景校准，不等于正确概率。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("当前关注类别") {
                ForEach(SoundKind.allCases) { kind in
                    LabeledContent(kind.title, value: workspace.preferences.sounds.contains(kind) ? "已关注" : "已关闭")
                }
                Text("\(workspace.preferences.sensitivity.title)：连续 \(workspace.preferences.sensitivity.windows) 个窗口的首位类别得分至少为 \(workspace.preferences.sensitivity.threshold, format: .number.precision(.fractionLength(2))) 才进入事件整理。可在「我的」修改；阈值仍需真机校准。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("明确标注的界面演示") {
                Button("加入一条演示事件") {
                    workspace.register(category: "demo-knock", title: "敲门提醒界面演示", source: .demonstration)
                }
                ForEach(workspace.ledger.events.prefix(5)) { event in
                    EventRow(event: event) { workspace.confirm(event.id) }
                }
            }
        }.seePageCanvas().navigationTitle("声音关注")
    }
}

private final class CameraSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let view = CameraSurface()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct HandPage: View {
    @ObservedObject var hand: HandProbe
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(.black)
                    if hand.isRunning {
                        CameraPreview(session: hand.session).clipShape(RoundedRectangle(cornerRadius: 24))
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "hand.wave").font(.largeTitle)
                            Text("你开启后，画面才会出现")
                        }.foregroundStyle(.white).padding()
                    }
                }.aspectRatio(3.0 / 4.0, contentMode: .fit).frame(maxHeight: 480)
                Text(hand.status).font(.headline)
                Text("当前有效关键点：\(hand.points.count)").foregroundStyle(.secondary)
                Button(hand.isRunning ? "停止摄像头" : "开启手部检测") {
                    if hand.isRunning { hand.stop() }
                    else { Task { await hand.start() } }
                }.buttonStyle(.borderedProminent).tint(SeePalette.button).disabled(hand.isStarting)
                if hand.isStarting { ProgressView("准备摄像头") }
                Notice(text: "这是基于关键点运动的挥手规则原型，不是训练好的动作模型；不能识别对方是否在叫你，也不会替你确认提醒。原始画面不保存。")
                Notice(text: "请先竖屏验证。摄像头遮挡、离开画面或关键点不足时，不作挥手判断。")
            }.padding(20).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }.background(SeePalette.canvas).seePageCanvas().navigationTitle("挥手检测")
    }
}


struct WatchPage: View {
    @ObservedObject var bridge: ConnectivityBridge
    @ObservedObject var workspace: Workspace
    var body: some View {
        Form {
            Section("配对设备") {
                WatchConnectionPanel(bridge:bridge)
                Text("先在配对的 iPhone 和 Watch 上安装「见声」，并打开两端 App。iPad 不直接接入这条链路。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("手动通信测试") {
                Button("发送通信测试卡") {
                    let event = workspace.register(category: "watch-test", title: "见声通信测试", source: .demonstration)
                    bridge.sendEvent(event)
                }.disabled(!bridge.reachable || bridge.latestEvent.map { bridge.isSending($0.id) } == true)
                Text(bridge.delivery)
                if let event = bridge.latestEvent {
                    Text(event.title).font(.headline)
                    if let note = bridge.confirmationNotes[event.id] {
                        if note != bridge.delivery { Text(note) }
                    } else { Text("尚未完成用户确认") }
                    if let reply = bridge.quickReplyNotes[event.id] { Text("手表回应：\(reply)").foregroundStyle(Color.seeAccent) }
                    if workspace.event(event.id)?.status == .pending {
                        Button("在手机上确认这条提醒", systemImage: "checkmark.circle") { workspace.confirm(event.id) }
                    } else if !bridge.confirmedIDs.contains(event.id) {
                        Button("重试同步手机确认", systemImage: "arrow.clockwise") { bridge.syncConfirmation(event.id) }
                            .disabled(!bridge.reachable || bridge.isSending(event.id))
                    }
                    if bridge.transfers.records[event.id]?.phase == .failed,
                       workspace.event(event.id)?.status == .pending {
                        Button("重试发送这条事件", systemImage: "arrow.clockwise") { bridge.sendEvent(event) }
                            .disabled(!bridge.reachable)
                    }
                }
                Text("接收回执不等于用户已读。测试卡会标注为演示，不冒充真实识别事件。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("真实事件也可以手动转发") {
                Text("在「事件 → 事件详情」中，可将最近 5 分钟内、尚未确认的提醒手动发送到手表。声音模型、动作规则和演示标记会随事件一起传递。")
                Text("不会自动发送，不上传音视频，不建立远程联系人。不可达时不排队，过期消息会拒收；后台通知和离线补传仍未实现。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.seePageCanvas().navigationTitle("腕上回应")
    }
}

struct CreditsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("已采用的基础代码") {
                    Text("Apple：Classifying Live Audio Input with a Built-in Sound Classifier。复用并修改声音采集与分类服务；移除同步权限等待，增加输入格式检查和退出时的分析队列清理。")
                    Text("Apple：Detecting Hand Poses with Vision。参考摄像头、Vision 请求和关键点处理；新增本项目的实验性挥手时序规则。")
                    Text("Naoya Maeda：Watch-Connectivity-Sample（MIT）。参考会话激活与消息回传；新增事件结构、有效期、回执和用户确认区分。")
                }
                Section("新增采用的开源组件") {
                    ForEach(AdoptedLibrary.all) { library in
                        VStack(alignment: .leading, spacing: 7) {
                            Link("\(library.name) · \(library.version)", destination: URL(string: library.url)!)
                            Text(library.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("源码以固定版本随工程保留。WhisperKit 仅接入可选文件转写；模型与真实效果另行验证。Vocable 复用的是短语与分类资源。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("后续候选") {
                    Text("sherpa-onnx、MediaPipe 与 TCA 尚未接入。模型与开源组件的来源及许可保留在工程中。")
                }
                Section("公开声音数据") {
                    Link("ESC-50 · Karol J. Piczak", destination: URL(string: "https://github.com/karolpiczak/ESC-50")!)
                    Text("见声三类子集：敲门、拍手，以及键盘 / 吸尘器。CC BY-NC 3.0；24 段测试录音随实验室提供，保留原始署名。")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("完整数据许可与逐段署名") {
                        ScrollView { Text(license("ESC50-LICENSE")).font(.caption).textSelection(.enabled).padding(20) }.seePageCanvas().navigationTitle("ESC-50 许可")
                    }
                }
                ForEach(["AppleSound-LICENSE", "AppleHand-LICENSE", "WatchSample-LICENSE", "ThirdParty-Notices"], id: \.self) { name in
                    Section(name) {
                        Text(license(name)).font(.caption).textSelection(.enabled)
                    }
                }
            }.seePageCanvas().navigationTitle("来源与许可")
        }
    }
    private func license(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url) else { return "许可文件未能读取；完整原文同时保留在项目 References 目录。" }
        return text
    }
}
