// WatchConnectivity lifecycle and message patterns adapted from
// NAOYA-MAEDA-DEV/Watch-Connectivity-Sample (MIT). See References/Watch/LICENSE.
import Combine
import Foundation
import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

@MainActor
final class ConnectivityBridge: NSObject, ObservableObject {
    @Published private(set) var status = "尚未激活通信"
    @Published private(set) var delivery = "未发送事件"
    @Published private(set) var reachable = false
    @Published private(set) var linkState:WatchLinkState = .idle
    @Published private(set) var agendaDelivery:WatchAgendaDeliveryState = .idle
    @Published private(set) var latestEvent: SenseEvent?
    @Published private(set) var confirmedIDs: Set<UUID> = []
    @Published private(set) var transfers = DeliveryTracker()
    @Published private(set) var confirmationNotes: [UUID: String] = [:]
    @Published private(set) var quickReplyNotes: [UUID: String] = [:]
    @Published private(set) var agendaItems:[WatchAgendaItem] = []
    @Published private(set) var agendaStatus = "还没有发送事务摘要"
    @Published private(set) var agendaSending = false
    @Published private(set) var latestAgendaDate:Date?
    var onAgendaConnection:(()->Void)?
    var onAgendaAction:((UUID,String,WatchAgendaAction) -> WatchAgendaResolution)?
    private var sentAgenda:[UUID:WatchAgendaItem] = [:]
    private var agendaAttempt = UUID()
    private var agendaReplies = AgendaReplyCache()
    private var retryActions:[UUID:WatchAgendaPacket] = [:]
    var onConfirmation: ((UUID) -> Bool)?
    var onQuickReply: ((UUID, WatchQuickReply) -> Bool)?
    var isLocallyConfirmed: ((UUID) -> Bool)?
    var appIsActive = false

    private var activeSession: WCSession?
    private var receivedIDs: [UUID] = []
    private var sentIDs: Set<UUID> = []
    private var sentOrder: [UUID] = []
    private var receivedEvents: [UUID: SenseEvent] = [:]

    func activate() {
        guard WCSession.isSupported() else {
            linkState = .unsupported;status = "此设备不支持直接与 Watch 通信；请在配对的 iPhone 上验证"
            return
        }
        if let session = activeSession, session.activationState == .activated { refresh(); return }
        #if os(watchOS)
        loadWatchAgenda()
        #endif
        let session = WCSession.default
        activeSession = session
        session.delegate = self
        linkState = .activating;status = "正在连接配对设备"
        session.activate()
    }

    func refresh() {
        guard let session = activeSession else { return }
        reachable = session.activationState == .activated && session.isReachable
        #if os(iOS)
        linkState = .evaluate(supported:true,active:session.activationState == .activated,paired:session.isPaired,installed:session.isWatchAppInstalled,reachable:reachable)
        if reachable { status = "对端当前可达" }
        else if !session.isPaired { status = "未发现与此 iPhone 配对的 Watch" }
        else if !session.isWatchAppInstalled { status = "已配对，请先安装并打开「见声」Watch App" }
        else { status = reachable ? "对端当前可达" : "对端当前不可达，请打开两端 App" }
        #else
        linkState = .evaluate(supported:true,active:session.activationState == .activated,paired:true,installed:true,reachable:reachable)
        status = reachable ? "配对 iPhone 当前可达" : "配对 iPhone 当前不可达，请打开两端 App"
        #endif
    }

    func sendEvent(_ event: SenseEvent) {
        guard event.status == .pending else { delivery = "事件已确认，无需重复转发"; return }
        guard (try? PacketCodec.decode(PacketCodec.encode(.event(event)))) != nil else {
            delivery = "事件过期或格式不正确，未发送"
            return
        }
        sentIDs.insert(event.id)
        sentOrder.removeAll { $0 == event.id }
        sentOrder.append(event.id)
        while sentOrder.count > 100 { sentIDs.remove(sentOrder.removeFirst()) }
        latestEvent = event
        transmit(.event(event))
    }

    func confirmLatest() {
        guard let event = latestEvent else { return }
        guard !confirmedIDs.contains(event.id) else { return }
        guard reachable else { delivery = "无法回传确认：对端不可达；本轮不在后台排队"; return }
        transmit(.response(.confirmation, to: event.id))
    }

    func replyLatest(_ reply: WatchQuickReply) {
        guard let event = latestEvent, !confirmedIDs.contains(event.id), event.status == .pending,
              Date().timeIntervalSince(event.lastSeen) <= 300, reachable else {
            delivery = "暂不能回应；请检查连接、事件时间和确认状态"; return
        }
        transmit(.response(.quickReply, to: event.id, quickReply: reply))
    }

