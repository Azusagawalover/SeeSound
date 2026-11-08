import SwiftUI

private struct SeeReduceMotionKey: EnvironmentKey { static let defaultValue = false }
private struct SeeLeftHandedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var seeReduceMotion: Bool {
        get { self[SeeReduceMotionKey.self] }
        set { self[SeeReduceMotionKey.self] = newValue }
    }
    var seeLeftHanded: Bool {
        get { self[SeeLeftHandedKey.self] }
        set { self[SeeLeftHandedKey.self] = newValue }
    }
}

struct ReadingRoot: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dynamicTypeSize) private var systemSize
    @Environment(\.accessibilityReduceMotion) private var systemMotion
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var minimumSize: DynamicTypeSize {
        switch workspace.preferences.reading.textSize {
        case .standard: return systemSize
        case .large: return max(systemSize, .xxxLarge)
        case .extraLarge: return max(systemSize, .accessibility1)
        }
    }
    var body: some View {
        RootView(workspace: workspace)
            .environment(\.dynamicTypeSize, minimumSize)
            .environment(\.seeReduceMotion, systemMotion || workspace.preferences.reading.reduceMotion)
            .environment(\.seeLeftHanded, workspace.preferences.reading.leftHanded)
            .contrast(workspace.preferences.reading.highContrast && systemContrast != .increased ? 1.18 : 1)
            .transaction { if systemMotion || workspace.preferences.reading.reduceMotion { $0.disablesAnimations = true; $0.animation = nil } }
    }
}

struct ReadingSettingsPage: View {
    @ObservedObject var workspace: Workspace
    private func binding<T>(_ key: WritableKeyPath<ReadingPreferences, T>) -> Binding<T> {
        Binding(get: { workspace.preferences.reading[keyPath: key] }, set: { value in workspace.updatePreferences { $0.reading[keyPath: key] = value } })
    }
    var body: some View {
        Form {
            Section("阅读方式") {
                Picker("文字大小", selection: binding(\.textSize)) { ForEach(ReadingTextSize.allCases) { Text($0.title).tag($0) } }
                Toggle("增强对比度", isOn: binding(\.highContrast))
                Toggle("减少动态效果", isOn: binding(\.reduceMotion))
                Toggle("左手操作：朗读回应按钮靠左", isOn: binding(\.leftHanded))
                Text("文字大小是最低值，仍尊重系统设置的更大字号。左手设置仅调整回应按钮位置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("预览") {
                Label("可能有人敲门", systemImage: "hand.tap").font(.headline)
                Text("重要的文字应当看得清楚。字幕可能出错，请确认姓名、数字和地点。")
                Button("我已看到") {}.buttonStyle(.borderedProminent).tint(SeePalette.button).accessibilityHint("仅为外观预览")
            }
        }.seePageCanvas().navigationTitle("阅读与操作")
    }
}

struct IntroPage: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    private let titles = ["让信息看得见", "先选舒服的阅读方式", "什么时候使用权限", "从一次演示开始"]
    private let symbols = ["ear.badge.waveform", "textformat.size", "hand.raised", "sparkles"]
    private let details = ["声音提醒、面对面文字和腕上回应。由你选择何时开启，每次都可以停止。", "支持系统大字体、增强对比度和减少动画。稍后也可以在「我的」中调整。", "声音和字幕使用麦克风，挥手与扫码使用摄像头，文字共享使用本地网络。只有主动开启相应功能才申请权限；系统通知单独在提醒规则中申请。", "现在可以加入标注清楚的演示文字；不会开启麦克风、摄像头或连接其他设备。"]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text("见声 / \(step + 1) · 4").font(.caption.weight(.semibold)).foregroundStyle(Color.seeAccent)
                    SeeArtworkView(artwork:step == 0 ? .speech : step == 1 ? .books : step == 2 ? .shield : .compass,size:140).padding(.vertical,15)
                    Text(titles[step]).font(.system(.largeTitle,design:.rounded,weight:.bold)).foregroundStyle(SeePalette.ink)
                    Text(details[step]).font(.title3).foregroundStyle(.secondary)
                    if step == 1 {
                        Picker("文字大小", selection: Binding(get: { workspace.preferences.reading.textSize }, set: { size in workspace.updatePreferences { $0.reading.textSize = size } })) {
                            ForEach(ReadingTextSize.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Toggle("增强对比度", isOn: Binding(get: { workspace.preferences.reading.highContrast }, set: { enabled in workspace.updatePreferences { $0.reading.highContrast = enabled } }))
                    }
                    if step == 3 {
                        Button("加入演示文字并开始使用") { workspace.audio.addDemonstration(); finish() }.buttonStyle(SeePrimaryButtonStyle())
                        Button("直接开始使用") { finish() }.buttonStyle(SeeSecondaryButtonStyle())
                    } else { Button("下一步", systemImage: "arrow.right") { step += 1 }.buttonStyle(SeePrimaryButtonStyle()) }
                    if step > 0 { Button("上一步") { step -= 1 } }
                    Notice(text: "这是辅助工具。识别和连接会失败，请保留适合自己的其他沟通方式。")
                }.padding(28).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }.background(SeePalette.canvas)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("稍后设置") { finish() } } }
        }.interactiveDismissDisabled()
    }
    private func finish() { workspace.updatePreferences { $0.hasFinishedIntro = true }; dismiss() }
}

