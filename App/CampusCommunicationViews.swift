import SwiftUI

struct JourneyQuestionPage:View {
    @ObservedObject var studio:WorkroomService
    let journeyID:UUID
    let questionID:UUID
    @State private var answer = ""
    @State private var baseline:String?
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    private var journey:CampusJourney? { studio.campus.journeys.first{$0.id == journeyID} }
    private var question:JourneyQuestion? { journey?.questions.first{$0.id == questionID} }
    var body:some View {
        Form {
            if let question {
                Section { CampusHero(title:question.text,detail:question.answer.isEmpty ? "还没有留下答案。可以先沟通，再选择摘录作为依据。" : "查看已有回答，也可以核对后修改。",symbol:"questionmark.bubble") }
                Section("核对后的回答") {
                    TextField("填写回答（最多500字）",text:$answer,axis:.vertical).lineLimit(3...10).accessibilityIdentifier("question.answer")
                    Button("保存回答") {
                        do {
                            guard var journey,try journey.fingerprint() == baseline,let index = journey.questions.firstIndex(where:{$0.id == questionID}) else { throw CampusError.stale }
                            journey.questions[index].answer = answer;try studio.putJourney(journey,baseline:baseline);baseline = try studio.campus.journeys.first(where:{$0.id == journeyID})?.fingerprint();error = nil
                        } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("question.save")
                }
                if let link = journey?.plan?.questionEvidence.first(where:{$0.questionID == questionID}) {
                    Section("回答依据") {
                        Text(link.quote).textSelection(.enabled)
                        Text("来自："+(journey?.conversations.first(where:{$0.id == link.excerptID})?.title ?? "沟通摘录")).font(.caption)
                        if question.answer != link.answer { Label("回答已另行修改，以上是先前关联的依据，请重新检查。",systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                    }
                }
                NavigationLink("从沟通摘录关联回答依据") { JourneyAnswerLinkPage(studio:studio,journeyID:journeyID,questionID:questionID) }
                Text("答案由你核对后填写；模型意见或字幕本身不会自动变成已确认安排。").font(.caption).foregroundStyle(.secondary)
            } else { ContentUnavailableView("问题当前不可用",systemImage:"questionmark.bubble") }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("问题与回答").modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
            .onAppear {
                if let journey { baseline = try? journey.fingerprint();answer = question?.answer ?? "";try? studio.rememberJourney(journeyID,section:.questions,targetID:questionID) }
            }
    }
}
struct JourneyAnswerLinkPage:View {
    @ObservedObject var studio:WorkroomService
    let journeyID:UUID
    var excerptID:UUID?
    var questionID:UUID?
    @State private var chosenExcerpt:UUID?
    @State private var chosenQuestion:UUID?
    @State private var quote = ""
    @State private var answer = ""
    @State private var agreed = false
    @State private var baseline:String?
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    private var journey:CampusJourney? { studio.campus.journeys.first{$0.id == journeyID} }
    var body:some View {
        Form {
            if let journey {
                Section("选择问题与摘录") {
                    Picker("问题",selection:$chosenQuestion) { Text("请选择").tag(nil as UUID?);ForEach(journey.questions) { Text($0.text).tag(Optional($0.id)) } }
                    Picker("沟通摘录",selection:$chosenExcerpt) { Text("请选择").tag(nil as UUID?);ForEach(journey.conversations) { Text($0.title).tag(Optional($0.id)) } }
                    if let row = journey.conversations.first(where:{$0.id == chosenExcerpt}) { Text(row.text).textSelection(.enabled) }
                }
                Section("明确留下依据") {
                    TextField("摘录中的原话（必须与摘录一致）",text:$quote,axis:.vertical).lineLimit(3...8).accessibilityIdentifier("answer.quote")
                    TextField("你核对后的回答",text:$answer,axis:.vertical).lineLimit(2...6).accessibilityIdentifier("answer.value")
                    Toggle("我已核对原话和回答，同意保存关联",isOn:$agreed).accessibilityIdentifier("answer.consent")
                    Button("保存回答与依据") {
                        do { guard let chosenQuestion,let chosenExcerpt,let baseline else { throw CampusError.missing };try studio.linkJourneyAnswer(journeyID,questionID:chosenQuestion,excerptID:chosenExcerpt,quote:quote,answer:answer,baseline:baseline,consent:agreed);dismiss() } catch { self.error = error.localizedDescription }
                    }.disabled(!agreed || quote.isEmpty || answer.isEmpty).accessibilityIdentifier("answer.save")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("关联回答依据").modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
            .onAppear {
                if baseline == nil { baseline = try? journey?.fingerprint();chosenQuestion = questionID;chosenExcerpt = excerptID }
            }.onChange(of:chosenExcerpt) { _,id in quote = String((journey?.conversations.first(where:{$0.id == id})?.text ?? "").prefix(500));agreed = false }
            .onChange(of:chosenQuestion) { _,_ in agreed = false }.onChange(of:quote) { _,_ in agreed = false }.onChange(of:answer) { _,_ in agreed = false }
    }
}
struct JourneyCommunicationHub:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    let id:UUID
    @State private var showDisplay = false
    @State private var displayText = ""
    @State private var showClip = false
    @State private var showCards = false
    private var journey:CampusJourney? { studio.campus.journeys.first{$0.id == id} }
    var body:some View {
        List {
            if let journey {
                Section { CampusHero(title:"这次沟通，一起说清楚",detail:journey.title+" · 选一句话显示给对方，或打开字幕留下需要的片段。",symbol:"person.2.wave.2") }
                Section("现场操作") {
                    Button("打开面对面字幕",systemImage:"captions.bubble") { workspace.navigationRequest = .captions }
                    Button("将已结束的字幕片段加入旅程",systemImage:"text.badge.plus") { showClip = true }.accessibilityIdentifier("journey.clip")
                    Button("连续核对本次信息卡",systemImage:"rectangle.stack") { showCards = true }.disabled(journey.facts.isEmpty).accessibilityIdentifier("journey.carousel")
                }
                Section("根据这段旅程准备的表达") {
                    ForEach(journey.contextualPhrases,id:\.self) { phrase in
                        VStack(alignment:.leading,spacing:8) {
                            Text(phrase).font(.headline).fixedSize(horizontal:false,vertical:true)
                            HStack { Button("大字展示") { workspace.stopCapture();displayText = phrase;showDisplay = true };Spacer();Button("填入回应") { workspace.prepareJourneyPhrase(phrase,demonstration:journey.demonstration) } }.font(.subheadline).buttonStyle(.borderless)
                        }.padding(.vertical,6)
                    }
                    Text("大字展示会暂停采集与朗读。填入回应不会自动朗读、发送或保存；模拟旅程的表达保留演示标记。").font(.caption).foregroundStyle(.secondary)
                }
                Section("已有沟通摘录") {
                    ForEach(journey.conversations) { row in
                        NavigationLink { JourneyAnswerLinkPage(studio:studio,journeyID:id,excerptID:row.id) } label: { VStack(alignment:.leading,spacing:6) { Text(row.title);Text(row.text).lineLimit(2).font(.caption).foregroundStyle(.secondary) } }
                    }
                }
            } else { ContentUnavailableView("旅程已移除",systemImage:"text.bubble") }
        }.seePageCanvas().navigationTitle("旅程沟通").onAppear{try? studio.rememberJourney(id,section:.communication)}
            .fullScreenCover(isPresented:$showDisplay) { JourneyDisplayPage(text:displayText,demonstration:journey?.demonstration ?? false) }
            .sheet(isPresented:$showClip) { JourneyClipPicker(studio:studio,turns:workspace.audio.conversation.turns,activeCapture:workspace.audio.conversation.activeCapture,initialJourneyID:id) }
            .sheet(isPresented:$showCards) { NavigationStack { JourneyCardCarousel(studio:studio,id:id).toolbar { Button("关闭") { showCards = false } } } }.modifier(WorkroomPrivacy())
    }
}
struct JourneyClipPicker:View {
    @ObservedObject var studio:WorkroomService
    let turns:[ConversationTurn]
    var activeCapture:UUID?
    var initialJourneyID:UUID?
    @State private var journeyID:UUID?
    @State private var selected = Set<UUID>()
    @State private var title = "现场沟通选段"
    @State private var agreed = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    private var journey:CampusJourney? { studio.campus.journeys.first{$0.id == journeyID} }
    private var available:[ConversationTurn] { turns.filter{$0.id != activeCapture && $0.state != .partial && ($0.origin == .demonstration) == journey?.demonstration} }
    private var text:String { available.filter{selected.contains($0.id)}.map{($0.speaker == .me ? "我：" : "对方：")+$0.text}.joined(separator:"\n") }
    var body:some View {
        NavigationStack { List {
            Section {
                Picker("加入哪段旅程",selection:$journeyID) { Text("请选择").tag(nil as UUID?);ForEach(studio.campus.journeys.filter{$0.stage != .finished}) { Text($0.title+($0.demonstration ? " · 演示" : "")).tag(Optional($0.id)) } }
                TextField("选段标题",text:$title)
                Text("只列出已结束且与旅程来源一致的文字。当前正在识别的片段不可加入；演示与普通文字分别处理。").font(.caption).foregroundStyle(.secondary)
            }
            Section("选择需要的片段") {
                ForEach(available) { turn in Toggle(isOn:Binding(get:{selected.contains(turn.id)},set:{if $0 { selected.insert(turn.id) } else { selected.remove(turn.id) };agreed = false})) { VStack(alignment:.leading,spacing:6) { Text(turn.text);if turn.state == .interrupted { Text("采集中断，请重点复核").font(.caption).foregroundStyle(.orange) } } } }
                if available.isEmpty { Text("没有可加入的已结束片段。先回到字幕页沟通，或使用旅程中的手动摘录。") }
            }
            if !selected.isEmpty { Section("保存前预览") { Text(text).textSelection(.enabled);Text("\(text.count)/6000字").font(.caption);Toggle("我已核对，同意将以上文字留在本机旅程中",isOn:$agreed);Button("加入所选旅程") { save() }.disabled(!agreed || text.count > 6000).accessibilityIdentifier("clip.save") } }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("字幕加入旅程").toolbar { Button("取消") { dismiss() } }.modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
            .onAppear{journeyID = initialJourneyID}.onChange(of:journeyID) { _,_ in selected = [];agreed = false } }
    }
    private func save() {
        do { guard let journey,!selected.isEmpty else { throw CampusError.missing };try studio.addJourneyExcerpt(journey.id,text:text,title:title,demonstration:journey.demonstration,consent:agreed);dismiss() } catch { self.error = error.localizedDescription }
    }
}
struct JourneyDisplayPage:View {
    let text:String
    let demonstration:Bool
    @State private var end = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body:some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing:24) {
                HStack { Label(demonstration ? "演示 · 现场展示" : "请看这段文字",systemImage:"person.2").font(.headline);Spacer();Button("结束展示") { end = true }.frame(minHeight:44) }
                ScrollView { Text(text).font(.system(.largeTitle,design:.rounded,weight:.semibold)).frame(maxWidth:900,alignment:.leading).padding(.vertical,30).textSelection(.enabled) }
                Text("只展示所选文字 · 不显示旅程备注").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
            if phase != .active { DailyPrivacyCover() }
        }.confirmationDialog("结束现场展示？",isPresented:$end,titleVisibility:.visible) { Button("返回旅程") { dismiss() } }
    }
}
struct JourneyCardCarousel:View {
    @ObservedObject var studio:WorkroomService
    let id:UUID
    var currentOnly = false
    @State private var index = 0
    private var facts:[JourneyFact] {
        let all = studio.campus.journeys.first{$0.id == id}?.facts ?? []
        return currentOnly ? all.filter{!$0.superseded} : all
    }
    var body:some View {
        VStack(spacing:0) {
            if !facts.isEmpty {
                let position = min(index,facts.count-1)
                HStack { Button("上一项") { index = max(0,index-1) }.disabled(position == 0).accessibilityIdentifier("carousel.previous");Spacer();Text("第 \(position+1) / \(facts.count) 项").font(.headline).accessibilityIdentifier("carousel.position");Spacer();Button("下一项") { index = min(facts.count-1,index+1) }.disabled(position == facts.count-1).accessibilityIdentifier("carousel.next") }.buttonStyle(.borderless).padding()
                JourneyConfirmationPage(studio:studio,journeyID:id,factID:facts[position].id).id(facts[position].id)
            } else { ContentUnavailableView("还没有确认卡",systemImage:"rectangle.stack") }
        }.seePageCanvas().navigationTitle("连续核对").navigationBarTitleDisplayMode(.inline)
    }
}
struct CampusPresentationPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @State private var id:UUID?
    @State private var step = 0
    @State private var reset = false
    @State private var error:String?
    private let titles = ["收到一份通知","准备要问的问题","现场沟通留下摘录","双方一起核对","接力到其他设备","补充通知发生变化","记录办理结果"]
    var body:some View {
        List {
            Section { CampusHero(title:"用三分钟讲清一个故事",detail:"全部使用明确标注的模拟校园材料。每一步打开应用中的实际功能，模型效果另到评测页展示。",symbol:"play.rectangle");ProgressView(value:Double(step+1),total:Double(titles.count));Text("第 \(step+1) / \(titles.count) 步 · "+titles[step]).font(.headline).accessibilityIdentifier("presentation.step") }
            Section("讲解提示") { Text(explanation);Text("建议用时：20–30秒").font(.caption).foregroundStyle(.secondary) }
            if let id,let journey = studio.campus.journeys.first(where:{$0.id == id}) {
                Section {
                    if step == 0 { NavigationLink("打开通知与来源位置") { JourneyMaterialHistoryPage(studio:studio,id:id) } }
                    else if step == 1 { NavigationLink("打开提问清单") { JourneyDetailPage(workspace:workspace,studio:studio,id:id) } }
                    else if step == 2 { Button("准备一段模拟窗口回答") { prepareConversation(id) };NavigationLink("查看模拟沟通摘录与关联") { JourneyCommunicationHub(workspace:workspace,studio:studio,id:id) } }
                    else if step == 3 { NavigationLink("逐张展示并实际核对") { JourneyCardCarousel(studio:studio,id:id) } }
                    else if step == 4 { NavigationLink("导出这段演示旅程") { LibraryBackupPage(workspace:workspace,journeyID:id) };NavigationLink("发送Watch摘要") { DeviceContinuityPage(workspace:workspace,bridge:workspace.bridge,studio:studio,routines:workspace.routines) } }
                    else if step == 5 { Button("加入明确标注的模拟改期通知") { prepareChange(id) };NavigationLink("查看受影响的信息与来源") { CampusChangeCenter(workspace:workspace,studio:studio,journeyID:id) } }
                    else { NavigationLink("实际记录办理结果") { JourneyOutcomePage(studio:studio,id:id) };NavigationLink("查看旅程现状") { JourneyDetailPage(workspace:workspace,studio:studio,id:id) } }
                    Text("演示旅程第 \(journey.revision) 版").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section { HStack { Button("上一步") { step -= 1 }.disabled(step == 0).accessibilityIdentifier("presentation.previous");Spacer();Button("下一步") { step += 1 }.disabled(step == titles.count-1).accessibilityIdentifier("presentation.next") }.buttonStyle(.borderless);Button("重建这段内置演示旅程",role:.destructive) { reset = true }.accessibilityIdentifier("presentation.reset");Text("仅重建本页专用的内置旅程，其他普通/演示资料和已创建的关联事务保留。").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("作品演示").onAppear { run { id = try studio.startCampusPresentation(reset:false) } }
            .confirmationDialog("重建本页专用的演示旅程？",isPresented:$reset,titleVisibility:.visible) { Button("重建演示",role:.destructive) { run { id = try studio.startCampusPresentation(reset:true);step = 0 } }.accessibilityIdentifier("presentation.reset.confirm") }.modifier(WorkroomPrivacy())
    }
    private var explanation:String {
        ["从原始通知出发，展示本机文字、版本和可追溯依据。","场景只提供问题，不捏造学校规定。用户清楚知道哪些信息还没得到答案。","模拟回答必须保留演示标记。展示选段、预览与主动保存，不采集真实音视频。","自己核对与记录对方确认是两步。修改后失效，避免旧安排被当成新确认。","文件加密后再接力。Watch摘要收到回执与用户已查看分别记录；需要连接两端。","主动加入模拟新版本，显示旧确认失效、材料对照及重新核对入口。","留下实际办理结果，可明确建立后续任务；提醒需要另外主动开启。"][step]
    }
    private func run(_ block:()throws->Void) { do { try block();error = nil } catch { self.error = error.localizedDescription } }
    private func prepareConversation(_ id:UUID) {
        run { try studio.changeJourney(id) { journey in guard journey.plan?.presentationID == "campus-040",journey.demonstration else { throw CampusError.invalid };if !journey.conversations.contains(where:{$0.title == "模拟窗口回答"}) { journey.conversations.append(.init(title:"模拟窗口回答",text:"【模拟对话，不是真实字幕】对方：请在学生服务中心一楼提交材料，领取时间请等窗口另行通知。")) } } }
    }
    private func prepareChange(_ id:UUID) {
        run { try studio.changeJourney(id) { journey in
            guard journey.plan?.presentationID == "campus-040",journey.demonstration,let old = journey.documents.first else { throw CampusError.invalid }
            guard !journey.documents.contains(where:{$0.draftID == old.draftID && $0.revision == 2}) else { return }
            var next = old;next.id = UUID();next.revision = 2;next.text = "【模拟补充通知，不代表学校实际规定】\n地点：学生服务中心二楼\n费用：10元\n材料：校园卡、证件照\n领取时间请向窗口确认。"
            try journey.attach(next)
        } }
    }
}
