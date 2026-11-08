import SwiftUI

struct ProductToolsSection: View {
    @ObservedObject var workspace:Workspace
    var body:some View {
        Section {
          DisclosureGroup("资料与事务工具") {
            NavigationLink { InboxPage(workspace:workspace,studio:workspace.workroom) } label: { Label("待整理收件箱",systemImage:"tray") }
            NavigationLink { LibraryOrganizerPage(workspace:workspace,studio:workspace.workroom) } label: { Label("文件夹、标签与批量整理",systemImage:"folder") }
            NavigationLink { CaseCalendarPage(workspace:workspace,studio:workspace.workroom) } label: { Label("事务日历",systemImage:"calendar") }
            NavigationLink { CaseTemplatesPage(studio:workspace.workroom) } label: { Label("事务模板",systemImage:"square.on.square") }
            NavigationLink { RecentlyDeletedPage(studio:workspace.workroom) } label: { Label("最近删除与撤销",systemImage:"trash") }
            NavigationLink { ExampleExperiencePage(workspace:workspace,studio:workspace.workroom) } label: { Label("完整体验",systemImage:"play.rectangle") }
            NavigationLink { LibraryCleanupPage(studio:workspace.workroom) } label: { Label("资料清理",systemImage:"archivebox") }
            NavigationLink { ProductHelpPage() } label: { Label("使用帮助",systemImage:"questionmark.circle") }
          }
        }
    }
}
struct InboxPage: View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @State private var shared:[SharePacket] = []
    @State private var error:String?
    @State private var busy = false
    @State private var text = ""
    @State private var pending:SharePacket?
    @State private var previewText = ""
    @State private var previewIsDemo = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        List {
            Section {
                Label("先收下，再慢慢整理",systemImage:"tray.fill").font(.title2.bold())
                Text("主动加入的文字保存在本机。系统分享的图片只暂存到你处理或删除，不会联网。加入后仍需核对内容。 ").font(.subheadline).foregroundStyle(.secondary)
                Button("刷新共享收件箱",systemImage:"arrow.clockwise",action:reload)
                TextField("记下一段待整理文字",text:$text,axis:.vertical).lineLimit(3...8)
                Button("加入收件箱") { perform { var draft = WorkroomDraft();draft.title = String(text.prefix(30));draft.text = text;try studio.addToInbox(draft);text = "" } }.disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
            if !shared.isEmpty {
                Section("从系统分享收到 · \(shared.count)") {
                    ForEach(shared) { packet in
                        VStack(alignment:.leading,spacing:8) {
                            Label(packet.image == nil ? String(packet.text.prefix(80)) : "待识字图片",systemImage:packet.image == nil ? "text.alignleft" : "photo")
                            Text(packet.createdAt,style:.date).font(.caption)
                            if !packet.text.isEmpty && packet.image != nil { Text("备注："+packet.text).font(.caption).lineLimit(3) }
                            HStack {
                                Button(packet.image == nil ? "保存文字到收件箱" : "本机识字并预览") { read(packet) }.disabled(busy)
                                Spacer();Button("删除",role:.destructive) { perform { try ShareInboxStore().remove(packet.id);reload() } }.disabled(busy)
                            }.font(.caption).buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section("已存待整理材料") {
                let items = studio.drafts.filter { $0.inInbox == true }
                if items.isEmpty { Text("收件箱已整理完。照片和文档可在文字工作室预览后加入。 ").foregroundStyle(.secondary) }
                ForEach(items) { draft in
                    VStack(alignment:.leading,spacing:7) {
                        Text(draft.title).font(.headline);if draft.demonstration { Label("演示材料",systemImage:"play.rectangle").font(.caption).foregroundStyle(Color.seeAccent) };Text(draft.text).lineLimit(3).font(.subheadline).foregroundStyle(.secondary)
                        Button("打开并开始核对") { perform { try studio.openInbox(draft.id);workspace.navigationRequest = .workroom;dismiss() } }
                    }
                }
            }
            if busy { ProgressView("本机识字中…") };if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("待整理收件箱").onAppear(perform:reload).onChange(of:phase) { _,value in if value == .active { reload() } }
            .sheet(item:$pending) { packet in NavigationStack { Form { TextEditor(text:$previewText).frame(height:320);Toggle("这份材料只用于演示",isOn:$previewIsDemo);Text("识字结果需检查后保存。原分享图片在保存成功后删除。").font(.caption);Button("确认文字并保存到收件箱") { perform { var draft = WorkroomDraft();draft.id = packet.id;draft.title = "分享图片识字";draft.text = previewText;draft.origin = previewIsDemo ? .demonstration : .imageText;try studio.addToInbox(draft);try ShareInboxStore().remove(packet.id);pending = nil;previewText = "";reload() } };if let error { Text(error).foregroundStyle(.red) } }.seePageCanvas().navigationTitle("识字预览").toolbar { Button("取消") { pending = nil;previewText = "" } } }.modifier(WorkroomPrivacy()) }
            .modifier(WorkroomPrivacy())
    }
    private func reload() { do { shared = try ShareInboxStore().load();error = nil } catch { self.error = error.localizedDescription } }
    private func read(_ packet:SharePacket) {
        if let image = packet.image {
            busy = true;Task { do { let recognized = try await Task.detached { try WorkroomImport.image(image) }.value;previewText = recognized+(packet.text.isEmpty ? "" : "\n分享备注："+packet.text);previewIsDemo = false;pending = packet } catch { self.error = error.localizedDescription };busy = false }
        } else { perform { var draft = WorkroomDraft();draft.id = packet.id;draft.title = String(packet.text.prefix(30));draft.text = packet.text;try studio.addToInbox(draft);try ShareInboxStore().remove(packet.id);reload() } }
    }
    private func perform(_ action:() throws -> Void) { do { try action();error = nil } catch { self.error = error.localizedDescription } }
}
struct LibraryOrganizerPage: View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @State private var query = ""
    @State private var folder = ""
    @State private var tag = ""
    @State private var selected = Set<String>()
    @State private var editing = false
    var records:[GlobalSearchHit] { WorkroomSearch.hits(query:"",events:workspace.ledger.events,conversations:workspace.conversations.items,cards:workspace.information.cards,routines:workspace.routines.items,drafts:studio.drafts,cases:studio.cases,annotations:workspace.annotations,includeAllWhenEmpty:true,journeys:studio.campus.journeys) }
    private var visible:[GlobalSearchHit] { records.filter { row in let filing = studio.enhancements.filing[row.id] ?? RecordFiling();return (query.isEmpty || row.matches(query) || filing.tags.contains { $0.localizedCaseInsensitiveContains(query) }) && (folder.isEmpty || filing.folder == folder) && (tag.isEmpty || filing.tags.contains(tag)) } }
    var body:some View {
        List {
            Section {
                Picker("文件夹",selection:$folder) { Text("全部文件夹").tag("");ForEach(Array(Set(studio.enhancements.filing.values.map(\.folder).filter { !$0.isEmpty })).sorted(),id:\.self) { Text($0).tag($0) } }
                Picker("标签",selection:$tag) { Text("全部标签").tag("");ForEach(Array(Set(studio.enhancements.filing.values.flatMap(\.tags))).sorted(),id:\.self) { Text($0).tag($0) } }
                HStack { Button("选择当前结果") { selected.formUnion(visible.map(\.id)) };Spacer();Button("清空选择") { selected = [] } }.font(.caption)
                Button("整理已选 \(selected.count) 项",systemImage:"folder.badge.plus") { editing = true }.disabled(selected.isEmpty)
                Text("分类只保存文件夹和标签；临时内容仍需在原页面主动保存。批量设置会替换所选记录的分类。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(visible) { hit in
                HStack(alignment:.top) {
                    Button { if selected.contains(hit.id) { selected.remove(hit.id) } else { selected.insert(hit.id) } } label: { Image(systemName:selected.contains(hit.id) ? "checkmark.circle.fill" : "circle").frame(width:34,height:44) }.buttonStyle(.borderless).accessibilityLabel("选择："+hit.title)
                    NavigationLink { LibraryRecordPage(workspace:workspace,hit:hit,query:query) } label: {
                        VStack(alignment:.leading,spacing:5) { Text(hit.title).font(.headline);Text(hit.kind.rawValue+(hit.demonstration ? " · 演示" : "")).font(.caption);let filing = studio.enhancements.filing[hit.id] ?? RecordFiling();if !filing.folder.isEmpty || !filing.tags.isEmpty { Text(([filing.folder]+filing.tags.map { "#"+$0 }).filter { !$0.isEmpty }.joined(separator:" · ")).font(.caption).foregroundStyle(Color.seeAccent) } }
                    }
                }
            }
            if visible.isEmpty { ContentUnavailableView("没有匹配的资料",systemImage:"folder") }
        }.seePageCanvas().navigationTitle("我的资料").searchable(text:$query,prompt:"搜索标题、内容或标签").sheet(isPresented:$editing) { FilingEditor(studio:studio,keys:selected,titles:Dictionary(uniqueKeysWithValues:records.map { ($0.id,$0.title) })) }.modifier(WorkroomPrivacy())
    }
}
struct FilingEditor:View {
    @ObservedObject var studio:WorkroomService
    let keys:Set<String>
    var titles:[String:String] = [:]
    @State private var folder = ""
    @State private var tags = ""
    @State private var error:String?
    @State private var preview:FilingChangePreview?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack { Form {
            Section("准备整理 \(keys.count) 项资料") {
                TextField("文件夹，留空移出文件夹",text:$folder).accessibilityIdentifier("filing.folder")
                TextField("标签，用中文或英文逗号分隔",text:$tags,axis:.vertical).accessibilityIdentifier("filing.tags")
                Text("文件夹最多 30 字；最多 8 个标签，每个不超过 20 字。确认前会展示影响范围。").font(.caption).foregroundStyle(.secondary)
                Button("预览分类调整") { do {
                    let values = tags.split(whereSeparator:{$0 == "," || $0 == "，"}).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    preview = try studio.previewFiling(keys,filing:.init(folder:folder.trimmingCharacters(in:.whitespacesAndNewlines),tags:Array(Set(values)).sorted()));error = nil
                } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("filing.preview")
            }
            if let preview {
                Section("确认前预览 · \(preview.keys.count) 项") {
                    LabeledContent("新文件夹",value:preview.replacement.folder.isEmpty ? "未分类" : preview.replacement.folder)
                    LabeledContent("新标签",value:preview.replacement.tags.isEmpty ? "无" : preview.replacement.tags.joined(separator:"、"))
                    ForEach(preview.keys.sorted(),id:\.self) { key in
                        let old = preview.previous[key] ?? RecordFiling()
                        VStack(alignment:.leading,spacing:6) { Text(titles[key] ?? "所选资料").font(.headline);Text("之前："+(old.folder.isEmpty ? "未分类" : old.folder)+(old.tags.isEmpty ? "" : " · "+old.tags.joined(separator:"、"))).font(.caption).foregroundStyle(.secondary) }
                    }
                    Button("确认整理 \(preview.keys.count) 项") { do { try studio.applyFilingPreview(preview);dismiss() } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("filing.confirm")
                    Text("本次会替换所选资料的分类。完成后可撤销最近一次调整。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.seePageCanvas().navigationTitle("整理资料").toolbar { Button("取消") { dismiss() } }
            .onAppear { if keys.count == 1,let key = keys.first,let value = studio.enhancements.filing[key] { folder = value.folder;tags = value.tags.joined(separator:"，") } }
            .onChange(of:folder) { _,_ in preview = nil }.onChange(of:tags) { _,_ in preview = nil }
            .modifier(KeyboardCloseToolbar())
        }.modifier(WorkroomPrivacy())
    }
}
struct LibraryRecordPage:View {
    @ObservedObject var workspace:Workspace
    let hit:GlobalSearchHit
    var query = ""
    var body:some View {
        Group { if hit.parentJourneyID != nil { JourneySearchDestination(workspace:workspace,studio:workspace.workroom,hit:hit,query:query) } else if !query.isEmpty { LocatedSearchDocumentPage(workspace:workspace,studio:workspace.workroom,conversations:workspace.conversations,hit:hit,query:query)
                .toolbar { NavigationLink("原记录") { fullRecord } }
            } else { recordSummary } }
    }
    private var recordSummary:some View {
        List {
            if !query.isEmpty { Section("命中内容 · \(query)") { Text(highlight(hit.excerpt(for:query),query:query)).textSelection(.enabled);Text("下方可以打开完整记录核对上下文。").font(.caption).foregroundStyle(.secondary) } }
            Section { Text(hit.title).font(.title2);Text(hit.kind.rawValue);NavigationLink("打开完整记录") { fullRecord };NavigationLink("查看哪些记录引用了它") { ReverseLinksPage(workspace:workspace,hit:hit) };NavigationLink("修改文件夹与标签") { FilingEditorBody(studio:workspace.workroom,key:hit.id) } }
        }.seePageCanvas().navigationTitle("资料定位").modifier(WorkroomPrivacy())
    }
    @ViewBuilder private var fullRecord:some View {
        switch hit.kind {
        case .journey, .question, .journeyFact, .excerpt, .journeySource: JourneySearchDestination(workspace:workspace,studio:workspace.workroom,hit:hit,query:query)
        case .event: EventDetail(workspace:workspace,eventID:hit.recordID)
        case .card: InformationCardDetail(workspace:workspace,service:workspace.information,cardID:hit.recordID)
        case .routine: RoutineDetail(workspace:workspace,service:workspace.routines,information:workspace.information,itemID:hit.recordID)
        case .project: WorkroomCaseDetail(workspace:workspace,studio:workspace.workroom,cards:workspace.information,routines:workspace.routines,itemID:hit.recordID)
        case .draft:
            if let draft = workspace.workroom.drafts.first(where:{$0.id == hit.recordID}) { List { Text(draft.text).textSelection(.enabled);Button("继续编辑这份材料") { do { try workspace.workroom.use(draft);workspace.navigationRequest = .workroom } catch { workspace.notify(error.localizedDescription) } } }.seePageCanvas().navigationTitle(draft.title) } else { Text("材料已移除") }
        case .conversation:
            if let saved = workspace.conversations.items.first(where:{$0.id == hit.recordID}) { ScrollView { LazyVStack { ForEach(saved.turns) { SavedTurnCard(turn:$0) } }.padding() }.seePageCanvas().navigationTitle(saved.title) } else { Text("会话已移除") }
        }
    }
}
struct FilingEditorBody:View {
    @ObservedObject var studio:WorkroomService
    let key:String
    @State private var presented = false
    var body:some View { VStack(spacing:20) { Text("分类："+(studio.enhancements.filing[key]?.folder ?? "未分类"));Button("编辑分类") { presented = true } }.sheet(isPresented:$presented) { FilingEditor(studio:studio,keys:[key]) }.seePageCanvas().navigationTitle("文件夹与标签") }
}
struct ReverseLinksPage:View {
    @ObservedObject var workspace:Workspace
    let hit:GlobalSearchHit
    var body:some View {
        List {
            Section { Text("查找当前记录中的明确关联，不根据相似文字猜测引用。").font(.caption) }
            let cases = workspace.workroom.cases.filter { item in hit.kind == .draft ? item.preparation?.draftID == hit.recordID : item.links.contains { $0.id == hit.recordID && (hit.kind == .card && $0.kind == .card || hit.kind == .routine && $0.kind == .routine) } }
            Section("引用它的事务 · \(cases.count)") { ForEach(cases) { item in NavigationLink(item.title) { WorkroomCaseDetail(workspace:workspace,studio:workspace.workroom,cards:workspace.information,routines:workspace.routines,itemID:item.id) } };if cases.isEmpty { Text("没有事务引用") } }
            let tasks = workspace.routines.items.filter { hit.kind == .card && $0.sourceCardID == hit.recordID }
            Section("由它生成的待办 · \(tasks.count)") { ForEach(tasks) { item in NavigationLink(item.title) { RoutineDetail(workspace:workspace,service:workspace.routines,information:workspace.information,itemID:item.id) } };if tasks.isEmpty { Text("没有关联待办") } }
        }.seePageCanvas().navigationTitle("反向关联").modifier(WorkroomPrivacy())
    }
}
struct CaseCalendarPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @State private var date = Date()
    var body:some View {
        List {
            Section { DatePicker("选择日期",selection:$date,displayedComponents:.date).datePickerStyle(.graphical);Text("按事务截止日期查看。提醒时间仍需在事务里单独设置。").font(.caption).foregroundStyle(.secondary) }
            Section("当天到期") { let rows = studio.cases.filter { !$0.isArchived && $0.dueAt.map { Calendar.current.isDate($0,inSameDayAs:date) } == true };ForEach(rows) { row in link(row) };if rows.isEmpty { Text("这一天没有截止事务") } }
            Section("尚未安排日期") { ForEach(studio.cases.filter { $0.isActive && $0.dueAt == nil }) { row in link(row) } }
        }.seePageCanvas().navigationTitle("事务日历").modifier(WorkroomPrivacy())
    }
    private func link(_ row:WorkroomCase) -> some View { NavigationLink { WorkroomCaseDetail(workspace:workspace,studio:studio,cards:workspace.information,routines:workspace.routines,itemID:row.id) } label: { VStack(alignment:.leading) { Text(row.title);Text(row.stateTitle+(row.demonstration ? " · 演示" : "")).font(.caption).foregroundStyle(.secondary) } } }
}
struct CaseTemplatesPage:View {
    @ObservedObject var studio:WorkroomService
    @State private var editing:WorkroomCase?
    @State private var error:String?
    var body:some View {
        List {
            Section { Text("模板只带入材料和步骤文字。新事务需要你检查后保存，不带入旧进度、原文依据、关联或提醒。").font(.subheadline) }
            Section("内置模板") { ForEach(CaseTemplate.presets) { template in templateRow(template) } }
            Section("我的模板") { ForEach(studio.enhancements.templates) { template in VStack(alignment:.leading) { templateRow(template);Button("删除模板",role:.destructive) { do { try studio.updateEnhancements { $0.templates.removeAll { $0.id == template.id } } } catch { self.error = error.localizedDescription } }.font(.caption).buttonStyle(.borderless) } };if studio.enhancements.templates.isEmpty { Text("在事务详情里，把材料和步骤存为模板。") } }
            if let error { Text(error).foregroundStyle(.red) }
        }.seePageCanvas().navigationTitle("事务模板").sheet(item:$editing) { WorkroomCaseEditor(studio:studio,initial:$0) }.modifier(WorkroomPrivacy())
    }
    private func templateRow(_ template:CaseTemplate) -> some View { Button { editing = template.makeCase() } label: { VStack(alignment:.leading,spacing:8) { Label(template.title,systemImage:"square.on.square").font(.headline);Text("\(template.materials.count) 项材料 · \(template.steps.count) 个步骤").font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain) }
}
struct LibraryCleanupPage:View {
    @ObservedObject var studio:WorkroomService
    @State private var draftIDs = Set<UUID>()
    @State private var caseIDs = Set<UUID>()
    @State private var preview:CleanupChangePreview?
    @State private var error:String?
    var body:some View {
        List {
            Section { Text("选择后先查看影响范围，再移到最近删除。当前编辑区、原始信息卡和待办保留；误选可从最近删除恢复。").font(.subheadline);Button("选择 30 天前的草稿") { draftIDs = Set(studio.drafts.filter { $0.updatedAt < Date().addingTimeInterval(-30*86400) }.map(\.id)) } }
            Section("已存草稿") {
                ForEach(studio.drafts) { draft in
                    Toggle(isOn:Binding(get:{ draftIDs.contains(draft.id) },set:{ value in if value { draftIDs.insert(draft.id) } else { draftIDs.remove(draft.id) } })) {
                        VStack(alignment:.leading) {
                            Text(draft.title)
                            Text(draft.updatedAt,style:.date).font(.caption)
                            if studio.cases.contains(where:{$0.preparation?.draftID == draft.id}) {
                                Text("有事务引用，删除后原材料将不可用").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            Section("已归档事务") { ForEach(studio.cases.filter { $0.isArchived && studio.savedCaseIDs.contains($0.id) }) { row in Toggle(row.title,isOn:Binding(get:{caseIDs.contains(row.id)},set:{ if $0 { caseIDs.insert(row.id) } else { caseIDs.remove(row.id) } })) } }
            Section { Button("预览选中 \(draftIDs.count+caseIDs.count) 项") { do { preview = try studio.previewCleanup(draftIDs:draftIDs,caseIDs:caseIDs) } catch { self.error = error.localizedDescription } }.disabled(draftIDs.isEmpty && caseIDs.isEmpty);if let error { Text(error).foregroundStyle(.red) } }
        }.seePageCanvas().navigationTitle("资料清理").sheet(item:$preview) { value in CleanupPreviewPage(studio:studio,preview:value) { draftIDs = [];caseIDs = [] } }.modifier(WorkroomPrivacy())
    }
}
struct KeyFieldsPanel:View {
    let text:String
    @State private var checked = Set<String>()
    var body:some View {
        let fields = KeyFieldReview.fields(text)
        Section("时间 · 地点 · 费用，一起核对") {
            if fields.isEmpty { Text("没有提取到明确的关键字段。请直接检查原文；未提取不代表没有。") }
            ForEach(fields) { field in Button { if checked.contains(field.id) { checked.remove(field.id) } else { checked.insert(field.id) } } label: { Label(field.text.hasPrefix(field.kind+"：") || field.text.hasPrefix(field.kind+":") ? field.text : field.kind+"："+field.text,systemImage:checked.contains(field.id) ? "checkmark.circle.fill" : "circle") }.foregroundStyle(checked.contains(field.id) ? Color.seeAccent : .primary) }
            Text("这些是本机格式提示，不推断缺失内容，不会自动修改信息卡、日期或系统提醒。请特别核对是否属于同一件事。").font(.caption).foregroundStyle(.secondary)
        }.onChange(of:text) { _,_ in checked = [] }
    }
}
func highlight(_ text:String,query:String) -> AttributedString {
    var value = AttributedString(text)
    guard !query.isEmpty else { return value }
    var search = text.startIndex..<text.endIndex
    while let range = text.range(of:query,options:.caseInsensitive,range:search) {
        if let mapped = Range(range,in:value) { value[mapped].backgroundColor = .yellow.opacity(0.35);value[mapped].inlinePresentationIntent = .stronglyEmphasized }
        guard range.upperBound < text.endIndex else { break };search = range.upperBound..<text.endIndex
    };return value
}

struct CaseFlowEditor:View {
    @ObservedObject var studio:WorkroomService
    let itemID:UUID
    @State private var flow = CaseFlow()
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    private var item:WorkroomCase? { studio.cases.first { $0.id == itemID } }
    var body:some View {
        NavigationStack { Form {
            if let item {
                Section("推进状态") {
                    Picker("当前状态",selection:$flow.disposition) { ForEach(CaseDisposition.allCases) { Text($0.title).tag($0) } }
                    if flow.disposition == .waiting {
                        TextField("在等谁、等什么？",text:$flow.waitingFor,axis:.vertical)
                        Toggle("安排跟进日期",isOn:Binding(get:{flow.followUpAt != nil},set:{flow.followUpAt = $0 ? Date().addingTimeInterval(86400) : nil}))
                        if flow.followUpAt != nil { DatePicker("计划跟进",selection:Binding(get:{flow.followUpAt ?? .now},set:{flow.followUpAt = $0})) }
                    }
                    if flow.disposition == .deferred {
                        Toggle("记录恢复时间",isOn:Binding(get:{flow.resumeAt != nil},set:{flow.resumeAt = $0 ? Date().addingTimeInterval(86400) : nil}))
                        if flow.resumeAt != nil { DatePicker("计划恢复",selection:Binding(get:{flow.resumeAt ?? .now},set:{flow.resumeAt = $0})) }
                        Text("到时间后可手动恢复，是否通知仍取决于事务里的提醒设置。").font(.caption)
                    }
                }
                Section("重复安排") { Picker("重复频率",selection:$flow.cadence) { ForEach(CaseCadence.allCases) { Text($0.title).tag($0) } };Text("完成本次后再点“建立下一次”。不提前完成下一次，不复制旧的待办完成状态和系统提醒。").font(.caption).foregroundStyle(.secondary) }
                Section("步骤依赖 · 必须先完成") {
                    ForEach(item.materials+item.steps) { row in
                        DisclosureGroup(row.title) {
                            ForEach((item.materials+item.steps).filter { $0.id != row.id }) { parent in
                                Toggle(parent.title,isOn:Binding(get:{flow.dependencies[row.id.uuidString]?.contains(parent.id) == true},set:{ selected in var values = flow.dependencies[row.id.uuidString] ?? [];if selected { values.append(parent.id) } else { values.removeAll { $0 == parent.id } };flow.dependencies[row.id.uuidString] = values }))
                            }
                        }
                    }
                    Text("不能设置循环依赖；已完成项目的前置项必须全部完成。未满足时，主清单会提示阻塞原因。").font(.caption).foregroundStyle(.secondary)
                }
                Section { Button("保存推进规则") { do { guard var latest = self.item,latest == item else { throw DailyError.stale };var changed = flow;if changed.disposition == .waiting && latest.workflow.disposition != .waiting { changed.waitingSince = Date() };if changed.disposition != .waiting { changed.waitingSince = nil };latest.flow = changed;try studio.putCase(latest,saveLocally:studio.savedCaseIDs.contains(item.id));dismiss() } catch { self.error = "无法保存，请检查是否循环依赖，或已完成的项目仍有未完成前置项。" } };if let error { Text(error).foregroundStyle(.red) } }
            }
        }.seePageCanvas().navigationTitle("事务推进规则").toolbar { Button("取消") { dismiss() } }.onAppear { if let item { flow = item.workflow } } }.modifier(WorkroomPrivacy())
    }
}
struct DiagnosticExportPage:View {
    @ObservedObject var workspace:Workspace
    @State private var report = ""
    var body:some View {
        List {
            Section { Label("只导出白名单状态",systemImage:"lock.shield").font(.headline);Text("报告仅包含版本、系统版本、模拟器标记、输入开关、资料数量及恢复状态。不读取原文、姓名、地点、字幕、文件路径、密钥、配对码或个人备注。").font(.subheadline);Button("生成脱敏预览",systemImage:"doc.text.magnifyingglass",action:generate) }
            if !report.isEmpty { Section("导出前预览") { Text(report).font(.system(.body,design:.monospaced)).textSelection(.enabled);ShareLink("导出这份诊断报告",item:report) } }
        }.seePageCanvas().navigationTitle("诊断报告").modifier(WorkroomPrivacy())
    }
    private func generate() {
        let bundle = Bundle.main
        report = ["见声 · 脱敏诊断", "版本：\(bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "未知") (\(bundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "未知"))", "系统：iOS \(UIDevice.current.systemVersion)","运行环境：\(DeviceContext.simulator ? "模拟器" : "设备")", "麦克风：\(workspace.audio.mode == .idle ? "关闭" : "开启")", "摄像头：\(workspace.hand.isRunning ? "开启" : "关闭")", "事务数：\(workspace.workroom.cases.count)", "已存草稿数：\(workspace.workroom.drafts.count)", "信息卡数：\(workspace.information.cards.count)", "待办数：\(workspace.routines.items.count)", "已存会话数：\(workspace.conversations.items.count)", "草稿自动保护：\(workspace.workroom.enhancements.autosave ? "开启" : "关闭")", "资料恢复：\(workspace.libraryRecoveryMessage == nil ? "无待恢复状态" : "需处理")", "说明：此报告不证明识别准确率、通知送达或真机测试通过。"].joined(separator:"\n")
    }
}
struct ProductHelpPage:View {
    private let lessons:[(String,String,String,[String])] = [
        ("doc.on.doc","一件事务，多份来源","从补充材料到确认变更，一起留在事务里。",["事务详情打开材料页，可加入已有草稿或直接补充文字，保留加入时的版本。","新通知选择与现有安排对照，勾选时间、地点、费用和新增材料后再确认。","截止时间与系统提醒分别勾选。已有准备状态保留，新增材料从未准备开始。"]),
        ("rectangle.split.2x1","原图逐行对照","识字位置与核对后的内容清楚区分。",["导入照片并识字后打开原图对照，点击识字行会框出图中位置。","需要以后查看时，选择保存草稿时一并保留原图，再主动保存材料。","原图只保存在本机，备份保留文字；删除原图后材料文字仍可使用。"]),
        ("tray.and.arrow.down","从材料开始","照片、文件与系统分享都先进入本机预览。",["工作室导入照片时可旋转、裁切；PDF 先选页，最多读取 12 页。","核对姓名、数字和关键字段后，继续整理；暂时没空可存收件箱。","系统分享后打开见声的收件箱，选择保存文字或本机识字；随时可删除待处理图片。"]),
        ("checklist","推进一件事","核对、准备、执行的状态分别保留。",["从内置模板新建，或在文字工作室确认事务建议。","在推进规则中记录等待事项、暂缓时间与前置步骤。","已完成的重复事务可手动建立下一次；新一轮需重新处理，提醒重新设置。"]),
        ("folder","整理与找回","文件夹、标签、搜索和反向关联共同使用。",["我的资料中筛选文件夹与标签，勾选多条后批量整理。","搜索会展示命中附近文字，打开定位页再查看完整上下文。","反向关联只展示明确引用；删除原记录不会伪造恢复它。"]),
        ("captions.bubble","面对面沟通","字幕可能持续修订，关键内容需要双方确认。",["时间、地点和费用使用醒目文字提示，不代表系统已确认正确。","识别修订和人工修改分别标注；有修订时请重新核对数字。","面对面阅读可把回应翻转 180° 给对方看；减少动画跟随系统。"]),
        ("lock.doc","保护与恢复","默认需要你主动保存。",["草稿自动保护由你开启，停顿后更新本机副本；关闭不会删除旧副本。","备份可选择类别和事务，默认补齐关联资料，导出前查看数量。","分享图片留在共享收件箱到处理或删除；备份不包含原图、API 密钥和系统权限。"])
    ]
    var body:some View {
        List {
            Section { Label("见声使用指南",systemImage:"book.closed.fill").font(.largeTitle.bold());Text("从导入到完成，按你需要的节奏使用。").foregroundStyle(.secondary) }
            ForEach(Array(lessons.enumerated()),id:\.offset) { _,lesson in
                Section {
                    HStack(spacing:16) { Image(systemName:lesson.0).font(.system(size:32)).foregroundStyle(Color.seeAccent).frame(width:60,height:60).background(Color.seeAccent.opacity(0.1),in:RoundedRectangle(cornerRadius:16));VStack(alignment:.leading,spacing:6) { Text(lesson.1).font(.title3.bold());Text(lesson.2).font(.caption).foregroundStyle(.secondary) } }
                    ForEach(Array(lesson.3.enumerated()),id:\.offset) { index,text in HStack(alignment:.top) { Text("\(index+1)").font(.caption.bold()).frame(width:24,height:24).background(Color.seeAccent.opacity(0.1),in:Circle());Text(text).font(.subheadline).fixedSize(horizontal:false,vertical:true) } }
                }
            }
            Section("设备与演示") { Text("iPhone / iPad 的核心整理流程可独立使用。Watch 通信、触觉和系统通知需在真实设备分别检查；模拟器能展示界面，不能证明这些能力已可靠运行。").font(.subheadline) }
        }.seePageCanvas().navigationTitle("使用帮助")
    }
}

func captionHighlight(_ text:String) -> AttributedString {
    var value = AttributedString(text)
    for field in KeyFieldReview.fields(text) {
        if let range = value.range(of:field.text) { value[range].foregroundColor = .primary;value[range].backgroundColor = .yellow.opacity(0.24);value[range].inlinePresentationIntent = .stronglyEmphasized }
    }
    return value
}
