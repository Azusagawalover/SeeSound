import SwiftUI

struct ChecklistFeedback:View {
    @ObservedObject var studio:WorkroomService
    @Binding var receipt:ChecklistUndo?
    @State private var error:String?
    var body:some View {
        if let receipt {
            VStack(alignment:.leading,spacing:10) {
                Text(receipt.message).font(.subheadline).fixedSize(horizontal:false,vertical:true)
                Button("撤销这次清单修改") { do { try studio.undoChecklist(receipt);self.receipt = nil;error = nil } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("checklist.undo")
                Text("撤销只在本次页面保留。后续事务内容变化后，需要重新检查，避免覆盖新修改。").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.onChange(of:receipt.id) { _,_ in error = nil }
        }
    }
}
struct CaseListOptionsPage:View {
    @Binding var options:CaseListOptions
    let filing:[String:RecordFiling]
    @Environment(\.dismiss) private var dismiss
    private var folders:[String] { Array(Set(filing.values.map(\.folder).filter { !$0.isEmpty })).sorted() }
    private var tags:[String] { Array(Set(filing.values.flatMap(\.tags))).sorted() }
    var body:some View {
        NavigationStack { Form {
            Section("显示顺序") { Picker("排序",selection:$options.sort) { ForEach(CaseListSort.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("cases.sort");Text("置顶事务始终在前。筛选和排序在本页保留，不会修改事务内容。").font(.caption).foregroundStyle(.secondary) }
            Section("进一步缩小范围") {
                Picker("事务范围",selection:$options.scope) { ForEach(CaseListScope.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("cases.scope")
                Picker("文件夹",selection:$options.folder) { Text("全部文件夹").tag("");ForEach(Array(Set(folders+[options.folder].filter { !$0.isEmpty })).sorted(),id:\.self) { Text($0).tag($0) } }
                Picker("标签",selection:$options.tag) { Text("全部标签").tag("");ForEach(Array(Set(tags+[options.tag].filter { !$0.isEmpty })).sorted(),id:\.self) { Text($0).tag($0) } }
                Text("这些条件与清单上的状态筛选同时生效。未来七天按当前时间起算，包含仍在进行中的事务。").font(.caption).foregroundStyle(.secondary)
            }
            Section { Button("恢复默认筛选与排序") { options = .init() }.accessibilityIdentifier("cases.resetOptions") }
        }.seePageCanvas().navigationTitle("筛选与排序").toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } } }
    }
}
struct ChecklistBatchPage:View {
    @ObservedObject var studio:WorkroomService
    let initial:WorkroomCase
    @Binding var receipt:ChecklistUndo?
    @State private var selected = Set<UUID>()
    @State private var preview:ChecklistBatchPreview?
    @State private var acknowledged = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    private var ready:[CaseFocusRow] { CaseFocusQueue.ready(in:initial) }
    var body:some View {
        NavigationStack { List {
            Section {
                Text("一并确认已经处理的项目").font(.title2.bold())
                Text("只勾选你实际处理过的材料和步骤。依赖其他未完成项目的行不能选择，关联待办仍需到原页面核对。").font(.subheadline).foregroundStyle(.secondary)
                Button("选择当前可处理的全部项目") { selected = Set(ready.map(\.id)) }.disabled(ready.isEmpty).accessibilityIdentifier("batch.selectReady")
                Button("清空选择") { selected = [] }.disabled(selected.isEmpty)
            }
            ForEach(ChecklistKind.allCases) { kind in
                Section(kind.title) { ForEach(kind.rows(in:initial).filter { !$0.done }) { row in
                    let blocked = !initial.blockedBy(row).isEmpty
                    Button { if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) } } label: {
                        VStack(alignment:.leading,spacing:8) { Label(row.title,systemImage:selected.contains(row.id) ? "checkmark.circle.fill" : "circle");if blocked { Text("先处理："+initial.blockedBy(row).map(\.title).joined(separator:"、")).font(.caption).foregroundStyle(.secondary) } }
                    }.disabled(blocked).accessibilityIdentifier("batch.row."+row.id.uuidString)
                } }
            }
            Section {
                Button("预览所选 \(selected.count) 项") { do { preview = try .make(item:initial,ids:selected);error = nil } catch { self.error = error.localizedDescription } }.disabled(selected.isEmpty).accessibilityIdentifier("batch.preview")
                if let preview {
                    Text("确认后将标为已处理：").font(.headline)
                    ForEach(Array(preview.titles.enumerated()),id:\.offset) { _,title in Text(title) }
                    Toggle("我已检查这些项目，确认已经处理",isOn:$acknowledged).accessibilityIdentifier("batch.acknowledged")
                    Button("确认批量标为已处理") { do { receipt = try studio.applyChecklistBatch(preview);dismiss() } catch { self.error = error.localizedDescription } }.disabled(!acknowledged).accessibilityIdentifier("batch.apply")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }.seePageCanvas().navigationTitle("批量处理清单").toolbar { ToolbarItem(placement:.cancellationAction) { Button("返回") { dismiss() } } }
            .onChange(of:selected) { _,_ in preview = nil;acknowledged = false }
        }.modifier(WorkroomPrivacy())
    }
}
struct ChecklistRenamePage:View {
    @ObservedObject var studio:WorkroomService
    let initial:WorkroomCase
    let row:CaseStep
    @Binding var receipt:ChecklistUndo?
    @State private var title:String
    @State private var error:String?
    @State private var discarding = false
    @FocusState private var nameFocused:Bool
    @Environment(\.dismiss) private var dismiss
    init(studio:WorkroomService,initial:WorkroomCase,row:CaseStep,receipt:Binding<ChecklistUndo?>) { self.studio = studio;self.initial = initial;self.row = row;_receipt = receipt;_title = State(initialValue:row.title) }
    private var dirty:Bool { title != row.title }
    var body:some View {
        NavigationStack { Form {
            Section("修改清单名称") { TextEditor(text:$title).frame(height:120).focused($nameFocused).accessibilityLabel("项目名称，最多100字").accessibilityIdentifier("checklist.name").task { await Task.yield();nameFocused = true };Text("\(title.count) / 100 字").font(.caption).foregroundStyle(.secondary);Text("只改这项名称，保留完成状态、顺序及建立时依据。").font(.caption).foregroundStyle(.secondary) }
            if let quote = row.sourceQuote { Section("保留的建立时依据") { Text(quote).textSelection(.enabled);Text("新名称由你填写，不会被标成原文中的新结论。").font(.caption).foregroundStyle(.secondary) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.seePageCanvas().navigationTitle("修改项目名称").toolbar {
            ToolbarItem(placement:.cancellationAction) { Button("取消") { if dirty { discarding = true } else { dismiss() } } }
            ToolbarItem(placement:.confirmationAction) { Button("保存") { do { receipt = try studio.changeChecklist(caseID:initial.id,fingerprint:initial.reviewFingerprint(),change:.rename(row.id,title));dismiss() } catch { self.error = error.localizedDescription } }.disabled(!dirty || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || title.count > 100).accessibilityIdentifier("checklist.saveName") }
        }.modifier(KeyboardCloseToolbar()).interactiveDismissDisabled(dirty)
            .confirmationDialog("放弃这次未保存的名称修改？",isPresented:$discarding,titleVisibility:.visible) { Button("放弃修改",role:.destructive) { dismiss() } }
        }.modifier(WorkroomPrivacy())
    }
}
struct ChecklistOrderPage:View {
    @ObservedObject var studio:WorkroomService
    let initial:WorkroomCase
    let kind:ChecklistKind
    @Binding var receipt:ChecklistUndo?
    @State private var rows:[CaseStep]
    @State private var discarding = false
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    init(studio:WorkroomService,initial:WorkroomCase,kind:ChecklistKind,receipt:Binding<ChecklistUndo?>) { self.studio = studio;self.initial = initial;self.kind = kind;_receipt = receipt;_rows = State(initialValue:kind.rows(in:initial)) }
    private var dirty:Bool { rows.map(\.id) != kind.rows(in:initial).map(\.id) }
    var body:some View {
        NavigationStack { List {
            Section { Text("拖动右侧手柄，或用上移、下移调整。确认前只预览顺序，不会改变完成状态和步骤依赖。").font(.subheadline).foregroundStyle(.secondary) }
            Section(kind.title+"顺序") {
                ForEach(Array(rows.enumerated()),id:\.element.id) { index,row in
                    VStack(alignment:.leading,spacing:8) {
                        Text("\(index+1). "+row.title).font(.headline)
                        HStack {
                            Button("上移",systemImage:"arrow.up") { rows.swapAt(index,index-1) }.disabled(index == 0).accessibilityIdentifier("order.up."+row.id.uuidString)
                            Button("下移",systemImage:"arrow.down") { rows.swapAt(index,index+1) }.disabled(index == rows.count-1).accessibilityIdentifier("order.down."+row.id.uuidString)
                        }.font(.caption).buttonStyle(.borderless)
                    }.padding(.vertical,5)
                }.onMove { source,destination in rows.move(fromOffsets:source,toOffset:destination) }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.environment(\.editMode,.constant(.active)).seePageCanvas().navigationTitle("调整"+kind.title+"顺序").toolbar {
            ToolbarItem(placement:.cancellationAction) { Button("取消") { if dirty { discarding = true } else { dismiss() } } }
            ToolbarItem(placement:.confirmationAction) { Button("确认顺序") { do { receipt = try studio.changeChecklist(caseID:initial.id,fingerprint:initial.reviewFingerprint(),change:.reorder(kind,rows.map(\.id)));dismiss() } catch { self.error = error.localizedDescription } }.disabled(!dirty).accessibilityIdentifier("order.apply") }
        }.interactiveDismissDisabled(dirty)
            .confirmationDialog("放弃尚未确认的顺序调整？",isPresented:$discarding,titleVisibility:.visible) { Button("放弃调整",role:.destructive) { dismiss() } }
        }.modifier(WorkroomPrivacy())
    }
}
struct CaseFocusPage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    let itemID:UUID
    @Binding var receipt:ChecklistUndo?
    @State private var skipped = Set<UUID>()
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    private var item:WorkroomCase? { studio.cases.first { $0.id == itemID } }
    var body:some View {
        NavigationStack { ScrollView {
            VStack(alignment:.leading,spacing:20) {
                if let item {
                    VStack(alignment:.leading,spacing:10) {
                        Text(item.title).font(.title2.bold()).fixedSize(horizontal:false,vertical:true)
                        let progress = item.progress(routines:workspace.routines.items)
                        Text("\(progress.done) / \(progress.total) 项已处理").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("focus.progress")
                        ProgressView(value:Double(progress.done),total:Double(max(1,progress.total)))
                        if item.demonstration { Label("演示事务",systemImage:"play.rectangle").font(.caption).foregroundStyle(Color.seeAccent) }
                    }.modifier(WorkspaceSurface())
                    if let current = CaseFocusQueue.ready(in:item,skipping:skipped).first {
                        VStack(alignment:.leading,spacing:18) {
                            Label("现在处理一项"+current.kind.title,systemImage:current.kind == .material ? "bag" : "checklist").font(.subheadline).foregroundStyle(Color.seeAccent)
                            Text(current.row.title).font(.largeTitle.bold()).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("focus.title")
                            if current.row.renamedByUser == true { Text(current.row.sourceQuote == nil ? "名称由你修改" : "名称由你修改，原依据保留").font(.caption).foregroundStyle(.secondary) }
                            if let quote = current.row.sourceQuote { Text("建立时依据").font(.caption.bold());Text(quote).font(.body).textSelection(.enabled) }
                            Button("这项已处理，继续下一项",systemImage:"checkmark.circle.fill") { perform { receipt = try studio.changeChecklist(caseID:item.id,fingerprint:item.reviewFingerprint(),change:.complete([current.id],true)) } }.buttonStyle(.borderedProminent).tint(SeePalette.button).accessibilityIdentifier("focus.complete")
                            Button("暂时跳过这一项") { skipped.insert(current.id) }.accessibilityIdentifier("focus.skip")
                            Text("跳过只影响本次专注顺序，不会标为完成。退出后，下次仍会看到未处理项目。").font(.caption).foregroundStyle(.secondary)
                        }.modifier(WorkspaceSurface())
                    } else if item.isCompleted || item.isArchived {
                        FeatureMessage(title:item.isArchived ? "事务已归档" : "事务已完成",detail:"进度已保留，可以返回事务详情。",symbol:"checkmark.circle")
                    } else if item.workflow.disposition != .ready {
                        FeatureMessage(title:item.stateTitle,detail:"请返回详情，记录回复或调整暂缓安排后再继续。",symbol:"clock")
                    } else {
                        let progress = item.progress(routines:workspace.routines.items)
                        VStack(alignment:.leading,spacing:14) {
                            Text("这一轮可处理项目已看完").font(.title2.bold())
                            if !skipped.isEmpty { Text("本次跳过 \(skipped.count) 项，仍保留在未处理清单。");Button("重新查看跳过的项目") { skipped = [] }.accessibilityIdentifier("focus.resetSkipped") }
                            if progress.total > 0 && progress.done == progress.total {
                                Button("确认完成这件事务") { perform { try studio.completeCase(item.id,completed:true,routines:workspace.routines.items);receipt = nil } }.buttonStyle(.borderedProminent).tint(SeePalette.button).accessibilityIdentifier("focus.finish")
                            } else {
                                Text("未处理的步骤依赖和关联待办会保留。请回到详情核对，专注模式不会代替关联待办的完成确认。").font(.subheadline).foregroundStyle(.secondary)
                                Button("返回清单继续检查") { dismiss() }
                            }
                        }.modifier(WorkspaceSurface())
                    }
                    if receipt != nil { ChecklistFeedback(studio:studio,receipt:$receipt).modifier(WorkspaceSurface()) }
                    if let error { FeatureMessage(title:"暂未更新",detail:error) }
                } else { FeatureMessage(title:"事务已移除",detail:"返回清单查看当前记录。") }
            }.padding(18)
        }.background(SeePalette.canvas).seePageCanvas().navigationTitle("专注处理").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("返回详情") { dismiss() }.accessibilityIdentifier("focus.close") } }
        }.modifier(WorkroomPrivacy())
    }
    private func perform(_ action:() throws -> Void) { do { try action();error = nil } catch { self.error = error.localizedDescription } }
}

struct ChecklistSheetRoute:Identifiable {
    enum Action { case batch,rename(CaseStep),order(ChecklistKind) }
    let id = UUID()
    let initial:WorkroomCase
    let action:Action
}