struct ReminderSettingsPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var service: ReminderService
    private let categories = SoundKind.allCases.map { ($0.rawValue, $0.title) } + [("wave", "画面内挥手")]
    var body: some View {
        Form {
            Section("按声音与动作设置") {
                ForEach(categories, id: \.0) { category in
                    NavigationLink(category.1) { ReminderRuleEditor(workspace: workspace, service: service, category: category.0, title: category.1) }
                }
            }
            Section("系统通知") {
                Text(service.permission)
                Button("申请通知权限") { Task { await service.requestPermission() } }
                Text("仅主动点击才申请权限。重复提醒最多两次；系统专注模式、设备设置可能影响呈现。iPad 不提供手机振动。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section { Text(service.status).font(.footnote); Text("冷却和暂缓只影响提醒，事件仍保留。系统通知是已检测事件的补提醒，后台不会继续录音识别。关于 Watch 的事件仍由你手动转发。") .font(.footnote).foregroundStyle(.secondary) }
        }.seePageCanvas().navigationTitle("提醒规则").task { await service.refreshPermission() }
    }
}

private struct ReminderRuleEditor: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var service: ReminderService
    let category: String
    let title: String
    private func binding<T>(_ key: WritableKeyPath<ReminderRule, T>) -> Binding<T> {
        Binding(get: { workspace.preferences.reminderRule(for: category)[keyPath: key] }, set: { value in
            workspace.updatePreferences {
                var rule = $0.reminderRule(for: category); rule[keyPath: key] = value; $0.reminderRules[category] = rule
            }
        })
    }
    var body: some View {
        Form {
            Section("提醒方式") {
                Toggle("应用内事件卡片", isOn: binding(\.visual))
                Toggle("iPhone 触觉反馈", isOn: binding(\.haptic))
                Toggle("系统通知", isOn: binding(\.notifications))
                Picker("视觉重点", selection: binding(\.priority)) { ForEach(ReminderPriority.allCases) { Text($0.title).tag($0) } }
            }
            Section("减少重复打扰") {
                Picker("同类冷却", selection: binding(\.cooldownSeconds)) {
                    ForEach([0, 10, 30, 60, 300], id: \.self) { Text($0 == 0 ? "不冷却" : "\($0) 秒").tag($0) }
                }
                Picker("系统通知补提醒", selection: binding(\.repeatCount)) { ForEach(0...2, id: \.self) { Text("\($0) 次").tag($0) } }
                Picker("补提醒间隔", selection: binding(\.repeatInterval)) { ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) 秒").tag($0) } }
                Text("确认、删除事件会取消它的待发通知。暂缓会暂停这一类别 5 分钟。修改规则会取消这一类别已经安排的通知，之后按新规则提醒。") .font(.footnote).foregroundStyle(.secondary)
                Button("恢复这一类提醒") { service.resume(category) }
            }
            Section("亲自预览") {
                Button("预览这一类提醒") {
                    let event = SenseEvent(category: "demo-" + category, title: title + " · 规则预览", source: .demonstration)
                    service.deliver(event, rule: workspace.preferences.reminderRule(for: category), preview: true)
                }
                Text("预览会使用上面已开启的触觉和通知；不会加入事件历史，也不是识别结果。") .font(.footnote).foregroundStyle(.secondary)
            }
        }.seePageCanvas().navigationTitle(title)
    }
}


