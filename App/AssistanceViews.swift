import SwiftUI
import Flow

struct SceneProfilesPage: View {
    @ObservedObject var workspace: Workspace
    @State private var editing: SceneProfile?
    @State private var deleting: SceneProfile?
    private func newTitle(_ base: String) -> String {
        var title = base; var number = 2
        while workspace.preferences.profiles.contains(where: { $0.title == title }) { title = "\(base) \(number)"; number += 1 }
        return title
    }
    var body: some View {
        List {
            Section {
                Label(workspace.preferences.sceneTitle, systemImage: workspace.preferences.activeProfile?.symbol ?? workspace.preferences.scene.symbol).font(.title3.bold())
                Text("切换会停止采集。自定场景一起切换关注类别、敏感度与提醒规则；内置场景只切换关注类别。字幕和摄像头由你手动开启。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("把当前设置存为新场景", systemImage: "plus.circle") {
                    editing = SceneProfile(title: newTitle("我的场景"), preferences: workspace.preferences)
                }.disabled(workspace.preferences.profiles.count >= SceneProfile.limit)
            }
            Section("常用模板 · 先预览再保存") {
                ForEach(SceneTemplate.allCases) { template in
                    Button {
                        editing = template.makeProfile(title: newTitle(template.title))
                    } label: { VStack(alignment: .leading, spacing: 5) { Text(template.title).font(.headline); Text(template.detail).font(.caption).foregroundStyle(.secondary) } }
                        .disabled(workspace.preferences.profiles.count >= SceneProfile.limit)
                }
                Text("模板默认不启用系统通知或触感；预览保存后再由你应用。").font(.caption).foregroundStyle(.secondary)
            }
            Section("内置场景") {
                ForEach(ListeningScene.allCases) { scene in
                    Button { workspace.applyScene(scene) } label: {
                        HStack { Label(scene.title, systemImage: scene.symbol); Spacer(); if workspace.preferences.activeProfileID == nil && workspace.preferences.scene == scene { Image(systemName: "checkmark") } }
                    }
                }
            }
            Section("自定场景 · 最多 12 个") {
                if workspace.preferences.profiles.isEmpty { Text("试试保存一个“图书馆”或“宿舍”场景。").foregroundStyle(.secondary) }
                ForEach(workspace.preferences.profiles) { profile in
                    VStack(alignment: .leading, spacing: 12) {
                        Label(profile.title, systemImage: profile.symbol).font(.headline)
                        Text(profile.sounds.isEmpty ? "未关注声音" : profile.sounds.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary)
                        HFlow(spacing: 10) {
                            Button(workspace.preferences.activeProfileID == profile.id ? "重新应用" : "应用") { workspace.applyProfile(profile.id) }.buttonStyle(.borderedProminent).tint(SeePalette.button)
                            Button("编辑") { editing = profile }.buttonStyle(.bordered)
                            Menu("更多") {
                                Button("复制") { var copy = profile; copy.id = UUID(); copy.title = newTitle(String(profile.title.prefix(16)) + " 副本"); editing = copy }.disabled(workspace.preferences.profiles.count >= 12)
                                Button("删除", role: .destructive) { deleting = profile }
                            }
                        }
                    }.padding(.vertical, 6)
                }
            }
        }.seePageCanvas().navigationTitle("我的场景")
            .sheet(item: $editing) { profile in SceneProfileEditor(workspace: workspace, initial: profile) }
            .confirmationDialog("删除这个场景？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除场景", role: .destructive) { if let id = deleting?.id { workspace.deleteProfile(id) }; deleting = nil }
            } message: { Text("当前关注与提醒设置会保留。") }
    }
}

