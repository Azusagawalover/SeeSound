import SwiftUI

struct CaseDocumentsPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    let itemID:UUID
    @State private var error:String?
    @State private var title = "补充材料"
    @State private var text = ""
    private var item:WorkroomCase? { studio.cases.first { $0.id == itemID } }
    private var drafts:[WorkroomDraft] {
        var rows = studio.drafts
        if (try? studio.active.validate()) != nil,!rows.contains(where:{$0.id == studio.active.id && $0.revision == studio.active.revision}) { rows.insert(studio.active,at:0) }
        return rows.filter { $0.demonstration == item?.demonstration }
    }
    var body:some View {
        List {
            if let item {
                Section {
                    Label("一件事，把材料放在一起",systemImage:"doc.on.doc").font(.title2.bold())
                    Text("已加入 \(item.documents.count) / 8 份材料。保存的是加入时的文字版本；以后编辑原草稿，这里的来源仍保留。").font(.subheadline).foregroundStyle(.secondary)
                    Text(studio.savedCaseIDs.contains(itemID) ? "点“加入”会把该份材料文字一起保存在本机事务中。" : "当前事务仅本次运行；保存事务后，加入的材料也会保存。 ").font(.caption).foregroundStyle(.secondary)
                }
                Section("已加入的材料") {
                    ForEach(item.documents) { document in
                        NavigationLink { CaseDocumentDetailPage(workspace:workspace,studio:studio,itemID:itemID,document:document) } label: {
                            VStack(alignment:.leading,spacing:6) { Label(document.title,systemImage:document.origin == .imageText ? "photo.on.rectangle" : "doc.text").font(.headline);Text("第 \(document.revision) 版 · \(document.text.count) 字"+(document.demonstration ? " · 演示" : "")).font(.caption).foregroundStyle(.secondary) }
                        }
                        NavigationLink { CaseUpdateReviewPage(workspace:workspace,studio:studio,api:workspace.caseUpdateAPI,itemID:itemID,incoming:document) } label: { Label("与现有安排对照 · "+document.title,systemImage:"arrow.triangle.2.circlepath").frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle()) }.accessibilityIdentifier("source.compare."+document.title)
                    }
                    if item.documents.isEmpty { FeatureMessage(title:"还没有加入来源材料",detail:"可以从下方选择已有草稿，或输入一段补充通知。",symbol:"doc.badge.plus") }
                }
                if item.isActive {
                    Section("从已有草稿加入") {
                        ForEach(drafts) { draft in
                            let already = item.documents.contains { $0.draftID == draft.id && $0.revision == draft.revision }
                            Button { attach(CaseDocument(draft:draft)) } label: { Label(draft.title+(already ? " · 已加入" : ""),systemImage:already ? "checkmark.circle" : "plus.circle").frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.disabled(already || item.documents.count >= 8).accessibilityIdentifier("source.add."+draft.title)
                        }
                        if drafts.isEmpty { Button("去文字工作室导入材料") { workspace.navigationRequest = .workroom } }
                    }
                    Section("直接补充文字") {
                        TextField("材料标题",text:$title)
                        TextEditor(text:$text).frame(height:180).accessibilityLabel("补充材料原文")
                        Text("\(text.count) / 12000 字").font(.caption).foregroundStyle(.secondary)
                        Button("加入这份补充材料",systemImage:"plus.circle") {
                            var draft = WorkroomDraft();draft.title = title;draft.text = text;draft.origin = item.demonstration ? .demonstration : .typed
                            if attach(CaseDocument(draft:draft)) { text = "" }
                        }.disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || item.documents.count >= 8)
                    }
                }
                if let error { Section { FeatureMessage(title:"材料未加入",detail:error,actionTitle:"保留文字，继续检查",action:{self.error = nil}) } }
            } else { FeatureMessage(title:"事务已移除",detail:"返回事务清单选择当前记录。",symbol:"doc.badge.clock") }
        }.seePageCanvas().navigationTitle("事务材料").modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
    }
    @discardableResult private func attach(_ source:CaseDocument) -> Bool {
        do { try studio.attach(source,to:itemID);error = nil;return true } catch { self.error = error.localizedDescription;return false }
    }
}
struct CaseDocumentDetailPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    let itemID:UUID
    let document:CaseDocument
    @State private var deleting = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        List {
            Section { Text(document.title).font(.title2.bold());Text("加入时第 \(document.revision) 版 · \(document.origin.informationSource)").font(.caption).foregroundStyle(.secondary)
                if let current = studio.drafts.first(where:{$0.id == document.draftID}),current.revision != document.revision { Label("原草稿已有新版本，这里保留加入时的文字。",systemImage:"doc.badge.clock").font(.caption).foregroundStyle(.orange) }
                if document.visualID != nil { NavigationLink("查看本机保留原图") { SavedOriginalPage(studio:studio,visualID:document.visualID,text:document.text) } }
            }
            Section("材料全文") { Text(document.text).textSelection(.enabled) }
            Section {
                NavigationLink("对照并确认新的安排") { CaseUpdateReviewPage(workspace:workspace,studio:studio,api:workspace.caseUpdateAPI,itemID:itemID,incoming:document) }
                Button("从此事务移除材料",role:.destructive) { deleting = true }
                Text("已经用于确认安排或变更记录的来源会保留，以便以后核对。").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
        }.seePageCanvas().navigationTitle("材料来源").confirmationDialog("移除这份材料？原草稿保留。",isPresented:$deleting) { Button("移除",role:.destructive) { do { try studio.removeDocument(document.id,from:itemID);dismiss() } catch { self.error = error.localizedDescription } } }.modifier(WorkroomPrivacy())
    }
}
struct CaseFollowUpPage:View {
    @ObservedObject var studio:WorkroomService
    let itemID:UUID
    @State private var note = ""
    @State private var resume = true
    @State private var hasNextDate = false
    @State private var nextDate = Date().addingTimeInterval(86400)
    @State private var error:String?
    private var item:WorkroomCase? { studio.cases.first { $0.id == itemID } }
    var body:some View {
        Form {
            if let item {
                Section("当前跟进") {
                    Text(item.title).font(.title2.bold());Text(item.workflow.waitingFor.isEmpty ? item.stateTitle : "等待："+item.workflow.waitingFor)
                    if let since = item.workflow.waitingSince { LabeledContent("开始等待",value:since.formatted(date:.abbreviated,time:.shortened));Text("已等待 \(max(0,Int(Date().timeIntervalSince(since)/86400))) 天").font(.caption).foregroundStyle(.secondary) }
                    if let date = item.workflow.followUpAt { LabeledContent("计划跟进",value:date.formatted(date:.abbreviated,time:.shortened));if date <= Date() { Label("已到计划跟进时间",systemImage:"clock.badge.exclamationmark").foregroundStyle(.orange) } }
                }
                if item.isActive {
                    Section("记录回复或进展") {
                        TextField("例如：已收到回复，需要补交一份材料",text:$note,axis:.vertical).lineLimit(4...8)
                        Toggle("收到回复，恢复推进",isOn:$resume)
                        Toggle("记录下一次跟进日期",isOn:$hasNextDate)
                        if hasNextDate { DatePicker("下次跟进",selection:$nextDate) }
                        Text("跟进日期用于工作台提示；需要系统通知时，到事务编辑页单独设置提醒。").font(.caption).foregroundStyle(.secondary)
                        Button("保存进展") { do { if hasNextDate && nextDate <= Date() { throw DailyError.invalid };try studio.recordFollowUp(itemID,note:note,resume:resume,nextDate:hasNextDate ? nextDate : nil);note = "";error = nil } catch { self.error = error.localizedDescription } }.disabled(note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("跟进记录") { ForEach((item.workflow.followUps ?? []).reversed()) { row in VStack(alignment:.leading,spacing:8) { Text(row.note);Text(row.date,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary);if row.resumed { Label("本次已恢复推进",systemImage:"arrow.right.circle").font(.caption).foregroundStyle(Color.seeAccent) } } };if (item.workflow.followUps ?? []).isEmpty { Text("还没有记录回复或进展。 ").foregroundStyle(.secondary) } }
                if let error { Section { FeatureMessage(title:"进展未保存",detail:error) } }
            }
        }.seePageCanvas().navigationTitle("等待与跟进").modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
    }
}
struct CaseUpdateReviewPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @ObservedObject var api:IntelligenceService
    let itemID:UUID
    let incoming:CaseDocument
    @State private var baseline:WorkroomCase?
    @State private var fingerprint = ""
    @State private var candidates:[CaseChangeCandidate] = []
    @State private var selected = Set<String>()
    @State private var generator = "本机格式对照"
    @State private var materialCandidates:[CaseMaterialSuggestion] = []
    @State private var selectedMaterials = Set<String>()
    @State private var consent = false
    @State private var acknowledged = false
    @State private var saveLocally = false
    @State private var changeDue = false
    @State private var due = Date().addingTimeInterval(86400)
    @State private var changeReminder = false
    @State private var removeReminder = false
    @State private var reminder = Date().addingTimeInterval(3600)
    @State private var status:String?
    @State private var configuration = false
    @Environment(\.scenePhase) private var phase
    private var item:WorkroomCase? { studio.cases.first { $0.id == itemID } }
    private var previous:CaseDocument? { baseline?.documents.last { $0.id != incoming.id } }
    private var request:InsightRequest { CaseUpdateComparison.request(previous:previous,incoming:incoming) }
    private var summary:CaseReviewSummary { CaseReviewSummary.make(candidates:candidates,baseline:baseline,materialCount:materialCandidates.count) }
    private var fresh:Bool { item.flatMap { try? $0.reviewFingerprint() } == fingerprint }
    var body:some View {
        Form {
            Section {
                Label("补充通知，逐项核对",systemImage:"arrow.triangle.2.circlepath").font(.title2.bold())
                Text(incoming.title+" · 第 \(incoming.revision) 版").font(.subheadline)
                Text("选择要更新的时间、地点或费用。原有完成进度会保留；截止时间和提醒需要在下面单独确认。 ").font(.caption).foregroundStyle(.secondary)
                if !fresh { FeatureMessage(title:"事务已变化",detail:"刷新对照后再选择，避免覆盖刚才的修改。",actionTitle:"刷新对照",action:refresh) }
            }
            Section("本次待核对") {
                ForEach(ArrangementKind.allCases) { kind in LabeledContent(kind.title,value:"\(summary.changed.filter { $0.kind == kind }.count) 项") }
                LabeledContent("新增材料",value:"\(summary.materialCount) 项")
                if !summary.unchanged.isEmpty { DisclosureGroup("已确认且未变化 · \(summary.unchanged.count) 项") { ForEach(summary.unchanged) { candidate in VStack(alignment:.leading,spacing:5) { Label(candidate.kind.title+"："+candidate.value,systemImage:"checkmark.circle");Text("新通知依据："+candidate.quote).font(.caption).foregroundStyle(.secondary) } } } }
            }
            if let baseline {
                Section("新通知可能影响的清单项目") {
                    let affected = CaseUpdateComparison.affectedRows(item:baseline,changes:summary.changed)
                    ForEach(affected) { row in VStack(alignment:.leading,spacing:6) { Text(row.title).font(.headline);ForEach(row.reasons,id:\.self) { Text($0).font(.caption).foregroundStyle(.secondary) } } }
                    Text(affected.isEmpty ? "没有找到直接引用旧值的项目。请仍核对其他步骤；系统不会自动推断所有依赖或清除完成状态。" : "这里只标记直接引用旧值的项目。其他步骤可能也需调整，请对照通知后处理。完成状态不会自动清除。").font(.caption).foregroundStyle(.secondary)
                }
                Section { DisclosureGroup("已确认安排与旧材料候选") {
                    ForEach(ArrangementKind.allCases) { kind in
                        VStack(alignment:.leading,spacing:5) {
                            LabeledContent(kind.title,value:baseline.priorValue(for:kind,excluding:incoming.id))
                            Text(baseline.confirmedFacts.contains(where:{$0.kind == kind}) ? "此前已由你确认" : "来自旧材料的格式候选，尚未确认").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let oldDue = baseline.dueAt { LabeledContent("事务截止",value:oldDue.formatted(date:.abbreviated,time:.shortened)) }
                    if let oldReminder = baseline.reminderAt { LabeledContent("原提醒",value:oldReminder.formatted(date:.abbreviated,time:.shortened)) }
                } }
            }
            Section("本次采用哪些信息 · 每类最多一项") {
                if candidates.isEmpty { Text("没有提取到可采用字段。可展开全文直接核对，或主动使用 DeepSeek 辅助。").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(summary.changed) { candidate in
                    VStack(alignment:.leading,spacing:8) {
                        Button { toggle(candidate) } label: { Label(candidate.kind.title+"："+candidate.value,systemImage:selected.contains(candidate.id) ? "checkmark.circle.fill" : "circle").frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(selected.contains(candidate.id) ? Color.seeAccent : .primary).accessibilityIdentifier("change."+candidate.kind.rawValue+"."+candidate.value)
                        Text((baseline?.confirmedFacts.contains(where:{$0.kind == candidate.kind}) == true ? "此前已确认：" : "旧材料候选：")+(baseline?.priorValue(for:candidate.kind,excluding:incoming.id) ?? "尚未确认")).font(.caption).foregroundStyle(.secondary)
                        if candidate.kind == .time && candidate.date == nil { Text("相对或不完整时间，需要手动选择完整截止日期。").font(.caption).foregroundStyle(.orange) }
                        Text("新通知依据："+candidate.quote).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.vertical,5)
                }
                Text("格式提取不理解全部改约语义，也可能包含多个活动的信息，请核对引用再选择。 ").font(.caption).foregroundStyle(.secondary)
            }
            Section("新通知中的新增材料 · 原文明示") {
                ForEach(materialCandidates) { material in
                    VStack(alignment:.leading,spacing:8) {
                        Button { acknowledged = false;if selectedMaterials.contains(material.id) { selectedMaterials.remove(material.id) } else { selectedMaterials.insert(material.id) } } label: { Label(material.title,systemImage:selectedMaterials.contains(material.id) ? "checkmark.circle.fill" : "circle").frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("change.material."+material.title)
                        Text("依据："+material.quote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if materialCandidates.isEmpty { Text("没有提取到清单之外的明确新增材料。可以展开原文核对。 ").font(.caption).foregroundStyle(.secondary) }
                Text("选择后作为未准备项加入，原有项目的完成状态保留。需要取消的旧要求可在事务清单中核对处理。").font(.caption).foregroundStyle(.secondary)
            }
            scheduleSections
            Section("确认应用") {
                Toggle("将事务和此次变更保存在本机",isOn:$saveLocally).disabled(changeReminder && !removeReminder)
                Toggle("已核对来源、所选字段及时间选项",isOn:$acknowledged).accessibilityIdentifier("change.acknowledged")
                Button("应用已确认的变更",action:apply).buttonStyle(.borderedProminent).tint(SeePalette.button).accessibilityIdentifier("change.apply").disabled(!acknowledged || !fresh || api.isBusy || (selected.isEmpty && selectedMaterials.isEmpty && !changeDue && !changeReminder) || item?.isActive != true)
                if let status { Text(status).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("change.status") }
            }
            comparisonSections
        }.seePageCanvas().navigationTitle("通知变更对照").modifier(KeyboardCloseToolbar()).onAppear { if baseline == nil { refresh() } }
            .onReceive(api.$result) { result in
                guard let result,api.source?.turns == request.turns else { return }
                do { candidates = try CaseUpdateComparison.assistedCandidates(result,request:request,incoming:incoming);generator = String(("DeepSeek · "+result.model).prefix(80));selected = [];acknowledged = false;status = "建议已返回，请逐项选择采用内容。" } catch { status = error.localizedDescription }
            }
            .onChange(of:phase) { _,value in if value != .active { api.cancel();consent = false } }
            .onDisappear { api.cancel() }
            .sheet(isPresented:$configuration) { IntelligenceConfiguration(service:api,onConfigure:workspace.configureIntelligence) }
            .modifier(WorkroomPrivacy())
    }
    @ViewBuilder private var comparisonSections:some View {
        Section("对照原文") {
            if let previous { DisclosureGroup("之前："+previous.title) { Text(previous.text).textSelection(.enabled) } }
            DisclosureGroup("新材料："+incoming.title) { Text(incoming.text).textSelection(.enabled) }
            Button("重新进行本机格式对照",action:refresh).disabled(api.isBusy)
            DisclosureGroup("让 DeepSeek 辅助核对") {
                Text("只发送下方展示的片段：旧、新材料各最多前三段，共最多 3000 字。未包含的段落不参与此次模型对照。").font(.caption).foregroundStyle(.secondary)
                ForEach(request.turns) { turn in Text(turn.text).font(.caption).textSelection(.enabled) }
                Toggle("同意发送以上文字到 DeepSeek",isOn:$consent).disabled(api.isBusy)
                Button("发送并生成候选") { selected = [];acknowledged = false;api.organize(request) }.disabled(!consent || api.isBusy)
                Button("服务配置") { configuration = true }
                if api.isBusy { ProgressView("等待整理建议…");Button("停止请求，保留原文") { api.cancel() } }
                if let failure = api.failure { FeatureMessage(title:"暂时未取得建议",detail:failure,actionTitle:"重新发送已同意的片段",action:{api.organize(request)}).disabled(!consent || api.isBusy) }
                else { Text(api.status).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    @ViewBuilder private var scheduleSections:some View {
        Section("截止和提醒 · 单独确认") {
            Toggle("同时更改事务截止时间",isOn:$changeDue)
            if changeDue { DatePicker("新截止时间",selection:$due) }
            Toggle("同时更改或取消系统提醒",isOn:$changeReminder).disabled(!saveLocally || incoming.demonstration)
            if changeReminder { Toggle("取消原提醒",isOn:$removeReminder);if !removeReminder { DatePicker("新提醒时间",selection:$reminder) } }
            Text("不勾选时保留原设置。通知中的活动时间不会自动作为事务截止时间。设置系统提醒需要先选择本机保存。").font(.caption).foregroundStyle(.secondary)
        }.onChange(of:changeDue) { _,_ in acknowledged = false }.onChange(of:due) { _,_ in acknowledged = false }.onChange(of:changeReminder) { _,_ in acknowledged = false }.onChange(of:removeReminder) { _,_ in acknowledged = false }.onChange(of:reminder) { _,_ in acknowledged = false }
    }
    private func refresh() {
        api.cancel();consent = false;acknowledged = false;selected = [];selectedMaterials = [];changeDue = false;changeReminder = false
        guard let item else { status = "事务已移除。";return }
        baseline = item;fingerprint = (try? item.reviewFingerprint()) ?? "";saveLocally = studio.savedCaseIDs.contains(itemID)
        due = item.dueAt ?? Date().addingTimeInterval(86400);reminder = item.reminderAt.flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(3600)
        candidates = CaseUpdateComparison.localCandidates(source:incoming);materialCandidates = CaseUpdateComparison.materialSuggestions(source:incoming,existing:item.materials);generator = "本机格式对照";status = nil
    }
    private func toggle(_ candidate:CaseChangeCandidate) {
        acknowledged = false
        if selected.contains(candidate.id) { selected.remove(candidate.id) }
        else { for other in candidates where other.kind == candidate.kind { selected.remove(other.id) };selected.insert(candidate.id) }
    }
    private func apply() {
        do {
            try studio.applyUpdate(caseID:itemID,fingerprint:fingerprint,document:incoming,candidates:candidates.filter { selected.contains($0.id) },generator:selected.isEmpty && !selectedMaterials.isEmpty ? "本机材料核对" : generator,changeDue:changeDue,dueAt:due,changeReminder:changeReminder,reminderAt:removeReminder ? nil : reminder,saveLocally:saveLocally,confirmed:acknowledged,materials:materialCandidates.filter { selectedMaterials.contains($0.id) })
            refresh();status = "已按你的选择更新事务。原进度保留，可在事务详情查看变更记录。"
        } catch { status = error.localizedDescription }
    }
}