struct SavedTurnCard: View {
    let turn: SavedConversationTurn
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(turn.displayName).font(.caption.bold()); Spacer(); Text(turn.createdAt, style: .time).font(.caption2) }.foregroundStyle(Color.seeAccent)
            Text(captionHighlight(turn.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if (turn.recognitionRevision ?? 0) > 0 { Text("识别曾修订 \(turn.recognitionRevision ?? 0) 次，请核对数字").font(.caption).foregroundStyle(.orange) }
            Text(turn.sourceTitle + (turn.isEdited ? " · 已人工修改" : "") + (turn.state == .partial ? " · 正在更新" : turn.state == .interrupted ? " · 未完成" : ""))
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct SaveConversationSheet: View {
    @ObservedObject var audio: AudioProbes
    @ObservedObject var service: ConversationArchiveService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var title = "这次对话"
    @State private var consent = false
    var body: some View {
        NavigationStack {
            Form {
                Section("保存到本机") {
                    TextField("会话标题", text: $title).onChange(of: title) { _, value in title = String(value.prefix(60)) }
                    Text("将停止字幕与朗读，保存当时的最多 50 段文字。最多保存 30 个会话；不会默认保存以后产生的内容。") .font(.footnote)
                    Toggle("我确认保存这些文字到本机", isOn: $consent)
                    if let status = service.status { Text(status).foregroundStyle(.red).font(.footnote) }
                }
            }.seePageCanvas().navigationTitle("保存当前会话")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            audio.stopEverything()
                            if service.save(title: title, turns: audio.conversation.turns, consent: consent) { dismiss() }
                        }.disabled(!consent || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || audio.conversation.turns.isEmpty)
                    }
                }.overlay { if scenePhase != .active { DailyPrivacyCover() } }
        }
    }
}

struct SavedConversationsPage: View {
    @ObservedObject var service: ConversationArchiveService
    @State private var query = ""
    @State private var deletion: UUID?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            Section {
                Text("只有主动确认保存的会话会出现在这里。文字留在本机，可单独删除或主动导出。\n\(service.items.count) / 30 个会话") .font(.footnote).foregroundStyle(.secondary)
                if let status = service.status { Text(status).foregroundStyle(.red) }
            }
            ForEach(service.items.filter { $0.matches(query) }) { item in
                NavigationLink {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if item.containsDemonstration { Notice(text: "含演示文字，不是真实识别验证。") }
                            ForEach(item.turns) { SavedTurnCard(turn: $0) }
                            NavigationLink { SharePreviewPage(original:item.exportText) } label: { Label("预览并分享这份文字",systemImage:"square.and.arrow.up") }.buttonStyle(.bordered)
                            Text("分享后生成的副本由接收者管理。") .font(.caption).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
                    }.background(SeePalette.canvas).seePageCanvas().navigationTitle(item.title)
                        .overlay { if scenePhase != .active { DailyPrivacyCover() } }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.headline)
                        Text("\(item.turns.count) 段 · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))\(item.containsDemonstration ? " · 含演示" : "")").font(.caption).foregroundStyle(.secondary)
                        Text(item.turns.first?.text ?? "").lineLimit(2).font(.subheadline)
                    }.padding(.vertical, 6)
                }.swipeActions { Button("删除", role: .destructive) { deletion = item.id } }
            }
            if service.items.isEmpty { ContentUnavailableView("还没有保存的会话", systemImage: "text.bubble", description: Text("在面对面沟通中选择「保存当前会话」。")) }
        }.searchable(text: $query, prompt: "搜索标题、文字或说话者").seePageCanvas().navigationTitle("已保存会话")
            .confirmationDialog("删除这份本地会话？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
                Button("删除", role: .destructive) { if let deletion { service.delete(deletion) }; deletion = nil }
            }.overlay { if scenePhase != .active { DailyPrivacyCover() } }
    }
}