private struct SceneProfileEditor: View {
    @ObservedObject var workspace: Workspace
    @State private var profile: SceneProfile
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(workspace: Workspace, initial: SceneProfile) { self.workspace = workspace; _profile = State(initialValue: initial) }
    private func rule(_ key: String) -> Binding<ReminderRule> { Binding(get: { profile.reminderRules[key] ?? ReminderRule() }, set: { profile.reminderRules[key] = $0 }) }
    var body: some View {
        NavigationStack {
            Form {
                Section("名称与外观") {
                    TextField("场景名称（最多 24 字）", text: $profile.title)
                    Picker("图标", selection: $profile.symbol) { ForEach(SceneProfile.symbols, id: \.self) { Image(systemName: $0).tag($0) } }
                    Picker("基础场景", selection: $profile.scene) { ForEach(ListeningScene.allCases) { Text($0.title).tag($0) } }
                    Text("基础场景决定首页风格和主要入口；不会在编辑时覆盖下面的声音设置。").font(.caption).foregroundStyle(.secondary)
                    Button("用当前运行设置更新此草稿") {
                        profile.scene = workspace.preferences.scene; profile.sounds = workspace.preferences.sounds
                        profile.sensitivity = workspace.preferences.sensitivity; profile.reminderRules = workspace.preferences.reminderRules
                    }
                }
                Section("关注声音") {
                    ForEach(SoundKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(get: { profile.sounds.contains(kind) }, set: { if $0 { profile.sounds.insert(kind) } else { profile.sounds.remove(kind) } }))
                    }
                    Picker("敏感度", selection: $profile.sensitivity) { ForEach(DetectionSensitivity.allCases) { Text($0.title).tag($0) } }
                }
                ForEach(SceneProfile.categories, id: \.self) { key in
                    Section(key == "wave" ? "挥手提醒" : (SoundKind(rawValue: key)?.title ?? key) + "提醒") {
                        Toggle("视觉提示", isOn: rule(key).visual)
                        Toggle("触感提示（支持的设备）", isOn: rule(key).haptic)
                        Toggle("通知（需已授权）", isOn: rule(key).notifications)
                        Picker("优先级", selection: rule(key).priority) { ForEach(ReminderPriority.allCases) { Text($0.title).tag($0) } }
                        Picker("同类冷却", selection: rule(key).cooldownSeconds) { ForEach([0, 10, 30, 60, 300], id: \.self) { Text("\($0) 秒").tag($0) } }
                        Picker("补提醒次数", selection: rule(key).repeatCount) { ForEach(0...2, id: \.self) { Text("\($0) 次").tag($0) } }
                        Picker("补提醒间隔", selection: rule(key).repeatInterval) { ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) 秒").tag($0) } }
                        TextField("专用回应：每行一句，最多 4 句", text: Binding(get: { (profile.responses[key] ?? []).joined(separator: "\n") }, set: { profile.responses[key] = $0.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }), axis: .vertical).lineLimit(2...5)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Section { Button("保存场景", systemImage: "checkmark.circle", action: save).frame(minHeight: 44) }
            }.seePageCanvas().navigationTitle("编辑场景")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
                }
        }
    }
    private func save() {
        do { profile.title = profile.title.trimmingCharacters(in: .whitespacesAndNewlines); try workspace.saveProfile(profile); dismiss() }
        catch { self.error = "\(error.localizedDescription) 请检查名称是否重复、回应是否超过 4 句（每句最多 80 字）。" }
    }
}

struct EventActionButton: View {
    @ObservedObject var workspace: Workspace
    let eventID: UUID
    @State private var showing = false
    var body: some View {
        Button("回应 / 沟通", systemImage: "bubble.left.and.text.bubble.right") { showing = true }
            .disabled(workspace.event(eventID) == nil)
            .sheet(isPresented: $showing) { EventActionPage(workspace: workspace, eventID: eventID) }
    }
}

