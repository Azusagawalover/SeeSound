import Foundation

enum WatchLinkState:String {
    case idle, unsupported, activating, unpaired, needsInstallation, unreachable, ready, failed
    var title:String {
        switch self { case .idle:return "尚未连接";case .unsupported:return "请使用配对 iPhone";case .activating:return "正在激活通信";case .unpaired:return "未配对手表";case .needsInstallation:return "手表应用尚未安装";case .unreachable:return "对端暂不可达";case .ready:return "当前可通信";case .failed:return "通信激活失败" }
    }
    var guidance:String {
        switch self {
        case .idle:return "点击激活连接，查看当前设备状态。"
        case .unsupported:return "Watch 与 iPhone 配对；iPad 可使用加密事务文件接力。"
        case .activating:return "正在等待系统激活结果。"
        case .unpaired:return "先在 iPhone 的 Watch 应用完成配对，再返回刷新。"
        case .needsInstallation:return "在配对手表安装见声，并打开两端应用。"
        case .unreachable:return "打开两端应用，检查蓝牙和连接后再刷新；当前操作不会离线排队。"
        case .ready:return "可以发送摘要。连接可达与操作已保存是两个状态，仍需等待有效回执。"
        case .failed:return "重新激活连接；若仍失败，请在系统 Watch 应用检查配对状态。"
        }
    }
    static func evaluate(supported:Bool,active:Bool,paired:Bool,installed:Bool,reachable:Bool) -> WatchLinkState {
        if !supported { return .unsupported };if !active { return .activating };if !paired { return .unpaired };if !installed { return .needsInstallation };return reachable ? .ready : .unreachable
    }
}
enum WatchAgendaDeliveryState:String {
    case idle, awaitingReceipt, received, applied, refused, unknown
    var title:String {
        switch self { case .idle:return "尚未传递";case .awaitingReceipt:return "等待对端回执";case .received:return "对端应用已接收";case .applied:return "手机已确认处理";case .refused:return "操作未采用";case .unknown:return "处理结果未知" }
    }
}

// A successful operation receipt must also carry the resulting record state.
enum WatchReceiptPolicy {
    static func state(request:WatchAgendaPacket,response:WatchAgendaPacket) -> WatchAgendaDeliveryState {
        guard request.kind == .action,response.kind == .receipt,response.id == request.id,
              response.recordID == request.recordID,response.fingerprint == request.fingerprint,response.action == request.action else { return .unknown }
        if response.accepted == false { return .refused }
        guard response.accepted == true,response.items.count == 1,let item = response.items.first,item.id == request.recordID else { return .unknown }
        if request.action == .complete { return item.kind == .routine && item.completed ? .applied : .unknown }
        return item.seen ? .applied : .unknown
    }
}
