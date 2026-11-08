import SwiftUI

struct KeyboardCloseToolbar:ViewModifier {
    func body(content:Content) -> some View {
        content.scrollDismissesKeyboard(.interactively).toolbar {
            ToolbarItemGroup(placement:.keyboard) { Spacer();Button("收起键盘") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil) }.accessibilityIdentifier("keyboard.dismiss") }
        }
    }
}
struct WorkroomNoticeBanner:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @State private var error:String?
    @Environment(\.dynamicTypeSize) private var typeSize
    var body:some View {
        if let notice = studio.notice {
            VStack(alignment:.leading,spacing:6) {
                if typeSize.isAccessibilitySize {
                    Text(notice.text).font(.subheadline).fixedSize(horizontal:false,vertical:true)
                    HStack(spacing:12) { actions(notice);Spacer(minLength:4);closeButton }
                } else {
                    HStack(alignment:.center,spacing:12) {
                        Text(notice.text).font(.subheadline).fixedSize(horizontal:false,vertical:true)
                        Spacer(minLength:4);actions(notice);closeButton
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.onChange(of:notice.id) { _,_ in error = nil }.padding(.horizontal,18).padding(.vertical,8).background(.regularMaterial)
        }
    }
    private var closeButton:some View { Button { studio.clearNotice() } label: { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("关闭操作提示") }
    @ViewBuilder private func actions(_ notice:WorkroomNotice) -> some View {
        switch notice.action {
        case .restore(let id): Button("恢复") { perform { try studio.restoreDeleted(id) } }.accessibilityIdentifier("notice.restore")
        case .undoFiling: Button("撤销") { perform { try studio.undoLastFiling() } }.accessibilityIdentifier("notice.undoFiling")
        case .recentlyDeleted: Button("查看") { workspace.navigationRequest = .recentlyDeleted }.accessibilityIdentifier("notice.trash")
        case .none: EmptyView()
        }
    }
    private func perform(_ work:() throws -> Void) { do { try work();error = nil } catch { self.error = error.localizedDescription } }
}
struct RecentlyDeletedPage:View {
    @ObservedObject var studio:WorkroomService
    @State private var permanent:Set<UUID> = []
    @State private var error:String?
    var body:some View {
        List {
            Section {
                Label("给误操作留一次回头的机会",systemImage:"arrow.uturn.backward.circle").font(.title2.bold())
                Text("最近删除最多保留 50 条，直到你恢复或永久清理。恢复事务时旧提醒保持关闭；仅本次运行的事务也仅在本次可恢复。普通备份不包含这里的内容。").font(.subheadline).foregroundStyle(.secondary)
                if studio.filingUndo != nil { Button("撤销最近一次分类调整") { perform { try studio.undoLastFiling() } } }
                if !studio.trash.isEmpty { Button("永久清空最近删除",role:.destructive) { permanent = Set(studio.trash.map(\.id)) } }
            }
            ForEach(studio.trash) { entry in
                Section {
                    VStack(alignment:.leading,spacing:8) {
                        Text(entry.title).font(.headline)
                        Text((entry.draft == nil ? "事务" : "草稿")+(entry.demonstration ? " · 演示" : "")+(entry.savedLocally ? " · 已存本机" : " · 仅本次运行")).font(.caption).foregroundStyle(.secondary)
                        Text(entry.deletedAt,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        if let item = entry.project { Text("恢复后状态："+item.stateTitle).font(.caption) }
                    }
                    DisclosureGroup("查看保留内容") {
                        Text(entry.draft?.text ?? entry.project?.export(routines:[]) ?? "").textSelection(.enabled)
                    }
                    Button("恢复原记录",systemImage:"arrow.uturn.backward") { perform { try studio.restoreDeleted(entry.id) } }.accessibilityIdentifier("trash.restore."+entry.recordID.uuidString)
                    Button("永久删除这条记录",role:.destructive) { permanent = [entry.id] }
                }
            }
            if studio.trash.isEmpty { ContentUnavailableView("最近删除是空的",systemImage:"trash",description:Text("移除的草稿和事务会先来到这里。")) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.seePageCanvas().navigationTitle("最近删除")
            .confirmationDialog("永久删除所选 \(permanent.count) 条记录？这一步不能恢复，仅被这些记录引用的原图也会清理。",isPresented:Binding(get:{!permanent.isEmpty},set:{if !$0 { permanent = [] }}),titleVisibility:.visible) {
                Button("确认永久删除",role:.destructive) { perform { try studio.permanentlyRemoveDeleted(permanent);permanent = [] } }
            }.modifier(WorkroomPrivacy())
    }
    private func perform(_ work:() throws -> Void) { do { try work();error = nil } catch { self.error = error.localizedDescription } }
}
struct CleanupPreviewPage:View {
    @ObservedObject var studio:WorkroomService
    let preview:CleanupChangePreview
    let completed:()->Void
    @Environment(\.dismiss) private var dismiss
    @State private var error:String?
    var body:some View {
        NavigationStack { List {
            Section("这次将移到最近删除") {
                LabeledContent("草稿",value:"\(preview.draftIDs.count)");LabeledContent("已归档事务",value:"\(preview.caseIDs.count)")
                Text("原始信息卡、待办和当前编辑区保留。所选记录与仍被引用的原图可从最近删除恢复。").font(.caption).foregroundStyle(.secondary)
            }
            Section("所选记录") { ForEach(Array(preview.titles.enumerated()),id:\.offset) { _,title in Text(title) } }
            Section { Button("确认移到最近删除") { do { try studio.applyCleanupPreview(preview);completed();dismiss() } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("cleanup.confirm");if let error { Text(error).foregroundStyle(.red) } }
        }.seePageCanvas().navigationTitle("清理前预览").toolbar { Button("返回修改") { dismiss() } } }.modifier(WorkroomPrivacy())
    }
}