private struct EventActionPage: View {
    @ObservedObject var workspace: Workspace
    let eventID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var custom = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let event = workspace.event(eventID) {
                        Label(event.title, systemImage: event.symbol).font(.title2.bold())
                        Notice(text: event.isDemonstration ? "演示回应会保留演示标记。选句只填入草稿，由你决定显示或朗读；不会确认提醒。" : "选句只填入草稿，由你决定显示或朗读；不会确认提醒。已连接时，对话会同步到文字共享设备。")
                        Text("适合这条事件的回应").font(.headline)
                        HFlow(spacing: 10) {
                            ForEach(EventResponseContext.suggestions(for: event, profile: workspace.preferences.activeProfile), id: \.self) { phrase in response(phrase) }
                        }
                        Text("我的常用语").font(.headline)
                        HFlow(spacing: 10) { ForEach(workspace.preferences.phrases.prefix(8), id: \.self) { phrase in response(phrase) } }
                        TextField("自己写一句回应", text: $custom, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                        Button("用这句话回应") { choose(custom) }.buttonStyle(.borderedProminent).tint(SeePalette.button).disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let error { Text(error).foregroundStyle(.red) }
                    } else { ContentUnavailableView("事件已移除", systemImage: "tray", description: Text("请返回选择其他事件。")) }
                }.padding(20).frame(maxWidth: 750).frame(maxWidth: .infinity)
            }.background(SeePalette.canvas).seePageCanvas().navigationTitle("事件行动卡")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .modifier(AssistancePrivacyCover())
        }
    }
    private func response(_ phrase: String) -> some View { Button(phrase) { choose(phrase) }.buttonStyle(.bordered).frame(minHeight: 44) }
    private func choose(_ phrase: String) {
        if workspace.prepareResponse(to: eventID, text: phrase) { dismiss() }
        else { error = "请先结束场景演示，或返回重新选择事件。" }
    }
}

