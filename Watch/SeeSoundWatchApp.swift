import SwiftUI

private extension Color { static let journalRose = Color(red:0.97,green:0.73,blue:0.81) }

@main
struct SeeSoundWatchApp: App {
    @StateObject private var bridge = ConnectivityBridge()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHelp = false
    @State private var pendingAgenda:WatchAgendaItem?

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 8) {
                    HStack {
                        Label("见声", systemImage: "ear.badge.waveform").font(.headline)
                        Spacer()
                        Image(systemName: bridge.reachable ? "link" : "link.badge.plus")
                            .accessibilityLabel(bridge.reachable ? "手机可达" : "手机不可达")
                    }.foregroundStyle(Color.journalRose).padding(.vertical,4)
                    Text(bridge.linkState.title)
                    Text(bridge.linkState.guidance).font(.caption2).foregroundStyle(.secondary)
                    Text(bridge.status).font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !bridge.reachable {
                        Button("连接手机") { bridge.activate() }.buttonStyle(.bordered)
                    }
                    if let event = bridge.latestEvent {
                        Text(event.isDemonstration ? "演示 · 非识别结果" : event.source == .gesture ? "实验性动作规则" : "声音模型提醒")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(event.title).font(.headline).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(event.lastSeen, style: .time).font(.caption2).foregroundStyle(.secondary)
                        if bridge.confirmedIDs.contains(event.id) {
                            Label("已确认", systemImage: "checkmark.circle.fill")
                                .font(.headline).foregroundStyle(Color.journalRose).padding(.vertical, 8)
                        } else {
                            Button {
                                bridge.confirmLatest()
                            } label: {
                                Text(bridge.isSending(event.id) ? "正在回传…" : "我已看到")
                                    .font(.headline).frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).tint(Color.journalRose).foregroundStyle(.black)
                                .disabled(!bridge.reachable || bridge.isSending(event.id))
                            ForEach(WatchQuickReply.allCases) { reply in
                                Button(reply.title) { bridge.replyLatest(reply) }
                                    .font(.caption).buttonStyle(.bordered)
                                    .disabled(!bridge.reachable || bridge.isSending(event.id))
                            }
                        }
                        if let reply = bridge.quickReplyNotes[event.id] {
                            Text("回应：\(reply) · 不等于确认").font(.caption2).foregroundStyle(Color.journalRose)
                        }
                        Text(bridge.confirmationNotes[event.id] ?? bridge.delivery)
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "tray").font(.title2).foregroundStyle(Color.journalRose)
                            Text("等待一条提醒").font(.headline)
                            Text("在手机上手动发送事件，\n就能在这里查看和确认。")
                                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(.vertical, 8)
                    }
                    if !bridge.agendaItems.isEmpty {
                        Divider()
                        TimelineView(.periodic(from:.now,by:30)) { _ in
                            VStack(spacing:12) {
                                Text("旅程与事项").font(.headline)
                                ForEach(bridge.agendaItems) { item in
                                    VStack(alignment:.leading,spacing:7) {
                                        if item.demonstration { Text("演示摘要").font(.caption2).foregroundStyle(.orange) }
                                        Text(item.title).font(.headline).fixedSize(horizontal:false,vertical:true)
                                        if !item.next.isEmpty { Text(item.next).font(.caption2).foregroundStyle(.secondary) }
                                        if let due = item.dueAt { Text(due,style:.time).font(.caption2) }
                                        if item.outdated == true { Label("手机内容已变更，请重发摘要",systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                                        if item.completed { Label("手机已保存完成",systemImage:"checkmark.circle.fill").font(.caption).foregroundStyle(Color.journalRose) }
                                        else if item.seen { Label("手机已收到查看回执",systemImage:"checkmark.bubble").font(.caption).foregroundStyle(Color.journalRose) }
                                        else {
                                            Button(item.kind == .routine ? "确认完成待办" : "我已看到") {
                                                if item.kind == .routine { pendingAgenda = item }
                                                else { bridge.actOnAgenda(item,action:.seen) }
                                            }.disabled(!bridge.reachable || !bridge.agendaIsFresh || bridge.agendaSending || item.outdated == true)
                                        }
                                    }.frame(maxWidth:.infinity,alignment:.leading).padding(10)
                                        .background(LinearGradient(colors:[Color.journalRose.opacity(0.13),Color.white.opacity(0.04)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:18))
                                        .overlay(RoundedRectangle(cornerRadius:18).stroke(Color.journalRose.opacity(0.22),lineWidth:1))
                                }
                                if !bridge.agendaIsFresh { Text("摘要已过期，请从手机重发。").font(.caption2).foregroundStyle(.orange) }
                            }
                        }
                        Text(bridge.agendaDelivery.title).font(.caption2).foregroundStyle(Color.journalRose)
                        Text(bridge.agendaStatus).font(.caption2).foregroundStyle(.secondary)
                        Button("清除手表上的事务摘要") { bridge.clearWatchAgenda() }.font(.caption2)
                    }
                    Button("使用说明") { showHelp = true }.font(.caption2).buttonStyle(.plain)
                }.padding(.horizontal, 6)
            }
            .onChange(of: scenePhase) { phase in
                bridge.appIsActive = phase == .active
                if phase == .active { bridge.refresh() }
            }
            .onAppear { bridge.appIsActive = true; bridge.activate() }
            .confirmationDialog("确认完成这项待办？",isPresented:Binding(get:{pendingAgenda != nil},set:{ if !$0 { pendingAgenda = nil } })) {
                Button("标记待办完成") { if let item = pendingAgenda { bridge.actOnAgenda(item,action:.complete) };pendingAgenda = nil }
                Button("取消",role:.cancel) { pendingAgenda = nil }
            } message: { Text("手机保存并返回有效回执后才显示完成。") }
            .sheet(isPresented: $showHelp) {
                ScrollView {
                    VStack(spacing: 12) {
                        Text("可查看手机主动发送的事件与最多五项事务摘要。事务摘要保存在手表本机，十分钟后需重发；断线不排队。待办完成需要手机回执，事务已看到不会自动完成步骤。事件会话状态在重启后需重新发送。模拟器不能验证腕上触觉。")
                            .font(.caption)
                        Button("知道了") { showHelp = false }
                    }.padding()
                }
            }
        }
    }
}
