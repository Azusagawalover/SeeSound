import SwiftUI

struct WorkspaceSurface:ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content:Content) -> some View {
        content.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            .background(SeePalette.surface,in:RoundedRectangle(cornerRadius:20))
            .overlay(RoundedRectangle(cornerRadius:20).stroke(SeePalette.line.opacity(contrast == .increased ? 1 : 0.65),lineWidth:contrast == .increased ? 2 : 0.8).allowsHitTesting(false))
            .shadow(color:SeePalette.ink.opacity(contrast == .increased ? 0 : 0.035),radius:9,x:0,y:4)
    }
}
struct FeatureMessage:View {
    let title:String
    let detail:String
    var symbol = "exclamationmark.circle"
    var actionTitle:String? = nil
    var action:(()->Void)? = nil
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Label(title,systemImage:symbol).font(.headline).foregroundStyle(Color.seeAccent)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let actionTitle,let action { Button(actionTitle,action:action).buttonStyle(.bordered) }
        }.modifier(WorkspaceSurface()).accessibilityElement(children:.contain)
    }
}
struct WorkspaceHomePanel:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @ObservedObject var routines:RoutineService
    let showReply:()->Void
    let open:(ProbePage)->Void
    @State private var selection = 0
    @Environment(\.dynamicTypeSize) private var textSize
    var body:some View {
        TimelineView(.periodic(from:.now,by:30)) { context in
            let overview = WorkspaceOverview.make(drafts:studio.drafts,cases:studio.cases,now:context.date)
            VStack(alignment:.leading,spacing:18) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:6) {
                        HStack(spacing:5) { Image(systemName:"calendar");Text(context.date,format:.dateTime.month().day().weekday()) }
                            .font(.caption.weight(.medium)).foregroundStyle(SeePalette.ink)
                            .padding(.horizontal,10).padding(.vertical,6).background(SeePalette.oat,in:RoundedRectangle(cornerRadius:6))
                        Text("沟通与提醒").font(.system(.title2,design:.rounded,weight:.semibold)).foregroundStyle(SeePalette.ink)
                    }
                    Spacer();Button { open(.search) } label: { Image(systemName:"magnifyingglass").frame(width:44,height:44).background(SeePalette.surface,in:Circle()) }.accessibilityLabel("搜索本机资料")
                }
                communicationCover
                LazyVGrid(columns:textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()),GridItem(.flexible())],spacing:10) {
                    hearingShortcut("声音提醒",symbol:"bell.badge",color:SeePalette.oat) { open(.sound) }.accessibilityIdentifier("home.alerts")
                    hearingShortcut("拿给对方看",symbol:"text.bubble",color:SeePalette.sage,action:showReply).accessibilityIdentifier("home.showCard")
                }
                HearingHomeStatus(audio:workspace.audio,hand:workspace.hand,bridge:workspace.bridge,open:open)
                VStack(alignment:.leading,spacing:6) {
                    Label("沟通之后 · 校园办事",systemImage:"point.topleft.down.to.point.bottomright.curvepath").font(.headline).foregroundStyle(SeePalette.ink)
                    Text("把谈好的时间、地点和材料核对清楚，再继续办理。").font(.caption).foregroundStyle(SeePalette.secondary)
                }.padding(.top,4)
                SeeHomeCover(journey:studio.campus.journeys.first(where:{$0.id == studio.campus.lastJourneyID})) { open(.campus) }.padding(.top,6)
                if let current = studio.campus.journeys.first(where:{$0.id == studio.campus.lastJourneyID && $0.stage != .finished}) {
                    NavigationLink {
                        CounterVisitPage(workspace:workspace,studio:studio,id:current.id)
                    } label: {
                        HStack(spacing:12) {
                            Image(systemName:"person.2.wave.2").foregroundStyle(Color.seeAccent)
                            VStack(alignment:.leading,spacing:4) {
                                Text("继续窗口办理").font(.headline).foregroundStyle(SeePalette.ink)
                                Text(current.title+(current.demonstration ? " · 演示" : "")).font(.caption).foregroundStyle(SeePalette.secondary)
                            }
                            Spacer();Image(systemName:"arrow.right").foregroundStyle(Color.seeAccent)
                        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(SeePalette.surface,in:RoundedRectangle(cornerRadius:16)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("home.counterVisit")
                }
                DisclosureGroup("待办与材料概览") {
                VStack(alignment:.leading,spacing:14) {
                HStack { Label("事项清单",systemImage:"checklist").font(.system(.headline,design:.rounded,weight:.semibold)).foregroundStyle(SeePalette.ink);Spacer();Button("全部事务") { open(.cases) }.font(.caption) }
                if !studio.campus.recoveries.isEmpty { Button("有 \(studio.campus.recoveries.count) 份未保存修改可恢复",systemImage:"arrow.clockwise") { open(.campus) } }
                LazyVGrid(columns:textSize.isAccessibilitySize ? [GridItem(.flexible()),GridItem(.flexible())] : Array(repeating:GridItem(.flexible()),count:4),spacing:4) {
                    metric("待整理",count:overview.inbox,index:0,symbol:"tray")
                    metric("今天截止",count:overview.dueToday.count,index:1,symbol:"calendar")
                    metric("等待回复",count:overview.waiting.count,index:2,symbol:"clock.arrow.circlepath")
                    metric("已到期",count:overview.overdue.count,index:3,symbol:"flag")
                }
                if let message = studio.error { FeatureMessage(title:"资料暂时无法更新",detail:message,actionTitle:"打开备份与恢复",action:{open(.backup)}) }
                if selection == 0 {
                    let drafts = studio.drafts.filter { $0.inInbox == true && !$0.demonstration }
                    if drafts.isEmpty {
                        HStack(alignment:.center,spacing:12) {
                            Image(systemName:"tray").font(.title3).foregroundStyle(SeePalette.ink).frame(width:42,height:42).background(SeePalette.oat,in:RoundedRectangle(cornerRadius:12)).accessibilityHidden(true)
                            VStack(alignment:.leading,spacing:5) {
                                Text("还没有待整理文字").font(.subheadline.weight(.medium)).foregroundStyle(SeePalette.ink)
                                Text("分享来的图片可到收件箱查看。").font(.caption).foregroundStyle(SeePalette.secondary).fixedSize(horizontal:false,vertical:true)
                            }
                        }.padding(.vertical,5)
                    }
                    ForEach(drafts.prefix(3)) { row in
                        Button { do { try studio.openInbox(row.id);open(.workroom) } catch { workspace.notify(error.localizedDescription) } } label: { rowLabel(row.title,detail:"打开原文，开始核对",symbol:"doc.text") }.buttonStyle(.plain)
                    }
                    Button("打开收件箱",systemImage:"tray.and.arrow.down") { open(.inbox) }.buttonStyle(.bordered).tint(SeePalette.button).font(.subheadline)
                } else {
                    let rows = selection == 1 ? overview.dueToday : selection == 2 ? overview.waiting : overview.overdue
                    if rows.isEmpty { Text(selection == 2 ? "目前没有等待回复的普通事务。" : "这个分类暂时没有事务。").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(rows.sorted { selection == 2 ? ($0.workflow.followUpAt ?? .distantFuture) < ($1.workflow.followUpAt ?? .distantFuture) : ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }.prefix(3)) { item in
                        Button { workspace.scheduledDestination = .init(kind:.project,recordID:item.id) } label: { rowLabel(item.title,detail:selection == 2 && item.workflow.followUpAt != nil ? "计划跟进："+item.workflow.followUpAt!.formatted(date:.abbreviated,time:.shortened) : item.nextAction(routines:routines.items) ?? "核对后确认完成",symbol:selection == 2 ? "bubble.left" : "checklist") }.buttonStyle(.plain)
                    }
                    Button("查看全部事务",systemImage:"list.bullet") { open(.cases) }.buttonStyle(.bordered)
                }
                }.padding(16).background(SeePalette.surface,in:RoundedRectangle(cornerRadius:16))
                if let id = studio.enhancements.lastCaseID,let item = studio.cases.first(where:{$0.id == id && $0.isActive}) {
                    Divider();Button { workspace.scheduledDestination = .init(kind:.project,recordID:id) } label: { rowLabel("继续上次 · "+item.title,detail:item.demonstration ? "演示事务" : item.stateTitle,symbol:"arrow.uturn.forward") }.buttonStyle(.plain)
                } else if let id = studio.enhancements.lastDraftID,let draft = studio.drafts.first(where:{$0.id == id}) {
                    Divider();Button { do { try studio.use(draft);open(.workroom) } catch { workspace.notify(error.localizedDescription) } } label: { rowLabel("继续上次 · "+draft.title,detail:draft.demonstration ? "演示草稿" : "回到材料核对",symbol:"arrow.uturn.forward") }.buttonStyle(.plain)
                }
                }.tint(.seeAccent)
            }
        }
    }
    private func metric(_ title:String,count:Int,index:Int,symbol:String) -> some View {
        Button { selection = index } label: {
            VStack(alignment:.leading,spacing:5) { Text(count,format:.number).font(.system(.title3,design:.rounded,weight:.semibold)).monospacedDigit();Text(title).font(.caption2).fixedSize(horizontal:false,vertical:true) }
                .frame(maxWidth:.infinity,minHeight:42,alignment:.leading).padding(8).foregroundStyle(SeePalette.ink)
                .background(selection == index ? SeePalette.rose : SeePalette.canvas.opacity(0.35),in:RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(selection == index ? Color.seeAccent.opacity(0.5) : .clear,lineWidth:1))
        }.buttonStyle(.plain).accessibilityAddTraits(selection == index ? .isSelected : [])
    }
    private var communicationCover:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:12) {
                VStack(alignment:.leading,spacing:8) {
                    Text("面对面沟通").font(.system(.title2,design:.rounded,weight:.semibold)).foregroundStyle(SeePalette.ink)
                    Text("看清对方说的话，也能用文字回应。").font(.subheadline).foregroundStyle(SeePalette.secondary).fixedSize(horizontal:false,vertical:true)
                }.frame(maxWidth:.infinity,alignment:.leading)
                if !textSize.isAccessibilitySize { SeeArtworkView(artwork:.speech,size:76) }
            }
            Button { open(.captions) } label: {
                HStack { Label("打开面对面字幕",systemImage:"captions.bubble");Spacer();Image(systemName:"arrow.right") }
            }.buttonStyle(SeeSecondaryButtonStyle()).accessibilityIdentifier("home.communication")
            Text("打开后点击“开始字幕”，麦克风才会开启。").font(.caption).foregroundStyle(SeePalette.secondary)
        }.modifier(WorkspaceSurface())
    }
    private func hearingShortcut(_ title:String,symbol:String,color:Color,action:@escaping()->Void) -> some View {
        Button(action:action) {
            HStack(spacing:10) {
                Image(systemName:symbol).font(.title3).foregroundStyle(SeePalette.ink).frame(width:38,height:38).background(color,in:RoundedRectangle(cornerRadius:12)).accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(SeePalette.ink).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
            }.frame(maxWidth:.infinity,minHeight:50,alignment:.leading).padding(12).background(SeePalette.surface,in:RoundedRectangle(cornerRadius:16)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func rowLabel(_ title:String,detail:String,symbol:String) -> some View {
        HStack(spacing:12) { Image(systemName:symbol).foregroundStyle(Color.seeAccent).frame(width:30);VStack(alignment:.leading,spacing:5) { Text(title).font(.headline).foregroundStyle(.primary);Text(detail).font(.caption).foregroundStyle(.secondary) };Spacer();Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary) }.padding(.vertical,6)
    }
}
private struct HearingHomeStatus:View {
    @ObservedObject var audio:AudioProbes
    @ObservedObject var hand:HandProbe
    @ObservedObject var bridge:ConnectivityBridge
    let open:(ProbePage)->Void
    @Environment(\.dynamicTypeSize) private var textSize
    private var microphone:String {
        if audio.isScenarioDemo { return "演示中 · 麦克风关闭" }
        if audio.isStarting { return "正在准备收音" }
        switch audio.mode { case .idle:return "未开启";case .sound:return "声音关注中";case .captions:return "字幕收音中" }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("当前状态").font(.subheadline.weight(.semibold)).foregroundStyle(SeePalette.ink)
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing:8)) : AnyLayout(HStackLayout(alignment:.top,spacing:8))
            layout {
                status("麦克风",value:microphone,hint:"查看收音与权限",symbol:audio.mode == .idle ? "mic.slash" : "mic",id:"home.captureStatus") { open(audio.mode == .sound ? .sound : .captions) }
                status("Apple Watch",value:bridge.linkState.title,hint:"查看连接与接收回执",symbol:"applewatch",id:"home.watchStatus") { open(.watch) }
            }
            Button { open(.hand) } label: {
                HStack {
                    Label(hand.isStarting ? "摄像头准备中" : hand.isRunning ? "摄像头已开启" : "摄像头未开启",systemImage:hand.isRunning ? "camera" : "camera.slash")
                    Spacer(minLength:8);Text("挥手检测");Image(systemName:"chevron.right")
                }.font(.caption).foregroundStyle(SeePalette.secondary).frame(minHeight:44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("home.cameraStatus")
        }.padding(14).background(SeePalette.surface,in:RoundedRectangle(cornerRadius:18))
    }
    private func status(_ title:String,value:String,hint:String,symbol:String,id:String,action:@escaping()->Void) -> some View {
        Button(action:action) {
            VStack(alignment:.leading,spacing:5) {
                Label(title,systemImage:symbol).font(.caption).foregroundStyle(SeePalette.secondary)
                Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(SeePalette.ink).fixedSize(horizontal:false,vertical:true)
                Text(hint).font(.caption2).foregroundStyle(Color.seeAccent)
            }.frame(maxWidth:.infinity,minHeight:62,alignment:.leading).padding(10).background(SeePalette.canvas.opacity(0.45),in:RoundedRectangle(cornerRadius:12)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children:.combine).accessibilityIdentifier(id)
    }
}

struct OriginalTextComparePage:View {
    let evidence:WorkroomVisualEvidence
    var checkedText:String? = nil
    var initialQuote:String? = nil
    var editingText:Binding<String>? = nil
    var onDone:(()->Void)? = nil
    @State private var workingText = ""
    @State private var initializedEditor = false
    @State private var selected:UUID?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    var body:some View {
        GeometryReader { geometry in
            let wide = sizeClass == .regular && geometry.size.width >= 820 && !typeSize.isAccessibilitySize
            ScrollViewReader { proxy in
                Group {
                    if wide {
                        HStack(alignment:.top,spacing:18) {
                            ScrollView { imagePanel(height:max(120,min(600,geometry.size.height-220)),proxy:proxy) }.frame(maxWidth:.infinity).accessibilityIdentifier("compare.imageColumn")
                            ScrollView { textPanel(proxy:proxy,wide:true) }.frame(maxWidth:.infinity).accessibilityIdentifier("compare.textColumn")
                        }.padding(18)
                    } else {
                        ScrollView { VStack(alignment:.leading,spacing:18) { imagePanel(height:320,proxy:proxy);textPanel(proxy:proxy,wide:false) }.padding(18) }
                    }
                }.background(SeePalette.canvas)
            }
        }.onAppear {
            if !initializedEditor { workingText = editingText?.wrappedValue ?? checkedText ?? evidence.originalText;initializedEditor = true }
            if selected == nil,let quote = initialQuote { selected = evidence.regions.first(where:{quote.contains($0.text) || $0.text.contains(quote)})?.id }
        }.onDisappear { if initializedEditor { editingText?.wrappedValue = workingText } }
        .toolbar { if let onDone { Button("返回核对") { editingText?.wrappedValue = workingText;onDone() } } }.seePageCanvas().navigationTitle("原图对照").modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
    }
    private func imagePanel(height:CGFloat,proxy:ScrollViewProxy) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Label("看原图，也看清文字",systemImage:"rectangle.split.2x1").font(.title2.bold())
            Text("可缩放和拖动图片。点击识字行，会标出对应位置；框选位置不代表文字已经正确。").font(.caption).foregroundStyle(.secondary)
            if let image = UIImage(data:evidence.image) { EvidenceZoomCanvas(image:image,region:evidence.regions.first { $0.id == selected }).frame(height:height) }
            if let row = evidence.regions.first(where:{$0.id == selected}) { Text("选中："+row.text).font(.subheadline).foregroundStyle(Color.seeAccent);Button("回到选中的识字行") { proxy.scrollTo(row.id,anchor:.center) }.accessibilityIdentifier("compare.returnToLine") }
        }.modifier(WorkspaceSurface()).id("original-image")
    }
    private func textPanel(proxy:ScrollViewProxy,wide:Bool) -> some View {
        VStack(alignment:.leading,spacing:16) {
            if editingText != nil {
                VStack(alignment:.leading,spacing:10) { Text("核对后的文字").font(.headline);ComparisonTextEditor(text:$workingText).frame(height:240);Text("\(workingText.count) / 12000 字").font(.caption).foregroundStyle(.secondary);Text("这里的修改会带回文字工作室，原始识字行保留用于对照。").font(.caption).foregroundStyle(.secondary) }.modifier(WorkspaceSurface())
            } else if let checkedText,checkedText != evidence.originalText { DisclosureGroup("查看编辑后的材料文字") { Text(checkedText).textSelection(.enabled) }.modifier(WorkspaceSurface()) }
            VStack(alignment:.leading,spacing:10) {
                Text("原始识字行 · \(evidence.regions.count)").font(.headline)
                Text("分区与对比度复核在本机执行。多栏、表格和手写文字仍需检查阅读顺序；置信度不是正确率。").font(.caption).foregroundStyle(.secondary)
                ForEach(evidence.regions) { row in
                    Button { selected = row.id;if !wide { proxy.scrollTo("original-image",anchor:.top) } } label: {
                        HStack(alignment:.top) { Image(systemName:selected == row.id ? "viewfinder.circle.fill" : "viewfinder.circle");Text(row.text).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true) }.padding(12).foregroundStyle(selected == row.id ? Color.seeAccent : .primary).background(selected == row.id ? Color.seeAccent.opacity(0.08) : .clear,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).id(row.id).accessibilityIdentifier("compare.line."+row.id.uuidString)
                    if let confidence = row.confidence,confidence < 0.65 { Label("建议重点核对这一行",systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                    if let alternatives = row.alternatives,!alternatives.isEmpty { DisclosureGroup("其他识字候选") { ForEach(alternatives,id:\.self) { Text($0).font(.caption).textSelection(.enabled) };Text("候选仅供参考，不会自动改写材料。").font(.caption).foregroundStyle(.secondary) } }
                }
            }.modifier(WorkspaceSurface())
        }
    }
}
// Keep the native selection while the surrounding OCR layout and keyboard change.
// Reassigning an unchanged text value can move the caret during continuous input.
private struct ComparisonTextEditor:UIViewRepresentable {
    @Binding var text:String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle:.body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label;view.backgroundColor = .clear
        view.accessibilityLabel = "核对后的材料文字";view.accessibilityIdentifier = "compare.editor"
        view.text = text
        let toolbar = UIToolbar();toolbar.sizeToFit()
        let done = UIBarButtonItem(title:"收起键盘",style:.done,target:context.coordinator,action:#selector(Coordinator.closeKeyboard))
        done.accessibilityIdentifier = "keyboard.dismiss"
        toolbar.items = [UIBarButtonItem(systemItem:.flexibleSpace),done]
        view.inputAccessoryView = toolbar;context.coordinator.view = view
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) {
        context.coordinator.parent = self
        guard view.markedTextRange == nil,view.text != text else { return }
        let selected = view.selectedRange
        view.text = text
        let length = (text as NSString).length
        let location = min(selected.location,length)
        view.selectedRange = NSRange(location:location,length:min(selected.length,length-location))
    }
    final class Coordinator:NSObject,UITextViewDelegate {
        var parent:ComparisonTextEditor
        weak var view:UITextView?
        init(_ parent:ComparisonTextEditor) { self.parent = parent }
        func textViewDidChange(_ textView:UITextView) {
            // Leave composition untouched; its final text is delivered by the delegate.
            parent.text = textView.text
        }
        @objc func closeKeyboard() { view?.resignFirstResponder() }
    }
}
struct SavedOriginalPage:View {
    @ObservedObject var studio:WorkroomService
    let visualID:UUID?
    let text:String
    @State private var evidence:WorkroomVisualEvidence?
    @State private var busy = true
    @State private var deleting = false
    @State private var deleteFailed = false
    @State private var message = "这份材料没有保留原图，或原图来自另一台设备。文字和来源摘录仍可查看。"
    var body:some View {
        Group {
            if let evidence { OriginalTextComparePage(evidence:evidence,checkedText:text)
                .toolbar { Button("删除保留原图",systemImage:"trash") { deleting = true } }
                .confirmationDialog("删除本机这张保留原图？引用它的材料文字和事务记录会保留。",isPresented:$deleting,titleVisibility:.visible) { Button("删除原图",role:.destructive) { do { try studio.forgetOriginal(evidence.id);self.evidence = nil;message = "本机保留原图已删除，材料文字保留。" } catch { message = error.localizedDescription;deleteFailed = true } } }
                .alert("删除未完成",isPresented:$deleteFailed) { Button("知道了",role:.cancel) {} } message: { Text(message) }
            }
            else if busy { ProgressView("读取本机原图…") }
            else { FeatureMessage(title:"原图当前不可用",detail:message,symbol:"photo").padding() }
        }.task { do { evidence = try studio.visual(for:visualID) } catch { message = error.localizedDescription };busy = false }
    }
}
struct LocatedSearchDocumentPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @ObservedObject var conversations:ConversationArchiveService
    let hit:GlobalSearchHit
    let query:String
    private var sections:[SearchDocumentSection] { SearchDocumentBuilder.sections(hit:hit,drafts:studio.drafts,cases:studio.cases,conversations:conversations.items) }
    var body:some View {
        ScrollViewReader { proxy in
            let matches = sections.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) }
            List {
                Section {
                    Label("\(matches.count) 处命中",systemImage:"text.magnifyingglass").font(.headline)
                    Text("已滚动到第一处命中，长段落显示关键词附近文字；展开可看完整段落。").font(.caption).foregroundStyle(.secondary)
                    if matches.count > 1 { Menu("跳到其他命中") { ForEach(matches) { section in Button(section.title) { proxy.scrollTo(section.id,anchor:.center) } } } }
                }.id("start")
                ForEach(sections) { section in
                    let isMatch = matches.contains(where:{$0.id == section.id})
                    Section(section.title) {
                        let excerpt = GlobalSearchHit(recordID:hit.recordID,kind:hit.kind,title:section.title,detail:section.text,demonstration:hit.demonstration).excerpt(for:query)
                        Text(highlight(isMatch ? excerpt : String(section.text.prefix(200)),query:query)).textSelection(.enabled)
                        if section.text.count > (isMatch ? excerpt.count : 200) { DisclosureGroup("完整段落") { Text(highlight(section.text,query:query)).textSelection(.enabled) } }
                    }.id(section.id).listRowBackground(isMatch ? Color.seeAccent.opacity(0.07) : SeePalette.surface)
                }
                if sections.isEmpty { FeatureMessage(title:"记录已变化",detail:"返回搜索页刷新结果，再选择当前记录。",symbol:"doc.badge.clock") }
            }.task(id:query) { await Task.yield();if let first = matches.first { proxy.scrollTo(first.id,anchor:.center) } }
        }.seePageCanvas().navigationTitle(hit.title).modifier(WorkroomPrivacy())
    }
}
struct WatchConnectionPanel:View {
    @ObservedObject var bridge:ConnectivityBridge
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Label(bridge.linkState.title,systemImage:bridge.linkState == .ready ? "applewatch.radiowaves.left.and.right" : "applewatch.slash").font(.headline).foregroundStyle(Color.seeAccent)
            Text(bridge.linkState.guidance).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            LabeledContent("摘要操作",value:bridge.agendaSending ? "等待对端回执" : bridge.agendaDelivery.title).font(.caption)
            Text(bridge.agendaStatus).font(.caption).foregroundStyle(.secondary)
            Button("激活并刷新连接",systemImage:"arrow.clockwise") { bridge.activate();bridge.refresh() }.buttonStyle(.bordered)
        }
    }
}
