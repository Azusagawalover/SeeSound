import SwiftUI

struct WelcomeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("见声 SEESOUND", systemImage: "ear.badge.waveform")
                    .font(.caption.weight(.bold)).tracking(1.5)
                Spacer()
                Image(systemName: "sparkle").font(.title2).accessibilityHidden(true)
            }
            Text("留意身边，\n也安心做自己。")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(["声音", "动作", "沟通"], id: \.self) { item in
                    Text(item).font(.caption.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 7)
                        .background(SeePalette.oat, in: Capsule())
                }
            }
        }
        .foregroundStyle(SeePalette.ink).padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
              ZStack(alignment: .trailing) {
                LinearGradient(colors: [SeePalette.surface, SeePalette.rose.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                ZStack {
                    ForEach(0..<4) { index in
                        Circle().stroke(SeePalette.line.opacity(0.5), lineWidth: 1)
                            .frame(width: CGFloat(95 + index * 64), height: CGFloat(95 + index * 64))
                    }
                }.offset(x: 100).accessibilityHidden(true)
              }.frame(width: geometry.size.width, height: geometry.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 28))
            }
        }
    }
}

extension SenseEvent {
    var sourceTitle: String {
        switch source { case .sound: return "声音模型"; case .gesture: return "动作规则"; case .demonstration: return "演示 · 非识别结果" }
    }
    var symbol: String {
        if isDemonstration { return "play.rectangle" }
        if source == .gesture { return "hand.wave" }
        return SoundKind.matching(category)?.symbol ?? "waveform"
    }
}

struct EventTile: View {
    let event: SenseEvent
    var bridge: ConnectivityBridge? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    private var sourceDescription: String {
        event.isDemonstration ? event.sourceTitle : event.sourceTitle + " · 候选提醒"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: event.symbol).font(.title3).foregroundStyle(SeePalette.ink)
                    .frame(width: 42, height: 42)
                    .background(event.isDemonstration ? SeePalette.oat : SeePalette.rose, in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(event.title).font(.headline).foregroundStyle(SeePalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sourceDescription).font(.subheadline).foregroundStyle(SeePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { acknowledgment; eventTime }
                    VStack(alignment: .leading, spacing: 8) { acknowledgment; eventTime }
                }
                if let bridge { EventWatchReceipt(bridge: bridge, eventID: event.id) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(SeePalette.secondary).padding(.top, 4).accessibilityHidden(true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .combine)
            .accessibilityHint("打开详情，查看来源、转发到手表或标记误报")
    }

    private var acknowledgment: some View {
        Label(event.status == .confirmed ? "已确认看到" : "待你查看",
              systemImage: event.status == .confirmed ? "checkmark.circle.fill" : "circle.dotted")
            .font(.subheadline.weight(.semibold)).foregroundStyle(SeePalette.ink)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(event.status == .confirmed ? SeePalette.sage : SeePalette.rose, in: Capsule())
    }

    private var eventTime: some View {
        Text(event.lastSeen, format: .dateTime.month().day().hour().minute())
            .font(.caption).foregroundStyle(SeePalette.secondary)
    }
}

private enum JournalFilter: String, CaseIterable, Identifiable {
    case all = "全部", pending = "待查看", confirmed = "已看到", corrections = "标记误报"
    var id: String { rawValue }
}

struct EventCenter: View {
    @ObservedObject var workspace: Workspace
    @State private var search = ""
    @State private var filter: JournalFilter = .all
    @State private var source = "all"
    @State private var confirmClear = false