struct InformationCardsPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var service: InformationCardService
    @State private var editing: InformationCard?
    @State private var reset = false
    @State private var query = ""
    @State private var kind: InformationKind?
    @State private var selection: InformationSelection = .all
    private var shown: [InformationCard] { InformationCard.select(service.cards, query: query, kind: kind, selection: selection) }
    var body: some View {
        List {
            Section {
                Text("把时间、地点、金额和电话单独放大核对。只在本次运行保留，勾选保存才写入本机；最多 30 张。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("新建信息卡", systemImage: "plus.circle") { var card = InformationCard(); card.kind = .place; if workspace.demoRun != nil { card.origin = .demonstration }; editing = card }.disabled(service.cards.count >= 30)
                Menu("添加示例核对卡（演示）", systemImage: "play.rectangle") {
                    ForEach(InformationKind.allCases) { kind in
                        Button(kind.title) {
                            var card = InformationCard(); card.kind = kind; card.origin = .demonstration
                            card.sourceQuote = "手动加入的界面演示样例，不是真实对话或识别结果。"
                            switch kind { case .time: break; case .place: card.value = "图书馆二楼"; case .amount: card.value = "28.50"; case .phone: card.value = "010-00000000" }
                            editing = card
                        }
                    }
                }.disabled(service.cards.count >= 30)
                Picker("状态", selection: $selection) { ForEach(InformationSelection.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Picker("类型", selection: $kind) {
                    Text("所有类型").tag(Optional<InformationKind>.none)
                    ForEach(InformationKind.allCases) { Text($0.title).tag(Optional($0)) }
                }
            }
            if let error = service.error { Section { Text(error).foregroundStyle(.red); Button("删除本地信息卡并重置", role: .destructive) { reset = true } } }
            if shown.isEmpty { ContentUnavailableView(service.cards.isEmpty ? "还没有信息卡" : "没有匹配的信息卡", systemImage: "rectangle.on.rectangle", description: Text("可以调整筛选，或在对话中点击“制作核对卡”。")) }
            ForEach(shown) { card in
                NavigationLink { InformationCardDetail(workspace: workspace, service: service, cardID: card.id) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(card.kind.title + (card.origin == .demonstration ? " · 演示" : ""), systemImage: card.kind.symbol).font(.headline)
                        Text(card.displayValue).font(.title3).lineLimit(2)
                        HFlow(spacing: 8) {
                            if card.isPinned { Label("置顶", systemImage: "pin.fill") }
                            Text(card.reviewed ? "你标记已核对" : "待核对")
                            Text(service.savedIDs.contains(card.id) ? "已存本机" : "仅本次运行")
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
        }.seePageCanvas().navigationTitle("重要信息核对")
            .searchable(text: $query, prompt: "搜索内容、原文或备注")
            .sheet(item: $editing) { card in InformationCardEditor(service: service, initial: card) }
            .confirmationDialog("删除所有本地信息卡？", isPresented: $reset, titleVisibility: .visible) { Button("删除并重置", role: .destructive) { do { try service.reset() } catch { workspace.notify(error.localizedDescription) } } }
            .modifier(AssistancePrivacyCover())
    }
}

struct InformationCardEditor: View {
    @ObservedObject var service: InformationCardService
    @State private var card: InformationCard
    @State private var saveLocally: Bool
    @State private var error: String?
    @State private var dateChosen: Bool
    @Environment(\.dismiss) private var dismiss
    init(service: InformationCardService, initial: InformationCard, requiresDateChoice: Bool = false) {
        self.service = service; _card = State(initialValue: initial); _saveLocally = State(initialValue: service.savedIDs.contains(initial.id))
        _dateChosen = State(initialValue: !requiresDateChoice)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("请对照原文，手动整理") {
                    Picker("类型", selection: $card.kind) { ForEach(InformationKind.allCases) { Text($0.title).tag($0) } }
                    if card.kind == .time { DatePicker("完整日期与时间", selection: $card.dateValue, in: Calendar.current.date(from: DateComponents(year: 1900, month: 1, day: 1))!...Calendar.current.date(from: DateComponents(year: 2200, month: 12, day: 31))!) }
                    if card.kind == .time && !dateChosen { Toggle("我已手动核对并选择完整日期时间", isOn: $dateChosen) }
                    else if card.kind == .amount {
                        TextField("金额，如 28.50", text: $card.value).keyboardType(.decimalPad)
                        Picker("币种", selection: $card.currency) { ForEach(["CNY", "USD", "EUR", "JPY", "HKD"], id: \.self) { Text($0).tag($0) } }
                        Text("最多两位小数，不自动换算或识别币种。").font(.caption).foregroundStyle(.secondary)
                    } else if card.kind == .phone { TextField("电话 / 分机", text: $card.value).keyboardType(.phonePad) }
                    else { TextField("具体地点（最多 120 字）", text: $card.value, axis: .vertical) }
                    TextField("备注（最多 120 字）", text: $card.note, axis: .vertical)
                }
                Section("来源") {
                    Text(card.origin.informationSource)
                    if let assistant = card.assistedBy { Text("\(assistant) 整理建议 · 请核对后采用").foregroundStyle(Color.seeAccent) }
                    if !card.sourceQuote.isEmpty { Text(card.sourceQuote).textSelection(.enabled) }
                    Text("不会自动从一句话猜测日期、金额或电话。修改信息后，原来的核对标记失效，请重新与对方核对。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("将这张卡保存在本机", isOn: $saveLocally)
                    Text("未勾选时只保留到本次运行结束；已保存的卡取消勾选后，会删除本地副本。独立于事件历史和已保存会话。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Section { Button("完成信息卡", systemImage: "checkmark.circle", action: save).frame(minHeight: 44) }
            }.seePageCanvas().navigationTitle("整理信息卡")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成", action: save) }
                }.modifier(AssistancePrivacyCover())
        }
    }
    private func save() {
        guard card.kind != .time || dateChosen else { error = "原文没有确定完整日期，请手动选择并确认日期时间。"; return }
        do { card.value = card.value.trimmingCharacters(in: .whitespacesAndNewlines); try service.put(card, saveLocally: saveLocally); dismiss() }
        catch { self.error = "\(error.localizedDescription) 请检查字段，金额只填数字，电话需 3–20 位数字。" }
    }
}

struct InformationCardDetail: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var service: InformationCardService
    let cardID: UUID
    @State private var editing: InformationCard?
    @State private var deleting = false
    @State private var big = false
    @State private var routineDraft: RoutineItem?
    @Environment(\.dismiss) private var dismiss
    private var card: InformationCard? { service.cards.first { $0.id == cardID } }
    var body: some View {
        Form {
            if let card {
                Section {
                    Label(card.kind.title + (card.origin == .demonstration ? " · 演示" : ""), systemImage: card.kind.symbol).font(.headline)
                    Text(card.displayValue).font(.largeTitle.bold()).textSelection(.enabled)
                    Text(card.reviewed ? "你标记已与对方核对 · 第 \(card.revision) 版" : "尚未核对 · 第 \(card.revision) 版").foregroundStyle(.secondary)
                    Button("放大给对方看", systemImage: "arrow.up.left.and.arrow.down.right") { big = true }
                    Button("朗读这张信息卡", systemImage: "speaker.wave.2") { workspace.audio.speak(card.exportText) }
                    Button("停止朗读") { workspace.audio.stopSpeaking() }
                }
                Section("你的核对记录") {
                    Toggle("我已与对方核对", isOn: Binding(get: { card.reviewed }, set: { value in perform { try service.review(cardID, reviewed: value) } }))
                    Text("这是你自己记录的核对状态。设备的“已读”回执不能证明时间、地点或金额正确。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("原文与来源") {
                    Text(card.origin.informationSource)
                    if let assistant = card.assistedBy { Text("\(assistant) 整理建议 · 核对状态由你记录").foregroundStyle(Color.seeAccent) }
                    if !card.sourceQuote.isEmpty { Text(card.sourceQuote).textSelection(.enabled) }
                    if !card.note.isEmpty { Text(card.note) }
                    Text(service.savedIDs.contains(card.id) ? "已保存到本机" : "仅本次运行保留").font(.caption).foregroundStyle(.secondary)
                }
                Section("由你决定下一步") {
                    Button(card.isPinned ? "取消置顶" : "置顶这张卡", systemImage: card.isPinned ? "pin.slash" : "pin") { perform { try service.togglePin(card.id) } }
                    Button("从已核对卡建立待办", systemImage: "checklist") {
                        guard workspace.demoRun == nil || card.origin == .demonstration else { workspace.notify("请先结束演示，再建立真实待办"); return }
                        perform { routineDraft = try RoutineItem(card: card) }
                    }.disabled(!card.reviewed || workspace.routines.items.count >= 80)
                    if !card.reviewed { Text("先与对方核对，再把约定留成待办。").font(.caption).foregroundStyle(.secondary) }
                    NavigationLink("查看约定与待办") { RoutinePage(workspace: workspace, service: workspace.routines, information: service) }
                    Button("编辑内容") { editing = card }
                    NavigationLink("预览并分享这张卡") { SharePreviewPage(original:card.exportText) }
                    Button("加入对话（已连接时会共享）") { workspace.addInformationToConversation(card) }
                    Button("删除这张卡", role: .destructive) { deleting = true }
                }
            } else { Text("这张信息卡已移除") }
        }.seePageCanvas().navigationTitle("信息核对")
            .sheet(item: $editing) { InformationCardEditor(service: service, initial: $0) }
            .sheet(item: $routineDraft) { RoutineEditor(service: workspace.routines, initial: $0) }
            .fullScreenCover(isPresented: $big) {
                NavigationStack {
                    ScrollView { if let card { VStack(spacing: 30) { Text(card.origin == .demonstration ? "演示信息" : "请一起核对").font(.title2); Text(card.kind.title).font(.title); Text(card.displayValue).font(.system(size: 48, weight: .bold, design: .rounded)); Text(card.reviewed ? "用户标记已核对" : "尚未核对").font(.title3) }.padding(30).frame(maxWidth: .infinity) } }
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { big = false } } }.modifier(AssistancePrivacyCover())
                }
            }
            .confirmationDialog("删除这张信息卡？", isPresented: $deleting, titleVisibility: .visible) { Button("删除", role: .destructive) { perform { try service.remove(cardID); dismiss() } } }
            .modifier(AssistancePrivacyCover()).onDisappear { workspace.audio.stopSpeaking() }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { workspace.notify(error.localizedDescription) } }
}

struct AssociationTimelinePage: View {
    @ObservedObject var workspace: Workspace
    @State private var filter = "全部"
    @State private var restore = false
    @State private var query = ""
    @State private var period: TimelinePeriod = .all
    private var groups: [EventAssociation] {
        workspace.associations.filter { group in
            period.includes(group.date, now: Date())
            && (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || group.events.contains { event in
                [event.title, event.category, workspace.annotation(for: event.id)?.note ?? ""].contains { $0.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }) && (filter == "全部" || group.events.contains { event in
                filter == "演示" ? event.isDemonstration : !event.isDemonstration && event.source == (filter == "声音" ? .sound : .gesture)
            })
        }
    }
    var body: some View {
        List {
            Section {
                Picker("关联窗口", selection: Binding(get: { workspace.preferences.associationWindow }, set: { value in workspace.updatePreferences { $0.associationWindow = value } })) {
                    ForEach([2, 5, 10], id: \.self) { Text("\($0) 秒").tag($0) }
                }.pickerStyle(.segmented)
                Picker("筛选", selection: $filter) { ForEach(["全部", "声音", "动作", "演示"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                Picker("时间范围", selection: $period) { ForEach(TimelinePeriod.allCases) { Text($0.title).tag($0) } }
                Text("只整理时间接近的不同类别或来源，整组跨度不超过所选窗口。关联不代表同一原因，也不判断来访或危险；演示与真实事件分开。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("恢复已拆分的关联", systemImage: "arrow.uturn.backward") { restore = true }.disabled(workspace.suppressedLinks.isEmpty && workspace.demoSuppressedLinks.isEmpty)
                Button("体验联合事件演示（不录音）", systemImage: "play.rectangle") { workspace.startDemo(.visitor); filter = "演示" }
            }
            if groups.isEmpty { Section { ContentUnavailableView("还没有对应事件", systemImage: "timeline.selection", description: Text("可以在场景演示中体验门铃、敲门和挥手的联合时间线。")); Button("开始来访演示（不录音）") { workspace.startDemo(.visitor); filter = "演示" } } }
            ForEach(groups) { group in
                Section {
                    if group.events.count > 1 {
                        Label(group.title, systemImage: "link").font(.headline)
                        Text("时间关联 · \(group.events.count) 条原事件，未合并事实或确认状态").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(group.events) { event in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) { Label(event.title, systemImage: event.symbol).font(.headline); Spacer(); Text(event.lastSeen, format: .dateTime.hour().minute().second()).font(.caption).monospacedDigit() }
                            Text(event.sourceTitle + " · " + (event.status == .confirmed ? "已确认看到" : "待确认看到")).font(.caption).foregroundStyle(.secondary)
                            if let annotation = workspace.annotation(for: event.id) { Text("人工复核：\(annotation.verdict.title)").font(.caption).foregroundStyle(.secondary) }
                            HFlow(spacing: 12) {
                                NavigationLink("原事件与复核") { EventDetail(workspace: workspace, eventID: event.id) }
                                EventActionButton(workspace: workspace, eventID: event.id)
                                if group.events.count > 1 { Button("单独显示") { workspace.detach(event.id, from: group) } }
                            }.font(.subheadline).buttonStyle(.bordered)
                        }.padding(.vertical, 6)
                    }
                } header: { Text(group.date, format: .dateTime.month().day().hour().minute()) }
            }
        }.seePageCanvas().navigationTitle("联合事件时间线")
            .searchable(text: $query, prompt: "搜索事件或人工备注")
            .confirmationDialog("恢复按当前窗口自动关联？", isPresented: $restore, titleVisibility: .visible) { Button("恢复关联") { workspace.restoreAssociations() } }
    }
}

private struct AssistancePrivacyCover: ViewModifier {
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View { content.overlay { if phase != .active { DailyPrivacyCover() } } }
}
