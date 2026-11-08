import Combine
import MultipeerConnectivity
import UIKit

struct NearbyTextRoom: Identifiable {
    let peer: MCPeerID
    let session: UUID
    var id: String { peer.displayName + session.uuidString }
}

/// Foreground, explicit, encrypted text-only sessions. No audio, files or disk cache.
@MainActor
final class TextSharingService: NSObject, ObservableObject {
    enum Role { case idle, host, viewer, preview }
    @Published private(set) var role: Role = .idle
    @Published private(set) var status = "两端打开见声，手动建立临时文字连接。"
    @Published private(set) var code = ""
    @Published private(set) var rooms: [NearbyTextRoom] = []
    @Published private(set) var pendingPeer: String?
    @Published private(set) var connectedName: String?
    @Published private(set) var turns: [SavedConversationTurn] = []
    @Published private(set) var revision = -1
    @Published private(set) var acknowledgedRevision = -1
    @Published private(set) var clearEpoch = UUID()
    @Published private(set) var lastTextAt: Date?
    @Published private(set) var invitationPending = false
    var foreground = true
    private var network: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var invitationReply: ((Bool, MCSession?) -> Void)?
    private var acceptedPeer: MCPeerID?
    private var sessionID: UUID?
    private var cursor = SharedTextCursor()
    private var readState = SharedReadState()
    private var latest: [SavedConversationTurn] = []
    private var failures = 0
    private var timeout: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var liveness = SharedTextLiveness()
    private var needsPublication = true
    private let service = "seesound-share"

    func startHost() {
        stop()
        role = .host; sessionID = UUID(); code = String(format: "%06d", Int.random(in: 0...999999))
        let session = makeSession()
        let ad = MCNearbyServiceAdvertiser(peer: session.myPeerID,
            discoveryInfo: ["version": "1", "room": sessionID!.uuidString], serviceType: service)
        advertiser = ad; ad.delegate = self; ad.startAdvertisingPeer()
        status = "等待另一台设备输入连接码，再由你确认。连接码不代表实名认证。"
    }
    func startViewer() {
        stop(); role = .viewer
        let session = makeSession()
        let search = MCNearbyServiceBrowser(peer: session.myPeerID, serviceType: service)
        browser = search; search.delegate = self; search.startBrowsingForPeers()
        status = "正在查找附近的文字房间；请允许本地网络访问。"
    }
    private func makeSession() -> MCSession {
        let label = UIDevice.current.userInterfaceIdiom == .pad ? "见声 iPad" : "见声 iPhone"
        let peer = MCPeerID(displayName: label + " " + UUID().uuidString.prefix(4))
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        network = session; session.delegate = self; return session
    }
    var localName: String { network?.myPeerID.displayName ?? "本机" }
    var isConnected: Bool { connectedName != nil }
    func invite(_ room: NearbyTextRoom, code: String) {
        guard role == .viewer, !isConnected, acceptedPeer == nil, let network,
              code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }), rooms.contains(where: { $0.id == room.id }),
              let data = try? JSONEncoder().encode(ShareInvitation(session: room.session, code: code)) else {
            status = "请选择房间，并输入对方屏幕上的 6 位数字。"; return
        }
        sessionID = room.session; acceptedPeer = room.peer; cursor.begin(room.session)
        invitationPending = true
        browser?.invitePeer(room.peer, to: network, withContext: data, timeout: 120)
        status = "已发出邀请，等待发送端核对设备并确认。"
        let id = room.session
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 125_000_000_000) } catch { return }
            guard let self, self.sessionID == id, !self.isConnected else { return }
            self.stop(message: "连接未完成；请两端重新打开房间并核对连接码。")
        }
    }
    func approve(_ allow: Bool) {
        guard let reply = invitationReply else { return }
        invitationReply = nil; pendingPeer = nil
        if !allow { acceptedPeer = nil }
        reply(allow, allow ? network : nil)
        status = allow ? "已允许这台设备，正在建立加密文字连接。" : "已拒绝连接。"
    }
    func publish(_ conversation: ConversationSession) {
        let next = Array(conversation.turns.suffix(20)).map(SavedConversationTurn.init)
        if latest != next { latest = next; needsPublication = true }
        publishLatest()
    }
    private func publishLatest() {
        guard role == .host, foreground, isConnected, needsPublication, let id = sessionID else { return }
        guard revision < 999_999 else { stop(message: "本次共享达到更新上限，请重新连接。"); return }
        revision += 1
        needsPublication = false
        send(SharedTextPacket(session: id, revision: revision, kind: .snapshot, turns: latest))
    }
    func acknowledge(_ visibleRevision: Int) {
        guard role == .viewer, isConnected, visibleRevision >= 0, visibleRevision <= revision, let id = sessionID else { return }
        send(SharedTextPacket(session: id, revision: visibleRevision, kind: .acknowledgement))
    }
    func preview() {
        stop(); role = .preview
        var demo = ConversationSession(); demo.addDemonstration()
        turns = demo.turns.map(SavedConversationTurn.init); revision = 0
        lastTextAt = Date()
        status = "本机演示 · 未连接任何其他设备，文字为预设示例。"
    }
    func stop(message: String = "共享已结束，接收文字已清除。", notifyPeer: Bool = true) {
        if notifyPeer, isConnected, let id = sessionID { send(SharedTextPacket(session: id, revision: max(0, revision), kind: .ended)) }
        timeout?.cancel(); timeout = nil
        maintenance?.cancel(); maintenance = nil; liveness.clear()
        invitationReply?(false, nil); invitationReply = nil
        advertiser?.stopAdvertisingPeer(); advertiser?.delegate = nil; advertiser = nil
        browser?.stopBrowsingForPeers(); browser?.delegate = nil; browser = nil
        let old = network; network = nil; old?.delegate = nil; old?.disconnect()
        acceptedPeer = nil; pendingPeer = nil; sessionID = nil; code = ""; failures = 0
        connectedName = nil; rooms = []; turns = []; latest = []; cursor.clear(); readState.clear()
        revision = -1; acknowledgedRevision = -1; role = .idle; clearEpoch = UUID(); status = message
        lastTextAt = nil; needsPublication = true; invitationPending = false
    }
    private func send(_ packet: SharedTextPacket) {
        guard let network, let peer = acceptedPeer, network.connectedPeers.contains(peer), foreground else { return }
        do { try network.send(SharedTextCodec.encode(packet), toPeers: [peer], with: .reliable) }
        catch { stop(message: "文字发送失败，已结束共享。", notifyPeer: false) }
    }
    private func receive(_ data: Data, from peer: MCPeerID) {
        guard foreground, peer == acceptedPeer, let packet = try? SharedTextCodec.decode(data), packet.session == sessionID else { return }
        liveness.receive()
        if packet.kind == .heartbeat { return }
        if packet.kind == .ended { stop(); return }
        if role == .viewer, cursor.accept(packet) {
            turns = packet.turns; revision = packet.revision
            lastTextAt = Date()
            status = "收到第 \(revision + 1) 次文字更新；设备接收不等于你已阅读。"
        } else if role == .host, let sessionID, readState.accept(packet, currentRevision: revision, session: sessionID) {
            acknowledgedRevision = readState.acknowledgedRevision
            status = readState.hasRead(revision) ? "对方已主动确认看到当前版本。" : "对方确认了较早版本；最新文字尚未确认。"
        }
    }
    private func maintain(_ session: MCSession) {
        liveness.begin(); maintenance?.cancel()
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, self.network === session, self.isConnected, let id = self.sessionID else { return }
                if self.liveness.expired() {
                    self.stop(message: "超过 45 秒未收到对端信号，已清除临时文字，请重新连接。", notifyPeer: false); return
                }
                if self.foreground { self.send(SharedTextPacket(session: id, revision: max(0, self.revision), kind: .heartbeat)) }
            }
        }
    }
}