    private var events: [SenseEvent] {
        workspace.ledger.events.filter { event in
            let statusMatches = filter == .all || filter == .pending && event.status == .pending
                || filter == .confirmed && event.status == .confirmed
                || filter == .corrections && workspace.annotations[event.id]?.verdict == .falseAlarm
            let sourceMatches = source == "all" || event.source.rawValue == source
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches = query.isEmpty || event.title.localizedCaseInsensitiveContains(query)
                || event.sourceTitle.localizedCaseInsensitiveContains(query)
                || (workspace.annotations[event.id]?.note.localizedCaseInsensitiveContains(query) ?? false)
            return statusMatches && sourceMatches && searchMatches
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("留意到的事，都在这里")
                            .font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(SeePalette.ink)
                        Text("先查看，再确认。声音和动作的候选提醒，可以由你复核。")
                            .font(.subheadline).foregroundStyle(SeePalette.secondary)
                    }
                    HStack(spacing: 12) {
                        summary("待你查看", count: workspace.ledger.events.filter { $0.status == .pending }.count,
                                symbol: "circle.dotted", selection: .pending)
                        summary("已确认看到", count: workspace.ledger.events.filter { $0.status == .confirmed }.count,
                                symbol: "checkmark.circle", selection: .confirmed)
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("alerts.status")
                    ReminderToolLinks(workspace: workspace, audio: workspace.audio, hand: workspace.hand, bridge: workspace.bridge)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("提醒记录").font(.title3.bold()).foregroundStyle(SeePalette.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text("「我已看到」只表示你已收到提醒，不代表识别正确。可到详情标记误报。")
                            .font(.footnote).foregroundStyle(SeePalette.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(JournalFilter.allCases) { option in
                                    Button { filter = option } label: {
                                        Text(option.rawValue).font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 15).frame(minHeight: 44)
                                            .foregroundStyle(SeePalette.ink)
                                            .background(filter == option ? SeePalette.rose : SeePalette.surface, in: Capsule())
                                            .overlay(Capsule().stroke(filter == option ? SeePalette.button : SeePalette.line, lineWidth: 1))
                                    }.buttonStyle(.plain)
                                        .accessibilityAddTraits(filter == option ? .isSelected : [])
                                        .accessibilityLabel("筛选：\(option.rawValue)")
                                }
                            }.padding(.vertical, 1)
                        }
                    }
                    HStack {
                        Text("\(events.count) 条记录").font(.subheadline).foregroundStyle(SeePalette.secondary)
                        Spacer()
                        Picker("事件来源", selection: $source) {
                            Text("所有来源").tag("all")
                            Text("声音模型").tag(EventSource.sound.rawValue)
                            Text("动作规则").tag(EventSource.gesture.rawValue)
                            Text("演示").tag(EventSource.demonstration.rawValue)
                        }.pickerStyle(.menu).frame(minHeight: 44)
                    }
                    if events.isEmpty {
                        SeeEmptyState(title:search.isEmpty ? "暂时没有这类提醒" : "没有找到匹配记录",detail:"你可以进入声音关注或挥手检测，手动开启后留意身边的动静。演示事件会单独标明。",artwork:.headphone)
                    }
                    ForEach(events) { event in
                        ReminderRecordCard(workspace: workspace, event: event)
                    }
                    Notice(text: workspace.preferences.saveHistory
                           ? "摘要保存在这台设备，最多 40 条、保留 \(workspace.preferences.retentionDays) 天。到期记录会在打开 App 或更新记录时清理。演示也会标注保存。"
                           : "尚未开启历史保存。关闭 App 进程后，本次事件和复核备注不会保留；常用语和偏好单独保存在本机。")
                    if let message = workspace.storageMessage { Notice(text: message) }
                }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
            }.background(SeePalette.canvas)
                .safeAreaInset(edge: .top) { WorkflowStatusArea(workspace: workspace) }
                .seePageCanvas().navigationTitle("提醒")
                .searchable(text: $search, prompt: "搜索事件或备注")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ShareLink(item: JournalExport.summary(events: events, annotations: workspace.annotations)) {
                                Label("导出当前筛选摘要", systemImage: "square.and.arrow.up")
                            }.disabled(events.isEmpty)
                            Button("清空所有记录", systemImage: "trash", role: .destructive) { confirmClear = true }
                                .disabled(workspace.ledger.events.isEmpty)
                        } label: { Label("记录操作", systemImage: "ellipsis.circle") }
                    }
                }
                .confirmationDialog("删除全部事件和复核备注？", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("删除全部记录", role: .destructive) { workspace.clear() }
                } message: { Text("此操作同时更新本地历史。已由你导出的副本需要单独删除。") }
                .navigationDestination(for: UUID.self) { id in EventDetail(workspace: workspace, eventID: id) }
        }
    }

    private func summary(_ title: String, count: Int, symbol: String, selection: JournalFilter) -> some View {
        Button { filter = selection } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(count, format: .number).font(.system(.title, design: .rounded, weight: .bold))
            }.foregroundStyle(SeePalette.ink).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(SeePalette.line, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("\(title)，\(count) 条，查看记录")
    }
}

