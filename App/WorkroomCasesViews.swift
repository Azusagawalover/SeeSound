import SwiftUI

struct WorkroomCasesPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @ObservedObject var cards:InformationCardService
    @ObservedObject var routines:RoutineService
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedID:UUID?
    @State private var columnVisibility:NavigationSplitViewVisibility = .all
    @State private var editing:WorkroomCase?
    @State private var query = ""
    @State private var filter:CaseFilter = .active
    @State private var includeDemo = true
    @State private var options = CaseListOptions()
    var body:some View {
        GeometryReader { geometry in
            if horizontalSizeClass == .regular && geometry.size.width >= 820 && !typeSize.isAccessibilitySize {
                NavigationSplitView(columnVisibility:$columnVisibility) {
                    WorkroomCaseList(workspace:workspace,studio:studio,cards:cards,routines:routines,selectedID:$selectedID,editing:$editing,query:$query,filter:$filter,includeDemo:$includeDemo,options:$options)
                        .navigationSplitViewColumnWidth(min:280,ideal:340,max:420)
                } detail: {
                    NavigationStack {
                        if let id = selectedID {
                            WorkroomCaseDetail(workspace:workspace,studio:studio,cards:cards,routines:routines,itemID:id).id(id)
                        } else { SeeEmptyState(title:"选一件事务继续",detail:"左侧查看进度，右侧处理材料和步骤。",artwork:.clipboard).frame(maxWidth:.infinity,maxHeight:.infinity).seePageCanvas() }
                    }
                }.navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack {
                    WorkroomCaseList(workspace:workspace,studio:studio,cards:cards,routines:routines,selectedID:$selectedID,editing:$editing,query:$query,filter:$filter,includeDemo:$includeDemo,options:$options)
                        .navigationDestination(item:$selectedID) { id in WorkroomCaseDetail(workspace:workspace,studio:studio,cards:cards,routines:routines,itemID:id) }
                }
            }
        }.onAppear { options = studio.campus.listOptions;filter = studio.campus.caseFilter ?? .active;includeDemo = studio.campus.includeDemo ?? true }.onChange(of:filter) { _,value in
            do { try studio.updateEnhancements { var ledger = $0.campus ?? .init();ledger.caseFilter = value;$0.campus = ledger } } catch { workspace.notify(error.localizedDescription) }
        }.onChange(of:includeDemo) { _,value in
            do { try studio.updateEnhancements { var ledger = $0.campus ?? .init();ledger.includeDemo = value;$0.campus = ledger } } catch { workspace.notify(error.localizedDescription) }
        }.onChange(of:options) { _,value in
            do { try studio.updateEnhancements { var ledger = $0.campus ?? .init();ledger.listOptions = value;$0.campus = ledger } } catch { workspace.notify(error.localizedDescription) }
        }.onChange(of:studio.cases.map(\.id)) { _,ids in if let id = selectedID,!ids.contains(id) { selectedID = nil } }
            .sheet(item:$editing) { WorkroomCaseEditor(studio:studio,initial:$0) }
    }
}