extension TextSharingService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard self.network === session, peerID == self.acceptedPeer else { return }
            if state == .connected {
                self.timeout?.cancel(); self.connectedName = peerID.displayName; self.invitationPending = false
                self.advertiser?.stopAdvertisingPeer(); self.browser?.stopBrowsingForPeers()
                self.status = "已连接 \(peerID.displayName) · 只共享文字"
                self.needsPublication = true; self.publishLatest(); self.maintain(session)
            } else if state == .notConnected { self.stop(message: "连接已断开，临时文字已清除，请手动重新连接。") }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= 65_536 else { return }
        Task { @MainActor in guard self.network === session else { return }; self.receive(data, from: peerID) }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension TextSharingService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                               withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            guard self.advertiser === advertiser, self.role == .host, self.foreground, self.acceptedPeer == nil,
                  let id = self.sessionID, let context, context.count <= 1024,
                  let invite = try? JSONDecoder().decode(ShareInvitation.self, from: context), invite.matches(session: id, code: self.code) else {
                invitationHandler(false, nil)
                if self.advertiser === advertiser, self.acceptedPeer == nil {
                    self.failures += 1
                    if self.failures >= 5 { self.stop(message: "连接码连续不匹配，房间已关闭，请重新创建。") }
                }
                return
            }
            self.acceptedPeer = peerID; self.pendingPeer = peerID.displayName; self.invitationReply = invitationHandler
            self.status = "请与对方核对设备名称，再允许共享。"
            self.timeout?.cancel()
            self.timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
                guard let self, self.advertiser === advertiser, self.invitationReply != nil else { return }
                self.approve(false); self.status = "请求超过两分钟未确认，已拒绝；对方可以重新发起。"
            }
        }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in guard self.advertiser === advertiser else { return }; self.stop(message: "无法创建房间：\(error.localizedDescription)") }
    }
}

extension TextSharingService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard self.browser === browser, info?["version"] == "1", let value = info?["room"], let id = UUID(uuidString: value),
                  !self.rooms.contains(where: { $0.peer == peerID }), self.rooms.count < 12 else { return }
            self.rooms.append(NearbyTextRoom(peer: peerID, session: id))
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in guard self.browser === browser else { return }; self.rooms.removeAll { $0.peer == peerID } }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in guard self.browser === browser else { return }; self.stop(message: "无法查找房间：\(error.localizedDescription)") }
    }
}
