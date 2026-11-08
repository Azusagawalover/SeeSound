import SwiftUI

struct WorkflowStatusArea: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.scenePhase) private var phase
    var body: some View {
        if phase == .active {
            VStack(spacing: 6) {
                DemoActivityStrip(workspace: workspace) { workspace.navigationRequest = .demo }
                SharedConnectionStrip(service: workspace.textSharing) { workspace.navigationRequest = .sharing }
                ReminderBanner(workspace: workspace, service: workspace.reminders, bridge: workspace.bridge)
            }
        }
    }
}

struct ReminderBanner: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var service: ReminderService
    @ObservedObject var bridge: ConnectivityBridge
    @State private var showQueue = false
    private var availableCount: Int { service.queue.available().count }
    var body: some View {
        Group {
            if let event = service.activeEvent {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(service.hasPreview ? "规则预览" : "\(availableCount) 条待查看", systemImage: "tray.full").font(.caption.bold())
                        Spacer()
                        if !service.queue.entries.isEmpty { Button("全部") { showQueue = true }.font(.caption) }
                        Button("收起", systemImage: "chevron.up") { service.dismiss() }.labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44).accessibilityLabel("收起卡片，保留待处理队列")
                    }
                    Text(event.title).font(service.activePriority == .prominent ? .title2.bold() : .headline)
                    Text(event.isDemonstration ? "演示事件 · 非识别结果" : event.source == .gesture ? "实验性动作规则" : "声音检测事件")
                        .font(.caption).foregroundStyle(.secondary)
                    if let note = bridge.quickReplyNotes[event.id] { Text("手表回应：" + note).font(.subheadline) }
                    if !service.hasPreview { EventActionButton(workspace: workspace, eventID: event.id).font(.subheadline) }
                    ViewThatFits(in: .horizontal) {
                        HStack { actions(event) }
                        VStack(alignment: .leading) { actions(event) }
                    }
                }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.seeAccent, lineWidth: service.activePriority == .prominent ? 3 : 1))
                    .padding(.horizontal, 12).frame(maxWidth: 750)
            } else if !service.queue.entries.isEmpty {
                HStack {
                    Label(availableCount > 0 ? "\(availableCount) 条待查看" : "\(service.queue.entries.count) 条已暂缓", systemImage: "tray.full")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button(availableCount > 0 ? "展开" : "查看队列") {
                        if availableCount > 0 { service.restoreQueue() } else { showQueue = true }
                    }.font(.caption)
                    Button("全部") { showQueue = true }.font(.caption)
                }.padding(.horizontal, 18).padding(.vertical, 10).background(Color.seeAccent.opacity(0.08))
            }
        }.sheet(isPresented: $showQueue) { ReminderQueuePage(workspace: workspace, service: service, bridge: bridge) }
    }
    @ViewBuilder private func actions(_ event: SenseEvent) -> some View {
        Button("我已看到") { if !workspace.confirm(event.id) { service.confirm(event.id) } }.buttonStyle(.borderedProminent).tint(SeePalette.button)
        Button("此类暂缓 5 分钟") { service.snooze(event) }.buttonStyle(.bordered)
        if !service.hasPreview && availableCount > 1 { Button("下一条") { service.next() }.buttonStyle(.bordered) }
    }
}

