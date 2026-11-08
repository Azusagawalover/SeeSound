import SwiftUI

@MainActor enum ExampleNotificationImage {
    static func make() -> Data {
        let size = CGSize(width:1800,height:1800),format = UIGraphicsImageRendererFormat();format.scale = 1
        return UIGraphicsImageRenderer(size:size,format:format).image { context in
            UIColor.white.setFill();context.fill(CGRect(origin:.zero,size:size))
            let title = "见声 · 内置体验通知"
            (title as NSString).draw(at:CGPoint(x:100,y:90),withAttributes:[.font:UIFont.boldSystemFont(ofSize:74),.foregroundColor:UIColor.systemTeal])
            let paragraph = NSMutableParagraphStyle();paragraph.lineSpacing = 30
            (ExampleExperience.notification().text as NSString).draw(in:CGRect(x:100,y:260,width:1600,height:1450),withAttributes:[.font:UIFont.systemFont(ofSize:66),.foregroundColor:UIColor.black,.paragraphStyle:paragraph])
        }.pngData() ?? Data()
    }
}
struct ExampleExperiencePage:View {
    @ObservedObject var workspace:Workspace
    @ObservedObject var studio:WorkroomService
    @State private var error:String?
    @State private var replacing = false
    @State private var clearing = false
    private var example:WorkroomCase? { studio.cases.first { $0.exampleGroup == ExampleExperience.groupID && $0.demonstration } }
    var body:some View {
        List {
            Section {
                Label("从一份通知，到办完一件事",systemImage:"play.rectangle.fill").font(.title2.bold())
                Text("体验会在本机创建标注为演示的通知与事务。示例使用固定的虚构安排，整个流程可以离线完成，随时能单独清理。").font(.subheadline).foregroundStyle(.secondary)
                Button("开始完整体验：导入示例通知",systemImage:"text.viewfinder") { requestStart() }.accessibilityIdentifier("experience.start")
                Button("直接查看示例事务",systemImage:"list.bullet.clipboard") { perform { if let id = try studio.installExampleSources(includeProject:true) { workspace.scheduledDestination = .init(kind:.project,recordID:id) } } }.accessibilityIdentifier("experience.quickCase")
                if let example {
                    Button("继续当前示例："+example.title) { workspace.scheduledDestination = .init(kind:.project,recordID:example.id) }.accessibilityIdentifier("experience.continue")
                    Text("目前："+example.stateTitle+" · \(example.progress(routines:workspace.routines.items).done)/\(example.progress(routines:workspace.routines.items).total) 项已处理").font(.caption).foregroundStyle(Color.seeAccent)
                }
            }
            Section("按这五步体验") {
                step(1,"导入并核对","识别示例通知，打开原图对照。检查时间、地点和学生证，再使用文字。")
                step(2,"整理成事务","选择离线整理，预览材料和步骤，勾选检查及本机保存，再建立事务。")
                step(3,"收到补充通知","事务材料页加入“内置体验 · 补充通知”，打开与现有安排对照。")
                step(4,"确认改期和新增材料","检查时间、地点、费用摘要，选择报名凭证。确认后加入未准备项，旧进度保留。")
                step(5,"完成与找回","按下一步处理清单，完成后可体验移到最近删除及恢复；恢复不会重开旧提醒。")
            }
            Section("也试试新的清单工具") {
                Text("打开示例事务，在清单工具里进入专注处理，可以跳过、逐项处理和撤销。全部项目完成后，再确认完成事务。")
                Text("更多清单操作支持批量预览及顺序调整；项目右侧的菜单可以改名。名称改变后，建立时依据仍保留。")
            }
            Section("示例工具") {
                NavigationLink("查看最近删除") { RecentlyDeletedPage(studio:studio) }
                Button("只清理这套内置体验数据",role:.destructive) { clearing = true }.accessibilityIdentifier("experience.clear")
                Text("只按内置体验的专用标记清理。你手动创建的普通资料及其他演示资料保留。").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Section { FeatureMessage(title:"体验暂未开始",detail:error) } }
        }.seePageCanvas().navigationTitle("完整体验")
            .confirmationDialog("当前工作室有未保存文字。",isPresented:$replacing,titleVisibility:.visible) {
                Button("先保存当前草稿，再开始") { perform { try studio.saveDraft();try start() } }
                Button("不保留当前未存文字，开始示例",role:.destructive) { perform { try start() } }
            }
            .confirmationDialog("清理这套内置体验创建的材料、事务及其最近删除副本？",isPresented:$clearing,titleVisibility:.visible) { Button("确认清理内置体验",role:.destructive) { perform { try studio.clearExampleExperience() } } }
            .modifier(WorkroomPrivacy())
    }
    private func requestStart() {
        let active = studio.active
        if !active.text.isEmpty,active.exampleGroup != ExampleExperience.groupID,!studio.drafts.contains(where:{$0.id == active.id && $0.text == active.text}) { replacing = true }
        else { perform { try start() } }
    }
    private func start() throws {
        _ = try studio.installExampleSources(includeProject:false);studio.newDraft()
        workspace.pendingExampleImport = .init(image:ExampleNotificationImage.make(),title:ExampleExperience.notification().title,group:ExampleExperience.groupID)
        workspace.navigationRequest = .workroom
    }
    private func step(_ number:Int,_ title:String,_ text:String) -> some View {
        HStack(alignment:.top,spacing:12) { Text("\(number)").font(.headline).frame(width:30,height:30).background(Color.seeAccent.opacity(0.1),in:Circle());VStack(alignment:.leading,spacing:7) { Text(title).font(.headline);Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) } }.padding(.vertical,6)
    }
    private func perform(_ action:() throws -> Void) { do { try action();error = nil } catch { self.error = error.localizedDescription } }
}
struct EvidenceZoomCanvas:View {
    let image:UIImage
    let region:OCRTextRegion?
    @State private var zoom:CGFloat = 1
    @State private var offset = CGSize.zero
    @GestureState private var magnification:CGFloat = 1
    @GestureState private var translation = CGSize.zero
    var body:some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width/image.size.width,geometry.size.height/image.size.height)
            let width = image.size.width*scale,height = image.size.height*scale
            let total = min(5,max(1,zoom*magnification))
            let xLimit = max(0,(width*total-geometry.size.width)/2),yLimit = max(0,(height*total-geometry.size.height)/2)
            let x = min(xLimit,max(-xLimit,offset.width+translation.width)),y = min(yLimit,max(-yLimit,offset.height+translation.height))
            ZStack {
                Color(.tertiarySystemFill)
                Image(uiImage:image).resizable().frame(width:width,height:height).overlay {
                    if let region {
                        Rectangle().fill(Color.orange.opacity(0.18)).overlay(Rectangle().stroke(Color.orange,lineWidth:2/total))
                            .frame(width:region.width*width,height:region.height*height)
                            .position(x:(region.x+region.width/2)*width,y:(1-region.y-region.height/2)*height)
                    }
                }.scaleEffect(total).offset(x:x,y:y)
            }.frame(width:geometry.size.width,height:geometry.size.height).clipped().contentShape(Rectangle())
                .gesture(MagnificationGesture().updating($magnification) { value,state,_ in state = value }.onEnded { value in zoom = min(5,max(1,zoom*value)) })
                .simultaneousGesture(DragGesture().updating($translation) { value,state,_ in if zoom > 1 { state = value.translation } }.onEnded { value in if zoom > 1 { offset = CGSize(width:min(xLimit,max(-xLimit,offset.width+value.translation.width)),height:min(yLimit,max(-yLimit,offset.height+value.translation.height))) } })
                .onChange(of:region?.id) { _,_ in if let region,zoom > 1 { offset = CGSize(width:min(xLimit,max(-xLimit,-(region.x+region.width/2-0.5)*width*zoom)),height:min(yLimit,max(-yLimit,-((1-region.y-region.height/2)-0.5)*height*zoom))) } }
        }.overlay(alignment:.bottom) {
            HStack(spacing:16) {
                Button { zoom = max(1,zoom-0.5);if zoom == 1 { offset = .zero } } label: { Image(systemName:"minus.magnifyingglass").frame(width:44,height:44) }.accessibilityLabel("缩小原图")
                Text("\(zoom,format:.number.precision(.fractionLength(1)))×").font(.caption.monospacedDigit()).accessibilityIdentifier("compare.zoom")
                Button { zoom = min(5,zoom+0.5) } label: { Image(systemName:"plus.magnifyingglass").frame(width:44,height:44) }.accessibilityLabel("放大原图").accessibilityIdentifier("compare.zoomIn")
                Button("复位") { zoom = 1;offset = .zero }.frame(minHeight:44)
            }.padding(.horizontal,12).background(.regularMaterial,in:Capsule()).padding(8)
        }.clipShape(RoundedRectangle(cornerRadius:14)).accessibilityElement(children:.contain)
    }
}
