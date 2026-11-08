import SwiftUI

struct CampusHero:View {
    let title:String
    let detail:String
    var symbol = "point.topleft.down.to.point.bottomright.curvepath"
    var body:some View {
        SeeHero(title:title,detail:detail,artwork:SeeArtwork.forSymbol(symbol))
    }
}
struct CampusWorkspaceLinks:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    var body:some View {
        if let id = studio.campus.lastJourneyID,let journey = studio.campus.journeys.first(where:{$0.id == id}) {
            Section("继续处理") {
                if let bookmark = studio.campusWorkspace.bookmarks.first(where:{$0.id == id}) {
                    NavigationLink("回到“"+journey.title+"” · "+bookmark.section.title) { JourneyResumeDestination(workspace:workspace,studio:studio,bookmark:bookmark) }.accessibilityIdentifier("campus.resume")
                } else { NavigationLink(journey.title) { JourneyDetailPage(workspace:workspace,studio:studio,id:id) } }
            }
        }
        if !studio.campusWorkspace.favoriteJourneyIDs.isEmpty {
            Section("收藏的旅程") {
                ForEach(studio.campus.journeys.filter{studio.campusWorkspace.favoriteJourneyIDs.contains($0.id)}) { item in
                    NavigationLink { JourneyDetailPage(workspace:workspace,studio:studio,id:item.id) } label: { Label(item.title,systemImage:"star.fill") }
                }
            }
        }
        Section("办事工作台") {
            NavigationLink { CampusScenarioPage(workspace:workspace,studio:studio) } label: { SeeToolRow(title:"按场景开始",detail:"选一件事，准备要问的问题",artwork:.compass) }.accessibilityIdentifier("campus.scenarios")
            NavigationLink { CampusChangeCenter(workspace:workspace,studio:studio) } label: { SeeToolRow(title:"变更处理 · \(CampusOverview.attention(studio.campus.journeys,cases:studio.cases).count)",detail:"查看材料变化与待重新核对的安排",artwork:.folder) }.accessibilityIdentifier("campus.changes")
            NavigationLink { CampusSchedulePage(workspace:workspace,studio:studio) } label: { SeeToolRow(title:"今天、本周与待回复",detail:"按自己的计划继续办理",artwork:.calendar) }.accessibilityIdentifier("campus.schedule")
            NavigationLink { CampusQuestionsPage(workspace:workspace,studio:studio) } label: { SeeToolRow(title:"集中查看未解决问题",detail:"把还没问清楚的事留在这里",artwork:.books) }.accessibilityIdentifier("campus.questions")
        }
    }
}
struct CampusWorkspaceToolLinks:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    var body:some View {
        Section("材料、搜索与演示") {
            NavigationLink { CampusDeskPage(workspace:workspace,studio:studio) } label: { SeeToolRow(title:"材料与核对工作台",detail:"原文和相关信息放在一起看",artwork:.clipboard) }.accessibilityIdentifier("campus.desk")
            NavigationLink { GlobalSearchPage(workspace:workspace,studio:studio,cards:workspace.information,routines:workspace.routines,conversations:workspace.conversations) } label: { SeeToolRow(title:"搜索旅程里的内容",detail:"查找问题、材料与确认卡",artwork:.search) }.accessibilityIdentifier("campus.search")
            NavigationLink { CampusEvaluationPage(speech:workspace.offlineSpeech) } label: { SeeToolRow(title:"中文模型评测与错误复查",detail:"查看实际输出，留下人工复查",artwork:.memo) }.accessibilityIdentifier("campus.evaluation")
            NavigationLink { CampusPresentationPage(workspace:workspace,studio:studio) } label: { SeeToolRow(title:"三分钟作品演示",detail:"用一段模拟旅程体验完整流程",artwork:.campus) }.accessibilityIdentifier("campus.presentation")
        }
    }
}
struct CampusScenarioPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @State private var scenario:CampusScenario?
    @State private var selected:UUID?
    @State private var error:String?
    private var scenarios:[CampusScenario] {
        CampusScenario.allCases.sorted { a,b in
            let x = studio.campusWorkspace.favoriteScenarios.contains(a),y = studio.campusWorkspace.favoriteScenarios.contains(b)
            return x != y ? x : a.rawValue < b.rawValue
        }
    }
    var body:some View {
        List {
            Section { CampusHero(title:"先选这次要办的事",detail:"场景只提供提问清单。具体要求来自你的材料与现场核对，不预填学校规定。",symbol:"sparkles") }
            ForEach(scenarios) { item in
                HStack(spacing:16) {
                    Button { scenario = item } label: {
                        SeeToolRow(title:item.title,detail:item.questions.first ?? "",artwork:item == .certificate ? .memo : item == .clinic ? .shield : item == .counter ? .speech : .books)
                    }.buttonStyle(.plain).accessibilityIdentifier("scenario."+item.rawValue)
                    Button { toggle(item) } label: { Image(systemName:studio.campusWorkspace.favoriteScenarios.contains(item) ? "star.fill" : "star").frame(width:44,height:44) }.buttonStyle(.borderless).accessibilityLabel("收藏场景："+item.title)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("场景开始").sheet(item:$scenario) { item in CampusJourneyWizard(studio:studio,scenario:item) { selected = $0;scenario = nil } }
            .navigationDestination(item:$selected) { JourneyDetailPage(workspace:workspace,studio:studio,id:$0) }.modifier(WorkroomPrivacy())
    }
    private func toggle(_ item:CampusScenario) {
        do { try studio.updateCampusWorkspace { state in if state.favoriteScenarios.contains(item) { state.favoriteScenarios.removeAll{$0 == item} } else { state.favoriteScenarios.append(item) } };error = nil } catch { self.error = error.localizedDescription }
    }
}
struct CampusJourneyWizard:View {
    @ObservedObject var studio:WorkroomService
    let scenario:CampusScenario
    let onCreated:(UUID)->Void
    @State private var step = 0
    @State private var title = ""
    @State private var questions:[String] = []
    @State private var hasDate = false
    @State private var date = Date().addingTimeInterval(3600)
    @State private var draftID:UUID?
    @State private var agreed = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            Form {
                Section { Label("第 \(step+1) / 3 步",systemImage:scenario.symbol).font(.headline);ProgressView(value:Double(step+1),total:3).tint(.seeAccent) }
                if step == 0 {
                    Section("这次的目标") { TextField("旅程标题",text:$title).accessibilityIdentifier("wizard.title");Toggle("安排一个计划日期",isOn:$hasDate);if hasDate { DatePicker("我计划去办理的时间",selection:$date) };Text("计划时间由你安排，不是通知里的官方截止时间，也不会自动开启提醒。").font(.caption).foregroundStyle(.secondary) }
                } else if step == 1 {
                    Section("准备问什么") {
                        ForEach(questions.indices,id:\.self) { i in TextField("待询问问题",text:$questions[i],axis:.vertical) }
                        Button("再加一个问题") { questions.append("") }.disabled(questions.count >= 10)
                    }
                    Section("可选：带入已存材料") {
                        Picker("来源材料",selection:$draftID) { Text("稍后再加入").tag(nil as UUID?);ForEach(studio.drafts.filter{!$0.demonstration}) { Text($0.title).tag(Optional($0.id)) } }
                        Text("只带入你选中的本机文字，不采集音视频。").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("建立前预览") { Text(title).font(.title2.bold());Text(scenario.title);ForEach(Array(questions.filter{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}.enumerated()),id:\.offset) { Text("待询问："+$0.element) };if hasDate { Text(date,format:.dateTime.year().month().day().hour().minute()) };Text(draftID == nil ? "本次暂不加入材料" : "带入所选材料快照");Toggle("我已检查，同意将这段旅程保存到本机",isOn:$agreed).accessibilityIdentifier("wizard.consent") }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Section {
                    if step > 0 { Button("上一步") { step -= 1;agreed = false } }
                    Button(step == 2 ? "建立并开始" : "下一步") { if step < 2 { step += 1 } else { create() } }.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (step == 2 && !agreed)).accessibilityIdentifier("wizard.next")
                }
            }.seePageCanvas().navigationTitle(scenario.title).toolbar { Button("取消") { dismiss() } }.modifier(KeyboardCloseToolbar()).onAppear { if title.isEmpty { title = scenario.title;questions = scenario.questions } }
        }
    }
    private func create() {
        do {
            guard agreed else { throw CampusError.consent }
            var journey = try scenario.makeJourney(title:title,questions:questions.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty},date:hasDate ? date : nil)
            if let id = draftID { guard let draft = studio.drafts.first(where:{$0.id == id && !$0.demonstration}) else { throw CampusError.stale };try journey.attach(CaseDocument(draft:draft)) }
            try studio.putJourney(journey);onCreated(journey.id);dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
struct JourneyWorkspaceActions:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    let journey:CampusJourney
    @State private var error:String?
    var body:some View {
        Section {
            SeeJourneyCover(journey:journey,next:next)
            NavigationLink {
                CounterVisitPage(workspace:workspace,studio:studio,id:journey.id)
            } label: {
                Label("窗口办事 · 按四步继续",systemImage:"person.2.wave.2")
                    .frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(SeeSecondaryButtonStyle()).accessibilityIdentifier("journey.counterVisit")
            NavigationLink("查看这段旅程的变化") { CampusChangeCenter(workspace:workspace,studio:studio,journeyID:journey.id) }
            NavigationLink("现场沟通与连续核对") { JourneyCommunicationHub(workspace:workspace,studio:studio,id:journey.id) }.accessibilityIdentifier("journey.communicationHub")
            NavigationLink("修改计划日期") { JourneyPlanDatePage(studio:studio,id:journey.id) }
            Button(studio.campusWorkspace.favoriteJourneyIDs.contains(journey.id) ? "取消收藏这段旅程" : "收藏这段旅程",systemImage:"star") {
                do { try studio.updateCampusWorkspace { state in if state.favoriteJourneyIDs.contains(journey.id) { state.favoriteJourneyIDs.removeAll{$0 == journey.id} } else { state.favoriteJourneyIDs.append(journey.id) } } } catch { self.error = error.localizedDescription }
            }.accessibilityIdentifier("journey.favorite")
            if let bookmark = studio.campusWorkspace.bookmarks.first(where:{$0.id == journey.id}) { NavigationLink("回到上次："+bookmark.section.title) { JourneyResumeDestination(workspace:workspace,studio:studio,bookmark:bookmark) } }
            if let error { Text(error).foregroundStyle(.red) }
        }
    }
    private var next:String {
        if journey.stage == .paused { return "进度已保留。准备好后继续，再查看尚未处理的问题。" }
        if let question = journey.questions.first(where:{$0.answer.isEmpty}) { return "下一步可以问："+question.text }
        if let fact = journey.facts.first(where:{!$0.isConfirmed}) { return "下一步：核对"+fact.kind.title+" · "+fact.value }
        return "查看随身办事单，办理后留下结果与后续安排。"
    }
}
struct JourneyPlanDatePage:View {
    @ObservedObject var studio:WorkroomService
    let id:UUID
    @State private var enabled = false
    @State private var date = Date()
    @State private var baseline:String?
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        Form {
            Toggle("为旅程安排计划时间",isOn:$enabled)
            if enabled { DatePicker("计划时间",selection:$date) }
            Text("这是你的办理计划；不会修改通知、事务截止时间或自动安排通知。").font(.caption).foregroundStyle(.secondary)
            Button("保存计划") {
                do { guard var item = studio.campus.journeys.first(where:{$0.id == id}),try item.fingerprint() == baseline else { throw CampusError.stale };var plan = item.plan ?? .init();plan.plannedAt = enabled ? date : nil;item.plan = plan;try studio.putJourney(item,baseline:baseline);dismiss() } catch { self.error = error.localizedDescription }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("旅程计划").onAppear { if baseline == nil,let item = studio.campus.journeys.first(where:{$0.id == id}) { baseline = try? item.fingerprint();enabled = item.plan?.plannedAt != nil;date = item.plan?.plannedAt ?? Date() } }
    }
}
struct CampusChangeCenter:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    var journeyID:UUID?
    private var journeys:[CampusJourney] { studio.campus.journeys.filter{journeyID == nil || $0.id == journeyID} }
    var body:some View {
        List {
            Section { CampusHero(title:"变化在这里处理",detail:"逐项查看变化和依据。记录采用的材料不会替你确认信息卡。",symbol:"arrow.triangle.2.circlepath") }
            let rows = CampusOverview.attention(journeys,cases:studio.cases)
            if rows.isEmpty { ContentUnavailableView("没有尚待处理的变化",systemImage:"checkmark.seal",description:Text("这不代表所有安排已经核对，请继续查看旅程中的待确认卡片。")) }
            ForEach(rows) { row in
                NavigationLink { JourneyChangeDetail(workspace:workspace,studio:studio,row:row) } label: {
                    VStack(alignment:.leading,spacing:8) { Label(row.title,systemImage:"exclamationmark.circle").font(.headline);Text(studio.campus.journeys.first(where:{$0.id == row.journeyID})?.title ?? "旅程");Text(row.detail).font(.caption).foregroundStyle(.secondary) }.padding(.vertical,6)
                }
            }
            ForEach(journeys) { journey in Section(journey.title+" · 材料记录") { NavigationLink("查看版本时间线与不同说法") { JourneyMaterialHistoryPage(studio:studio,id:journey.id) } } }
        }.seePageCanvas().navigationTitle("变更处理").modifier(WorkroomPrivacy())
    }
}
struct JourneyChangeDetail:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    let row:JourneyAttention
    @State private var error:String?
    var body:some View {
        List {
            Section { Text(row.title).font(.title2.bold());Text(row.detail) }
            if let journey = studio.campus.journeys.first(where:{$0.id == row.journeyID}) {
                if row.section == .confirmation,let id = row.targetID,let fact = journey.facts.first(where:{$0.id == id}) {
                    Section { Text("旧内容："+fact.value);NavigationLink("查看原依据") { JourneyConfirmationPage(studio:studio,journeyID:journey.id,factID:id) };NavigationLink("参照最新材料修改信息") { JourneyFactEditor(studio:studio,journeyID:journey.id,initial:fact) } }
                } else if row.section == .materials {
                    JourneyConflictSections(studio:studio,journey:journey)
                } else {
                    Section("当前关联事务") { ForEach(journey.caseIDs,id:\.self) { id in
                        if let item = studio.cases.first(where:{$0.id == id}) { NavigationLink(item.title) { WorkroomCaseDetail(workspace:workspace,studio:studio,cards:workspace.information,routines:workspace.routines,itemID:id) } }
                    };Button("我已逐项对照最新关联事务") { do { try studio.acknowledgeJourneyCases(journey.id) } catch { self.error = error.localizedDescription } } }
                    Text("这里只更新已查看的版本，失效的信息卡仍需修改后重新核对。").font(.caption)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("处理这项变化").onAppear { try? studio.rememberJourney(row.journeyID,section:.changes,targetID:row.targetID) }
    }
}
struct JourneyMaterialHistoryPage:View {
    @ObservedObject var studio:WorkroomService
    let id:UUID
    var body:some View {
        List {
            if let journey = studio.campus.journeys.first(where:{$0.id == id}) {
                Section { CampusHero(title:"来源与变化都有记录",detail:"同一材料按版本查看；不同材料的格式候选并排核对。文字差异不等于学校已正式改约。",symbol:"doc.on.doc") }
                JourneyConflictSections(studio:studio,journey:journey)
                ForEach(JourneyRevisionDelta.history(journey).reversed(),id:\.after.id) { delta in
                    Section(delta.after.title+" · 第 \(delta.after.revision) 版") {
                        NavigationLink("查看这一版原文") { EvidenceQuotePage(studio:studio,source:delta.after,quote:String(delta.after.text.prefix(100)),journeyID:id) }
                        if let before = delta.before { Text("对照第 \(before.revision) 版").font(.caption);ForEach(Array(delta.added.enumerated()),id:\.offset) { Text("新增："+$0.element).foregroundStyle(Color.seeAccent) };ForEach(Array(delta.removed.enumerated()),id:\.offset) { Text("旧行："+$0.element).foregroundStyle(.secondary) } }
                        else { Text("这份材料首次加入时的快照。").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.seePageCanvas().navigationTitle("材料版本").onAppear { try? studio.rememberJourney(id,section:.materials) }.modifier(WorkroomPrivacy())
    }
}
struct JourneyConflictSections:View {
    @ObservedObject var studio:WorkroomService
    let journey:CampusJourney
    var body:some View {
        ForEach(JourneyMaterialAnalysis.conflicts(journey)) { conflict in
            Section(conflict.kind.title+" · 材料中有不同说法") {
                ForEach(conflict.options) { option in VStack(alignment:.leading,spacing:6) { Text(option.value).font(.headline);Text(option.title+" · 第 \(option.revision) 版").font(.caption);Text(option.quote).font(.caption).foregroundStyle(.secondary) } }
                if let resolution = journey.plan?.resolutions.first(where:{$0.id == conflict.id}) {
                    Label("已记录判断："+resolution.note,systemImage:"checkmark.bubble").foregroundStyle(Color.seeAccent)
                    Text("采用来源："+(journey.documents.first(where:{$0.id == resolution.selectedSourceID})?.title ?? "材料")).font(.caption)
                }
                NavigationLink("核对并记录采用的依据") { JourneyConflictEditor(studio:studio,journey:journey,conflict:conflict) }
                Text("可能是不同事项或不同时间的安排，需你判断；不会自动合并成一个结论。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct JourneyConflictEditor:View {
    @ObservedObject var studio:WorkroomService
    let journey:CampusJourney
    let conflict:JourneyConflict
    @State private var sourceID:UUID?
    @State private var note = ""
    @State private var agreed = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        Form {
            ForEach(conflict.options) { row in Section(row.title) { Text(row.quote);Button(sourceID == row.sourceID ? "已选为采用依据" : "采用这份来源") { sourceID = row.sourceID;agreed = false } } }
            TextField("说明判断，例如：窗口确认应采用补充通知",text:$note,axis:.vertical)
            Toggle("我已核对是否为同一安排，并记录判断依据",isOn:$agreed)
            Button("保存本次判断") {
                do { guard let sourceID,agreed else { throw CampusError.consent };try studio.resolveJourneyConflict(journey.id,key:conflict.id,sourceID:sourceID,note:note,baseline:journey.fingerprint());dismiss() } catch { self.error = error.localizedDescription }
            }.disabled(sourceID == nil || note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !agreed)
            Text("已有确认卡不会跟随改写。请返回相应卡片，按新依据修改并重新确认。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("核对不同说法").modifier(KeyboardCloseToolbar())
    }
}
struct JourneySourcePreview:View {
    @ObservedObject var studio:WorkroomService
    let journey:CampusJourney
    let source:CaseDocument
    @State private var agreed = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    private var duplicates:[CaseDocument] { JourneyMaterialAnalysis.duplicates(source,in:journey) }
    var body:some View {
        NavigationStack { List {
            Section("将加入的材料") { Text(source.title).font(.title2.bold());Text("第 \(source.revision) 版");Text(source.text).textSelection(.enabled) }
            if !duplicates.isEmpty { Section("发现相同文字") {
                ForEach(duplicates) { Text($0.title+" · 第 \($0.revision) 版") }
                Button("使用已有材料，不重复加入") { dismiss() }
                Text("若它们属于不同来源，也可以明确保留两份。已有卡片依据不迁移。").font(.caption)
            } }
            if journey.documents.contains(where:{$0.draftID == source.draftID && $0.revision < source.revision}) { Section { Label("同一材料的新版本",systemImage:"arrow.triangle.2.circlepath");Text("加入后，引用旧版材料的信息卡将失效；旧材料保留供对照。") } }
            Section { Toggle("我已核对来源与重复情况",isOn:$agreed);Button(duplicates.isEmpty ? "确认加入材料" : "明确保留两份并加入") {
                do { guard agreed else { throw CampusError.consent };try studio.attachJourneySource(source,to:journey.id,baseline:journey.fingerprint(),allowDuplicate:!duplicates.isEmpty);dismiss() } catch { self.error = error.localizedDescription }
            }.disabled(!agreed) }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("加入材料前核对").toolbar { Button("取消") { dismiss() } } }
    }
}
struct CampusSchedulePage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @State private var date = Date()
    @State private var week = false
    var body:some View {
        List {
            Section { Picker("范围",selection:$week) { Text("当天").tag(false);Text("本周").tag(true) }.pickerStyle(.segmented);DatePicker("选择日期",selection:$date,displayedComponents:.date);Text("这里按自己设置的旅程计划时间显示，事务截止和提醒仍独立。").font(.caption) }
            let journeys = CampusOverview.scheduled(studio.campus.journeys,on:date,week:week)
            Section("计划办理 · \(journeys.count)") { ForEach(journeys) { item in NavigationLink { JourneyDetailPage(workspace:workspace,studio:studio,id:item.id) } label: { VStack(alignment:.leading) { Text(item.title);if let date = item.plan?.plannedAt { Text(date,format:.dateTime.month().day().hour().minute()).font(.caption) } } } };if journeys.isEmpty { Text("这个范围内还没有旅程计划。") } }
            Section("等待回复") { ForEach(studio.campus.journeys.filter{$0.stage == .followUp && $0.questions.contains(where:{$0.answer.isEmpty})}) { item in NavigationLink(item.title) { JourneyDetailPage(workspace:workspace,studio:studio,id:item.id) } } }
            Section("尚未安排时间") { ForEach(studio.campus.journeys.filter{$0.stage != .finished && $0.plan?.plannedAt == nil}) { item in NavigationLink(item.title) { JourneyPlanDatePage(studio:studio,id:item.id) } } }
            NavigationLink("查看事务截止日历") { CaseCalendarPage(workspace:workspace,studio:studio) }
        }.seePageCanvas().navigationTitle("办理计划").modifier(WorkroomPrivacy())
    }
}
struct CampusQuestionsPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @State private var includeAnswered = false
    var body:some View {
        List {
            Toggle("同时查看已填写答案的问题",isOn:$includeAnswered)
            ForEach(studio.campus.journeys.filter{$0.stage != .finished}) { journey in
                let rows = journey.questions.filter{includeAnswered || $0.answer.isEmpty}
                if !rows.isEmpty { Section(journey.title+(journey.demonstration ? " · 演示" : "")) { ForEach(rows) { row in NavigationLink { JourneyQuestionPage(studio:studio,journeyID:journey.id,questionID:row.id) } label: { VStack(alignment:.leading,spacing:6) { Text(row.text).font(.headline);Text(row.answer.isEmpty ? "尚未得到答案" : row.answer).font(.caption).foregroundStyle(.secondary) } } } } }
            }
            if studio.campus.journeys.flatMap(\.questions).allSatisfy({!$0.answer.isEmpty}) { ContentUnavailableView("没有待询问问题",systemImage:"checkmark.bubble") }
        }.seePageCanvas().navigationTitle("问题与待回复").modifier(WorkroomPrivacy())
    }
}
struct JourneySearchDestination:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    let hit:GlobalSearchHit
    var query = ""
    var body:some View {
        let id = hit.parentJourneyID ?? hit.recordID
        Group {
            if let journey = studio.campus.journeys.first(where:{$0.id == id}) {
                switch hit.kind {
                case .journey: JourneyDetailPage(workspace:workspace,studio:studio,id:id)
                case .question: JourneyQuestionPage(studio:studio,journeyID:id,questionID:hit.recordID)
                case .journeyFact: JourneyConfirmationPage(studio:studio,journeyID:id,factID:hit.recordID)
                case .journeySource:
                    if let source = journey.documents.first(where:{$0.id == hit.recordID}) {
                        EvidenceQuotePage(studio:studio,source:source,quote:source.text.components(separatedBy:.newlines).first(where:{!query.isEmpty && $0.localizedCaseInsensitiveContains(query)}) ?? String(source.text.prefix(100)),journeyID:id)
                    } else { ContentUnavailableView("材料已移除",systemImage:"doc") }
                case .excerpt:
                    if let row = journey.conversations.first(where:{$0.id == hit.recordID}) {
                        List { Section { Text(highlight(row.text,query:query)).textSelection(.enabled) };NavigationLink("关联为一个问题的回答依据") { JourneyAnswerLinkPage(studio:studio,journeyID:id,excerptID:row.id) } }.seePageCanvas().navigationTitle(row.title).onAppear{try? studio.rememberJourney(id,section:.communication,targetID:row.id)}
                    } else { ContentUnavailableView("摘录已移除",systemImage:"text.bubble") }
                default: EmptyView()
                }
            } else { ContentUnavailableView("旅程已移除",systemImage:"doc.badge.clock") }
        }.toolbar { if hit.kind != .journey { NavigationLink("旅程") { JourneyDetailPage(workspace:workspace,studio:studio,id:id) } } }.modifier(WorkroomPrivacy())
    }
}
struct JourneyResumeDestination:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    let bookmark:JourneyBookmark
    var body:some View {
        Group {
            switch bookmark.section {
            case .confirmation:
                if let id = bookmark.targetID,studio.campus.journeys.first(where:{$0.id == bookmark.journeyID})?.facts.contains(where:{$0.id == id}) == true { JourneyConfirmationPage(studio:studio,journeyID:bookmark.journeyID,factID:id) } else { CounterVisitPage(workspace:workspace,studio:studio,id:bookmark.journeyID) }
            case .questions:
                if let id = bookmark.targetID { JourneyQuestionPage(studio:studio,journeyID:bookmark.journeyID,questionID:id) } else { fallback }
            case .materials:
                if let target = bookmark.targetID,let source = studio.campus.journeys.first(where:{$0.id == bookmark.journeyID})?.documents.first(where:{$0.id == target}) { EvidenceQuotePage(studio:studio,source:source,quote:String(source.text.prefix(100)),journeyID:bookmark.journeyID) }
                else { JourneyMaterialHistoryPage(studio:studio,id:bookmark.journeyID) }
            case .communication, .outcome: CounterVisitPage(workspace:workspace,studio:studio,id:bookmark.journeyID)
            case .changes: CampusChangeCenter(workspace:workspace,studio:studio,journeyID:bookmark.journeyID)
            case .departure: JourneyDeparturePage(studio:studio,id:bookmark.journeyID)
            default: fallback
            }
        }
    }
    private var fallback:some View { JourneyDetailPage(workspace:workspace,studio:studio,id:bookmark.journeyID) }
}
struct CampusDeskPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @State private var journeyID:UUID?
    @State private var sourceID:UUID?
    @State private var panel = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    private var journey:CampusJourney? { studio.campus.journeys.first{$0.id == journeyID} }
    var body:some View {
        GeometryReader { geometry in
            VStack(spacing:0) {
                Picker("正在处理的旅程",selection:$journeyID) { Text("选择旅程").tag(nil as UUID?);ForEach(studio.campus.journeys) { Text($0.title).tag(Optional($0.id)) } }.padding().accessibilityIdentifier("desk.journey")
                if let journey {
                    if geometry.size.width >= 900 && !typeSize.isAccessibilitySize {
                        HStack(spacing:0) { sourceList(journey).frame(width:geometry.size.width*0.42);Divider();detailList(journey) }.accessibilityIdentifier("desk.columns")
                    } else { VStack { Picker("工作区域",selection:$panel) { Text("材料").tag(0);Text("问题").tag(1);Text("确认卡").tag(2) }.pickerStyle(.segmented).padding();if panel == 0 { sourceList(journey) } else { detailList(journey) } } }
                } else { ContentUnavailableView("先选择一段旅程",systemImage:"rectangle.split.2x1") }
            }
        }.seePageCanvas().navigationTitle("联动工作台").onAppear{journeyID = journeyID ?? studio.campus.lastJourneyID ?? studio.campus.journeys.first?.id}
            .onChange(of:journeyID) { _,_ in sourceID = nil }.modifier(WorkroomPrivacy())
    }
    private func sourceList(_ journey:CampusJourney) -> some View {
        List {
            Section("材料 · 选择后联动右侧确认卡") {
                Button("全部材料") { sourceID = nil }
                ForEach(journey.documents) { source in
                    Button { sourceID = source.id;panel = 2 } label: { Label(source.title+" · 第 \(source.revision) 版",systemImage:sourceID == source.id ? "checkmark.circle.fill" : "doc.text") }.accessibilityIdentifier("desk.source."+source.id.uuidString)
                }
            }
            if let source = journey.documents.first(where:{$0.id == sourceID}) { Section("所选原文") { Text(source.text).textSelection(.enabled) } }
            NavigationLink("版本与不同说法") { JourneyMaterialHistoryPage(studio:studio,id:journey.id) }
        }
    }
    private func detailList(_ journey:CampusJourney) -> some View {
        List {
            if panel != 2 { Section("问题与回答") { ForEach(journey.questions) { row in NavigationLink(row.text) { JourneyQuestionPage(studio:studio,journeyID:journey.id,questionID:row.id) } } } }
            Section(sourceID == nil ? "全部确认卡" : "引用所选材料的确认卡") {
                let facts = journey.facts.filter{sourceID == nil || $0.sourceID == sourceID}
                ForEach(facts) { fact in NavigationLink { JourneyConfirmationPage(studio:studio,journeyID:journey.id,factID:fact.id) } label: { VStack(alignment:.leading,spacing:7) { Text(fact.value).font(.headline);Text(fact.superseded ? "旧版依据，待重新核对" : fact.isConfirmed ? "我已核对" : "尚未核对").font(.caption).foregroundStyle(.secondary) } } }
                if facts.isEmpty { Text("该材料暂未建立确认卡。") }
            }
            if panel == 2 { Button("查看所有问题") { panel = 1 } }
            NavigationLink("打开这段旅程") { JourneyDetailPage(workspace:workspace,studio:studio,id:journey.id) }
        }
    }
}