    func syncConfirmation(_ id: UUID) {
        guard sentIDs.contains(id) else { return }
        guard !confirmedIDs.contains(id) else { return }
        guard reachable else { delivery = "手机已确认，手表尚未同步；连接后可手动重试"; return }
        if isSending(id) { delivery = "手机已确认，等待事件送达后同步"; return }
        transmit(.response(.confirmation, to: id))
    }

    func isSending(_ id: UUID) -> Bool { transfers.records[id]?.phase == .sending }

    private func transmit(_ packet: WatchPacket) {
        guard let session = activeSession, session.activationState == .activated, session.isReachable else {
            refresh()
            delivery = "未发送：对端不可达；本轮未实现离线排队"
            return
        }
        do {
            let data = try PacketCodec.encode(packet)
            guard let token = transfers.begin(packet.reference, message: "正在发送，等待对端回执") else { return }
            delivery = "正在发送，等待对端回执"
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                self?.finish(packet, token: token, phase: .failed, message: "等待回执超时；结果尚不确定，可以手动重试")
            }
            session.sendMessage(["packet": data], replyHandler: { [weak self] reply in
                let data = reply["packet"] as? Data
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let attempt = self.transfers.records[packet.reference],
                          attempt.token == token, attempt.phase == .sending else { return }
                    guard let data, let receipt = try? PacketCodec.decode(data),
                          receipt.kind == .receipt, receipt.reference == packet.reference,
                          receipt.quickReply == packet.quickReply else {
                        self.finish(packet, token: token, phase: .failed, message: "回执无效，不能确认送达")
                        return
                    }
                    if packet.kind == .quickReply, let reply = packet.quickReply {
                        if self.finish(packet, token: token, phase: .received, message: "手机已接收回应：\(reply.title)；事件尚未确认") {
                            self.quickReplyNotes[packet.reference] = reply.title
                            self.trimQuickReplies()
                        }
                    } else if packet.kind == .confirmation {
                        let note: String
                        #if os(watchOS)
                        note = "已在手表确认，手机已接收"
                        #else
                        note = "已在手机确认，手表已接收"
                        #endif
                        if self.finish(packet, token: token, phase: .confirmed, message: note) {
                            self.rememberConfirmation(packet.reference, note: note)
                        }
                    } else if receipt.isConfirmed == true {
                        #if os(iOS)
                        guard self.onConfirmation?(packet.reference) == true else {
                            self.finish(packet, token: token, phase: .failed, message: "对端确认已收到，但本机对应记录已被移除")
                            return
                        }
                        #endif
                        let note = "对端此前已确认，状态已同步"
                        if self.finish(packet, token: token, phase: .confirmed, message: note) {
                            self.rememberConfirmation(packet.reference, note: note)
                        }
                    } else {
                        if self.finish(packet, token: token, phase: .received, message: "对端 App 已接收；尚不代表用户已查看"),
                           self.isLocallyConfirmed?(packet.reference) == true {
                            self.syncConfirmation(packet.reference)
                        }
                    }
                }
            }, errorHandler: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.finish(packet, token: token, phase: .failed, message: "发送失败：\(error.localizedDescription)")
                }
            })
        } catch { delivery = "消息无法编码，未发送" }
    }

    @discardableResult
    private func finish(_ packet: WatchPacket, token: UUID, phase: DeliveryPhase, message: String) -> Bool {
        guard transfers.finish(packet.reference, token: token, phase: phase, message: message) else { return false }
        if latestEvent?.id == packet.reference { delivery = message }
        return true
    }

    private func rememberConfirmation(_ id: UUID, note: String) {
        confirmedIDs.insert(id)
        confirmationNotes[id] = note
        if confirmedIDs.count > 100 {
            let keep = Set(sentOrder + receivedIDs + [id])
            confirmedIDs = confirmedIDs.intersection(keep)
            if confirmedIDs.count > 100 {
                let extras = confirmedIDs.filter { $0 != id }.prefix(confirmedIDs.count - 100)
                for extra in extras { confirmedIDs.remove(extra) }
            }
            confirmationNotes = confirmationNotes.filter { confirmedIDs.contains($0.key) }
        }
        transfers.confirm(id, message: note)
    }

    private func trimQuickReplies() {
        let keep = Set(sentOrder + receivedIDs + (latestEvent.map { [$0.id] } ?? []))
        quickReplyNotes = quickReplyNotes.filter { keep.contains($0.key) }
    }

    private func receive(_ data: Data) -> Data? {
        guard let packet = try? PacketCodec.decode(data) else {
            delivery = "已拒绝过期或格式不正确的消息"
            return nil
        }
        switch packet.kind {
        case .quickReply:
            #if os(iOS)
            guard sentIDs.contains(packet.reference), !confirmedIDs.contains(packet.reference),
                  let reply = packet.quickReply, onQuickReply?(packet.reference, reply) == true else { return nil }
            quickReplyNotes[packet.reference] = reply.title
            trimQuickReplies()
            if latestEvent?.id == packet.reference { delivery = "手表回应：\(reply.title)；事件尚未确认" }
            return try? PacketCodec.encode(.response(.receipt, to: packet.reference, quickReply: reply))
            #else
            return nil
            #endif
        case .event:
            guard var event = packet.event else { return nil }
            let isNew = !receivedIDs.contains(event.id)
            if isNew {
                receivedIDs.append(event.id)
                if receivedIDs.count > 100 { receivedEvents[receivedIDs.removeFirst()] = nil }
            }
            if confirmedIDs.contains(event.id) { event.status = .confirmed }
            if let existing = receivedEvents[event.id], existing.lastSeen > event.lastSeen {
                return try? PacketCodec.encode(.response(.receipt, to: packet.reference, isConfirmed: confirmedIDs.contains(event.id)))
            }
            receivedEvents[event.id] = event
            if latestEvent == nil || latestEvent?.id == event.id || event.lastSeen >= latestEvent!.lastSeen {
                latestEvent = event
                delivery = confirmedIDs.contains(event.id) ? (confirmationNotes[event.id] ?? "已确认")
                    : isNew ? "收到事件，等待你确认" : "重复事件已更新，没有新增提醒"
            }
            #if os(watchOS)
            if isNew && event.status == .pending && appIsActive { WKInterfaceDevice.current().play(.notification) }
            #endif
        case .confirmation:
            #if os(watchOS)
            guard receivedEvents[packet.reference] != nil else {
                delivery = "确认不对应本次收到的事件"
                return nil
            }
            let note = "已在手机确认"
            #else
            guard sentIDs.contains(packet.reference), onConfirmation?(packet.reference) == true else {
                delivery = "确认不对应本次会话中的已发送事件"
                return nil
            }
            let note = "已在手表确认"
            #endif
            rememberConfirmation(packet.reference, note: note)
            if latestEvent?.id == packet.reference { latestEvent?.status = .confirmed; delivery = note }
        case .receipt:
            return nil
        }
        return try? PacketCodec.encode(.response(.receipt, to: packet.reference, isConfirmed: confirmedIDs.contains(packet.reference)))
    }
}

