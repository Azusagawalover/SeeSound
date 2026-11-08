import SwiftUI
import Flow

struct DailyWorkbench: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var information: InformationCardService
    @ObservedObject var routines: RoutineService
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("今天先做什么", systemImage: "sun.max").font(.title3.bold()); Spacer(); Button("工作台") { workspace.navigationRequest = .workbench } }
            HStack(spacing: 10) {
                metric("待看提醒", count: workspace.ledger.events.filter { !$0.isDemonstration && $0.status == .pending }.count, page: .timeline)
                metric("待核对", count: information.cards.filter { $0.origin != .demonstration && !$0.reviewed }.count, page: .information)
                metric("待完成", count: routines.items.filter { !$0.isDemonstration && !$0.completed }.count, page: .routines)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let overdue = routines.items.filter { !$0.isDemonstration && $0.overdue(at: context.date) }.count
                Button {
                    workspace.navigationRequest = overdue > 0 ? .routines : information.cards.contains(where: { $0.origin != .demonstration && !$0.reviewed }) ? .information : .captions
                } label: { Label(overdue > 0 ? "\(overdue) 项已到期，打开待办" : "继续沟通或核对约定", systemImage: overdue > 0 ? "clock.badge.exclamationmark" : "arrow.up.right").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }.buttonStyle(.bordered)
            }
            Text("仅统计当前可见的非演示记录；系统提醒需单独设置并授权。").font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 22))
    }
    private func metric(_ title: String, count: Int, page: ProbePage) -> some View {
        Button { workspace.navigationRequest = page } label: {
            VStack(alignment: .leading, spacing: 6) { Text(count, format: .number).font(.title.bold()).monospacedDigit(); Text(title).font(.caption) }.frame(maxWidth: .infinity, minHeight: 75, alignment: .leading)
        }.buttonStyle(.plain).foregroundStyle(Color.seeAccent)
    }
}

struct WorkbenchPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var information: InformationCardService
    @ObservedObject var routines: RoutineService
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DailyWorkbench(workspace: workspace, information: information, routines: routines)
                VStack(alignment: .leading, spacing: 14) {
                    Text("当前场景").font(.headline)
                    Label(workspace.preferences.sceneTitle, systemImage: workspace.preferences.activeProfile?.symbol ?? workspace.preferences.scene.symbol).font(.title3)
                    NavigationLink("管理场景与模板") { SceneProfilesPage(workspace: workspace) }.buttonStyle(.bordered)
                }.routineCard()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Text("接下来要做").font(.headline); Spacer(); NavigationLink("全部待办") { RoutinePage(workspace: workspace, service: routines, information: information) } }
                        let upcoming = RoutineItem.select(routines.items, query: "", filter: .pending, includeDemonstrations: false, now: context.date)
                        if upcoming.isEmpty { Text("还没有真实待办。可以新建，或从已核对的信息卡建立。").foregroundStyle(.secondary) }
                        ForEach(upcoming.prefix(3)) { item in
                            NavigationLink { RoutineDetail(workspace: workspace, service: routines, information: information, itemID: item.id) } label: { RoutineRow(item: item, now: context.date) }.buttonStyle(.plain)
                        }
                    }.routineCard()
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("当前可见记录").font(.headline)
                    LabeledContent("今天的非演示事件", value: "\(workspace.ledger.events.filter { !$0.isDemonstration && Calendar.current.isDateInToday($0.lastSeen) }.count) 条")
                    LabeledContent("你标记已核对的信息", value: "\(information.cards.filter { $0.origin != .demonstration && $0.reviewed }.count) 张")
                    LabeledContent("今天标记完成的非演示待办", value: "\(routines.items.filter { !$0.isDemonstration && $0.completedAt.map { Calendar.current.isDateInToday($0) } == true }.count) 项")
                    Text("事件受历史开关和保留期限限制，信息卡与待办各自保存；这里不是识别准确率或能力评分。").font(.caption).foregroundStyle(.secondary)
                }.routineCard()
                NavigationLink("不录音，体验一套完整流程") { ScenarioDemoPage(workspace: workspace, audio: workspace.audio, sharing: workspace.textSharing, bridge: workspace.bridge) }.buttonStyle(.borderedProminent).tint(SeePalette.button)
            }.padding(20).frame(maxWidth: 950).frame(maxWidth: .infinity)
        }.background(SeePalette.canvas).seePageCanvas().navigationTitle("今日工作台").modifier(RoutinePrivacy())
    }
}

