import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let seeSoundLibrary = UTType(exportedAs:"com.azusagawalover.seesound.library",conformingTo:.data) }
struct LibraryFileDocument:FileDocument {
    static var readableContentTypes:[UTType] { [.seeSoundLibrary,.data] }
    var data:Data
    init(data:Data) { self.data = data }
    init(configuration:ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents,bytes.count <= LibraryCryptography.maxSize else { throw LibraryError.invalid };data = bytes
    }
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}
struct AgendaCenterPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @ObservedObject var routines:RoutineService
    @ObservedObject var agenda:AppointmentReminderService
    @State private var filter = "全部"
    @State private var error:String?
    @Environment(\.openURL) private var openURL
    var body:some View {
        TimelineView(.periodic(from:.now,by:30)) { context in
            let rows = AgendaOverview.rows(routines:routines.items,savedRoutineIDs:routines.savedIDs,cases:studio.cases,savedCaseIDs:studio.savedCaseIDs,scheduled:agenda.scheduledIDs,delivered:agenda.deliveredIDs,failed:agenda.failedIDs,authorization:agenda.authorizationState,now:context.date)
            List {
                Section {
                    Label(agenda.permission,systemImage:agenda.authorizationState == .allowed ? "bell.badge" : "bell.slash").font(.headline)
                    Text(agenda.status).font(.subheadline).foregroundStyle(.secondary)
                    HStack { Button("刷新") { agenda.refresh() };Spacer();Button("通知设置") { if let url = URL(string:UIApplication.openSettingsURLString) { openURL(url) } } }
                    if agenda.authorizationState == .notDetermined { Button("允许系统通知") { Task { await agenda.requestPermission() } } }
                } footer: { Text("送达状态来自系统当前可查询记录，不代表已阅读。时间已过但没有系统记录时会显示未知。") }
                Section {
                    Picker("查看",selection:$filter) { ForEach(["全部","即将提醒","需要处理","已过时间"],id:\.self) { Text($0) } }
                    if rows.isEmpty { ContentUnavailableView("还没有设置提醒",systemImage:"bell",description:Text("在事务或待办的编辑页手动设置提醒时间。")) }
                    let visible = rows.filter { filter == "全部" || filter == "即将提醒" && $0.date > context.date && $0.state == .scheduled || filter == "需要处理" && $0.state.needsAttention || filter == "已过时间" && $0.date <= context.date }
                    if !rows.isEmpty && visible.isEmpty { Text("当前筛选没有提醒。").foregroundStyle(.secondary) }
                    ForEach(visible) { row in
                        VStack(alignment:.leading,spacing:10) {
                            Button { workspace.scheduledDestination = row.destination } label: { Label(row.title,systemImage:row.destination.kind == .project ? "list.bullet.clipboard" : "checklist").font(.headline).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain)
                            Text(row.date,format:.dateTime.month().day().hour().minute()).font(.subheadline)
                            Label(row.state.title,systemImage:row.state.needsAttention ? "exclamationmark.circle" : "bell").font(.caption).foregroundStyle(row.state.needsAttention ? Color.orange : Color.secondary)
                            if ![.inactive,.demonstration,.unsaved].contains(row.state) {
                                HStack {
                                    Button("10 分钟后提醒") { change(row,date:Date().addingTimeInterval(600)) }
                                    Spacer()
                                    Button("关闭提醒",role:.destructive) { change(row,date:nil) }
                                }.font(.caption).buttonStyle(.borderless)
                            }
                        }.padding(.vertical,6)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section { Text("最多预排最近 24 条。完成、删除、归档或取消保存会撤下未触发的提醒；应用下次打开时继续补排。专注模式可能影响显示时间。").font(.caption).foregroundStyle(.secondary) }
            }.onChange(of:context.date) { _,_ in agenda.refresh() }
        }.seePageCanvas().navigationTitle("提醒中心").task { agenda.refresh() }.modifier(WorkroomPrivacy())
    }
    private func change(_ row:AgendaEntry,date:Date?) {
        do {
            if row.destination.kind == .project, var item = studio.cases.first(where:{$0.id == row.destination.recordID}) {
                item.reminderAt = date;try studio.putCase(item,saveLocally:studio.savedCaseIDs.contains(item.id))
            } else if var item = routines.items.first(where:{$0.id == row.destination.recordID}) {
                item.reminderAt = date;try routines.put(item,saveLocally:routines.savedIDs.contains(item.id))
            };error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct LibraryBackupPage:View {
    @ObservedObject var workspace:Workspace
    @State private var selection = LibraryExportSelection()
    @State private var selectedCaseIDs = Set<UUID>()
    @State private var onlySelectedCases = false
    @State private var exportCounts:[String] = []
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var document:LibraryFileDocument?
    @State private var package:LibraryPackage?
    @State private var imported:Data?
    @State private var importedName = ""
    @State private var preview:LibraryRestorePreview?
    @State private var options = LibraryRestoreOptions()
    @State private var busy = false
    @State private var status:String?
    @State private var confirmed = false
    @State private var journeyDifferences:[LibraryJourneyDifference] = []
    @State private var receivedDifferences:[LibraryJourneyDifference] = []
    let handoffID:UUID?
    let journeyID:UUID?
    private var isHandoff:Bool { handoffID != nil || journeyID != nil }
    init(workspace:Workspace,handoffID:UUID? = nil,journeyID:UUID? = nil) {
        self.workspace = workspace;self.handoffID = handoffID;self.journeyID = journeyID
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--backup-fixture"),
           let url = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first?.appendingPathComponent("Validation.seesoundbackup"),
           let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= LibraryCryptography.maxSize,
           let data = try? Data(contentsOf:url) {
            _imported = State(initialValue:data);_importedName = State(initialValue:"Validation.seesoundbackup · 演示验证文件")
        }
        #endif
    }
    var body:some View {
        Form {
            Section {
                Label(!isHandoff ? "加密备份与恢复" : "接力所选旅程或事务",systemImage:"lock.doc").font(.headline)
                Text(!isHandoff ? "备份主动保存在本机的办事旅程、草稿、事务、信息卡、待办、会话、设置、事件摘要和验证记录。未保存的内容与原始音视频不进入备份。" : "包含所选已存旅程或事务、确认卡、沟通摘录与关联的已存待办、信息卡及材料；缺失的关联会在导入预览中提示。")
                Text("文件使用 AES-GCM 加密。密码不保存、不上传；忘记密码将无法恢复。API 密钥、配对码、系统权限和模型文件不进入备份。").font(.caption).foregroundStyle(.secondary)
            }
            Section("文件密码") {
                SecureField("至少 8 个字符",text:$password).textContentType(.newPassword)
                if imported == nil { SecureField("再次输入密码",text:$passwordConfirmation).textContentType(.newPassword) }
            }
            if imported == nil {
                if !isHandoff {
                    Section("选择备份范围") {
                        Toggle("事务与办事旅程",isOn:$selection.cases);Toggle("仅导出选中的事务",isOn:$onlySelectedCases).disabled(!selection.cases)
                        if onlySelectedCases && selection.cases { ForEach(workspace.workroom.cases.filter { workspace.workroom.savedCaseIDs.contains($0.id) }) { item in Toggle(item.title,isOn:Binding(get:{selectedCaseIDs.contains(item.id)},set:{if $0 { selectedCaseIDs.insert(item.id) } else { selectedCaseIDs.remove(item.id) }})) } }
                        Toggle("草稿与收件箱文字",isOn:$selection.drafts);Toggle("信息卡",isOn:$selection.cards);Toggle("待办",isOn:$selection.routines);Toggle("已存会话",isOn:$selection.conversations);Toggle("事件摘要",isOn:$selection.history);Toggle("验证与复核记录",isOn:$selection.quality);Toggle("偏好与我的模板",isOn:$selection.settings)
                        Toggle("自动补齐所选事务与待办的关联资料",isOn:$selection.includeDependencies)
                        Text("补齐关联可能额外带入草稿、卡片和待办。关闭后会保留引用，导入时提示缺失。共享收件箱里的原图片不进入备份。").font(.caption).foregroundStyle(.secondary)
                        Button("预览导出数量") { do { var choice = selection;choice.caseIDs = onlySelectedCases ? selectedCaseIDs : nil;let snapshot = try choice.apply(to:LibraryRepository().read());exportCounts = snapshot.counts.map { "\($0.0)：\($0.1)" } } catch { status = error.localizedDescription } }
                        ForEach(exportCounts,id:\.self) { Text($0).font(.caption) }
                    }
                }
                Section("导出") {
                    Button(!isHandoff ? "准备加密备份" : "准备加密接力文件",systemImage:"square.and.arrow.up",action:prepareExport).disabled(busy || password.count < 8 || password != passwordConfirmation)
                    Text("导出位置由你选择；如使用 iCloud Drive 或 AirDrop，文件离开本应用后由相应服务管理。").font(.caption).foregroundStyle(.secondary)
                }
                if !isHandoff { Section("恢复或接收接力") { Button("选择备份 / 接力文件",systemImage:"square.and.arrow.down") { importing = true }.disabled(busy) } }
            } else {
                Section("所选文件") {
                    Text(importedName)
                    Button("用密码打开预览",action:decrypt).disabled(busy || password.count < 8)
                    Button("取消导入") { imported = nil;package = nil;preview = nil;password = "";confirmed = false }
                }
            }
            if let package {
                Section(package.purpose == "handoff" ? "接力文件内容" : "备份文件内容") {
                    Text(package.createdAt,format:.dateTime.year().month().day().hour().minute())
                    ForEach(package.snapshot.counts,id:\.0) { entry in LabeledContent(entry.0,value:"\(entry.1)") }
                }
                Section("合并选项") {
                    Toggle("同一标识冲突时使用文件中的版本",isOn:$options.preferIncoming)
                    Toggle("同时采用文件中的偏好设置",isOn:$options.includeSettings)
                    Toggle("恢复事件摘要并开启本机事件保存",isOn:$options.includeHistory)
                    Toggle("启用文件中的未来提醒",isOn:$options.rearmReminders)
                    Text("默认保留本机同标识版本，不自动重开提醒或改变事件保存开关。关联仍按原标识连接，缺失记录不会伪造补齐。").font(.caption).foregroundStyle(.secondary)
                    Button("重新生成恢复预览",action:makePreview).disabled(busy)
                }.onChange(of:options.preferIncoming) { _,_ in invalidate() }.onChange(of:options.includeSettings) { _,_ in invalidate() }.onChange(of:options.includeHistory) { _,_ in invalidate() }.onChange(of:options.rearmReminders) { _,_ in invalidate() }
            }
            if let preview {
                Section("旅程差异导览") {
                    ForEach(journeyDifferences) { row in
                        VStack(alignment:.leading,spacing:8) { Text(row.title).font(.headline);ForEach(row.summary,id:\.self) { Text($0).font(.subheadline) };Text(row.appliesIncoming ? "本次将采用文件版本" : "本次保留本机版本").font(.caption).foregroundStyle(Color.seeAccent) }
                    }
                }
                Section("确认前预览") {
                    LabeledContent("同标识版本冲突",value:"\(preview.conflicts)")
                    ForEach(preview.package.snapshot.workroom.enhancements?.campus?.journeys ?? []) { journey in
                        VStack(alignment:.leading,spacing:6) {
                            Text(journey.title).font(.headline);Text("文件中的旅程：第 \(journey.revision) 版 · "+journey.stage.title).font(.caption)
                            if let local = workspace.workroom.campus.journeys.first(where:{$0.id == journey.id}) {
                                Text("本机旅程：第 \(local.revision) 版 · "+local.stage.title).font(.caption)
                                if journey.revision < local.revision { Label("文件版本较旧，请谨慎选择覆盖本机版本。",systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                    LabeledContent("仍然缺失的关联记录",value:"\(preview.missingLinks)")
                    ForEach(preview.target.counts,id:\.0) { entry in LabeledContent("合并后"+entry.0,value:"\(entry.1)") }
                    Toggle("我已核对内容、冲突处理和提醒选项",isOn:$confirmed)
                    Button("确认合并到本机",action:restore).disabled(!confirmed || busy)
                    Text("写入中断会尝试恢复原资料。写入前再次检查本机版本；不同版本的资料请先重新预览。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if busy { ProgressView("正在本机处理…") }
            if !receivedDifferences.isEmpty { Section("接收后继续核对") { ForEach(receivedDifferences.filter(\.appliesIncoming)) { row in NavigationLink(row.title+" · 查看接收后的内容") { JourneyDetailPage(workspace:workspace,studio:workspace.workroom,id:row.id) } };Text("请查看新增材料、变化的确认卡和后续安排；来源中的原图不会随文件传入。").font(.caption) } }
            if let status { Section { Text(status).textSelection(.enabled) } }
            if let status = workspace.libraryStatus { Section { Text(status) } }
            if workspace.libraryRecoveryMessage != nil { Section { Button("重试恢复上次写入前的资料") { Task { await workspace.retryLibraryRecovery() } } } }
        }.seePageCanvas().navigationTitle(!isHandoff ? "备份与恢复" : "接力文件").disabled(busy)
            .fileImporter(isPresented:$importing,allowedContentTypes:[.data]) { result in
                do {
                    let url = try result.get(),access = url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= LibraryCryptography.maxSize else { throw LibraryError.capacity }
                    imported = try Data(contentsOf:url);importedName = url.lastPathComponent;password = "";passwordConfirmation = "";package = nil;preview = nil;status = nil
                } catch { status = error.localizedDescription }
            }
            .fileExporter(isPresented:$exporting,document:document,contentType:.seeSoundLibrary,defaultFilename:!isHandoff ? "见声备份" : "见声事务接力") { result in
                if case .success = result { status = "加密文件已导出。请妥善保管文件密码。" }
                else if case .failure(let error) = result { status = error.localizedDescription }
                document = nil;password = "";passwordConfirmation = ""
            }.modifier(WorkroomPrivacy())
    }
    private func invalidate() { preview = nil;confirmed = false }
    private func prepareExport() {
        busy = true;status = nil
        var choice = selection;choice.caseIDs = onlySelectedCases ? selectedCaseIDs : nil
        let secret = password,id = handoffID,journey = journeyID,exportSelection = choice
        Task {
            do {
                let data = try await Task.detached(priority:.userInitiated) {
                    let snapshot = try LibraryRepository().read()
                    let subset = try journey.map { try snapshot.handoff(journeyID:$0) } ?? id.map { try snapshot.handoff(caseID:$0) } ?? exportSelection.apply(to:snapshot)
                    return try LibraryCryptography.seal(LibraryPackage(purpose:id == nil && journey == nil ? "backup" : "handoff",snapshot:subset),password:secret)
                }.value
                document = .init(data:data);exporting = true
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
    private func decrypt() {
        guard let data = imported else { return };busy = true;let secret = password
        Task {
            do { package = try await Task.detached(priority:.userInitiated) { try LibraryCryptography.open(data,password:secret) }.value;password = "";makePreview() }
            catch { status = error.localizedDescription }
            busy = false
        }
    }
    private func makePreview() {
        guard let package else { return }
        do { let local = try LibraryRepository().read();preview = try LibraryMerge.preview(local:local,package:package,options:options);journeyDifferences = LibraryJourneyDifference.make(local:local,package:package,preferIncoming:options.preferIncoming);confirmed = false;status = nil }
        catch { status = error.localizedDescription;preview = nil }
    }
    private func restore() {
        guard let preview,confirmed else { return };busy = true
        Task {
            if await workspace.restoreLibrary(preview) { receivedDifferences = journeyDifferences }
            self.preview = nil;package = nil;imported = nil;confirmed = false;busy = false
        }
    }
}

struct DeviceContinuityPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var bridge:ConnectivityBridge
    @ObservedObject var studio:WorkroomService
    @ObservedObject var routines:RoutineService
    @State private var selected:Set<UUID> = []
    private var available:[WatchAgendaItem] {
        return workspace.watchAgendaItems
    }
    var body:some View {
        List {
            Section("iPhone 与 iPad") {
                Text("在一台设备整理，在另一台设备继续。选择已存事务导出加密接力文件，再在另一台设备的备份中心导入；接收前核对版本、关联和提醒。").font(.subheadline)
                ForEach(studio.cases.filter { studio.savedCaseIDs.contains($0.id) }) { item in
                    NavigationLink { LibraryBackupPage(workspace:workspace,handoffID:item.id) } label: { Label(item.title+(item.demonstration ? " · 演示" : ""),systemImage:"square.and.arrow.up") }
                }
                if studio.savedCaseIDs.isEmpty { Text("先保存一件事务，即可只接力该事务和已存关联记录。").foregroundStyle(.secondary) }
                NavigationLink("接收接力文件 / 完整备份") { LibraryBackupPage(workspace:workspace) }
                Text("当前采用手动文件接力，不提供自动云同步。两台设备分别修改后，需再次导出，并在导入预览选择冲突处理。").font(.caption).foregroundStyle(.secondary)
            }
            Section("发送到配对 Watch · 最多 5 项") {
                WatchConnectionPanel(bridge:bridge)
                if !bridge.lastAgendaIDs.isEmpty {
                    DisclosureGroup("上次传递与重试") {
                        Text(bridge.agendaStatus).font(.subheadline)
                        Text("按当前记录重新生成摘要，不发送旧副本。点击重发才会再次传递，取得有效回执前不会标成成功。").font(.caption).foregroundStyle(.secondary)
                        Button("重新发送上次所选的当前摘要") { bridge.retryAgenda(current:available) }.disabled(bridge.agendaSending || UIDevice.current.userInterfaceIdiom != .phone)
                    }
                }
                if UIDevice.current.userInterfaceIdiom != .phone { Text("Watch 与 iPhone 配对；请在 iPhone 发送摘要，iPad 使用上方文件接力。").foregroundStyle(.secondary) }
                ForEach(available) { item in
                    Toggle(isOn:Binding(get:{selected.contains(item.id)},set:{ on in if on { if selected.count < 5 { selected.insert(item.id) } } else { selected.remove(item.id) } })) {
                        VStack(alignment:.leading,spacing:6) {
                            Text(item.title).font(.headline)
                            Text(item.kind == .routine ? "手表可确认完成此待办" : item.kind == .journey ? "旅程下一步与已核对安排，仅回传已看到" : "手表仅回传已看到，不改变事务步骤").font(.caption).foregroundStyle(.secondary)
                            if item.demonstration { Text("演示摘要").font(.caption).foregroundStyle(Color.seeAccent) }
                        }
                    }.disabled(!selected.contains(item.id) && selected.count >= 5)
                }
                if available.isEmpty { Text("没有可发送的进行中旅程、已存事务或待办。").foregroundStyle(.secondary) }
                Text("将发送所选名称、下一步、截止时间及处理状态。摘要在手表本机保留，10 分钟后不可直接操作；重启后仍需连接手机取得回执。不发送原文、音视频或 API 配置。").font(.caption).foregroundStyle(.secondary)
                Button("发送所选摘要（\(selected.count) 项）",systemImage:"applewatch") { bridge.sendAgenda(available.filter { selected.contains($0.id) }) }.disabled(selected.isEmpty || bridge.agendaSending || UIDevice.current.userInterfaceIdiom != .phone)
                Button("撤回手表上的事务摘要") { bridge.sendAgenda([]) }.disabled(bridge.agendaSending || UIDevice.current.userInterfaceIdiom != .phone)
                Text(bridge.agendaStatus).font(.subheadline).foregroundStyle(.secondary)
            }
        }.seePageCanvas().navigationTitle("设备接力").onChange(of:available) { _,items in selected.formIntersection(Set(items.map(\.id))) }.modifier(WorkroomPrivacy())
    }
}