extension ConnectivityBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            if let error { self.linkState = .failed;self.status = "激活失败：\(error.localizedDescription)" }
            else { self.refresh();self.onAgendaConnection?() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh();self.onAgendaConnection?() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        if let data = message["agendaPacket"] as? Data {
            Task { @MainActor in replyHandler(self.receiveAgenda(data) ?? [:]) };return
        }
        guard let data = message["packet"] as? Data else { replyHandler([:]); return }
        Task { @MainActor in
            guard let receipt = self.receive(data) else { replyHandler([:]); return }
            replyHandler(["packet": receipt])
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in self.reachable = false;self.linkState = .unreachable; self.status = "通信会话已暂停" }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in self.reachable = false;self.linkState = .idle; self.activeSession = nil; self.status = "配对已改变，请重新激活" }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }
    #endif
}


extension ConnectivityBridge {
    var agendaIsFresh:Bool { latestAgendaDate.map { Date().timeIntervalSince($0) <= 600 } == true }
    func sendAgenda(_ items:[WatchAgendaItem]) {
        guard !agendaSending else { return }
        let packet = WatchAgendaPacket(kind:.snapshot,items:items)
        guard let data = try? WatchAgendaCodec.encode(packet) else { agendaDelivery = .refused;agendaStatus = "摘要格式不符合要求，最多选择 5 项。";return }
        UserDefaults.standard.set(items.map { $0.id.uuidString },forKey:"SeeSound.sentAgendaIDs")
        guard let session = activeSession,session.isReachable else { agendaDelivery = .refused;agendaStatus = "尚未发送，请先打开配对的两端 App。";return }
        sentAgenda = Dictionary(uniqueKeysWithValues:items.map { ($0.id,$0) })
        let token = beginAgendaAttempt()
        session.sendMessage(["agendaPacket":data],replyHandler:{ [weak self] reply in
            let accepted = reply["agendaAccepted"] as? Bool,batch = reply["agendaBatchID"] as? String
            Task { @MainActor in
                guard let self,self.agendaAttempt == token else { return }
                self.agendaSending = false
                self.agendaDelivery = accepted == true && batch == packet.id.uuidString ? .received : .unknown
                self.agendaStatus = accepted == true && batch == packet.id.uuidString ? "手表 App 已接收摘要，不代表用户已查看。" : "没有取得有效接收回执，请重试。"
            }
        },errorHandler:{ [weak self] _ in Task { @MainActor in guard let self,self.agendaAttempt == token else { return };self.agendaSending = false;self.agendaDelivery = .unknown;self.agendaStatus = "发送失败，未确认送达；连接后可手动重试。" } })
    }
    var lastAgendaIDs:[UUID] { (UserDefaults.standard.stringArray(forKey:"SeeSound.sentAgendaIDs") ?? []).compactMap(UUID.init(uuidString:)) }
    func retryAgenda(current:[WatchAgendaItem]) {
        let ids = lastAgendaIDs
        guard !ids.isEmpty else { agendaStatus = "还没有可重发的摘要选择，请先选择记录。";return }
        let items = ids.compactMap { id in current.first(where:{$0.id == id}) }
        guard items.count == ids.count else { agendaStatus = "上次所选记录有删除或已结束，请重新选择；没有发送旧副本。";return }
        sendAgenda(items)
    }
    func actOnAgenda(_ item:WatchAgendaItem,action:WatchAgendaAction) {
        guard !agendaSending else { return }
        guard agendaIsFresh,reachable,let session = activeSession,!item.completed,item.outdated != true,
              action == .seen || item.kind == .routine else { agendaDelivery = .refused;agendaStatus = "摘要已过期、已完成或手机不可达，请重新发送。";return }
        let packet:WatchAgendaPacket
        if let previous = retryActions[item.id],previous.fingerprint == item.fingerprint,previous.action == action,Date().timeIntervalSince(previous.date) <= 600 { packet = previous }
        else { packet = WatchAgendaPacket(kind:.action,recordID:item.id,fingerprint:item.fingerprint,action:action);retryActions[item.id] = packet }
        guard let data = try? WatchAgendaCodec.encode(packet) else { return }
        let token = beginAgendaAttempt()
        session.sendMessage(["agendaPacket":data],replyHandler:{ [weak self] reply in
            let data = reply["agendaPacket"] as? Data
            Task { @MainActor in
                guard let self,self.agendaAttempt == token else { return };self.agendaSending = false
                guard let data,let receipt = try? WatchAgendaCodec.decode(data) else { self.agendaDelivery = .unknown;self.agendaStatus = "回执无效，手机处理结果未知，可重试。";return }
                self.agendaDelivery = WatchReceiptPolicy.state(request:packet,response:receipt)
                guard self.agendaDelivery != .unknown else { self.agendaStatus = "回执缺少有效的当前记录，请从手机重新发送摘要核对。";return }
                self.agendaStatus = receipt.message ?? "已收到手机回应"
                if receipt.accepted == true,let updated = receipt.items.first,updated.id == item.id,let index = self.agendaItems.firstIndex(where:{$0.id == item.id}) {
                    self.agendaItems[index] = updated;self.retryActions[item.id] = nil;self.persistWatchAgenda()
                }
            }
        },errorHandler:{ [weak self] _ in Task { @MainActor in guard let self,self.agendaAttempt == token else { return };self.agendaSending = false;self.agendaDelivery = .unknown;self.agendaStatus = "未取得手机回执，状态未改。连接后可重试。" } })
    }
    private func beginAgendaAttempt() -> UUID {
        let token = UUID();agendaAttempt = token;agendaSending = true;agendaDelivery = .awaitingReceipt;agendaStatus = "正在传递，等待对端回执…"
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds:12_000_000_000)
            guard let self,self.agendaAttempt == token,self.agendaSending else { return }
            self.agendaAttempt = UUID();self.agendaSending = false;self.agendaDelivery = .unknown;self.agendaStatus = "等待回执超时，结果未知，可以手动重试。"
        };return token
    }
    private func receiveAgenda(_ data:Data) -> [String:Any]? {
        guard let packet = try? WatchAgendaCodec.decode(data) else { return nil }
        switch packet.kind {
        case .snapshot:
            #if os(watchOS)
            guard latestAgendaDate.map({ packet.date >= $0 }) ?? true else { return nil }
            agendaItems = packet.items;latestAgendaDate = packet.date;agendaDelivery = .received;agendaStatus = "收到摘要，10 分钟内可回传操作；重启后保留所选摘要。"
            persistWatchAgenda()
            return ["agendaAccepted":true,"agendaBatchID":packet.id.uuidString]
            #else
            return nil
            #endif
        case .action:
            #if os(iOS)
            if let cached = agendaReplies.receipt(for:packet) { return ["agendaPacket":cached] }
            guard let id = packet.recordID,let fingerprint = packet.fingerprint,let action = packet.action,sentAgenda[id]?.fingerprint == fingerprint else { return nil }
            let result = onAgendaAction?(id,fingerprint,action) ?? WatchAgendaResolution(accepted:false,message:"手机记录当前不可用，请重新发送。",item:nil)
            let receipt = WatchAgendaPacket(id:packet.id,kind:.receipt,items:result.item.map { [$0] } ?? [],recordID:id,fingerprint:fingerprint,action:action,accepted:result.accepted,message:result.message)
            guard let data = try? WatchAgendaCodec.encode(receipt) else { return nil }
            try? agendaReplies.remember(request:packet,response:receipt)
            if result.accepted,let updated = result.item { sentAgenda[id] = updated }
            agendaDelivery = result.accepted ? .applied : .refused;agendaStatus = result.message
            return ["agendaPacket":data]
            #else
            return nil
            #endif
        case .receipt:return nil
        }
    }
    func clearWatchAgenda() {
        do {
            if FileManager.default.fileExists(atPath:watchAgendaURL.path) { try FileManager.default.removeItem(at:watchAgendaURL) }
            agendaItems = [];latestAgendaDate = nil;retryActions = [:];agendaStatus = "手表事务摘要已清除，手机原记录保留。"
        } catch { agendaStatus = "摘要清除未完成，请稍后重试。" }
    }
    private var watchAgendaURL:URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("SeeSoundHandoff/agenda.json") }
    private func persistWatchAgenda() {
        #if os(watchOS)
        do {
            var packet = WatchAgendaPacket(kind:.snapshot,items:agendaItems);packet.date = latestAgendaDate ?? .now
            let data = try WatchAgendaCodec.encode(packet)
            var directory = watchAgendaURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            var values = URLResourceValues();values.isExcludedFromBackup = true;try directory.setResourceValues(values)
            try data.write(to:watchAgendaURL,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:watchAgendaURL.path)
        } catch { agendaStatus += " 摘要只在本次运行保留，请重新发送。" }
        #endif
    }
    private func loadWatchAgenda() {
        #if os(watchOS)
        guard agendaItems.isEmpty,FileManager.default.fileExists(atPath:watchAgendaURL.path) else { return }
        do {
            guard try watchAgendaURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 24_000 else { return }
            let packet = try WatchAgendaCodec.decode(Data(contentsOf:watchAgendaURL));guard packet.kind == .snapshot else { return }
            agendaItems = packet.items;latestAgendaDate = packet.date;agendaStatus = "已载入上次收到的摘要，操作前需与手机连接。"
        } catch { agendaStatus = "旧摘要已过期或不可读，请从手机重新发送。" }
        #endif
    }
}