private struct ReminderRecordCard: View {
    @ObservedObject var workspace: Workspace
    let event: SenseEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: event.id) {
                VStack(alignment: .leading, spacing: 0) {
                    EventTile(event: event, bridge: workspace.bridge)
                    if let verdict = workspace.annotations[event.id]?.verdict, verdict != .unreviewed {
                        Label("你的复核：\(verdict.title)", systemImage: "text.badge.checkmark")
                            .font(.subheadline).foregroundStyle(SeePalette.ink)
                            .padding(.horizontal, 16).padding(.bottom, 16)
                    }
                }
            }.buttonStyle(.plain).accessibilityIdentifier("alerts.event.\(event.id.uuidString)")
            if event.status == .pending {
                Button("我已看到", systemImage: "checkmark.circle") { workspace.confirm(event.id) }
                    .buttonStyle(SeeSecondaryButtonStyle())
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    .accessibilityLabel("\(event.title)，我已看到")
                    .accessibilityHint("确认收到这条提醒；不会将识别结果标为正确")
                    .accessibilityIdentifier("alerts.confirm.\(event.id.uuidString)")
            }
        }.background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(SeePalette.line, lineWidth: 1))
    }
}

private struct ReminderToolLinks: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var audio: AudioProbes
    @ObservedObject var hand: HandProbe
    @ObservedObject var bridge: ConnectivityBridge

    private var soundStatus: String {
        if audio.isStarting { return "正在准备麦克风" }
        switch audio.mode {
        case .idle: return "未开启声音分析"
        case .sound: return "声音分析中"
        case .captions: return "麦克风用于字幕"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink { SoundPage(audio: audio, workspace: workspace) } label: {
                tool("声音关注", status: soundStatus, symbol: "waveform", wash: SeePalette.lilac)
            }.accessibilityIdentifier("alerts.sound")
            Divider().overlay(SeePalette.line).padding(.leading, 52)
            NavigationLink { HandPage(hand: hand) } label: {
                tool("挥手检测", status: hand.isStarting ? "正在准备摄像头" : hand.isRunning ? "手部检测中" : "摄像头未开启",
                     symbol: "hand.wave", wash: SeePalette.oat)
            }.accessibilityIdentifier("alerts.hand")
            Divider().overlay(SeePalette.line).padding(.leading, 52)
            NavigationLink { WatchPage(bridge: bridge, workspace: workspace) } label: {
                tool("腕上回应", status: bridge.linkState.title, symbol: "applewatch", wash: SeePalette.sky)
            }.accessibilityIdentifier("alerts.watch")
        }.buttonStyle(.plain)
            .background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(SeePalette.line, lineWidth: 1))
            .accessibilityElement(children: .contain)
    }

    private func tool(_ title: String, status: String, symbol: String, wash: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(SeePalette.ink)
                .frame(width: 32, height: 32).background(wash, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(SeePalette.ink)
                    Spacer(minLength: 4)
                    Text(status).font(.caption).foregroundStyle(SeePalette.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(SeePalette.ink)
                    Text(status).font(.caption).foregroundStyle(SeePalette.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(SeePalette.secondary).accessibilityHidden(true)
        }.padding(.horizontal, 14).padding(.vertical, 11).frame(minHeight: 54)
            .contentShape(Rectangle()).accessibilityElement(children: .combine)
            .accessibilityHint("打开工具，查看状态和可用操作")
    }
}

private struct EventWatchReceipt: View {
    @ObservedObject var bridge: ConnectivityBridge
    let eventID: UUID

    private var receipt: String {
        guard let record = bridge.transfers.records[eventID] else {
            return bridge.latestEvent?.id == eventID ? "Watch：\(bridge.delivery)" : "Watch：尚无接收回执"
        }
        switch record.phase {
        case .sending: return "Watch：等待接收回执"
        case .received: return "Watch App 已接收 · 不代表用户已看到"
        case .confirmed: return bridge.confirmationNotes[eventID] ?? record.message
        case .failed: return "Watch：\(record.message)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(receipt, systemImage: "applewatch")
            if let reply = bridge.quickReplyNotes[eventID] {
                Text("手表回应：\(reply) · 回应不等于确认")
            }
        }.font(.caption).foregroundStyle(SeePalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct EventDetail: View {
    @ObservedObject var workspace: Workspace
    let eventID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var verdict: EventVerdict = .unreviewed
    @State private var note = ""
    @State private var confirmDelete = false
    @State private var saved = false
    @FocusState private var noteFocused: Bool
    private var event: SenseEvent? { workspace.event(eventID) }

    var body: some View {
        Group {
            if let event {
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(event.sourceTitle, systemImage: event.symbol).font(.subheadline).foregroundStyle(Color.seeAccent)
                            Text(event.title).font(.title2.bold())
                            EventActionButton(workspace: workspace, eventID: event.id)
                            Text(event.lastSeen, format: .dateTime.month().day().hour().minute().second()).foregroundStyle(.secondary)
                            if event.status == .pending {
                                Button("我已看到", systemImage: "checkmark.circle") { workspace.confirm(event.id) }
                                    .buttonStyle(.borderedProminent).tint(SeePalette.button)
                            } else { Label("已确认", systemImage: "checkmark.circle.fill").foregroundStyle(Color.seeAccent) }
                        }.padding(.vertical, 8)
                    }
                    Section("为什么会有这条提醒") {
                        Text(event.isDemonstration ? "这是一条用户主动加入的演示事件，不来自麦克风或摄像头。"
                             : event.source == .sound ? "系统声音分类器的首位类别经过连续窗口规则后形成候选提醒。记录未保存音频或原始模型得分，无法据此复听或计算准确率。"
                             : "手部关键点的横向往返运动满足实验性规则。它不能判断对方是否在叫你，记录不包含原始画面。")
                        LabeledContent("合并检测窗口", value: "\(event.count)")
                        Text("窗口数不是实际敲门或挥手次数；你的确认只表示已看到，不代表模型识别正确。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("人工复核") {
                        Picker("与实际是否相符", selection: $verdict) {
                            ForEach(EventVerdict.allCases) { Text($0.title).tag($0) }
                        }
                        TextField("补充备注（最多 500 字）", text: $note, axis: .vertical).lineLimit(3...6)
                            .focused($noteFocused)
                            .onChange(of: note) { _, value in if value.count > 500 { note = String(value.prefix(500)) }; saved = false }
                        Button(saved ? "复核已更新" : "保存复核") {
                            workspace.annotate(event.id, verdict: verdict, note: note)
                            noteFocused = false
                            saved = true
                        }
                        Text(workspace.demoLedger.events.contains(where: { $0.id == event.id }) ? "这条演示复核只保留到演示结束，不写入真实事件历史。" : workspace.preferences.saveHistory ? "复核与事件一起保存在本机；不会自动用于训练。" : "复核只在本次运行保留；要长期保存，请在「我的」自愿开启历史记录。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("腕上回应") {
                        WatchForwardAction(bridge: workspace.bridge, event: event)
                    }
                    Section {
                        ShareLink(item: JournalExport.summary(events: [event], annotations: workspace.demoAnnotations.merging(workspace.annotations) { _, real in real })) {
                            Label("分享此事件摘要", systemImage: "square.and.arrow.up")
                        }
                        Text("摘要包含时间、类别、状态与复核标签，不包含备注或原始媒体。发送前可选择接收方。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("删除这条记录", role: .destructive) { confirmDelete = true }
                    }
                    if let message = workspace.storageMessage { Section { Text(message).foregroundStyle(.red) } }
                }.scrollDismissesKeyboard(.interactively)
            } else {
                ContentUnavailableView("这条记录已移除", systemImage: "tray", description: Text("记录可能已被删除、到期或超出保留上限。"))
            }
        }.seePageCanvas().navigationTitle("事件详情").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let annotation = workspace.annotation(for: eventID) ?? EventAnnotation()
                verdict = annotation.verdict; note = annotation.note
            }
            .onChange(of: verdict) { _, _ in saved = false }
            .confirmationDialog("删除这条事件及备注？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { workspace.remove(eventID); dismiss() }
            }
    }
}

private struct WatchForwardAction: View {
    @ObservedObject var bridge: ConnectivityBridge
    let event: SenseEvent
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fresh = context.date.timeIntervalSince(event.lastSeen) <= 300
            Button("手动发送到配对手表", systemImage: "applewatch") { bridge.sendEvent(event) }
                .disabled(!bridge.reachable || !fresh || event.status == .confirmed || bridge.isSending(event.id))
            Text(!fresh ? "事件已超过 5 分钟，不再转发。"
                 : event.status == .confirmed ? "你已经确认过这条提醒，无需再次发送。"
                 : bridge.reachable ? "两端 App 当前可达；只发送事件摘要。" : "请先打开两端 App，在「腕上回应」激活通信。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Text(bridge.delivery).font(.footnote).foregroundStyle(.secondary)
        if let reply = bridge.quickReplyNotes[event.id] { Text("手表回应：\(reply) · 回应不等于确认").font(.subheadline).foregroundStyle(Color.seeAccent) }
    }
}

struct PreferencesPage: View {
    @ObservedObject var workspace: Workspace
    @State private var consentHistory = false
    @State private var showCredits = false
    @State private var newPhrase = ""
    @State private var confirmClear = false
    @FocusState private var phraseFocused: Bool
    @State private var newPhraseCategory: PhraseCategory = .personal

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SeeHero(title:"用你舒服的方式",detail:"调整阅读、提醒和隐私，选择适合自己的节奏。",artwork:.shield,eyebrow:"见声 · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "预览")")
                }
                Section("沟通与提醒偏好") {
                    NavigationLink("字幕与阅读方式") { ReadingSettingsPage(workspace: workspace) }
                    NavigationLink("提醒方式与强度") { ReminderSettingsPage(workspace: workspace, service: workspace.reminders) }
                    NavigationLink("常用沟通卡") { PhraseLibraryPage(workspace: workspace) }
                    Text("按自己的沟通习惯选择字幕、文字回应和提醒方式。")
                        .font(.footnote).foregroundStyle(SeePalette.secondary)
                }
                Section("场景与声音") {
                    Picker("场景预设", selection: Binding(get: { workspace.preferences.scene }, set: { workspace.applyScene($0) })) {
                        ForEach(ListeningScene.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    Text("切换预设会重置下方关注类别并停止麦克风；不会自动开启字幕或摄像头。类别也可单独修改。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(SoundKind.allCases) { kind in
                        Toggle(isOn: Binding(get: { workspace.preferences.sounds.contains(kind) }, set: { enabled in
                            workspace.updatePreferences { if enabled { $0.sounds.insert(kind) } else { $0.sounds.remove(kind) } }
                        })) { Label(kind.title, systemImage: kind.symbol) }
                    }
                    Picker("提醒倾向", selection: Binding(get: { workspace.preferences.sensitivity }, set: { value in
                        workspace.updatePreferences { $0.sensitivity = value }
                    })) {
                        ForEach(DetectionSensitivity.allCases) { Text($0.title).tag($0) }
                    }
                    Text("积极关注可能增加误报；减少打扰可能增加漏报或延迟。这些初始阈值尚未经过真实场景校准。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("本地记录与隐私") {
                    Toggle("保存事件历史与复核", isOn: Binding(get: { workspace.preferences.saveHistory }, set: { value in
                        if value { consentHistory = true }
                        else { workspace.updatePreferences { $0.saveHistory = false } }
                    }))
                    Picker("记录保留时间", selection: Binding(get: { workspace.preferences.retentionDays }, set: { days in
                        workspace.updatePreferences { $0.retentionDays = days }
                    })) {
                        ForEach([1, 7, 30], id: \.self) { Text("\($0) 天").tag($0) }
                    }
                    Text("最多 40 条。开启后会保存当前及后续事件的时间、类别、状态、复核和备注。关闭会删除本地历史文件，本次运行中的事件仍可查看。原始音视频与字幕不会保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("删除全部事件与备注", role: .destructive) { confirmClear = true }
                    if let message = workspace.storageMessage { Text(message).font(.footnote).foregroundStyle(.red) }
                }
                Section("我的常用语") {
                    ForEach(workspace.preferences.phrases, id: \.self) { phrase in
                        HStack {
                            Text(phrase).frame(maxWidth: .infinity, alignment: .leading)
                            Menu {
                                ForEach(PhraseCategory.allCases) { category in
                                    Button(category.title, systemImage: category.symbol) {
                                        workspace.updatePreferences { $0.phraseCategories[phrase] = category }
                                    }
                                }
                            } label: {
                                Text(workspace.preferences.category(for: phrase).title).font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(Color.seeAccent.opacity(0.08), in: Capsule())
                            }.buttonStyle(.borderless).accessibilityLabel("修改这句常用语的分类")
                        }.swipeActions {
                            Button("删除", role: .destructive) { workspace.updatePreferences { $0.phrases.removeAll { $0 == phrase } } }
                        }
                    }
                    TextField("添加一句常用语（最多 80 字）", text: $newPhrase, axis: .vertical).lineLimit(1...3)
                        .focused($phraseFocused)
                        .onChange(of: newPhrase) { _, value in if value.count > 80 { newPhrase = String(value.prefix(80)) } }
                    Picker("新卡片分类", selection: $newPhraseCategory) {
                        ForEach(PhraseCategory.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    Button("添加到沟通卡", systemImage: "plus.circle") {
                        let phrase = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
                        workspace.updatePreferences {
                            $0.phrases.append(phrase)
                            $0.phraseCategories[phrase] = newPhraseCategory
                        }
                        newPhrase = ""
                        phraseFocused = false
                    }.disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               || workspace.preferences.phrases.count >= PhraseCollection.limit
                               || workspace.preferences.phrases.contains(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)))
                    NavigationLink("从中文模板库挑选") { PhraseLibraryPage(workspace: workspace) }
                    NavigationLink("扫码导入与分享卡片") { PhraseTransferPage(workspace: workspace) }
                    Text("最多 \(PhraseCollection.limit) 句，单独保存在本机。请避免填写敏感身份信息；对话字幕和临时回应不会随常用语保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("资料与设备") {
                    NavigationLink("提醒中心") { AgendaCenterPage(workspace:workspace,studio:workspace.workroom,routines:workspace.routines,agenda:workspace.agenda) }
                    NavigationLink("加密备份与恢复") { LibraryBackupPage(workspace:workspace) }
                    NavigationLink("设备接力") { DeviceContinuityPage(workspace:workspace,bridge:workspace.bridge,studio:workspace.workroom,routines:workspace.routines) }
                    NavigationLink("识别与可靠性") { ReliabilityPage(workspace:workspace,quality:workspace.quality) }
                    NavigationLink("使用验收清单") { AcceptancePage(quality:workspace.quality) }
                }
                Section("日常工具") {
                    NavigationLink("DeepSeek 智能整理") { IntelligencePage(workspace: workspace, audio: workspace.audio, service: workspace.intelligence) }
                    NavigationLink("今日工作台") { WorkbenchPage(workspace: workspace, information: workspace.information, routines: workspace.routines) }
                    NavigationLink("约定与待办") { RoutinePage(workspace: workspace, service: workspace.routines, information: workspace.information) }
                    NavigationLink("我的场景") { SceneProfilesPage(workspace: workspace) }
                    NavigationLink("联合事件时间线") { AssociationTimelinePage(workspace: workspace) }
                    NavigationLink("重要信息核对") { InformationCardsPage(workspace: workspace, service: workspace.information) }
                    NavigationLink("场景演示") { ScenarioDemoPage(workspace: workspace, audio: workspace.audio, sharing: workspace.textSharing, bridge: workspace.bridge) }
                    NavigationLink("提醒规则") { ReminderSettingsPage(workspace: workspace, service: workspace.reminders) }
                    NavigationLink("阅读与操作") { ReadingSettingsPage(workspace: workspace) }
                    NavigationLink("已保存会话") { SavedConversationsPage(service: workspace.conversations) }
                    NavigationLink("临时文字共享") { TextSharingPage(service: workspace.textSharing, audio: workspace.audio, workspace: workspace) }
                    NavigationLink("字幕快捷纠正") { CorrectionSettingsPage(workspace: workspace) }
                    NavigationLink("重新查看使用引导") { IntroPage(workspace: workspace) }
                }
                Section("关于与实验") {
                    NavigationLink("动效与提醒样式预览") { FeedbackPreviewPage(workspace: workspace) }
                    Button("开源来源与许可", systemImage: "doc.text") { showCredits = true }
                    NavigationLink("设备检查") { DeviceCheckPage(workspace: workspace, bridge: workspace.bridge) }
                    NavigationLink("个人声音样本") { SoundSamplePage(workspace: workspace, library: workspace.samples) }
                    NavigationLink("环境声音实验") { EnvironmentalPage(workspace: workspace, service: workspace.environment) }
                    Text("前台使用预览。新增环境声音引擎仍需真机校准；DeepSeek 仅在主动发送选中文字时联网整理。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.scrollDismissesKeyboard(.interactively).seePageCanvas().navigationTitle("我的")
                .safeAreaInset(edge: .top) { WorkflowStatusArea(workspace: workspace) }
                .sheet(isPresented: $showCredits) { CreditsView() }
                .confirmationDialog("在这台设备保存事件历史？", isPresented: $consentHistory, titleVisibility: .visible) {
                    Button("开启本地保存") { workspace.updatePreferences { $0.saveHistory = true } }
                } message: { Text("将保存当前及后续事件的摘要、人工复核和备注，最多 40 条。可随时关闭或删除；不保存音视频与字幕。") }
                .confirmationDialog("删除全部事件和备注？", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("删除全部记录", role: .destructive) { workspace.clear() }
                }
        }
    }
}