struct ReminderQueuePage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var service: ReminderService
    @ObservedObject var bridge: ConnectivityBridge
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("新提醒会排队，保留你正在看的卡片。下一条和收起都不会确认事件；醒目提醒在选择下一条时优先。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("\(service.queue.available().count) 条可查看 · \(service.queue.entries.count - service.queue.available().count) 条暂缓")
                }
                if service.queue.entries.isEmpty { ContentUnavailableView("队列已处理完", systemImage: "checkmark.circle", description: Text("原事件仍可在事件页中查看。")) }
                ForEach(service.queue.entries) { entry in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(entry.event.title).font(.headline)
                            Spacer()
                            if entry.priority == .prominent { Label("醒目", systemImage: "exclamationmark.circle").font(.caption) }
                        }
                        Text(entry.event.isDemonstration ? "演示 · 非识别结果" : entry.event.source == .gesture ? "实验性动作规则" : "声音检测")
                            .font(.caption).foregroundStyle(.secondary)
                        EventActionButton(workspace: workspace, eventID: entry.id)
                        if let date = entry.snoozedUntil, date > Date() {
                            Text("暂缓到 \(date, style: .time)").font(.subheadline)
                            Button("恢复这一类") { service.resume(ReminderQueue.categoryKey(for: entry.event)) }
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack { entryActions(entry.event) }
                                VStack(alignment: .leading) { entryActions(entry.event) }
                            }
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Button("转发到配对手表", systemImage: "applewatch") { bridge.sendEvent(entry.event) }
                                .disabled(!bridge.reachable || bridge.isSending(entry.id) || context.date.timeIntervalSince(entry.event.lastSeen) > 300)
                        }
                        if let note = bridge.quickReplyNotes[entry.id] { Text("手表回应：\(note) · 回应不等于确认").font(.caption).foregroundStyle(Color.seeAccent) }
                    }.padding(.vertical, 6)
                }
                Section("手表连接") {
                    Text(bridge.status).font(.footnote)
                    Button("激活 / 检查通信") { bridge.activate() }
                    Text("只手动转发最近五分钟内的待确认事件，不可达时不排队。") .font(.footnote).foregroundStyle(.secondary)
                }
            }.seePageCanvas().navigationTitle("待处理提醒").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear { service.refreshQueue() }
                .overlay { if phase != .active { DailyPrivacyCover() } }
        }
    }
    @ViewBuilder private func entryActions(_ event: SenseEvent) -> some View {
        Button("查看这条") { service.show(event.id); dismiss() }.buttonStyle(.bordered)
        Button("我已看到") { workspace.confirm(event.id) }.buttonStyle(.borderedProminent).tint(SeePalette.button)
        Button("暂缓此类") { service.snooze(event) }.buttonStyle(.bordered)
    }
}

struct DemoActivityStrip: View {
    @ObservedObject var workspace: Workspace
    let open: () -> Void
    var body: some View {
        if let run = workspace.demoRun {
            HStack(spacing: 10) {
                Label("演示 · \(run.scenario.title)", systemImage: "play.rectangle").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Button("步骤", action: open).font(.caption)
                Button("结束") { workspace.finishDemo() }.font(.caption)
            }.foregroundStyle(Color.seeAccent).padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.seeAccent.opacity(0.08))
        }
    }
}