struct WorkroomCaseList: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var studio: WorkroomService
    @ObservedObject var cards: InformationCardService
    @ObservedObject var routines: RoutineService
    @Binding var selectedID:UUID?
    @Binding var editing:WorkroomCase?
    @Binding var query:String
    @Binding var filter:CaseFilter
    @Binding var includeDemo:Bool
    @Binding var options:CaseListOptions
    @State private var showingOptions = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var operationError: String?
    private var optionsSummary:String {
        var parts = [options.sort.title,options.scope.title]
        if !options.folder.isEmpty { parts.append(options.folder) }
        if !options.tag.isEmpty { parts.append("#"+options.tag) }
        return parts.joined(separator:" · ")
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                Section {
                    SeeHero(title:"把沟通后的安排留下",detail:"先核对时间、地点和材料，再决定是否建立事务。",artwork:.clipboard)
                    let countLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing:12)) : AnyLayout(HStackLayout(spacing:12))
                    countLayout {
                        countTile("进行中", count: studio.cases.filter { $0.isActive && !$0.demonstration }.count, selection: .active)
                        countTile("已到期", count: studio.cases.filter { !$0.demonstration && $0.overdue(at: context.date) }.count, selection: .overdue)
                        countTile("已完成", count: studio.cases.filter { !$0.demonstration && $0.isCompleted && !$0.isArchived }.count, selection: .completed)
                    }.padding(.vertical,8)
                    Picker("查看事务", selection: $filter) { ForEach(CaseFilter.allCases) { Text($0.title).tag($0) } }
                    Toggle("包含演示事务", isOn: $includeDemo)
                    if let error = operationError ?? studio.error { Text(error).foregroundStyle(.red) }
                } footer: { Text("上方数字只统计非演示事务。置顶优先，其余按当前排序显示。") }
                Section("沟通之后") {
                    if let current = studio.campus.journeys.first(where:{$0.id == studio.campus.lastJourneyID && $0.stage != .finished}) {
                        NavigationLink { CounterVisitPage(workspace:workspace,studio:studio,id:current.id) } label: {
                            SeeToolRow(title:"继续窗口办理",detail:current.title+(current.demonstration ? " · 演示" : ""),artwork:.speech)
                        }.accessibilityIdentifier("cases.counterVisit")
                    }
                    NavigationLink { CampusJourneyPage(workspace:workspace,studio:studio) } label: {
                        SeeToolRow(title:"校园办事旅程",detail:"准备问题、现场沟通，再核对约定与办理结果",artwork:.campus)
                    }.accessibilityIdentifier("cases.journey")
                    NavigationLink { WorkroomPage(workspace:workspace,studio:studio,api:workspace.workroomAPI,importer:workspace.workroomImporter) } label: {
                        SeeToolRow(title:"导入与核对材料",detail:"从图片或文字开始，保留原文依据",artwork:.folder)
                    }.accessibilityIdentifier("cases.materials")
                    NavigationLink { InformationCardsPage(workspace:workspace,service:workspace.information) } label: {
                        SeeToolRow(title:"核对时间、地点和金额",detail:"把重要安排逐项确认后留下",artwork:.clipboard)
                    }.accessibilityIdentifier("cases.confirmations")
                }
                if !options.isDefault { Section { Text(optionsSummary).font(.caption).foregroundStyle(Color.seeAccent);Button("清除附加条件") { options = .init() }.accessibilityIdentifier("cases.clearOptions") } }
                let visible = options.select(studio.cases,query:query,filter:filter,includeDemo:includeDemo,filing:studio.enhancements.filing,routines:routines.items,now:context.date)
                if visible.isEmpty {
                    SeeEmptyState(title:query.isEmpty && options.isDefault && filter == .active ? "这里还没有进行中事务" : "没有符合条件的事务",detail:"可以调整筛选，或从一份文字材料开始。",artwork:.clipboard)
                    if query.isEmpty { Button("从文字材料开始", systemImage: "text.viewfinder") { workspace.navigationRequest = .workroom } }
                }
                ForEach(visible) { item in
                    Button { selectedID = item.id } label: {
                        HStack { CaseSummaryRow(item:item,routines:routines.items,saved:studio.savedCaseIDs.contains(item.id),now:context.date,filing:studio.enhancements.filing["事务:\(item.id)"]);Spacer(minLength:4);Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary) }
                    }.buttonStyle(.plain).listRowBackground(selectedID == item.id ? Color.seeAccent.opacity(0.08) : SeePalette.surface)
                    .swipeActions(edge: .leading) {
                        Button(item.isPinned ? "取消置顶" : "置顶", systemImage: "pin") { perform { var copy = item; copy.pinned = !item.isPinned; try studio.putCase(copy,saveLocally:studio.savedCaseIDs.contains(item.id)) } }.tint(.teal)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(item.isArchived ? "恢复" : "归档", systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox") { perform { try studio.archiveCase(item.id,archived:!item.isArchived) } }.tint(.indigo)
                    }
                }
                if let id = studio.enhancements.lastCaseID,let previous = studio.cases.first(where:{$0.id == id}) { Section { Button("继续上次："+previous.title,systemImage:"arrow.uturn.forward") { selectedID = id } } }
                ProductToolsSection(workspace:workspace)
            }.listStyle(.insetGrouped)
        }.seePageCanvas().navigationTitle("事务清单").searchable(text: $query, prompt: "搜索名称、原文、材料和标签")
            .toolbar { ToolbarItemGroup(placement: .primaryAction) {
                Button("筛选与排序",systemImage:options.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") { showingOptions = true }.accessibilityIdentifier("cases.options")
                Button("新建事务", systemImage: "plus") { editing = WorkroomCase() }.disabled(studio.cases.count >= 100)
            } }
            .sheet(isPresented:$showingOptions) { CaseListOptionsPage(options:$options,filing:studio.enhancements.filing) }
            .modifier(WorkroomPrivacy())
    }
    private func countTile(_ title: String, count: Int, selection: CaseFilter) -> some View {
        Button { filter = selection } label: {
            VStack(alignment:.leading,spacing:6) {
                Text(count,format:.number).font(.title2.bold()).monospacedDigit()
                Text(title).font(.caption)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
                .background(Color.seeAccent.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
        }.buttonStyle(.plain).foregroundStyle(Color.seeAccent)
    }
    private func perform(_ operation: () throws -> Void) { do { try operation(); operationError = nil } catch { operationError = error.localizedDescription } }
}

struct CaseSummaryRow: View {
    let item: WorkroomCase
    let routines: [RoutineItem]
    let saved: Bool
    let now: Date
    var filing:RecordFiling? = nil
    var body: some View {
        HStack(alignment:.top,spacing:14) {
            let progress = item.progress(routines:routines)
            ZStack {
                Circle().stroke(Color.seeAccent.opacity(0.12),lineWidth:4)
                Circle().trim(from:0,to:progress.total == 0 ? 0 : CGFloat(progress.done)/CGFloat(progress.total))
                    .stroke(Color.seeAccent,style:StrokeStyle(lineWidth:4,lineCap:.round)).rotationEffect(.degrees(-90))
                Image(systemName:item.isArchived ? "archivebox" : item.isCompleted ? "checkmark" : "list.bullet").font(.caption.bold()).foregroundStyle(Color.seeAccent)
            }.frame(width:34,height:34).padding(.top,4).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:8) {
                HStack(alignment:.top) {
                    Text(item.title).font(.headline)
                    if item.isPinned { Image(systemName:"pin.fill").font(.caption).foregroundStyle(Color.seeAccent).accessibilityLabel("已置顶") }
                    if item.priority == .important { Image(systemName:"flag.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("重要") }
                }
                if item.demonstration { Text("演示事务").font(.caption).foregroundStyle(Color.seeAccent) }
                if item.isActive, let next = item.nextAction(routines:routines) { Text("下一步 · " + next).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                Text("\(item.stateTitle) · \(progress.done)/\(progress.total) 项已处理").font(.caption).foregroundStyle(.secondary)
                if let due = item.dueAt {
                    Label(due.formatted(date:.abbreviated,time:.shortened),systemImage:item.overdue(at:now) ? "clock.badge.exclamationmark" : "calendar")
                        .font(.caption).foregroundStyle(item.overdue(at:now) ? Color.orange : Color.secondary)
                }
                if item.reminderAt != nil && item.isActive && !item.demonstration { Label("已设置提醒时间，详情查看安排状态",systemImage:"bell").font(.caption).foregroundStyle(.secondary) }
                if let filing, !filing.folder.isEmpty || !filing.tags.isEmpty { Text(([filing.folder].filter { !$0.isEmpty }+filing.tags.map { "#"+$0 }).joined(separator:" · ")).font(.caption).foregroundStyle(Color.seeAccent) }
                if !saved { Text("仅本次运行").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.vertical,8)
    }
}

struct WorkroomCaseEditor: View {
    @ObservedObject var studio: WorkroomService
    @State private var item: WorkroomCase
    @State private var saveLocally: Bool
    @State private var error: String?
    private let initialReminder: Date?
    private let initialItem:WorkroomCase
    private let initialSaved:Bool
    private let baselineFingerprint:String?
    @State private var discarding = false
    private var dirty:Bool { item != initialItem || saveLocally != initialSaved }
    @Environment(\.dismiss) private var dismiss
    init(studio: WorkroomService, initial: WorkroomCase) {
        self.studio = studio; _item = State(initialValue: initial); _saveLocally = State(initialValue: studio.savedCaseIDs.contains(initial.id)); initialReminder = initial.reminderAt
        initialItem = initial;initialSaved = studio.savedCaseIDs.contains(initial.id)
        baselineFingerprint = studio.cases.contains(where:{$0.id == initial.id}) ? try? initial.reviewFingerprint() : nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("这件事") {
                    if item.demonstration { Label("演示事务", systemImage: "play.rectangle") }
                    TextField("事务名称（最多 60 字）", text: $item.title).accessibilityIdentifier("caseEditor.title")
                    TextField("说明或材料摘录（最多 500 字）", text: $item.note, axis: .vertical).lineLimit(3...8)
                    Toggle("重要事务",isOn:Binding(get:{ item.priority == .important },set:{ item.priority = $0 ? .important : .ordinary }))
                    Toggle("置顶",isOn:Binding(get:{ item.isPinned },set:{ item.pinned = $0 }))
                }
                Section("时间安排 · 由你设置") {
                    Toggle("设置截止时间",isOn:Binding(get:{ item.dueAt != nil },set:{ item.dueAt = $0 ? Date().addingTimeInterval(3600) : nil }))
                    if item.dueAt != nil { DatePicker("截止时间",selection:Binding(get:{ item.dueAt ?? .now },set:{ item.dueAt = $0 })) }
                    Text("这里的时间由你指定，不会从原文或模型建议自动启用提醒。").font(.caption).foregroundStyle(.secondary)
                }
                ReminderTimingSection(date:$item.reminderAt,saveLocally:$saveLocally,demonstration:item.demonstration)
                Section("保存") {
                    Toggle("将这件事务保存在本机", isOn: $saveLocally).disabled(item.reminderAt != nil && !item.demonstration)
                    Text("设置系统提醒需要保存到本机。取消提醒后可以改为仅本次运行；取消保存会删除已存副本。").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("保存事务", action: save)
                }
            }.seePageCanvas().navigationTitle("编辑事务").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { if dirty { discarding = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: save) }
            }.modifier(KeyboardCloseToolbar()).interactiveDismissDisabled(dirty)
                .confirmationDialog("放弃这次未保存的事务修改？",isPresented:$discarding,titleVisibility:.visible) { Button("放弃修改",role:.destructive) { do { try studio.clearRecovery(item.id);dismiss() } catch { self.error = error.localizedDescription } }
            }.task(id:item) {
                guard dirty,studio.campus.recoverEdits else { return }
                do { try await Task.sleep(for:.milliseconds(700));try Task.checkCancellation();if (try? item.validate()) != nil { try studio.captureRecovery(item,baseline:baselineFingerprint,saveLocally:saveLocally) } } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }.modifier(WorkroomPrivacy())
        }
    }
    private func save() {
        guard item.reminderAt == initialReminder || item.reminderAt.map({ $0 > Date() }) != false else { error = "请选择将来的提醒时间。"; return }
        do {
            if let baselineFingerprint {
                guard let current = studio.cases.first(where:{$0.id == item.id}),try current.reviewFingerprint() == baselineFingerprint else { throw ChecklistError.stale }
            } else if studio.cases.contains(where:{$0.id == item.id}) { throw ChecklistError.stale }
            item.title = item.title.trimmingCharacters(in:.whitespacesAndNewlines)
            try studio.putCase(item, saveLocally: saveLocally || (item.reminderAt != nil && !item.demonstration),discardRecovery:true); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct WorkroomCaseDetail: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var studio: WorkroomService
    @ObservedObject var cards: InformationCardService
    @ObservedObject var routines: RoutineService
    let itemID: UUID
    @EnvironmentObject private var agenda: AppointmentReminderService
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var quoteEvidence:EvidenceSheetRoute?
    @State private var showingSources = false
    @State private var showingDocuments = false
    @State private var showingFocus = false
    @State private var checklistRoute:ChecklistSheetRoute?
    @State private var checklistUndo:ChecklistUndo?
    @State private var onlyRemaining = false
    @State private var removingRow:(item:WorkroomCase,row:CaseStep)?
    @State private var showingRules = false
    @State private var showingCompletion = false
    @State private var flowEditing = false
    @State private var pendingLink:CaseLink?
    @State private var templateConfirming = false
    @State private var focusID:String?
    @State private var focusRequest = UUID()
    @State private var material = ""
    @State private var step = ""
    @State private var editing: WorkroomCase?
    @State private var linking = false
    @State private var deleting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var item: WorkroomCase? { studio.cases.first { $0.id == itemID } }
    private var detailContent:some View {
        List {
            if let item {
                header(item)
                if item.isActive { Section("下一步") { primaryAction(item) } }
                if checklistUndo != nil { Section { ChecklistFeedback(studio:studio,receipt:$checklistUndo) } }
                Section("清单工具") {
                    if item.isActive { Button("进入专注处理",systemImage:"rectangle.center.inset.filled") { showingFocus = true }.accessibilityIdentifier("case.focus") }
                    Toggle("只看未处理项目",isOn:$onlyRemaining).accessibilityIdentifier("case.onlyRemaining")
                    if item.isActive { Menu {
                        Button("批量标为已处理") { checklistRoute = .init(initial:item,action:.batch) }.disabled(CaseFocusQueue.ready(in:item).isEmpty).accessibilityIdentifier("case.batch")
                        Button("调整材料顺序") { checklistRoute = .init(initial:item,action:.order(.material)) }.disabled(item.materials.count < 2)
                        Button("调整步骤顺序") { checklistRoute = .init(initial:item,action:.order(.step)) }.disabled(item.steps.count < 2)
                    } label: { Label("更多清单操作",systemImage:"ellipsis.circle").frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.borderless).accessibilityIdentifier("case.checklistTools") }
                }
                Section("准备材料 · \(item.materials.filter(\.done).count) / \(item.materials.count)") {
                    ForEach(item.materials.filter { !onlyRemaining || !$0.done }) { row in checklist(row, material: true).disabled(!item.isActive).id(row.id.uuidString) }
                    if onlyRemaining && item.materials.allSatisfy(\.done) { Text("没有未处理材料").font(.caption).foregroundStyle(.secondary) }
                    VStack(alignment:.leading,spacing:8) {
                        TextField("添加材料，例如学生证", text: $material,axis:.vertical).lineLimit(1...4).accessibilityIdentifier("case.addMaterialText")
                        Button("添加") { if update({ $0.materials.append(CaseStep(title: material)) }) { material = "" } }.disabled(material.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.materials.count >= 30 || !item.isActive).accessibilityIdentifier("case.addMaterial")
                    }
                }
                Section("处理步骤 · \(item.steps.filter(\.done).count) / \(item.steps.count)") {
                    ForEach(item.steps.filter { !onlyRemaining || !$0.done }) { row in checklist(row, material: false).disabled(!item.isActive).id(row.id.uuidString) }
                    if onlyRemaining && item.steps.allSatisfy(\.done) { Text("没有未处理步骤").font(.caption).foregroundStyle(.secondary) }
                    VStack(alignment:.leading,spacing:8) {
                        TextField("添加步骤，例如确认报名", text: $step,axis:.vertical).lineLimit(1...4)
                        Button("添加") { if update({ $0.steps.append(CaseStep(title: step)) }) { step = "" } }.disabled(step.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.steps.count >= 30 || !item.isActive)
                    }
                }
                Section { expansion("安排、来源与变更记录",expanded:$showingSources,id:"case.arrangements") }
                if showingSources { Section("材料与已确认安排") {
                    Button { showingDocuments = true } label: { HStack { Label("事务材料 · \(item.documents.count) 份",systemImage:"doc.on.doc");Spacer();Image(systemName:"chevron.right").font(.caption) }.frame(minHeight:44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("case.sources")
                    ForEach(item.confirmedFacts) { fact in LabeledContent(fact.kind.title,value:fact.value) }
                    NavigationLink("等待回复与跟进记录") { CaseFollowUpPage(studio:studio,itemID:item.id) }
                    if let last = item.updates?.last {
                        DisclosureGroup("最近一次确认的变更") { ForEach(last.changes,id:\.self) { Text($0).font(.subheadline) };Text(last.date,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                    }
                    if (item.updates?.count ?? 0) > 1 { DisclosureGroup("全部变更记录") { ForEach((item.updates ?? []).reversed()) { update in VStack(alignment:.leading,spacing:6) { Text(update.date,format:.dateTime.month().day().hour().minute()).font(.caption);ForEach(update.changes,id:\.self) { Text($0).font(.subheadline) } } } } }
                } }
                Section { expansion("推进规则与更多操作",expanded:$showingRules,id:"case.rules") }
                if showingRules { flowSection(item) }
                Section { expansion("完成与归档",expanded:$showingCompletion,id:"case.completion") }
                if showingCompletion { Section("事务状态") {
                    let progress = item.progress(routines:routines.items)
                    Button(item.isCompleted ? "重新打开事务" : "标记事务完成",systemImage:item.isCompleted ? "arrow.uturn.backward" : "checkmark.circle.fill") {
                        do { try studio.completeCase(item.id,completed:!item.isCompleted,routines:routines.items); error = nil } catch { self.error = error.localizedDescription }
                    }.disabled(item.isArchived || (!item.isCompleted && (progress.total == 0 || progress.done != progress.total)))
                    Button(item.isArchived ? "恢复到清单" : "归档事务",systemImage:item.isArchived ? "tray.and.arrow.up" : "archivebox") {
                        do { try studio.archiveCase(item.id,archived:!item.isArchived); error = nil } catch { self.error = error.localizedDescription }
                    }
                    Text("完成前需处理所有材料、步骤和关联待办。归档会收起事务并撤下提醒，保留原有进度。").font(.caption).foregroundStyle(.secondary)
                } }
                if let prepared=item.preparation {
                    Section("建立时的来源") {
                        Text("\(prepared.generator) 提供草稿，由你预览后建立。")
                        Text("\(prepared.title) · 第 \(prepared.revision) 版").font(.subheadline)
                        let current = studio.active.id == prepared.draftID ? studio.active : studio.drafts.first { $0.id == prepared.draftID }
                        if let current {
                            if current.revision != prepared.revision || current.title != prepared.title {
                                Label("当前原文版本不同，本事务仍保留建立时的依据。",systemImage:"exclamationmark.bubble").font(.caption).foregroundStyle(.orange)
                            }
                        } else { Text("原材料当前未载入；材料和步骤里的建立时依据仍保留。").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("关联信息与待办") {
                    Button("选择现有核对卡与待办", systemImage: "link") { linking = true }.disabled(!item.isActive)
                    ForEach(item.links) { link in linkedRow(link) }
                    Text("这里只主动关联你选择的内容。删除原记录后保留建立时摘录，并显示原记录不可用；删除本事务不会删除原记录。").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if studio.savedCaseIDs.contains(item.id) { NavigationLink("导出这件事的加密接力文件") { LibraryBackupPage(workspace:workspace,handoffID:item.id) } }
                    if let seen = item.watchSeenAt { LabeledContent((try? item.watchSummary(routines:routines.items).seen) == true ? "Watch 当前版本查看回执" : "Watch 旧版本查看回执",value:seen.formatted(date:.abbreviated,time:.shortened)) }
                    NavigationLink("预览并分享事务清单") { SharePreviewPage(original:item.export(routines:routines.items)) }
                    Button("移到最近删除", role: .destructive) { deleting = true }.accessibilityIdentifier("case.delete")
                    if let error { Text(error).foregroundStyle(.red) }
                }
            } else { Text("事务已移除") }
        }
    }
    var body:some View {
        ScrollViewReader { proxy in
        detailContent.seePageCanvas().navigationTitle("事务详情").modifier(KeyboardCloseToolbar())
            .onChange(of:focusRequest) { _,_ in if let id = focusID { proxy.scrollTo(id,anchor:.center) } }
            .onAppear { if studio.savedCaseIDs.contains(itemID) && studio.enhancements.lastCaseID != itemID { do { try studio.updateEnhancements { $0.lastCaseID = itemID } } catch { self.error = error.localizedDescription } } }
            .sheet(isPresented:$flowEditing) { CaseFlowEditor(studio:studio,itemID:itemID) }
            .confirmationDialog("保存这件事的材料和步骤文字为模板？模板中如有姓名等个人信息也会保留，请先检查。",isPresented:$templateConfirming,titleVisibility:.visible) { Button("保存模板") { do { guard let item else { return };let template = CaseTemplate(title:item.title,materials:item.materials.map(\.title),steps:item.steps.map(\.title));try studio.updateEnhancements { $0.templates.append(template) };workspace.notify("模板已保存") } catch { self.error = error.localizedDescription } } }
            .confirmationDialog(pendingLinkDescription,isPresented:Binding(get:{pendingLink != nil},set:{if !$0 { pendingLink = nil }}),titleVisibility:.visible) { Button("已核对，更新摘录") { if let link = pendingLink,let card = cards.cards.first(where:{$0.id == link.id}) { update { item in if let index = item.links.firstIndex(of:link) { item.links[index].snapshot = String((card.kind.title+"："+card.displayValue).prefix(300));item.links[index].revision = card.revision } } };pendingLink = nil } } message: { Text("不会自动更改事务日期或提醒。如有改约，请核对后单独编辑。") }
            .sheet(item: $editing) { WorkroomCaseEditor(studio: studio, initial: $0) }
            .sheet(isPresented: $linking) { CaseLinkPicker(studio: studio, cards: cards, routines: routines, itemID: itemID) }
            .confirmationDialog("把事务移到最近删除？原信息卡与待办保留，可以恢复。", isPresented: $deleting) { Button("确认移到最近删除", role: .destructive) { do { try studio.removeCase(itemID); dismiss() } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("case.delete.confirm") }
            .modifier(WorkroomPrivacy())
        }.sheet(item:$quoteEvidence) { route in NavigationStack { EvidenceQuotePage(studio:studio,source:route.source,quote:route.quote).toolbar { Button("关闭") { quoteEvidence = nil } } } }
        .sheet(isPresented:$showingFocus) { CaseFocusPage(workspace:workspace,studio:studio,itemID:itemID,receipt:$checklistUndo) }
        .sheet(item:$checklistRoute) { route in
            switch route.action {
            case .batch:ChecklistBatchPage(studio:studio,initial:route.initial,receipt:$checklistUndo)
            case .rename(let row):ChecklistRenamePage(studio:studio,initial:route.initial,row:row,receipt:$checklistUndo)
            case .order(let kind):ChecklistOrderPage(studio:studio,initial:route.initial,kind:kind,receipt:$checklistUndo)
            }
        }
        .confirmationDialog("从清单移除“"+(removingRow?.row.title ?? "")+"”？本次页面可撤销。",isPresented:Binding(get:{removingRow != nil},set:{if !$0 { removingRow = nil }}),titleVisibility:.visible) {
            Button("确认移除项目",role:.destructive) { if let pending = removingRow { do { checklistUndo = try studio.changeChecklist(caseID:pending.item.id,fingerprint:pending.item.reviewFingerprint(),change:.remove(pending.row.id));error = nil } catch { self.error = error.localizedDescription } };removingRow = nil }
        }
        .sheet(isPresented:$showingDocuments) {
            NavigationStack { CaseDocumentsPage(workspace:workspace,studio:studio,itemID:itemID)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成材料核对") { showingDocuments = false }.accessibilityIdentifier("case.closeSources") } }
            }
        }
    }
    private func header(_ item:WorkroomCase) -> some View {
        Section {
            Text(item.title).font(.title2.bold()).fixedSize(horizontal:false,vertical:true)
            let statusLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment:.leading,spacing:8)) : AnyLayout(HStackLayout())
            statusLayout { Text(item.stateTitle).accessibilityIdentifier("case.state");if item.demonstration { Label("演示",systemImage:"play.rectangle") };if item.priority == .important { Label("重要",systemImage:"flag.fill") } }.font(.caption).foregroundStyle(Color.seeAccent)
            let progress = item.progress(routines:routines.items)
            if progress.total > 0 { ProgressView(value:Double(progress.done),total:Double(progress.total));Text("\(progress.done) / \(progress.total) 项已处理").font(.caption).foregroundStyle(.secondary) }
            if let date = item.dueAt { Label(date.formatted(date:.abbreviated,time:.shortened),systemImage:"calendar").font(.caption) }
            if !item.note.isEmpty { DisclosureGroup("事务说明") { Text(item.note).textSelection(.enabled) } }
            if typeSize.isAccessibilitySize {
                Text(studio.savedCaseIDs.contains(item.id) ? "已存本机" : "仅本次运行").font(.caption).foregroundStyle(.secondary)
                Button("编辑与提醒") { editing = item }.frame(minHeight:44)
            } else {
                HStack { Text(studio.savedCaseIDs.contains(item.id) ? "已存本机" : "仅本次运行").font(.caption).foregroundStyle(.secondary);Spacer();Button("编辑与提醒") { editing = item } }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    private func expansion(_ title:String,expanded:Binding<Bool>,id:String) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack { Text(title).fixedSize(horizontal:false,vertical:true);Spacer(minLength:12);Image(systemName:expanded.wrappedValue ? "chevron.up" : "chevron.down").font(.caption.bold()) }.frame(minHeight:44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(expanded.wrappedValue ? "已展开" : "已折叠").accessibilityIdentifier(id)
    }
    @ViewBuilder private func primaryAction(_ item:WorkroomCase) -> some View {
        if item.workflow.disposition == .waiting {
            NavigationLink { CaseFollowUpPage(studio:studio,itemID:item.id) } label: { Label("记录回复，继续推进",systemImage:"bubble.left.and.bubble.right.fill").font(.headline).frame(minHeight:44) }.accessibilityIdentifier("case.primary")
            Text(item.workflow.waitingFor.isEmpty ? "正在等待对方回复" : "等待："+item.workflow.waitingFor).font(.caption).foregroundStyle(.secondary)
        } else if item.workflow.disposition == .deferred {
            Button("查看暂缓安排") { flowEditing = true }.accessibilityIdentifier("case.primary")
        } else if let row = item.materials.first(where:{!$0.done && item.blockedBy($0).isEmpty}) {
            Button { focusID = row.id.uuidString;focusRequest = UUID() } label: { Label("处理材料 · "+row.title,systemImage:"arrow.down.circle.fill").font(.headline).frame(minHeight:44) }.accessibilityIdentifier("case.primary")
        } else if let row = item.steps.first(where:{!$0.done && item.blockedBy($0).isEmpty}) {
            Button { focusID = row.id.uuidString;focusRequest = UUID() } label: { Label("继续 · "+row.title,systemImage:"arrow.down.circle.fill").font(.headline).frame(minHeight:44) }.accessibilityIdentifier("case.primary")
        } else if item.progress(routines:routines.items).total > 0 && item.progress(routines:routines.items).done == item.progress(routines:routines.items).total {
            Button("确认完成事务",systemImage:"checkmark.circle.fill") { do { try studio.completeCase(item.id,completed:true,routines:routines.items) } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("case.primary")
        } else {
            Text(item.nextAction(routines:routines.items) ?? "可以添加材料或步骤，开始处理。 ").font(.headline)
        }
    }
    private func flowSection(_ item:WorkroomCase) -> some View {
                Section("推进规则") {
                    Button("等待、暂缓、重复与步骤依赖",systemImage:"arrow.triangle.branch") { flowEditing = true }.disabled(!item.isActive)
                    if item.workflow.disposition != .ready && item.isActive { Button("恢复推进") { update { var flow = $0.workflow;flow.disposition = .ready;flow.resumeAt = nil;$0.flow = flow } } }
                    if let date = item.workflow.resumeAt,item.workflow.disposition == .deferred { LabeledContent("计划恢复",value:date.formatted(date:.abbreviated,time:.shortened)) }
                    if item.workflow.cadence != .none { Text("重复："+item.workflow.cadence.title).font(.caption)
                        if item.isCompleted && !item.isArchived { Button(item.workflow.nextOccurrenceID == nil ? "建立下一次事务" : "打开已建立的下一次") { do { let id = try studio.createNextOccurrence(item.id);workspace.scheduledDestination = .init(kind:.project,recordID:id) } catch { self.error = error.localizedDescription } } }
                    }
                    Button("将材料和步骤保存为模板",systemImage:"square.on.square") { templateConfirming = true }
                    NavigationLink("查看哪些记录引用了它") { ReverseLinksPage(workspace:workspace,hit:.init(recordID:item.id,kind:.project,title:item.title,detail:item.note,demonstration:item.demonstration)) }
                    NavigationLink("文件夹与标签") { FilingEditorBody(studio:studio,key:"事务:\(item.id)") }
                }
    }
    private var pendingLinkDescription:String {
        let old = pendingLink?.snapshot ?? ""
        let current = pendingLink.flatMap { link in cards.cards.first { $0.id == link.id } }
        return "原卡已变化："+old+" → "+(current.map { $0.kind.title+"："+$0.displayValue } ?? "")
    }
    private func checklist(_ row: CaseStep, material: Bool) -> some View {
        VStack(alignment:.leading,spacing:8) {
        let rowLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment:.leading,spacing:12)) : AnyLayout(HStackLayout())
        rowLayout {
            Button { changeChecklist(.complete([row.id],!row.done)) } label: { Label(row.title, systemImage: row.done ? "checkmark.circle.fill" : "circle").foregroundStyle(row.done ? Color.seeAccent : Color.primary) }.buttonStyle(.plain).accessibilityValue(row.done ? "已处理" : "未处理").accessibilityIdentifier("case.checklist."+(material ? "material." : "step.")+row.title)
            if !typeSize.isAccessibilitySize { Spacer() }
            Menu {
                Button("修改名称") { if let item { checklistRoute = .init(initial:item,action:.rename(row)) } }.accessibilityIdentifier("case.rename."+row.title)
                Button("从清单移除",role:.destructive) { if let item { removingRow = (item,row) } }
            } label: { Label("项目操作",systemImage:"ellipsis.circle").frame(minHeight:44) }.buttonStyle(.borderless).font(.caption).accessibilityIdentifier("case.rowTools."+row.title)
        }.frame(minHeight: 44)
            if let current = item,!current.blockedBy(row).isEmpty { Label("先完成："+current.blockedBy(row).map(\.title).joined(separator:"、"),systemImage:"lock").font(.caption).foregroundStyle(.orange) }
            if row.renamedByUser == true { Text(row.sourceQuote == nil ? "名称由你修改" : "名称由你修改，原依据保留").font(.caption).foregroundStyle(Color.seeAccent) }
            if let label=row.sourceLabel { Text(label).font(.caption).foregroundStyle(.secondary) }
            if let quote=row.sourceQuote { DisclosureGroup("建立时依据") { Text(quote).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let source = item?.documents.first(where:{$0.text.contains(quote)}) { Button("定位原文依据") { quoteEvidence = .init(source:source,quote:quote) }.buttonStyle(.borderless) }
            } }
        }
    }
    @ViewBuilder private func linkedRow(_ link: CaseLink) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(link.snapshot).font(.headline)
            if link.kind == .card {
                if let card = cards.cards.first(where: { $0.id == link.id }) {
                    Text(card.reviewed ? "用户已标记核对当前卡片" : "尚未核对当前卡片").font(.caption).foregroundStyle(card.reviewed ? Color.seeAccent : .orange)
                    if card.revision != link.revision { Label("原卡已更新，当前摘录仍为旧版", systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.orange) }
                    NavigationLink("打开原卡") { InformationCardDetail(workspace: workspace, service: cards, cardID: card.id) }
                    Button("核对当前卡片并更新摘录") { pendingLink = link }
                } else { Text("原信息卡当前不可用；这里保留建立时摘录。").font(.caption).foregroundStyle(.orange) }
            } else {
                if let routine = routines.items.first(where: { $0.id == link.id }) {
                    Text(routine.completed ? "关联待办已完成" : "关联待办待完成").font(.caption).foregroundStyle(.secondary)
                    NavigationLink("打开原待办") { RoutineDetail(workspace: workspace, service: routines, information: cards, itemID: routine.id) }
                } else { Text("原待办当前不可用，不计为已完成。").font(.caption).foregroundStyle(.orange) }
            }
            Button("取消关联", role: .destructive) { update { $0.links.removeAll { $0.id == link.id && $0.kind == link.kind } } }.font(.caption).disabled(item?.isActive != true)
        }.padding(.vertical, 5)
    }
    private func changeChecklist(_ change:ChecklistChange) {
        guard let item else { return }
        do { checklistUndo = try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:change);error = nil } catch { self.error = error.localizedDescription }
    }
    @discardableResult private func update(_ operation: (inout WorkroomCase) -> Void) -> Bool {
        guard var item, item.isActive else { return false }; operation(&item)
        do { try studio.putCase(item, saveLocally: studio.savedCaseIDs.contains(item.id)); error = nil; return true } catch { self.error = error.localizedDescription; return false }
    }
}

private struct CaseLinkPicker: View {
    @ObservedObject var studio: WorkroomService
    @ObservedObject var cards: InformationCardService
    @ObservedObject var routines: RoutineService
    let itemID: UUID
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var item: WorkroomCase? { studio.cases.first { $0.id == itemID } }
    var body: some View {
        NavigationStack {
            List {
                if let item {
                    Section { Text(item.demonstration ? "这里只显示演示内容。" : "这里只显示非演示内容。").font(.footnote).foregroundStyle(.secondary) }
                    Section("信息卡") {
                        ForEach(cards.cards.filter { ($0.origin == .demonstration) == item.demonstration }) { card in
                            Button { toggle(.init(id: card.id, kind: .card, snapshot: String((card.kind.title + "：" + card.displayValue).prefix(300)), revision: card.revision, demonstration: card.origin == .demonstration)) } label: {
                                Label(card.kind.title + "：" + card.displayValue, systemImage: item.links.contains { $0.kind == .card && $0.id == card.id } ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    Section("待办") {
                        ForEach(routines.items.filter { $0.isDemonstration == item.demonstration }) { routine in
                            Button { toggle(.init(id: routine.id, kind: .routine, snapshot: routine.title, demonstration: routine.isDemonstration)) } label: {
                                Label(routine.title, systemImage: item.links.contains { $0.kind == .routine && $0.id == routine.id } ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }.seePageCanvas().navigationTitle("选择关联内容").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }.modifier(WorkroomPrivacy())
        }
    }
    private func toggle(_ link: CaseLink) {
        guard var item else { return }
        if item.links.contains(where: { $0.id == link.id && $0.kind == link.kind }) { item.links.removeAll { $0.id == link.id && $0.kind == link.kind } }
        else { item.links.append(link) }
        do { try studio.putCase(item, saveLocally: studio.savedCaseIDs.contains(item.id)) } catch { self.error = error.localizedDescription }
    }
}

struct GlobalSearchPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var studio: WorkroomService
    @ObservedObject var cards: InformationCardService
    @ObservedObject var routines: RoutineService
    @ObservedObject var conversations: ConversationArchiveService
    @State private var query = ""
    @State private var includeDemo = false
    @State private var kind: GlobalSearchHit.Kind?
    private var results: [GlobalSearchHit] {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        return WorkroomSearch.hits(query: query, events: workspace.ledger.events + workspace.demoLedger.events, conversations: conversations.items,
                            cards: cards.cards, routines: routines.items, drafts: studio.drafts, cases: studio.cases, annotations: workspace.annotations.merging(workspace.demoAnnotations) { _,new in new },journeys:studio.campus.journeys).filter { (includeDemo || !$0.demonstration) && (kind == nil || $0.kind == kind) }
    }
    var body: some View {
        List {
            Section {
                Picker("搜索范围",selection:$kind) {
                    Text("全部记录").tag(nil as GlobalSearchHit.Kind?)
                    ForEach(GlobalSearchHit.Kind.allCases,id:\.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                Toggle("包含演示材料", isOn: $includeDemo); Text("只搜索这台设备当前可见的事件、已存会话、信息卡、待办、草稿、事务和办事旅程，不访问网络，不扫描其他 App。").font(.caption).foregroundStyle(.secondary) }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ContentUnavailableView("搜索你留下的内容", systemImage: "magnifyingglass", description: Text("输入地点、事项或关键词。")) }
            else if results.isEmpty { ContentUnavailableView.search(text: query) }
            ForEach(results) { hit in
                NavigationLink { LibraryRecordPage(workspace:workspace,hit:hit,query:query) } label: {
                    VStack(alignment: .leading, spacing: 7) { Text(highlight(hit.title,query:query)).font(.headline); Text(hit.kind.rawValue + (hit.demonstration ? " · 演示" : "")).font(.caption).foregroundStyle(Color.seeAccent); Text(highlight(hit.excerpt(for:query),query:query)).font(.subheadline).lineLimit(3).foregroundStyle(.secondary) }
                }
            }
        }.seePageCanvas().navigationTitle("全局搜索").searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索本机内容").modifier(WorkroomPrivacy())
    }
    @ViewBuilder private func destination(_ hit: GlobalSearchHit) -> some View {
        switch hit.kind {
        case .journey, .question, .journeyFact, .excerpt, .journeySource: JourneySearchDestination(workspace:workspace,studio:studio,hit:hit,query:query)
        case .event: EventDetail(workspace: workspace, eventID: hit.recordID)
        case .card: InformationCardDetail(workspace: workspace, service: cards, cardID: hit.recordID)
        case .routine: RoutineDetail(workspace: workspace, service: routines, information: cards, itemID: hit.recordID)
        case .project: WorkroomCaseDetail(workspace: workspace, studio: studio, cards: cards, routines: routines, itemID: hit.recordID)
        case .draft:
            if let draft = studio.drafts.first(where: { $0.id == hit.recordID }) {
                List { Text(draft.origin.informationSource); Text(draft.text).textSelection(.enabled); Button("在文字工作室继续编辑") { do { try studio.use(draft); workspace.navigationRequest = .workroom } catch { workspace.notify(error.localizedDescription) } } }.seePageCanvas().navigationTitle(draft.title).modifier(WorkroomPrivacy())
            } else { Text("草稿已删除") }
        case .conversation:
            if let item = conversations.items.first(where: { $0.id == hit.recordID }) {
                ScrollView { LazyVStack { ForEach(item.turns) { SavedTurnCard(turn: $0) }; NavigationLink("预览并分享会话") { SharePreviewPage(original:item.exportText) } }.padding() }.seePageCanvas().navigationTitle(item.title).modifier(WorkroomPrivacy())
            } else { Text("会话已删除") }
        }
    }
}

struct EvidenceSheetRoute:Identifiable { var id = UUID();var source:CaseDocument;var quote:String }