struct RoutinePage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var service: RoutineService
    @ObservedObject var information: InformationCardService
    @State private var query = ""
    @State private var filter: RoutineFilter = .pending
    @State private var includeDemo = true
    @State private var editing: RoutineItem?
    @State private var reset = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                Section {
                    Button("新建待办", systemImage: "plus.circle") { var item = RoutineItem(); if workspace.demoRun != nil { item.origin = .demonstration }; editing = item }.disabled(service.items.count >= 80)
                    Picker("查看", selection: $filter) { ForEach(RoutineFilter.allCases) { Text($0.title).tag($0) } }
                    Toggle("包含演示待办", isOn: $includeDemo)
                    Text("到期状态在打开见声时更新；编辑中可另设系统提醒。完成待办不会确认声音提醒，也不会替你核对信息卡。默认仅本次运行，主动勾选才保存。").font(.caption).foregroundStyle(.secondary)
                }
                if let error = service.error { Section { Text(error).foregroundStyle(.red); Button("删除本地待办并重置", role: .destructive) { reset = true } } }
                let shown = RoutineItem.select(service.items, query: query, filter: filter, includeDemonstrations: includeDemo, now: context.date)
                if shown.isEmpty { ContentUnavailableView("没有对应待办", systemImage: "checklist", description: Text("可以新建，或从已核对的信息卡建立。")) }
                ForEach(shown) { item in
                    NavigationLink { RoutineDetail(workspace: workspace, service: service, information: information, itemID: item.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            RoutineRow(item: item, now: context.date)
                            if item.sourceWarning(cards: information.cards) != nil { Label("原卡需要再核对", systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.orange) }
                            Text(service.savedIDs.contains(item.id) ? "已存本机" : "仅本次运行").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }.seePageCanvas().navigationTitle("约定与待办").searchable(text: $query, prompt: "搜索待办、备注或摘录")
            .sheet(item: $editing) { RoutineEditor(service: service, initial: $0) }
            .confirmationDialog("删除所有本地待办？", isPresented: $reset, titleVisibility: .visible) { Button("删除并重置", role: .destructive) { do { try service.reset() } catch { workspace.notify(error.localizedDescription) } } }
            .modifier(RoutinePrivacy())
    }
}

