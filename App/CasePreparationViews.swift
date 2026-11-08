import SwiftUI

struct WorkroomStageBar: View {
    let current: WorkroomStage
    let canOpen: (WorkroomStage) -> Bool
    let open: (WorkroomStage) -> Void
    var body: some View {
        HStack(spacing: 8) {
            ForEach(WorkroomStage.allCases) { stage in
                Button { open(stage) } label: {
                    VStack(spacing: 6) {
                        Text("\(stage.rawValue+1)").font(.subheadline.bold()).frame(width: 30,height: 30)
                            .background(current == stage ? SeePalette.rose : SeePalette.canvas, in: Circle())
                            .foregroundStyle(current == stage ? Color.seeAccent : SeePalette.secondary)
                        Text(stage.title).font(.caption.weight(current == stage ? .bold : .regular))
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain).disabled(!canOpen(stage)).accessibilityLabel("第 \(stage.rawValue+1) 步，\(stage.title)")
            }
        }.padding(.vertical,8)
    }
}

struct PreparedCaseReviewSections: View {
    @Binding var review: PreparedCaseDraft
    @Binding var acknowledged: Bool
    @Binding var saveLocally: Bool
    @State private var newTitle = ""
    @State private var newKind: CasePlanKind = .step
    var body: some View {
        Section("事务草稿 · \(review.source.generator)") {
            if review.source.origin == .demonstration { Label("演示草稿，非真实通知",systemImage:"play.rectangle").foregroundStyle(Color.seeAccent) }
            TextField("事务名称（最多 60 字）",text:$review.title)
            TextField("备注（最多 500 字）",text:$review.note,axis:.vertical)
            Text("来自：\(review.source.title) · 第 \(review.source.revision) 版").font(.caption).foregroundStyle(.secondary)
            Text("建议步骤只是安排建议。请逐项判断是否需要，不代表已经报名、缴费或完成核对。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(CasePlanKind.allCases) { kind in
            Section("\(kind.title) · 已选 \(review.items.filter { $0.kind == kind && $0.selected }.count) 项") {
                if !review.items.contains(where:{ $0.kind == kind }) { Text("没有自动提取到明确\(kind.title)，可以手动添加。").foregroundStyle(.secondary) }
                ForEach($review.items) { $row in
                    if row.kind == kind {
                        VStack(alignment:.leading,spacing:10) {
                            HStack(alignment:.top) {
                                Toggle("保留这项\(kind.title)",isOn:$row.selected).labelsHidden()
                                TextField("\(kind.title)名称",text:$row.title,axis:.vertical).font(.headline)
                            }
                            Text(row.basisTitle).font(.caption).foregroundStyle(Color.seeAccent)
                            if let proposal=row.proposal { DisclosureGroup("查看原文依据") { Text(proposal.quote).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) } }
                            Button("移除这项",role:.destructive) { review.items.removeAll { $0.id == row.id } }.font(.caption).buttonStyle(.borderless)
                        }.padding(.vertical,6)
                    }
                }
            }
        }
        Section("补一项自己的安排") {
            Picker("类型",selection:$newKind) { ForEach(CasePlanKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            TextField("自己添加的\(newKind.title)（最多 100 字）",text:$newTitle)
            Button("加入草稿") {
                review.items.append(ReviewedCaseItem(kind:newKind,title:newTitle.trimmingCharacters(in:.whitespacesAndNewlines),proposal:nil));newTitle=""
            }.disabled(newTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || newTitle.count > 100 || review.items.filter({ $0.kind == newKind }).count >= 30)
        }
        Section("建立前确认") {
            Toggle("我已检查所选材料、步骤和名称",isOn:$acknowledged).accessibilityIdentifier("prepared.acknowledged")
            Toggle("同时将本事务保存在本机",isOn:$saveLocally).accessibilityIdentifier("prepared.save")
            Text("默认只在本次运行保留。保存包含所选事项及其原文依据；原始图片不保存。信息卡、待办和通知不会自动建立。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
