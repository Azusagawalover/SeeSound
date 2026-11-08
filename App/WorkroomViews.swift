import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct WorkroomPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var studio: WorkroomService
    @ObservedObject var api: IntelligenceService
    @ObservedObject var importer: WorkroomImporter
    @State private var preparedImport:ImportPayload?
    @State private var comparingOriginal:WorkroomVisualEvidence?
    @State private var showFieldChanges = false
    @State private var autosaveTask:Task<Void,Never>?
    @State private var stage: WorkroomStage = .importing
    @State private var title = ""
    @State private var text = ""
    @State private var selected = Set<UUID>()
    @State private var consent = false
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var photoTask: Task<Void,Never>?
    @State private var importText: String?
    @State private var retainImportImage = false
    @State private var importIsDemo = false
    @State private var importExampleGroup:UUID?
    @State private var importTitle = "导入材料"
    @State private var result: InsightResult?
    @State private var source: InsightRequest?
    @State private var previous: InsightResult?
    @State private var configuration = false
    @State private var error: String?
    @State private var card: InformationCard?
    @State private var routine: RoutineItem?
    @State private var needsDate = false
    @State private var question: InsightQuestion?
    @State private var answer = ""
    @State private var prepared: PreparedCaseDraft?
    @State private var acknowledged = false
    @State private var saveCaseLocally = false
    @State private var receivedImportResult:String?
    @State private var receivedImportID:UUID?
    @State private var createdCaseID: UUID?
    @State private var observedID: UUID?
    @State private var observedRevision = 0
    @State private var observedTitle = ""
    @Environment(\.scenePhase) private var phase
    private var dirty: Bool { title != studio.active.title || text != studio.active.text }
    private var materialReady: Bool { (try? studio.active.validate()) != nil }
    private var request: InsightRequest { InsightRequest(turns: studio.active.fragments.filter { selected.contains($0.id) }, includeCasePlan: true) }
    private var resultMatches: Bool { !dirty && source?.turns == request.turns }
    var body: some View {
        List {
            Section {
                WorkroomStageBar(current:stage,canOpen:canOpen,open:open)
                SeeHero(title:stage.heading,detail:"第 \(stage.rawValue+1) 步 / 4 · 保留原文，逐步核对。",artwork:stage == .importing ? .folder : stage == .reviewing ? .search : stage == .organizing ? .memo : .clipboard)
                if let error { Text(error).foregroundStyle(.red) }
                if let error = studio.error { Text(error).foregroundStyle(.red) }
            }
            if stage == .importing && importText == nil { ProductToolsSection(workspace:workspace) }
            switch stage {
            case .importing: importSections
            case .reviewing: reviewSections
            case .organizing: organizeSections
            case .preparing: preparationSections
            }
        }.seePageCanvas().navigationTitle("文字工作室").modifier(KeyboardCloseToolbar())
            .safeAreaInset(edge:.bottom) { footer }
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Menu {
                NavigationLink("草稿箱") { WorkroomDraftsPage(studio:studio) }
                NavigationLink("事务清单") { WorkroomCasesPage(workspace:workspace,studio:studio,cards:workspace.information,routines:workspace.routines) }
                NavigationLink("原文修改对照") { WorkroomVersionsPage(studio:studio) }
                NavigationLink("双语沟通") { BilingualPage(workspace:workspace,api:workspace.translationAPI) }
                NavigationLink("全局搜索") { GlobalSearchPage(workspace:workspace,studio:studio,cards:workspace.information,routines:workspace.routines,conversations:workspace.conversations) }
            } label: { Label("其他工具",systemImage:"ellipsis.circle") } } }
            .onAppear {
                workspace.stopCapture()
                let first = observedID == nil
                if observedID != studio.active.id || observedRevision != studio.active.revision || observedTitle != studio.active.title {
                    invalidate();synchronize()
                }
                if first && materialReady { stage = .reviewing }
                if let pending = workspace.pendingExampleImport {
                    workspace.pendingExampleImport = nil;importExampleGroup = pending.group;importTitle = pending.title;stage = .importing;importer.load(image:pending.image)
                }
                #if DEBUG
                if let index=ProcessInfo.processInfo.arguments.firstIndex(of:"--workroom-stage"), ProcessInfo.processInfo.arguments.indices.contains(index+1),
                   let value=Int(ProcessInfo.processInfo.arguments[index+1]),let target=WorkroomStage(rawValue:value),first {
                    if target == .preparing { prepare() } else if canOpen(target) { stage=target }
                }
                if first,ProcessInfo.processInfo.arguments.contains("--original-fixture"),
                   let url = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first?.appendingPathComponent("OriginalFixture.png"),
                   let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= 20*1024*1024,let bytes = try? Data(contentsOf:url) {
                    importTitle = "演示 · 原图对照";stage = .importing;importer.load(image:bytes)
                }
                #endif
            }
            .onChange(of:studio.active) { old,new in invalidate(); synchronize(); if old.id != new.id { stage = .reviewing } }
            .onChange(of:text) { _,_ in if dirty { invalidate();scheduleProtection() } }
            .onChange(of:title) { _,_ in if dirty { invalidate();scheduleProtection() } }
            .onChange(of:stage) { _,value in if studio.drafts.contains(where:{$0.id == studio.active.id}) { perform { try studio.updateEnhancements { $0.lastDraftID = studio.active.id;$0.lastStage = value.rawValue } } } }
            .onChange(of:prepared) { _,_ in acknowledged = false }
            .onReceive(importer.$result) { value in
                // Reattaching a CurrentValuePublisher after closing the comparison
                // must not overwrite edits with the unchanged original OCR result.
                guard value != receivedImportResult || importer.resultID != receivedImportID else { return }
                receivedImportResult = value;receivedImportID = importer.resultID;importText = value
                if value != nil { importIsDemo = importExampleGroup != nil;retainImportImage = false }
            }
            .onReceive(api.$result) { value in
                if let value, let snapshot = api.source, snapshot.turns.allSatisfy({ studio.active.fragments.contains($0) }), !dirty {
                    result = value; source = snapshot
                }
            }
            .onChange(of:photo) { _,item in
                photoTask?.cancel(); photoTask = Task {
                    do { if let data = try await item?.loadTransferable(type:Data.self), !Task.isCancelled { importExampleGroup = nil;importTitle = "图片识字材料"; preparedImport = ImportPayload(data:data,pdf:false) } }
                    catch { self.error = error.localizedDescription }
                }
            }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.image,.plainText,.pdf]) { value in
                switch value {
                case .success(let url):
                    importExampleGroup = nil;importTitle = String(url.deletingPathExtension().lastPathComponent.prefix(60))
                    if url.pathExtension.lowercased() == "pdf" || UTType(filenameExtension:url.pathExtension)?.conforms(to:.image) == true {
                        perform { let access = url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } };guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 20*1024*1024 else { throw WorkroomError.tooLarge };preparedImport = ImportPayload(data:try Data(contentsOf:url),pdf:url.pathExtension.lowercased() == "pdf") }
                    } else { importer.load(file:url) }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            .fullScreenCover(item:$comparingOriginal) { evidence in
                NavigationStack {
                    OriginalTextComparePage(evidence:evidence,checkedText:importText ?? text,editingText:Binding(get:{importText ?? text},set:{ value in
                        if importer.visual?.id == evidence.id { importText = value }
                        else if studio.activeVisual?.id == evidence.id { text = value }
                        else { error = "材料已切换或导入已取消，本次修改没有覆盖其他材料。" }
                    }),onDone:{ comparingOriginal = nil })
                }
            }
            .sheet(item:$preparedImport) { payload in ImportPreparationView(payload:payload,acceptImage:{ importer.load(image:$0) },acceptPDF:{ importer.load(pdf:$0,pages:$1) }) }
            .sheet(isPresented:$showFieldChanges) { NavigationStack { Form { ForEach(KeyFieldReview.changed(old:studio.active.text,new:text),id:\.self) { Text($0) };Text("只更新原文。已有信息卡、事务和提醒不会跟随自动改约。请到对应记录核对后修改。").font(.caption);Button("确认原文变更，继续整理") { perform { try studio.edit(title:title,text:text);stage = .organizing;showFieldChanges = false } } }.seePageCanvas().navigationTitle("关键字段变更").toolbar { Button("返回检查") { showFieldChanges = false } }.modifier(WorkroomPrivacy()) } }
            .sheet(isPresented:$configuration) { IntelligenceConfiguration(service:api,onConfigure:workspace.configureIntelligence) }
            .sheet(item:$card) { InformationCardEditor(service:workspace.information,initial:$0,requiresDateChoice:needsDate) }
            .sheet(item:$routine) { RoutineEditor(service:workspace.routines,initial:$0) }
            .sheet(item:$question) { item in
                NavigationStack {
                    Form {
                        Text(item.question); Text("原文："+item.quote).foregroundStyle(.secondary)
                        TextField("你核对后的答案（最多 300 字）",text:$answer,axis:.vertical)
                        Button("补充到原文，返回核对") { perform { try studio.answer(item,text:answer); question = nil; stage = .reviewing } }
                        Text("补充会形成原文新版本。下一次发送前需要重新检查、同意，不会自动请求 AI。").font(.caption).foregroundStyle(.secondary)
                        if let error { Text(error).foregroundStyle(.red) }
                    }.seePageCanvas().navigationTitle("补充信息").toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { question = nil } } }
                        .modifier(WorkroomPrivacy())
                }
            }
            .onDisappear { protectNow();autosaveTask?.cancel();api.cancel(); importer.cancel(); photoTask?.cancel(); consent = false }
            .onChange(of:phase) { _,value in if value != .active { protectNow();autosaveTask?.cancel();api.cancel(); importer.cancel(); photoTask?.cancel(); consent = false } }
            .overlay { if phase != .active { DailyPrivacyCover() } }
    }
    @ViewBuilder private var importSections: some View {
        if importText == nil { Section {
            Text("图片、TXT 和 PDF 先在本机读取。先核对原文，再选择是否联网整理。").foregroundStyle(.secondary)
            PhotosPicker(selection:$photo,matching:.images) { Label("从照片选择截图",systemImage:"photo") }.disabled(importer.isBusy)
            Button("从文件导入图片、TXT 或 PDF",systemImage:"doc.badge.plus") { importing = true }.disabled(importer.isBusy)
            Button("没有文件，直接输入文字",systemImage:"square.and.pencil") { stage = .reviewing }
            Button("用读书会演示材料体验",systemImage:"play.rectangle") { perform { protectNow();try studio.use(.demonstrationDraft()); stage = .reviewing } }
            Text(importer.status).font(.caption).foregroundStyle(.secondary)
            if let failure = importer.failure { FeatureMessage(title:"材料暂未读入",detail:failure,actionTitle:"重新读取",action:{importer.retry()}) }
            if importer.isBusy { ProgressView("本机读取中"); Button("取消读取") { importer.cancel() } }
        } }
        if importText != nil {
            Section("识字结果 · 先预览") {
                Text(importer.status).font(.caption).foregroundStyle(.secondary)
                TextField("材料标题",text:$importTitle)
                TextEditor(text:Binding(get:{importText ?? ""},set:{importText=$0})).frame(height:280)
                if let visual = importer.visual {
                    Button("原图与识字逐行对照",systemImage:"rectangle.split.2x1") { comparingOriginal = visual }
                    Toggle("保存草稿时一并保留原图",isOn:$retainImportImage)
                    Text("原图随已存材料保存在本机；未保存材料只在本次查看。密码备份不包含原图。").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("这份材料只用于演示",isOn:$importIsDemo).disabled(importExampleGroup != nil)
Text("检查后，点击底部“使用文字，进入核对”继续。").font(.caption).foregroundStyle(.secondary)
                Button("先保存到待整理收件箱",systemImage:"tray.and.arrow.down") { perform { var draft = WorkroomDraft();draft.title = importTitle;draft.text = importText ?? "";draft.origin = importIsDemo ? .demonstration : importer.origin;draft.exampleGroup = importExampleGroup;draft.visualID = retainImportImage ? importer.visual?.id : nil;try studio.addToInbox(draft,visual:importer.visual);importer.cancel();importText = nil;workspace.notify("已存入本机收件箱") } }
                Button("丢弃读取结果",role:.destructive) { importer.cancel();importText=nil }
            }
        }
        Section {
            if let id = studio.enhancements.lastDraftID,let draft = studio.drafts.first(where:{$0.id == id}) {
                Button("继续上次："+draft.title,systemImage:"arrow.uturn.forward") { perform { try studio.use(draft);stage = studio.enhancements.lastStage >= 2 ? .organizing : .reviewing } }
            }
            NavigationLink("从已存草稿继续") { WorkroomDraftsPage(studio:studio) }
            Text("新材料会替换当前编辑区。需要保留旧材料时，请先到“核对”步骤保存草稿。原图片不长期保存，也不会直接上传。").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var reviewSections: some View {
        Section("原文 · 第 \(studio.active.revision) 版") {
            TextField("材料标题（最多 60 字）",text:$title)
            TextEditor(text:$text).frame(height:300).accessibilityLabel("材料原文")
            HStack { Text(studio.active.origin.informationSource);Spacer();Text("\(text.count) / 12000") }.font(.caption).foregroundStyle(.secondary)
            Text("重点查看姓名、时间、金额和地点。这里检查原文，不会替你给信息卡标记“已核对”。").font(.footnote).foregroundStyle(.secondary)
        }
        if let visual = studio.activeVisual { Section { Button("原图与识字逐行对照",systemImage:"rectangle.split.2x1") { comparingOriginal = visual } } }
        if let warning = studio.visualWarning { Section { FeatureMessage(title:"文字可继续使用",detail:warning,symbol:"photo") } }
        KeyFieldsPanel(text:text)
        Section("草稿保护 · 自愿开启") {
            Toggle("自动保护编辑中的文字到本机",isOn:Binding(get:{ studio.enhancements.autosave },set:{ value in perform { try studio.updateEnhancements { $0.autosave = value };if value { scheduleProtection() } else { autosaveTask?.cancel() } } }))
            Text("开启后，输入停顿 1 秒及离开页面时会更新草稿副本；关闭后不再自动保存，已有副本可在草稿箱删除。不会保存原图或发起网络请求。").font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Button("主动保存到草稿箱",systemImage:"tray.and.arrow.down") { perform {
                if dirty { try studio.edit(title:title,text:text) };try studio.saveDraft();workspace.notify("已保存原文及版本历史，未请求 AI")
            } }.disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            if !studio.active.history.isEmpty { NavigationLink("查看原文修改对照") { WorkroomVersionsPage(studio:studio) } }
        }
    }
    @ViewBuilder private var organizeSections: some View {
        Section("处理范围 · 已选 \(selected.count) / \(studio.active.fragments.count) 段") {
            ForEach(Array(studio.active.fragments.enumerated()),id:\.element.id) { index,turn in
                Button {
                    invalidate();if selected.contains(turn.id) { selected.remove(turn.id) } else if selected.count < 6 { selected.insert(turn.id) }
                } label: {
                    HStack(alignment:.top) {
                        Image(systemName:selected.contains(turn.id) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment:.leading,spacing:6) { Text("第 \(index+1) 段 · \(turn.text.count) 字").font(.caption);Text(turn.text).foregroundStyle(.primary) }
                    }
                }.disabled(api.isBusy)
            }
            Text("仅处理选中的最多六段，每段最多 500 字。生成信息候选和事务建议只需一次请求。").font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Button("离线整理与准备建议",systemImage:"iphone") { perform {
                api.cancel();previous=result ?? previous;prepared=nil;source=request;result=try LocalTextOrganizer.organize(request);consent=false
            } }.disabled(selected.isEmpty || api.isBusy).accessibilityIdentifier("workroom.offline")
            DisclosureGroup("使用 DeepSeek 获取更完整建议") {
                Button("服务配置") { configuration=true }
                Toggle("同意把选中原文发送到 DeepSeek",isOn:$consent).disabled(api.isBusy)
                Button("发送并生成信息、材料和步骤建议",systemImage:"sparkles") { previous=result ?? previous;result=nil;prepared=nil;source=request;api.organize(request) }.disabled(!consent || selected.isEmpty || api.isBusy)
                Text("不发送原图或未选段落；会使用 API 额度，失败不自动重试。").font(.caption).foregroundStyle(.secondary)
            }
            if api.isBusy { ProgressView("正在整理");Button("取消请求") { api.cancel() } }
            Text(api.status).font(.caption).foregroundStyle(.secondary)
        }
        if let result,resultMatches,let source {
            Section("\(result.assistantTitle) · 信息候选") {
                Text(result.summary)
                ForEach(result.candidates) { candidate in
                    DisclosureGroup(candidate.kind.title+"："+candidate.value) {
                        Text("原文："+candidate.quote).foregroundStyle(.secondary)
                        if candidate.kind == .time && candidate.date == nil { Text("日期尚未确定，编辑时需要手动选择。").font(.caption).foregroundStyle(.orange) }
                        Button(candidate.kind == .task ? "编辑为待办" : "编辑为核对卡") { perform {
                            if candidate.kind == .task { routine=try candidate.makeRoutine(request:source,assistant:result.assistantTitle) }
                            else { needsDate=candidate.kind == .time && candidate.date == nil;card=try candidate.makeCard(request:source,assistant:result.assistantTitle) }
                        } }
                    }
                }
                Text("这些卡片可按需单独编辑。下一步将预览事务的材料和步骤，不会自动保存卡片或完成待办。").font(.caption).foregroundStyle(.secondary)
            }
            let questions=result.questions ?? LocalTextOrganizer.questions(request:source,candidates:result.candidates)
            if !questions.isEmpty { Section("还需要问清楚") { ForEach(questions) { item in
                VStack(alignment:.leading,spacing:8) { Text(item.question).font(.headline);Text("依据："+item.quote).font(.caption).foregroundStyle(.secondary);Button("补充答案") { question=item;answer="" } }
            } } }
        }
        if let previous { Section { DisclosureGroup("上次建议 · 仅供对照") {
            ForEach(Array(previous.candidates.enumerated()),id:\.offset) { _,item in Text(item.kind.title+"："+item.value).foregroundStyle(.secondary) }
            Text("原文或范围改变后，旧建议不能采用。").font(.caption).foregroundStyle(.secondary)
        } } }
    }
    @ViewBuilder private var preparationSections: some View {
        if let id=createdCaseID,let item=studio.cases.first(where:{$0.id==id}) {
            Section {
                Label("事务已建立",systemImage:"checkmark.circle.fill").font(.title2).foregroundStyle(Color.seeAccent)
                Text(item.title).font(.headline)
                Text("\(item.materials.count) 项材料，\(item.steps.count) 个步骤；均从待处理开始。").foregroundStyle(.secondary)
                Text(studio.savedCaseIDs.contains(id) ? "已按你的选择保存在本机。" : "仅本次运行；可在事务详情里主动保存。").font(.caption)
                NavigationLink("打开事务，开始逐项处理") { WorkroomCaseDetail(workspace:workspace,studio:studio,cards:workspace.information,routines:workspace.routines,itemID:id) }.buttonStyle(.borderedProminent).tint(SeePalette.button).accessibilityIdentifier("workroom.openCreated")
            }
        } else if let initial=prepared,initial.isFresh(studio.active),!dirty {
            PreparedCaseReviewSections(review:Binding(get:{prepared ?? initial},set:{prepared=$0}),acknowledged:$acknowledged,saveLocally:$saveCaseLocally)
        } else {
            ContentUnavailableView("请按当前原文重新准备",systemImage:"arrow.clockwise",description:Text("原文、版本或选择范围改变后，旧草稿不能建立事务。"))
        }
    }
    private var footer: some View {
        HStack(spacing:12) {
            if stage != .importing { Button("上一步") { open(WorkroomStage(rawValue:stage.rawValue-1)!) }.buttonStyle(.bordered) }
            Spacer()
            switch stage {
            case .importing:
                if importText != nil {
                    Button("使用文字，进入核对",action:acceptImport).buttonStyle(.borderedProminent).tint(SeePalette.button).disabled(importer.isBusy).accessibilityIdentifier("workroom.acceptImport")
                } else {
                    Button(materialReady ? "继续当前材料" : "直接输入文字") { stage = .reviewing }.buttonStyle(.borderedProminent).tint(SeePalette.button)
                }
            case .reviewing:
                Button("已检查，下一步") { perform { if dirty && !KeyFieldReview.changed(old:studio.active.text,new:text).isEmpty { showFieldChanges = true } else { if dirty { try studio.edit(title:title,text:text) };try studio.active.validate();stage = .organizing } } }.buttonStyle(.borderedProminent).tint(SeePalette.button).accessibilityIdentifier("workroom.reviewNext").disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            case .organizing:
                Button("预览事务草稿",systemImage:"checklist") { prepare() }.buttonStyle(.borderedProminent).tint(SeePalette.button).accessibilityIdentifier("workroom.prepare").disabled(selected.isEmpty || api.isBusy || dirty)
            case .preparing:
                if createdCaseID == nil {
                    Button("确认建立事务") { perform { guard let prepared else { throw WorkroomError.stale };createdCaseID=try studio.createPreparedCase(prepared,confirmed:acknowledged,saveLocally:saveCaseLocally) } }
                        .buttonStyle(.borderedProminent).tint(SeePalette.button).accessibilityIdentifier("workroom.create").disabled(!acknowledged || prepared?.isFresh(studio.active) != true || prepared?.items.contains(where:{$0.selected}) != true || dirty)
                } else { Button("返回材料") { stage = .reviewing }.buttonStyle(.borderedProminent).tint(SeePalette.button) }
            }
        }.font(.subheadline).padding(.horizontal,16).padding(.vertical,12).background(SeePalette.surface)
    }
    private func scheduleProtection() {
        autosaveTask?.cancel();guard studio.enhancements.autosave else { return }
        autosaveTask = Task { do { try await Task.sleep(nanoseconds:1_000_000_000);guard !Task.isCancelled else { return };protectNow() } catch {} }
    }
    private func protectNow() {
        guard dirty,studio.enhancements.autosave else { return };perform { try studio.protectDraft(title:title,text:text,stage:stage.rawValue) }
    }
    private func canOpen(_ candidate:WorkroomStage)->Bool {
        if candidate == .importing || candidate == .reviewing { return true }
        if candidate == .organizing { return materialReady && !dirty }
        return materialReady && !dirty && !selected.isEmpty && !api.isBusy
    }
    private func open(_ candidate:WorkroomStage) {
        guard canOpen(candidate) else { return }
        if candidate == .preparing { prepare();return }
        if api.isBusy { api.cancel();consent=false };stage=candidate
    }
    private func acceptImport() {
        perform {
            var draft=WorkroomDraft();draft.title=importTitle;draft.text=importText ?? "";draft.origin=importIsDemo ? .demonstration : importer.origin;draft.exampleGroup = importExampleGroup
            protectNow();try studio.use(draft);try studio.stageVisual(importer.visual,retain:retainImportImage);importText=nil;importer.cancel();stage = .reviewing
        }
    }
    private func prepare() {
        perform {
            if let prepared,prepared.isFresh(studio.active) { stage = .preparing;return }
            let snapshot=resultMatches ? (source ?? request) : request
            let plan:CasePlan;let generator:String
            if resultMatches,let result,let proposed=result.casePlan { plan=proposed;generator=result.assistantTitle }
            else { plan=try LocalCasePlanner.propose(snapshot);generator="本地规则" }
            prepared=try PreparedCaseDraft(draft:studio.active,request:snapshot,plan:plan,generator:generator)
            acknowledged=false;saveCaseLocally=false;createdCaseID=nil;stage = .preparing
        }
    }
    private func synchronize() { title=studio.active.title;text=studio.active.text;selected=Set(studio.active.fragments.prefix(6).map(\.id));observedID=studio.active.id;observedRevision=studio.active.revision;observedTitle=studio.active.title }
    private func invalidate() { previous=result ?? previous;result=nil;source=nil;prepared=nil;createdCaseID=nil;api.cancel();consent=false;card=nil;routine=nil;acknowledged=false }
    private func perform(_ operation:() throws -> Void) { do { try operation();error=nil } catch { self.error=error.localizedDescription } }
}

struct WorkroomDraftsPage: View {
    @ObservedObject var studio: WorkroomService
    @State private var query = ""
    @State private var deleting: WorkroomDraft?
    @State private var error: String?
    @State private var reset = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section { Text("主动保存的材料及最多六版原文历史保存在本机，不保留图片或 AI 返回结果。打开草稿不发送请求。").font(.footnote).foregroundStyle(.secondary) }
            if let message = studio.error { Text(message).foregroundStyle(.red); Button("清除工作室本地文件并重置", role: .destructive) { reset = true } }
            if studio.drafts.isEmpty { ContentUnavailableView("草稿箱是空的", systemImage: "tray", description: Text("在文字工作室里主动保存一份材料。")) }
            ForEach(studio.drafts.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }) { draft in
                VStack(alignment: .leading, spacing: 8) {
                    Button { do { try studio.use(draft); dismiss() } catch { self.error = error.localizedDescription } } label: {
                        VStack(alignment: .leading, spacing: 6) { Text(draft.title).font(.headline); Text(draft.origin.informationSource + " · 第 \(draft.revision) 版").font(.caption); Text(draft.text).lineLimit(2).foregroundStyle(.secondary) }
                    }
                    HStack { NavigationLink("预览并分享文字") { SharePreviewPage(original:(draft.demonstration ? "【演示材料】\n" : "")+draft.title+"\n"+draft.text) }; Spacer(); Button("删除", role: .destructive) { deleting = draft } }.font(.caption)
                }.padding(.vertical, 5)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("草稿箱").searchable(text: $query, prompt: "搜索已保存材料")
            .confirmationDialog("移到最近删除？草稿及原文历史可以恢复，当前编辑区保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("移到最近删除", role: .destructive) { if let deleting { do { try studio.removeDraft(deleting.id) } catch { self.error = error.localizedDescription } }; deleting = nil }
            }
            .confirmationDialog("这会删除所有已存草稿、原文历史和事务，不删除信息卡或待办。", isPresented: $reset) {
                Button("删除并重置", role: .destructive) { do { try studio.reset() } catch { self.error = error.localizedDescription } }
            }.modifier(WorkroomPrivacy())
    }
}

struct WorkroomVersionsPage: View {
    @ObservedObject var studio: WorkroomService
    @State private var selected: UUID?
    @State private var error: String?
    private var old: TextRevision? { studio.active.history.first { $0.id == selected } ?? studio.active.history.last }
    var body: some View {
        List {
            if let old {
                Picker("旧版", selection: Binding(get: { selected ?? old.id }, set: { selected = $0 })) { ForEach(studio.active.history) { Text("第 \($0.number) 版").tag($0.id) } }
                let difference = TextComparison(old: old.text, new: studio.active.text)
                Section("新增或修改后的行") { if difference.added.isEmpty { Text("没有新增行") }; ForEach(Array(difference.added.enumerated()), id: \.offset) { _, text in Label(text, systemImage: "plus.circle").foregroundStyle(Color.seeAccent) } }
                Section("移除或修改前的行") { if difference.removed.isEmpty { Text("没有移除行") }; ForEach(Array(difference.removed.enumerated()), id: \.offset) { _, text in Label(text, systemImage: "minus.circle").foregroundStyle(.secondary) } }
                Section("完整旧原文 · 仅供对照") { Text(old.text).textSelection(.enabled); Button("将旧原文恢复为一个新版本") { do { try studio.edit(title: studio.active.title, text: old.text) } catch { self.error = error.localizedDescription } } }
            } else { Text("应用一次原文修改后，可在这里比较版本。") }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("原文修改对照").modifier(WorkroomPrivacy())
    }
}

struct WorkroomPrivacy: ViewModifier {
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View { content.overlay { if phase != .active { DailyPrivacyCover() } } }
}