struct ScenarioDemoPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var audio: AudioProbes
    @ObservedObject var sharing: TextSharingService
    @ObservedObject var bridge: ConnectivityBridge
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("先体验，再决定怎么用", systemImage: "play.rectangle").font(.title2.bold())
                    Text("用标注清楚的预设文字和事件，走一遍见声的使用流程。") .foregroundStyle(.secondary)
                }
                if let run = workspace.demoRun { running(run) }
                else {
                    Notice(text: "开始演示会停止采集、结束已有文字共享，暂存当前对话与输入草稿。结束后恢复原对话；不录音、不发系统通知、不写入事件历史。")
                    ForEach(DemoScenario.allCases) { scenario in
                        VStack(alignment: .leading, spacing: 14) {
                            Label(scenario.title, systemImage: scenario.symbol).font(.title3.bold())
                            Text(scenario.detail).foregroundStyle(.secondary)
                            Button("开始\(scenario.title)演示", systemImage: "play.fill") { workspace.startDemo(scenario) }
                                .buttonStyle(.borderedProminent).tint(SeePalette.button)
                        }.dailyCard()
                    }
                }
                Notice(text: "本机演示不伪造设备连接或识别成功。需要跨设备时，仍由你在两端连接、允许、转发和确认；没有手表或 iPad 也能体验本机部分。")
            }.padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.background(SeePalette.canvas).seePageCanvas().navigationTitle("场景演示")
            .safeAreaInset(edge: .top) { WorkflowStatusArea(workspace: workspace) }
            .overlay { if phase != .active { DailyPrivacyCover() } }
    }
    @ViewBuilder private func running(_ run: DemoRun) -> some View {
        HStack {
            Label("正在演示：\(run.scenario.title)", systemImage: run.scenario.symbol).font(.headline)
            Spacer()
            Button("结束并恢复") { workspace.finishDemo() }.buttonStyle(.bordered)
        }
        if !run.eventIDs.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Label("1 · 查看来访提醒", systemImage: "tray.full").font(.headline)
                Text("预设门铃与敲门已加入队列。可以逐条查看、暂缓和确认；原来的真实提醒仍保留。") .font(.subheadline).foregroundStyle(.secondary)
                ForEach(run.eventIDs, id: \.self) { id in
                    if let event = workspace.event(id) {
                        HStack {
                            Text(event.title)
                            Spacer()
                            Text(event.status == .confirmed ? "你已确认" : "待确认").font(.caption).foregroundStyle(.secondary)
                        }
                        if event.status == .pending { Button("查看这条提醒") { workspace.reminders.show(id) }.buttonStyle(.bordered) }
                    }
                }
            }.dailyCard()
        }
        VStack(alignment: .leading, spacing: 14) {
            Label(run.scenario == .visitor ? "2 · 用文字回应来访者" : "1 · 阅读并回应", systemImage: "captions.bubble").font(.headline)
            Text("回应框已准备一句示例。进入沟通页，切换「阅读 / 回应」，可改字、选择沟通卡，再主动显示或朗读。") .font(.subheadline).foregroundStyle(.secondary)
            NavigationLink { AnyView(ConversationPage(audio: audio, workspace: workspace)) } label: { Label("打开专注沟通", systemImage: "arrow.up.right") }.buttonStyle(.borderedProminent).tint(SeePalette.button)
            if audio.conversation.turns.contains(where: { $0.speaker == .me && $0.origin == .demonstration }) {
                Label("已加入你的演示回应", systemImage: "checkmark.circle").font(.subheadline)
            } else { Text("尚未加入自己的回应").font(.caption).foregroundStyle(.secondary) }
        }.dailyCard()
        if run.scenario != .visitor && run.scenario != .conversation {
            DemoInformationStep(workspace: workspace, information: workspace.information, routines: workspace.routines)
        }
        VStack(alignment: .leading, spacing: 14) {
            Label(run.scenario == .visitor ? "3 · 体验腕上回应" : "2 · 让 iPad 显示文字", systemImage: run.scenario == .visitor ? "applewatch" : "ipad.and.iphone").font(.headline)
            if run.scenario == .visitor {
                Text(bridge.status).font(.subheadline).foregroundStyle(.secondary)
                Button("激活 / 检查手表连接") { bridge.activate() }
                ForEach(run.eventIDs, id: \.self) { id in
                    if let event = workspace.event(id) {
                        Button("转发：\(event.title)") { bridge.sendEvent(event) }
                            .buttonStyle(.bordered).disabled(!bridge.reachable || bridge.isSending(id) || event.status == .confirmed || Date().timeIntervalSince(event.lastSeen) > 300)
                        if let note = bridge.quickReplyNotes[id] { Text("手表回应：\(note) · 不等于确认").foregroundStyle(Color.seeAccent) }
                        if bridge.confirmedIDs.contains(id) { Text(bridge.confirmationNotes[id] ?? "对端已确认").font(.caption) }
                    }
                }
                Text(bridge.delivery).font(.caption).foregroundStyle(.secondary)
            } else {
                NavigationLink("连接 iPad 文字屏") { TextSharingPage(service: sharing, audio: audio, workspace: workspace) }.buttonStyle(.bordered)
                Text(sharing.status).font(.subheadline).foregroundStyle(.secondary)
                if sharing.isConnected {
                    Text(sharing.acknowledgedRevision == sharing.revision && sharing.revision >= 0 ? "当前文字已获得对方主动确认" : "设备已连接，当前文字尚未获对方主动确认")
                        .font(.caption)
                }
            }
        }.dailyCard()
        Notice(text: "演示对话是独立临时内容。只有你在保存页逐次确认才会保存；跨设备也只传当前演示。结束时清除演示事件与共享，再恢复原对话和输入草稿。")
    }
}

private struct DemoInformationStep: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var information: InformationCardService
    @ObservedObject var routines: RoutineService
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("核对约定，再留成待办", systemImage: "checklist").font(.headline)
            Text("下面的卡片由这套演示预设，不是自动识别或提取。请先标记核对，再手动建立待办；不会自动标记已核对或完成。").font(.subheadline).foregroundStyle(.secondary)
            Button("准备这套演示的信息卡") { workspace.prepareDemoInformation() }.buttonStyle(.borderedProminent).tint(SeePalette.button)
            ForEach(workspace.demoRun?.informationIDs ?? [], id: \.self) { id in
                if let card = information.cards.first(where: { $0.id == id }) {
                    Label(card.kind.title + "：" + card.displayValue + (card.reviewed ? " · 你已标记核对" : " · 待核对"), systemImage: card.reviewed ? "checkmark.circle" : "circle").font(.subheadline)
                }
            }
            NavigationLink("打开信息卡，核对并建立待办") { InformationCardsPage(workspace: workspace, service: information) }.buttonStyle(.bordered)
            NavigationLink("查看演示待办") { RoutinePage(workspace: workspace, service: routines, information: information) }.buttonStyle(.bordered)
            Text("结束或切换演示时清理未保存的演示卡与待办；逐项主动保存的演示记录继续带有演示标记。").font(.caption).foregroundStyle(.secondary)
        }.dailyCard()
    }
}