struct CorrectionSettingsPage: View {
    @ObservedObject var workspace: Workspace
    @State private var from = ""
    @State private var to = ""
    private var correction: TextCorrection { TextCorrection(from: from.trimmingCharacters(in: .whitespacesAndNewlines), to: to.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var body: some View {
        Form {
            Section("常用替换") {
                ForEach(workspace.preferences.corrections) { item in
                    LabeledContent(item.from, value: item.to).swipeActions {
                        Button("删除", role: .destructive) { workspace.updatePreferences { $0.corrections.removeAll { $0.id == item.id } } }
                    }
                }
                Text("在已结束字幕的修改页中点击应用。只替换当前编辑文字，不自动改写字幕，也不训练模型。") .font(.footnote).foregroundStyle(.secondary)
            }
            Section("新增替换，最多 20 条") {
                TextField("容易识别错的词（40 字）", text: $from).onChange(of: from) { _, value in from = String(value.prefix(40)) }
                TextField("替换为（80 字）", text: $to).onChange(of: to) { _, value in to = String(value.prefix(80)) }
                Button("添加") { let item = correction; workspace.updatePreferences { $0.corrections.append(item) }; from = ""; to = "" }
                    .disabled(workspace.preferences.corrections.count >= 20 || (try? correction.validate()) == nil)
            }
        }.seePageCanvas().navigationTitle("字幕快捷纠正")
    }
}

struct TextSharingPage: View {
    @ObservedObject var service: TextSharingService
    @ObservedObject var audio: AudioProbes
    var workspace: Workspace? = nil
    @State private var code = ""
    @State private var selected: String?
    @State private var frozen: [SavedConversationTurn]?
    @State private var frozenRevision = -1
    @Environment(\.scenePhase) private var scenePhase
    private var shown: [SavedConversationTurn] { frozen ?? service.turns }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("把文字放到另一块屏幕", systemImage: "ipad.and.iphone").font(.title2.bold())
                    Text(service.status).foregroundStyle(.secondary)
                    if service.role == .idle {
                        Button("发送这台设备的对话") { service.startHost(); service.publish(audio.conversation) }.buttonStyle(.borderedProminent).tint(SeePalette.button)
                        Button("接收另一台设备的文字") { selected = nil; code = ""; service.startViewer() }.buttonStyle(.bordered)
                        Button("只看本机演示") { service.preview() }.buttonStyle(.bordered)
                    } else {
                        Text("本机：\(service.localName)").font(.caption)
                        Button("结束共享并清除临时文字", role: .destructive) { service.stop() }.buttonStyle(.bordered)
                    }
                }.dailyCard()
                if service.role == .host {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("连接码").font(.caption)
                        Text(service.code).font(.system(.largeTitle, design: .monospaced).bold()).accessibilityLabel("连接码 " + service.code.map(String.init).joined(separator: " "))
                        Text("接收端输入后，你还需要核对设备名称并允许。连接码用于选择房间，不证明对方真实身份。") .font(.footnote).foregroundStyle(.secondary)
                        if let peer = service.pendingPeer {
                            Text("\(peer) 请求接收文字").font(.headline)
                            HStack { Button("允许这台设备") { service.approve(true) }.buttonStyle(.borderedProminent).tint(SeePalette.button); Button("拒绝") { service.approve(false) }.buttonStyle(.bordered) }
                        }
                        if let name = service.connectedName {
                            Label(name, systemImage: "link").font(.headline)
                            Text(service.acknowledgedRevision == service.revision && service.revision >= 0 ? "对方已主动确认当前版本" : "最新文字尚未获对方主动确认").font(.subheadline)
                        }
                        Text("返回面对面沟通即可继续输入。房间会保持到应用进入后台或你主动结束。") .font(.footnote).foregroundStyle(.secondary)
                    }.dailyCard()
                }
                if service.role == .viewer && !service.isConnected {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("附近的文字房间").font(.headline)
                        ForEach(service.rooms) { room in
                            Button { selected = room.id } label: { Label(room.peer.displayName, systemImage: selected == room.id ? "checkmark.circle.fill" : "circle") }
                        }
                        if service.rooms.isEmpty { Text("尚未发现设备。请检查两端 Wi-Fi、蓝牙、本地网络权限，并保持应用在前台。") .font(.footnote).foregroundStyle(.secondary) }
                        TextField("输入对方的 6 位连接码", text: $code).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                            .onChange(of: code) { _, value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                        Button("请求接收文字") { if let room = service.rooms.first(where: { $0.id == selected }) { service.invite(room, code: code) } }
                            .buttonStyle(.borderedProminent).tint(SeePalette.button).disabled(code.count != 6 || selected == nil || service.invitationPending)
                    }.dailyCard()
                }
                if service.isConnected && service.role == .viewer || service.role == .preview {
                    HStack {
                        Text(service.role == .preview ? "本机演示 · 未联网" : "接收阅读屏").font(.headline)
                        Spacer()
                        Button(frozen == nil ? "暂停阅读" : "回到最新") {
                            if frozen == nil { frozen = service.turns; frozenRevision = service.revision } else { frozen = nil }
                        }.buttonStyle(.bordered)
                    }
                    if let date = service.lastTextAt {
                        Text("文字更新时间：\(date, style: .time) · 连接信号不代表已读").font(.caption).foregroundStyle(.secondary)
                    }
                    if frozen != nil { Notice(text: "阅读画面已固定；连接仍在接收最新文字。回到最新后可查看更新。") }
                    ForEach(shown) { SavedTurnCard(turn: $0).font(.title2) }
                    if service.role == .viewer {
                        Button("我已看到这版文字") { service.acknowledge(frozen == nil ? service.revision : frozenRevision) }
                            .buttonStyle(.borderedProminent).tint(SeePalette.button).disabled(shown.isEmpty || (frozen == nil ? service.revision : frozenRevision) < 0)
                    }
                }
                Notice(text: "仅前台、最多两台设备，最近 20 段文字。使用系统加密连接，不传音视频、不在接收端保存。进入后台或结束连接后清除临时内容；截图及主动复制的文字由使用者管理。")
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(SeePalette.canvas).seePageCanvas().navigationTitle("临时文字共享")
            .safeAreaInset(edge: .top) { if let workspace { WorkflowStatusArea(workspace: workspace) } }
            .onChange(of: service.clearEpoch) { _, _ in frozen = nil; frozenRevision = -1 }
            .overlay { if scenePhase != .active { DailyPrivacyCover() } }
    }
}

struct DailyPrivacyCover: View {
    var body: some View { Color(.systemBackground).ignoresSafeArea().overlay { Label("内容已遮盖", systemImage: "lock").font(.headline) } }
}

struct SharedConnectionStrip: View {
    @ObservedObject var service: TextSharingService
    let open: () -> Void
    var body: some View {
        if service.role != .idle {
            HStack(spacing: 10) {
                Image(systemName: service.isConnected ? "link" : "ipad.and.iphone").accessibilityHidden(true)
                Text(service.role == .preview ? "本机共享演示" : service.isConnected ? "文字共享已连接" : "文字共享等待连接")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Button("查看", action: open).font(.caption)
                Button("停止") { service.stop() }.font(.caption).accessibilityLabel("停止文字共享并清除接收内容")
            }.foregroundStyle(Color.seeAccent).padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.seeAccent.opacity(0.08))
        }
    }
}

extension View {
    func dailyCard() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}