private struct RoutineRow: View {
    let item: RoutineItem
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.title, systemImage: item.completed ? "checkmark.circle.fill" : item.priority == .important ? "flag.fill" : "circle").font(.headline)
            HFlow(spacing: 8) {
                if item.isDemonstration { Text("演示").foregroundStyle(Color.seeAccent) }
                Text(item.completed ? "已完成" : item.overdue(at: now) ? "已到期" : "待完成").foregroundStyle(item.overdue(at: now) ? Color.orange : .secondary)
                if let due = item.dueAt { Text(due, format: .dateTime.month().day().hour().minute()).monospacedDigit() }
            }.font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RoutineEditor: View {
    @ObservedObject var service: RoutineService
    @State private var item: RoutineItem
    @State private var hasDate: Bool
    @State private var due: Date
    @State private var saveLocally: Bool
    @State private var error: String?
    private let initialReminder: Date?
    @Environment(\.dismiss) private var dismiss
    init(service: RoutineService, initial: RoutineItem) {
        self.service = service; initialReminder = initial.reminderAt; _item = State(initialValue: initial); _hasDate = State(initialValue: initial.dueAt != nil)
        _due = State(initialValue: initial.dueAt ?? Date()); _saveLocally = State(initialValue: service.savedIDs.contains(initial.id))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("要做的事") {
                    if item.isDemonstration { Label("演示待办", systemImage: "play.rectangle") }
                    if let assistant = item.assistedBy { Text("\(assistant) 整理建议，请确认要做的事和时间。").font(.caption).foregroundStyle(Color.seeAccent) }
                    TextField("标题（最多 100 字）", text: $item.title, axis: .vertical).lineLimit(2...4)
                    TextField("备注（最多 200 字）", text: $item.note, axis: .vertical).lineLimit(2...5)
                    Picker("优先级", selection: $item.priority) { ForEach(RoutinePriority.allCases) { Text($0.title).tag($0) } }
                    Toggle("设置约定时间", isOn: $hasDate)
                    if hasDate { DatePicker("约定时间", selection: $due) }
                    Text("约定时间和提醒时间分别设置，避免误把截止时间当成提醒。").font(.caption).foregroundStyle(.secondary)
                }
                ReminderTimingSection(date:$item.reminderAt,saveLocally:$saveLocally,demonstration:item.isDemonstration)
                if !item.sourceSnapshot.isEmpty { Section("建立时的原文摘录") { Text(item.sourceSnapshot); Text(item.sourceCardID == nil ? "来自选中的文字整理建议，内容需你核对。" : "来自用户标记已核对的第 \(item.sourceRevision ?? 1) 版。编辑待办不会修改原卡。").font(.caption).foregroundStyle(.secondary) } }
                Section {
                    Toggle("将这项待办保存在本机", isOn: $saveLocally).disabled(item.reminderAt != nil && !item.isDemonstration)
                    Text("最多 80 项。取消勾选并完成编辑会删除已存副本；信息卡、事件历史和会话各自独立。").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("完成待办编辑", systemImage: "checkmark.circle", action: save).frame(minHeight: 44)
                }
            }.seePageCanvas().navigationTitle("编辑待办").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: save) }
            }.modifier(RoutinePrivacy())
        }
    }
    private func save() {
        guard item.reminderAt == initialReminder || item.reminderAt.map({ $0 > Date() }) != false else { error = "请选择将来的提醒时间。"; return }
        do { item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines); item.dueAt = hasDate ? due : nil; try service.put(item, saveLocally: saveLocally || (item.reminderAt != nil && !item.isDemonstration)); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct RoutineDetail: View {
    @EnvironmentObject private var agenda: AppointmentReminderService
    @ObservedObject var workspace: Workspace
    @ObservedObject var service: RoutineService
    @ObservedObject var information: InformationCardService
    let itemID: UUID
    @State private var editing: RoutineItem?
    @State private var deleting = false
    @State private var completeDespiteChange = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var item: RoutineItem? { service.items.first { $0.id == itemID } }
    var body: some View {
        Form {
            if let item {
                Section {
                    RoutineRow(item: item, now: Date())
                    if !item.note.isEmpty { Text(item.note) }
                    if let reminder = item.reminderAt {
                        LabeledContent("提醒时间",value:reminder.formatted(date:.abbreviated,time:.shortened))
                        Text(item.isDemonstration ? "演示待办不安排系统通知。" : item.completed ? "待办已完成，提醒已撤下。" : agenda.isScheduled(.routine,id:item.id) ? "系统提醒已安排。" : reminder <= Date() ? "提醒时间已过；是否已送达取决于系统通知设置。" : "本项尚未排入系统提醒。" + agenda.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(item.completed ? "重新设为待完成" : "我已完成这件事", systemImage: item.completed ? "arrow.uturn.backward" : "checkmark.circle") {
                        if !item.completed && item.sourceWarning(cards: information.cards) != nil { completeDespiteChange = true }
                        else { perform { try service.complete(item.id, completed: !item.completed) } }
                    }.buttonStyle(.borderedProminent).tint(SeePalette.button)
                    Text("只记录你对这件事的处理状态，不改变任何原事件或核对卡。").font(.caption).foregroundStyle(.secondary)
                }
                Section("来源与保存") {
                    Text(item.origin.informationSource)
                    if let assistant = item.assistedBy { Text("\(assistant) 整理建议 · 请自行核对内容").foregroundStyle(Color.seeAccent) }
                    Text(service.savedIDs.contains(item.id) ? "已存本机" : "仅本次运行")
                    if !item.sourceSnapshot.isEmpty {
                        Text("建立时摘录 · 第 \(item.sourceRevision ?? 1) 版").font(.caption)
                        Text(item.sourceSnapshot).textSelection(.enabled)
                    }
                    if let warning = item.sourceWarning(cards: information.cards) { Label(warning, systemImage: "exclamationmark.bubble").foregroundStyle(.orange) }
                    if let card = information.cards.first(where: { $0.id == item.sourceCardID }) {
                        Button("按最新已核对卡重建约定") { perform { try service.refreshSource(item.id, card: card) } }.disabled(!card.reviewed)
                        Text("重新生成标题、摘录和约定时间，并设为待完成；你的备注保留。").font(.caption).foregroundStyle(.secondary)
                        NavigationLink("查看并核对信息卡") { InformationCardsPage(workspace: workspace, service: information) }
                    }
                }
                Section {
                    Button("编辑待办") { editing = item }
                    NavigationLink("预览并分享待办文字") { SharePreviewPage(original:item.exportText) }
                    Button("删除这项待办", role: .destructive) { deleting = true }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            } else { Text("这项待办已移除") }
        }.seePageCanvas().navigationTitle("待办详情")
            .sheet(item: $editing) { RoutineEditor(service: service, initial: $0) }
            .confirmationDialog("原信息卡已改变、未核对或当前不可用，请先核对保留的摘录。", isPresented: $completeDespiteChange, titleVisibility: .visible) {
                Button("已核对摘录，仍标记完成") { perform { try service.complete(itemID, completed: true) } }
            }
            .confirmationDialog("删除这项待办？", isPresented: $deleting, titleVisibility: .visible) { Button("删除", role: .destructive) { perform { try service.remove(itemID); dismiss() } } }
            .modifier(RoutinePrivacy())
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
}

private struct RoutinePrivacy: ViewModifier {
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View { content.overlay { if phase != .active { DailyPrivacyCover() } } }
}
private extension View {
    func routineCard() -> some View { padding(18).frame(maxWidth: .infinity, alignment: .leading).background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 22)) }
}


struct ReminderTimingSection: View {
    @EnvironmentObject private var agenda: AppointmentReminderService
    @Binding var date: Date?
    @Binding var saveLocally: Bool
    let demonstration: Bool
    var body: some View {
        Section("系统提醒 · 手动开启") {
            if demonstration {
                Label("演示内容不安排系统通知",systemImage:"play.rectangle").foregroundStyle(.secondary)
            } else {
                Toggle("到点提醒我",isOn:Binding(get:{ date != nil },set:{ enabled in
                    date = enabled ? Date().addingTimeInterval(3600) : nil
                    if enabled { saveLocally = true }
                }))
                if date != nil {
                    DatePicker("提醒时间",selection:Binding(get:{ date ?? .now },set:{ date = $0 }))
                    if date.map({ $0 <= Date() }) == true { Text("提醒时间已过，如需再次提醒，请选择将来的时间。").font(.caption).foregroundStyle(.orange) }
                    Text(agenda.permission).font(.subheadline)
                    Button("允许系统通知") { Task { await agenda.requestPermission() } }
                    Button("刷新提醒状态") { agenda.refresh() }
                    Text(agenda.status).font(.caption).foregroundStyle(.secondary)
                }
                Text("保存后才安排。完成、删除、归档或关闭提醒会撤下尚未触发的通知。通知隐藏标题和原文；专注模式可能延后显示。最多预排最近 24 条，下次打开应用补排。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
