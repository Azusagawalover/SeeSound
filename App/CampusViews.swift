import SwiftUI

struct CampusJourneyPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var studio: WorkroomService
    @State private var adding = false
    @State private var title = ""
    @State private var error: String?
    @State private var selected: UUID?
    @State private var deleting: CampusJourney?
    var body: some View {
        List {
            Section {
                SeeHero(title:"每次办事，都有来有回",detail:"把材料、问题和核对好的安排，放进同一段旅程。",artwork:.campus,eyebrow:"准备这次办理")
                Button("开始办事旅程",systemImage:"plus.circle.fill") { adding = true }.buttonStyle(SeePrimaryButtonStyle()).accessibilityIdentifier("journey.new")
                Button(studio.campus.journeys.contains(where:{$0.demonstration && $0.title == "补办学生证 · 示例"}) ? "继续补办学生证示例" : "体验补办学生证示例",systemImage:"play.circle") {
                    run {
                        if let existing = studio.campus.journeys.first(where:{$0.demonstration && $0.title == "补办学生证 · 示例"}) { selected = existing.id }
                        else { let item = CampusJourney.studentCardExample();try studio.putJourney(item);selected = item.id }
                    }
                }.buttonStyle(SeeSecondaryButtonStyle()).accessibilityIdentifier("journey.example")
            }.listRowSeparator(.hidden)
            CampusWorkspaceLinks(workspace:workspace,studio:studio)
            ForEach(studio.campus.journeys) { item in
                Button { selected = item.id } label: {
                    SeeJourneyRow(journey:item)
                }.buttonStyle(.plain).swipeActions { Button("删除",role:.destructive) { deleting = item } }
            }
            CampusWorkspaceToolLinks(workspace:workspace,studio:studio)
            Section {
                NavigationLink("恢复编辑与隐私偏好") { CampusRecoveryPage(studio:studio) }
                NavigationLink("从一份通知拆分事务") { NoticeSplitPage(studio:studio) }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.seePageCanvas().navigationTitle("校园办事").navigationDestination(item:$selected) { JourneyDetailPage(workspace:workspace,studio:studio,id:$0) }
            .sheet(isPresented:$adding) {
                NavigationStack { Form {
                    Section("这次要办什么") { TextField("例如：补办学生证",text:$title).accessibilityIdentifier("journey.title");Text("点击建立后，旅程文字会保存在本机。").font(.caption).foregroundStyle(.secondary) }
                    Button("建立旅程") { run { let journey = CampusJourney(title:title.trimmingCharacters(in:.whitespacesAndNewlines));try studio.putJourney(journey);selected = journey.id;title = "";adding = false } }.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("journey.create")
                    if let error { Text(error).foregroundStyle(.red) }
                }.seePageCanvas().navigationTitle("开始办事").toolbar { Button("取消") { adding = false } }.modifier(KeyboardCloseToolbar()) }
            }
            .confirmationDialog("删除这段旅程及其中的沟通摘录？关联事务和原草稿会保留。",isPresented:Binding(get:{deleting != nil},set:{if !$0 { deleting = nil }}),titleVisibility:.visible) { Button("删除旅程",role:.destructive) { if let item = deleting { run { try studio.removeJourney(item.id) } };deleting = nil } }
            .modifier(WorkroomPrivacy())
    }
    private func run(_ operation:()throws->Void) { do { try operation();error = nil } catch { self.error = error.localizedDescription } }
}

struct JourneyDetailPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var studio: WorkroomService
    let id: UUID
    @State private var question = ""
    @State private var showingFact = false
    @State private var editingFact: JourneyFact?
    @State private var showDeparture = false
    @State private var showOutcome = false
    @State private var showConversation = false
    @State private var showSources = false
    @State private var error: String?
    private var item: CampusJourney? { studio.campus.journeys.first { $0.id == id } }
    var body: some View {
        List {
            if let item {
                JourneyWorkspaceActions(workspace:workspace,studio:studio,journey:item)
                Section {
                    if item.demonstration { Label("模拟校园规定，仅用于演示",systemImage:"play.rectangle").font(.caption).foregroundStyle(.secondary) }
                    Picker("当前阶段",selection:Binding(get:{item.stage},set:{stage in change { $0.stage = stage } })) { ForEach(JourneyStage.allCases.filter{$0 != .paused}) { Text($0.title).tag($0) };if item.stage == .paused { Text("已暂停").tag(JourneyStage.paused) } }
                    Button(item.stage == .paused ? "继续这段旅程" : "暂停并保留进度",systemImage:item.stage == .paused ? "play.circle" : "pause.circle") {
                        change { journey in if journey.stage == .paused { journey.stage = journey.resumeStage ?? .prepare;journey.resumeStage = nil } else { journey.resumeStage = journey.stage;journey.stage = .paused } }
                    }.accessibilityIdentifier("journey.pause")
                }
                Section("1 · 准备与提问") {
                    ForEach(item.questions) { row in
                        VStack(alignment:.leading,spacing:6) {
                            Text(row.text).font(.headline)
                            NavigationLink("回答与沟通依据") { JourneyQuestionPage(studio:studio,journeyID:id,questionID:row.id) }
                            TextField("核对后填写答案",text:Binding(get:{row.answer},set:{answer in change { journey in if let index = journey.questions.firstIndex(where:{$0.id == row.id}) { journey.questions[index].answer = answer } } }),axis:.vertical).lineLimit(1...5)
                            Button("移除问题",role:.destructive) { change { $0.questions.removeAll { $0.id == row.id };$0.plan?.questionEvidence.removeAll{$0.questionID == row.id} } }.font(.caption)
                        }
                    }
                    TextField("还需要问什么？",text:$question,axis:.vertical).accessibilityIdentifier("journey.question")
                    Button("加入问题") { change { $0.questions.append(.init(text:question)) };if error == nil { question = "" } }.disabled(question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    Button("材料与原文 · \(item.documents.count) 份",systemImage:"doc.on.doc") { showSources = true }.accessibilityIdentifier("journey.sources")
                }
                Section("2 · 现场沟通") {
                    Button("打开面对面字幕",systemImage:"captions.bubble") { workspace.navigationRequest = .captions }
                    Button("保存沟通摘录 / 关联已存会话",systemImage:"text.bubble") { showConversation = true }.accessibilityIdentifier("journey.conversation")
                    ForEach(item.conversations.reversed()) { row in
                        DisclosureGroup(row.title) { Text(row.text).textSelection(.enabled);Text(row.date,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary);if let linked = row.conversationID,!workspace.conversations.items.contains(where:{$0.id == linked}) { Text("原会话当前不可用，仍保留加入时的摘录。").font(.caption).foregroundStyle(.secondary) } }
                    }
                }
                Section("3 · 一起确认安排") {
                    Text("先自己核对，再把大字卡给对方看。“对方已确认”是你的记录，不代表远程签名。").font(.caption).foregroundStyle(.secondary)
                    ForEach(item.facts) { fact in
                        NavigationLink { JourneyConfirmationPage(studio:studio,journeyID:id,factID:fact.id) } label: {
                            VStack(alignment:.leading,spacing:7) {
                                Text(fact.kind.title).font(.caption).foregroundStyle(Color.seeAccent)
                                Text(fact.value).font(.headline).foregroundStyle(.primary)
                                Text(fact.superseded ? "来源或关联事务已有变化，需要重新核对" : fact.counterpartRecordedAt != nil ? "用户记录对方已确认" : fact.isConfirmed ? "我已核对，待对方确认" : "尚未核对").font(.caption).foregroundStyle(fact.superseded ? .orange : .secondary)
                            }.padding(.vertical,5)
                        }
                        Button("修改这项"+fact.kind.title) { editingFact = fact }.font(.caption)
                    }
                    Button("添加待核对信息",systemImage:"plus.circle") { showingFact = true }.disabled(item.documents.isEmpty).accessibilityIdentifier("journey.addFact")
                }
                Section("4 · 关联事务与变更") {
                    let changed = item.changedCases(studio.cases)
                    if !changed.isEmpty {
                        ForEach(Array(changed.enumerated()),id:\.offset) { Text($0.element).font(.subheadline).foregroundStyle(.orange) }
                        Button("我已对照最新关联事务") { do { try studio.acknowledgeJourneyCases(id);error = nil } catch { self.error = error.localizedDescription } }
                        Text("这里只记录你已查看事务变化，不会重新确认失效的信息卡。").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(item.caseIDs,id:\.self) { caseID in
                        if let project = studio.cases.first(where:{$0.id == caseID}) {
                            Button { workspace.scheduledDestination = .init(kind:.project,recordID:caseID) } label: { Label(project.title,systemImage:project.isCompleted ? "checkmark.circle" : "checklist") }
                        } else { Label("关联事务当前不可用",systemImage:"exclamationmark.circle").foregroundStyle(.secondary) }
                    }
                    Menu("关联已有事务") { ForEach(studio.cases.filter { $0.demonstration == item.demonstration && !item.caseIDs.contains($0.id) }) { project in Button(project.title+(studio.savedCaseIDs.contains(project.id) ? "" : " · 仅本次运行")) { do { try studio.linkCaseToJourney(project.id,journeyID:id);error = nil } catch { self.error = error.localizedDescription } } } }
                    if !item.caseIDs.isEmpty {
                        Menu("解除事务关联") {
                            ForEach(item.caseIDs,id:\.self) { caseID in
                                Button(studio.cases.first(where:{$0.id == caseID})?.title ?? "不可用的关联") {
                                    change { journey in journey.caseIDs.removeAll{$0 == caseID};journey.caseVersions?.removeValue(forKey:caseID.uuidString) }
                                }
                            }
                        }
                    }
                    NavigationLink("将当前通知拆成多件事务") { NoticeSplitPage(studio:studio,journeyID:id) }
                }
                Section("5 · 出发与办理结果") {
                    NavigationLink("导出这段旅程的加密接力文件") { LibraryBackupPage(workspace:workspace,journeyID:id) }
                    Button { showDeparture = true } label: {
                        Label("打开随身办事单",systemImage:"rectangle.portrait.on.rectangle.portrait").frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.accessibilityIdentifier("journey.departure")
                    Button { showOutcome = true } label: {
                        Label("记录办理结果与后续安排",systemImage:"square.and.pencil").frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.accessibilityIdentifier("journey.outcome")
                    ForEach(item.outcomes.reversed()) { outcome in VStack(alignment:.leading,spacing:6) { Text(outcome.note);if !outcome.nextAction.isEmpty { Text("后续："+outcome.nextAction).font(.subheadline) };Text(outcome.date,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) } }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            } else { ContentUnavailableView("旅程已移除",systemImage:"doc.badge.clock") }
        }.seePageCanvas().navigationTitle("办事旅程").modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
            .onAppear{try? studio.visitJourney(id)}
            .sheet(isPresented:$showSources) { NavigationStack { JourneySourcesPage(workspace:workspace,studio:studio,id:id).toolbar { Button("关闭") { showSources = false } } } }
            .sheet(isPresented:$showingFact) { JourneyFactEditor(studio:studio,journeyID:id) }
            .sheet(item:$editingFact) { JourneyFactEditor(studio:studio,journeyID:id,initial:$0) }
            .sheet(isPresented:$showConversation) { JourneyConversationEditor(workspace:workspace,studio:studio,id:id) }
            .sheet(isPresented:$showOutcome) { JourneyOutcomePage(studio:studio,id:id) }
            .sheet(isPresented:$showDeparture) { NavigationStack { JourneyDeparturePage(studio:studio,id:id).toolbar { Button("关闭") { showDeparture = false } } } }
    }
    private func change(_ operation:(inout CampusJourney)throws->Void) { do { try studio.changeJourney(id,operation);error = nil } catch { self.error = error.localizedDescription } }
}

struct JourneySourcesPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var studio: WorkroomService
    let id: UUID
    @State private var error: String?
    @State private var pendingSource:CaseDocument?
    @Environment(\.dismiss) private var dismiss
    private var item: CampusJourney? { studio.campus.journeys.first { $0.id == id } }
    private var drafts:[WorkroomDraft] {
        var rows = studio.drafts
        if (try? studio.active.validate()) != nil,!rows.contains(where:{$0.id == studio.active.id && $0.revision == studio.active.revision}) { rows.insert(studio.active,at:0) }
        return rows.filter { $0.demonstration == item?.demonstration }
    }
    private var caseDocuments:[CaseDocument] {
        var keys = Set<String>()
        return studio.cases.filter{item?.caseIDs.contains($0.id) == true}.flatMap(\.documents).filter{keys.insert($0.key).inserted}
    }
    var body: some View {
        List {
            if let item {
                Section("已加入来源 · 加入时的版本") {
                    NavigationLink("版本时间线与不同说法") { JourneyMaterialHistoryPage(studio:studio,id:id) }
                    ForEach(item.documents) { source in NavigationLink(source.title+" · 第 \(source.revision) 版") { EvidenceQuotePage(studio:studio,source:source,quote:String(source.text.prefix(100))) } }
                    Text("加入同一草稿的新版本后，旧版信息的双方确认会失效；旧摘录保留供对照。其他材料不会被覆盖。").font(.caption).foregroundStyle(.secondary)
                }
                if !caseDocuments.isEmpty { Section("从关联事务加入来源") { ForEach(caseDocuments) { source in
                    Button(source.title+" 第 \(source.revision) 版") { pendingSource = source }.disabled(item.documents.contains(where:{$0.key == source.key}))
                } } }
                Section("选择已导入的文字") {
                    ForEach(drafts) { draft in
                        let exists = item.documents.contains { $0.key == CaseDocument(draft:draft).key }
                        Button(draft.title+" · 第 \(draft.revision) 版"+(exists ? " · 已加入" : "")) { pendingSource = CaseDocument(draft:draft) }.disabled(exists)
                    }
                    Button("去文字工作室导入") { workspace.navigationRequest = .workroom;dismiss() }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("旅程材料").sheet(item:$pendingSource) { source in if let item { JourneySourcePreview(studio:studio,journey:item,source:source) } }.onAppear{try? studio.rememberJourney(id,section:.materials)}.modifier(WorkroomPrivacy())
    }
}

struct JourneyFactEditor: View {
    @ObservedObject var studio: WorkroomService
    let journeyID: UUID
    var initial: JourneyFact? = nil
    @State private var kind: JourneyFactKind = .time
    @State private var value = ""
    @State private var quote = ""
    @State private var sourceID: UUID?
    @State private var baseline: String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var journey: CampusJourney? { studio.campus.journeys.first { $0.id == journeyID } }
    var body: some View {
        NavigationStack { Form {
            if let journey {
                Section("待核对信息") { Picker("类别",selection:$kind) { ForEach(JourneyFactKind.allCases) { Text($0.title).tag($0) } };TextField("信息内容",text:$value,axis:.vertical).accessibilityIdentifier("journey.factValue") }
                Section("来自哪段原文") {
                    Picker("来源材料",selection:$sourceID) { Text("请选择").tag(nil as UUID?);ForEach(journey.documents) { Text($0.title+" 第 \($0.revision) 版").tag(Optional($0.id)) } }
                    if let source = journey.documents.first(where:{$0.id == sourceID}) {
                        DisclosureGroup("原文与格式候选") {
                            Text(source.text).textSelection(.enabled)
                            ForEach(CaseUpdateComparison.localCandidates(source:source)) { candidate in Button(candidate.kind.title+"："+candidate.value) { value = candidate.value;quote = candidate.quote;kind = candidate.kind == .time ? .time : candidate.kind == .place ? .place : .fee } }
                        }
                    }
                    TextField("粘贴原文中的依据（必须与原文一致）",text:$quote,axis:.vertical).lineLimit(3...8).accessibilityIdentifier("journey.factQuote")
                    Text("修改后将清除双方确认，需要重新核对。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("保存待核对信息") { save() }.accessibilityIdentifier("journey.factSave")
            }
        }.seePageCanvas().navigationTitle(initial == nil ? "添加信息" : "修改信息").toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } } }.modifier(KeyboardCloseToolbar()).onAppear {
            guard baseline == nil else { return };baseline = try? journey?.fingerprint()
            if let initial { kind = initial.kind;value = initial.value;quote = initial.quote;sourceID = initial.sourceID } else { sourceID = journey?.documents.last?.id }
        }.modifier(WorkroomPrivacy()) }
    }
    private func save() {
        do {
            guard var journey,try journey.fingerprint() == baseline,let sourceID else { throw CampusError.stale }
            if let initial,let index = journey.facts.firstIndex(where:{$0.id == initial.id}) {
                if kind == initial.kind,value == initial.value,quote == initial.quote,sourceID == initial.sourceID { dismiss();return }
                journey.facts[index].kind = kind;journey.facts[index].sourceID = sourceID;journey.facts[index].superseded = false;journey.facts[index].revise(value:value,quote:quote)
            } else { journey.facts.append(.init(kind:kind,value:value,sourceID:sourceID,quote:quote)) }
            try studio.putJourney(journey,baseline:baseline);dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct JourneyConfirmationPage: View {
    @ObservedObject var studio: WorkroomService
    let journeyID: UUID
    let factID: UUID
    @State private var error: String?
    @State private var confirmCounterpart = false
    @State private var pendingRevision:Int?
    private var journey: CampusJourney? { studio.campus.journeys.first { $0.id == journeyID } }
    private var fact: JourneyFact? { journey?.facts.first { $0.id == factID } }
    private var pendingCaseReview:Bool { !(journey?.changedCases(studio.cases) ?? []).isEmpty }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:24) {
            if let fact {
                HStack { VStack(alignment:.leading,spacing:7) { Text("一起确认这条信息").font(.system(.title2,design:.rounded,weight:.bold)).foregroundStyle(SeePalette.ink);Text("看清内容，再留下核对记录。").font(.subheadline).foregroundStyle(.secondary) };Spacer();SeeArtworkView(artwork:.clipboard,size:60) }
                SeeFactValue(fact:fact)
                if pendingCaseReview { FeatureMessage(title:"关联事务有变化",detail:"先返回旅程，对照最新事务并确认已查看，再核对本张信息卡。") }
                if fact.superseded { FeatureMessage(title:"依据已更新",detail:"返回旅程，参照最新材料或关联事务修改这项信息后，再让双方确认。") }
                if let source = journey?.documents.first(where:{$0.id == fact.sourceID}) { NavigationLink("回到原文与图片位置") { EvidenceQuotePage(studio:studio,source:source,quote:fact.quote) } }
                Label(fact.isConfirmed ? "我已核对" : "等待我核对",systemImage:fact.isConfirmed ? "checkmark.circle.fill" : "circle").font(.headline)
                if let recorded = fact.counterpartRecordedAt { Label("用户记录对方已确认",systemImage:"person.crop.circle.badge.checkmark").font(.headline).foregroundStyle(Color.seeAccent);Text(recorded,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                Button("我已核对这项信息") { confirm(counterpart:false,revision:fact.revision) }.buttonStyle(SeePrimaryButtonStyle()).disabled(fact.superseded || fact.isConfirmed || pendingCaseReview).accessibilityIdentifier("journey.confirmSelf")
                Button(fact.counterpartRecordedAt == nil ? "记录：对方已看过并确认" : "用户已记录对方确认") { pendingRevision = fact.revision;confirmCounterpart = true }.buttonStyle(SeeSecondaryButtonStyle()).disabled(!fact.isConfirmed || fact.counterpartRecordedAt != nil || pendingCaseReview).accessibilityIdentifier("journey.confirmPartner")
                Text("请把卡片给对方看，并询问内容是否正确。此记录由你填写；文字改变后，两项确认都会清除。").font(.subheadline).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
        }.padding(20).frame(maxWidth:900).frame(maxWidth:.infinity) }.background(SeePalette.canvas).seePageCanvas().navigationTitle("信息确认").modifier(WorkroomPrivacy())
            .onAppear{try? studio.rememberJourney(journeyID,section:.confirmation,targetID:factID)}
            .confirmationDialog("你已当面询问，且对方确认当前这版信息正确？",isPresented:$confirmCounterpart,titleVisibility:.visible) { Button("是，记录本次确认") { if let pendingRevision { confirm(counterpart:true,revision:pendingRevision) } }.accessibilityIdentifier("journey.confirmPartner.accept") }
    }
    private func confirm(counterpart:Bool,revision:Int) { do { try studio.confirmJourneyFact(journeyID,factID:factID,revision:revision,counterpart:counterpart);error = nil } catch { self.error = error.localizedDescription } }
}

struct EvidenceQuotePage: View {
    @ObservedObject var studio: WorkroomService
    let source: CaseDocument
    let quote: String
    var journeyID:UUID?
    @State private var evidence: WorkroomVisualEvidence?
    private var location: EvidenceLocation? { try? EvidenceLocation.locate(quote:quote,in:source) }
    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section { Text(source.title).font(.title2.bold());Text("加入时第 \(source.revision) 版").font(.caption).foregroundStyle(.secondary);Text(quote).font(.headline).foregroundStyle(Color.seeAccent)
                    if let evidence { NavigationLink("查看原图中对应的识字区域") { OriginalTextComparePage(evidence:evidence,checkedText:source.text,initialQuote:quote) } }
                    else { Text("原图未保留或不在这台设备上；下方原文摘录仍可核对。").font(.caption).foregroundStyle(.secondary) }
                    if let location { Button("跳到第 \(location.firstLine+1) 行") { proxy.scrollTo(location.firstLine,anchor:.center) }.accessibilityIdentifier("evidence.jump") }
                }
                Section("原文位置") {
                    ForEach(Array(source.text.components(separatedBy:.newlines).enumerated()),id:\.offset) { row in
                        let highlighted = row.offset >= (location?.firstLine ?? -10) && row.offset <= (location?.firstLine ?? -10)+quote.filter{$0 == "\n"}.count
                        VStack(alignment:.leading,spacing:6) { Text("第 \(row.offset+1) 行").font(.caption).foregroundStyle(.secondary);Text(row.element.isEmpty ? " " : row.element).textSelection(.enabled) }.padding(.vertical,5).listRowBackground(highlighted ? Color.seeAccent.opacity(0.12) : SeePalette.surface).id(row.offset)
                    }
                }
            }.onAppear { if let line = location?.firstLine { proxy.scrollTo(line,anchor:.center) } }
        }.seePageCanvas().navigationTitle("核对依据").task { evidence = try? studio.visual(for:source.visualID);if let journeyID { try? studio.rememberJourney(journeyID,section:.materials,targetID:source.id) } }.modifier(WorkroomPrivacy())
    }
}

struct JourneyConversationEditor: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var studio: WorkroomService
    let id: UUID
    @State private var title = "现场沟通摘录"
    @State private var text = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var journey: CampusJourney? { studio.campus.journeys.first { $0.id == id } }
    var body: some View {
        NavigationStack { Form {
            Section("手动留下需要的文字") { TextField("摘录标题",text:$title);TextEditor(text:$text).frame(minHeight:180).accessibilityLabel("沟通摘录");Text("\(text.count)/6000 字。只有点击保存才加入旅程，不保存录音。").font(.caption).foregroundStyle(.secondary);Button("保存这段沟通") { save(.init(title:title,text:text)) }.disabled(text.isEmpty) }
            Section("从已保存会话复制文字") { ForEach(workspace.conversations.items.filter { $0.containsDemonstration == journey?.demonstration }) { conversation in Button(conversation.title) { save(.init(title:conversation.title,text:String(conversation.exportText.prefix(6000)),conversationID:conversation.id)) } } }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("沟通记录").toolbar { Button("关闭") { dismiss() } }.modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy()) }
    }
    private func save(_ row:JourneyConversation) { do { try studio.changeJourney(id) { $0.conversations.append(row) };dismiss() } catch { self.error = error.localizedDescription } }
}

struct NoticeSplitPage: View {
    @ObservedObject var studio: WorkroomService
    var journeyID: UUID? = nil
    @State private var preview: NoticeSplitPreview?
    @State private var selected = Set<UUID>()
    @State private var confirmed = false
    @State private var status: String?
    var body: some View {
        Form {
            Section { Label("一份通知，分别处理",systemImage:"square.split.2x2").font(.title2.bold());Text("先在文字工作室打开通知；以空行分隔各个事项。这里只按明确段落拆分，不猜测相对日期，也不会自动开启提醒。只预览前10个符合长度限制的段落。").font(.subheadline).foregroundStyle(.secondary);Button("预览当前材料的拆分") { refresh() }.accessibilityIdentifier("split.preview") }
            if let preview {
                Section(preview.source.title+" · 第 \(preview.source.revision) 版") {
                    ForEach(preview.parts) { part in
                        VStack(alignment:.leading,spacing:8) { Toggle("选择这件事务",isOn:Binding(get:{selected.contains(part.id)},set:{if $0 { selected.insert(part.id) } else { selected.remove(part.id) };confirmed = false }));TextField("事务标题",text:Binding(get:{part.title},set:{value in updatePart(part.id) { $0.title = value } }));Text(part.quote).font(.caption).foregroundStyle(.secondary);Toggle("为这件事务设置截止时间",isOn:Binding(get:{part.dueAt != nil},set:{enabled in updatePart(part.id) { $0.dueAt = enabled ? Date().addingTimeInterval(86400) : nil } }))
                            if part.dueAt != nil { DatePicker("核对后的截止时间",selection:Binding(get:{part.dueAt ?? Date()},set:{date in updatePart(part.id) { $0.dueAt = date } }));Text("候选日期来自本段明确日期；请确认它确实是截止时间。不会自动开启提醒。").font(.caption).foregroundStyle(.secondary) } }
                    }
                    if preview.parts.isEmpty { Text("没有找到可拆分的段落，请回到原文，在独立事项之间加入空行。") }
                }
                Section { Toggle("我已检查所选标题、原文和日期，同意保存到本机",isOn:$confirmed).accessibilityIdentifier("split.consent");Button("建立选中的 \(selected.count) 件事务") { create() }.disabled(!confirmed || selected.isEmpty).accessibilityIdentifier("split.create") }
            }
            if let status { Text(status).foregroundStyle(.secondary) }
        }.seePageCanvas().navigationTitle("拆分通知").modifier(WorkroomPrivacy())
    }
    private func updatePart(_ id:UUID,_ change:(inout NoticeCasePart)->Void) { guard let index = preview?.parts.firstIndex(where:{$0.id == id}) else { return };change(&preview!.parts[index]);confirmed = false }
    private func refresh() { do { preview = try NoticeSplitPreview.make(studio.active);selected = [];confirmed = false;status = nil } catch { status = error.localizedDescription } }
    private func create() { do { guard let preview else { return };let ids = try studio.createSplitCases(preview,selected:selected,confirmed:confirmed,journeyID:journeyID);self.preview = nil;selected = [];confirmed = false;status = "已保存 \(ids.count) 件独立事务，原文依据已保留。" } catch { status = error.localizedDescription } }
}

struct JourneyDeparturePage: View {
    @ObservedObject var studio: WorkroomService
    let id: UUID
    private var journey: CampusJourney? { studio.campus.journeys.first { $0.id == id } }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            if let journey {
                Label("出发前，再核对一次",systemImage:"bag").font(.title2.bold())
                Text(journey.departure(cases:studio.cases)).font(.title3).textSelection(.enabled).modifier(WorkspaceSurface())
                if !journey.changedCases(studio.cases).isEmpty || journey.facts.contains(where:{!$0.isConfirmed}) || journey.questions.contains(where:{$0.answer.isEmpty}) { FeatureMessage(title:"仍有待确认内容",detail:"办事单已列出未解决问题；请向窗口核对后再依赖其中的时间、费用或材料。") }
                NavigationLink("预览、隐藏隐私并分享") { SharePreviewPage(original:journey.departure(cases:studio.cases)) }
                Text("办事单是当前版本的汇总，修改原信息后请重新打开。离线可查看；系统通知、交通或预约状态不会因此获得保证。").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth:900).frame(maxWidth:.infinity) }.background(SeePalette.canvas).seePageCanvas().navigationTitle("随身办事单").modifier(WorkroomPrivacy())
    }
}

struct JourneyOutcomePage: View {
    @ObservedObject var studio: WorkroomService
    let id: UUID
    @State private var note = ""
    @State private var action = ""
    @State private var finish = false
    @State private var notify = false
    @State private var date = Date().addingTimeInterval(86400)
    @State private var fingerprint: String?
    @State private var error: String?
    @State private var discard = false
    @EnvironmentObject private var agenda:AppointmentReminderService
    @Environment(\.dismiss) private var dismiss
    private var journey: CampusJourney? { studio.campus.journeys.first { $0.id == id } }
    private var hasChanges: Bool { !note.isEmpty || !action.isEmpty || finish || notify }
    var body: some View {
        NavigationStack { Form {
            Section("办理结果") {
                Text("选一句起头，再补充具体情况。").font(.caption).foregroundStyle(.secondary)
                ViewThatFits(in:.horizontal) {
                    HStack { resultTemplates }
                    VStack(alignment:.leading) { resultTemplates }
                }
                TextField("办成了什么，还缺什么？",text:$note,axis:.vertical).lineLimit(4...8).accessibilityIdentifier("journey.result")
                Text("\(note.count) / 500 字").font(.caption).foregroundStyle(.secondary)
                TextField("后续要做的一件事（可选，最多100字）",text:$action,axis:.vertical).accessibilityIdentifier("journey.nextAction")
                Toggle("这次已办完，结束这段旅程",isOn:$finish)
                Text(finish ? "保存后结束本次旅程，已建立的后续事项仍可单独处理。" : "保存后保留为待跟进，之后可以继续补充。").font(.caption).foregroundStyle(.secondary)
            }
            Section("后续提醒 · 主动开启") { Toggle("为后续事项启用提醒",isOn:$notify).disabled(journey?.demonstration == true || action.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty);if notify { DatePicker("提醒时间",selection:$date,in:Date()...);Label(agenda.permission,systemImage:agenda.authorizationState == .allowed ? "bell.badge" : "bell.slash").font(.caption)
                if agenda.authorizationState == .notDetermined { Button("允许系统通知") { Task { await agenda.requestPermission() } } }
                else if agenda.authorizationState == .denied { Button("打开系统通知设置") { if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } }
            };Text("填写后续事项时，保存后会建立一件关联事务；只有这里开启提醒才安排系统通知。是否可通知取决于系统授权。").font(.caption).foregroundStyle(.secondary) }
            Button("保存结果") { do { guard let fingerprint else { throw CampusError.stale };try studio.recordJourneyOutcome(id,fingerprint:fingerprint,note:note.trimmingCharacters(in:.whitespacesAndNewlines),nextAction:action.trimmingCharacters(in:.whitespacesAndNewlines),reminder:notify ? date : nil,finish:finish);dismiss() } catch { self.error = error.localizedDescription } }
                .disabled(fingerprint == nil || note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || note.count > 500 || action.count > 100).accessibilityIdentifier("journey.resultSave")
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("办理后").toolbar { Button("取消") { if hasChanges { discard = true } else { dismiss() } } }.onAppear { if fingerprint == nil { fingerprint = try? journey?.fingerprint() } }
            .onChange(of:action) { _,value in if value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { notify = false } }
            .interactiveDismissDisabled(hasChanges)
            .confirmationDialog("放弃尚未保存的办理结果？",isPresented:$discard,titleVisibility:.visible) { Button("放弃修改",role:.destructive) { dismiss() } }
            .modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy()) }
    }
    @ViewBuilder private var resultTemplates:some View {
        ForEach(["本次已完成：","还需要补充的材料：","正在等待的回复："],id:\.self) { text in
            Button(text == "本次已完成：" ? "办好了" : text == "还需要补充的材料：" ? "需要补材料" : "等待回复") {
                if !note.contains(text) { note += (note.isEmpty ? "" : "\n")+text }
            }.buttonStyle(.bordered).font(.subheadline).frame(minHeight:44)
        }
    }
}

struct SharePreviewPage: View {
    let original: String
    @State private var terms = ""
    @State private var identifiers = true
    @State private var reviewed = false
    private var text:String { ShareRedaction.apply(original,terms:terms.components(separatedBy:.newlines),identifiers:identifiers) }
    var body: some View {
        Form {
            Section("隐藏不想分享的内容") { Toggle("隐藏手机号、邮箱与身份证号",isOn:$identifiers);TextField("逐行填写姓名、学号或其他要隐藏的文字",text:$terms,axis:.vertical).lineLimit(3...8);Text("自动识别无法覆盖所有隐私，请逐行检查预览。").font(.caption).foregroundStyle(.secondary) }
            Section("将要分享的全部文字") { Text(text).textSelection(.enabled).accessibilityIdentifier("share.preview") }
            Section { Toggle("我已检查这份预览",isOn:$reviewed);if reviewed { ShareLink("分享这份文字",item:text).accessibilityIdentifier("share.export") } }
        }.seePageCanvas().navigationTitle("分享预览").onChange(of:terms) { _,_ in reviewed = false }.onChange(of:identifiers) { _,_ in reviewed = false }.modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
    }
}

struct CampusRecoveryPage: View {
    @ObservedObject var studio: WorkroomService
    @State private var error: String?
    @State private var selected: CaseEditRecovery?
    var body: some View {
        List {
            Section("意外退出后继续编辑") {
                Toggle("在本机保护未保存的事务修改",isOn:Binding(get:{studio.campus.recoverEdits},set:{enabled in run { try studio.updateEnhancements { var ledger = $0.campus ?? .init();ledger.recoverEdits = enabled;if !enabled { ledger.recoveries = [] };$0.campus = ledger } } })).accessibilityIdentifier("recovery.enable")
                Text("默认关闭。开启后，仅在内容有效时保存恢复副本；重新打开只展示预览，由你决定恢复。关闭会删除恢复副本。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(studio.campus.recoveries) { row in Button { selected = row } label: { VStack(alignment:.leading,spacing:6) { Text(row.item.title);Text(row.date,format:.dateTime.month().day().hour().minute()).font(.caption) } }.swipeActions { Button("删除恢复副本",role:.destructive) { run { try studio.clearRecovery(row.id) } } } }
            if studio.campus.recoveries.isEmpty { Text("没有待恢复修改").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("恢复编辑与隐私").sheet(item:$selected) { row in NavigationStack { Form {
            Section("恢复预览") { Text(row.item.title).font(.title2.bold());Text(row.item.note);Text(row.saveLocally ? "恢复后保存本机事务" : "恢复后仅本次运行").font(.caption);Text("恢复前会检查原事务是否被修改；不同版本会拒绝覆盖。").font(.caption).foregroundStyle(.secondary) }
            Button("确认恢复这次修改") { run { try studio.restoreRecovery(row);selected = nil } }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("恢复前核对").toolbar { Button("关闭") { selected = nil } } } }.modifier(WorkroomPrivacy())
    }
    private func run(_ operation:()throws->Void) { do { try operation();error = nil } catch { self.error = error.localizedDescription } }
}