extension ConnectivityBridge {
    func refreshAgendaVersions(_ current:[WatchAgendaItem]) {
        #if os(iOS)
        guard let session = activeSession,session.activationState == .activated else { return }
        let selected = Array((UserDefaults.standard.stringArray(forKey:"SeeSound.sentAgendaIDs") ?? []).prefix(5))
        guard !selected.isEmpty else { return }
        let versions = Dictionary(uniqueKeysWithValues:selected.map { id in (id,current.first(where:{$0.id.uuidString == id})?.fingerprint ?? "") })
        let notice = WatchVersionNotice(fingerprints:versions)
        guard (try? notice.validate()) != nil,let data = try? JSONEncoder().encode(notice) else { return }
        do { try session.updateApplicationContext(["agendaVersions":data]) }
        catch { agendaStatus = "版本更新未交给系统；旧摘要的操作仍需手机核对，连接后请重发摘要。" }
        #endif
    }
    nonisolated func session(_ session:WCSession,didReceiveApplicationContext applicationContext:[String:Any]) {
        guard let data = applicationContext["agendaVersions"] as? Data,data.count <= 4096 else { return }
        Task { @MainActor [weak self] in
            guard let self,let notice = try? JSONDecoder().decode(WatchVersionNotice.self,from:data),(try? notice.validate()) != nil else { return }
            #if os(watchOS)
            var changed = false
            for index in self.agendaItems.indices where notice.invalidates(self.agendaItems[index],snapshotDate:self.latestAgendaDate) {
                self.agendaItems[index].outdated = true;changed = true
            }
            if changed { self.agendaStatus = "手机内容已变更，旧摘要不能继续确认；请从手机重新发送。";self.persistWatchAgenda() }
            #endif
        }
    }
}
