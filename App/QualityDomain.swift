import Foundation

enum VerificationResult: String, Codable, CaseIterable, Identifiable {
    case notChecked, passed, needsWork
    var id:String { rawValue }
    var title:String { self == .passed ? "通过" : self == .needsWork ? "需调整" : "未检查" }
}
struct VerificationCheck: Identifiable {
    var id:String
    var title:String
    var steps:String
    var needsHardware:Bool
    static let all:[VerificationCheck] = [
        .init(id:"notify-front",title:"前台通知",steps:"保存普通事项，设置未来提醒并授权；保持应用在前台，检查横幅与事项一致。",needsHardware:false),
        .init(id:"notify-lock",title:"锁屏与后台送达",steps:"设置未来提醒，锁屏或切到后台；记录是否收到、是否延迟，以及专注模式状态。",needsHardware:true),
        .init(id:"notify-cold",title:"通知点击与重新启动",steps:"彻底关闭应用后点击真实送达的通知；检查进入对应事项，已删除事项不能重建。",needsHardware:true),
        .init(id:"data-restart",title:"重启与数据保留",steps:"主动保存一件事务，记录勾选进度，重新启动后检查；临时内容不应被当作已保存。",needsHardware:false),
        .init(id:"backup",title:"加密备份与恢复",steps:"在测试设备导出加密备份，预览恢复，检查关联、冲突选择与导入提醒默认关闭。",needsHardware:false),
        .init(id:"large-text",title:"大字体",steps:"使用辅助功能大字体，检查主页、事务、提醒与导入预览；按钮文字完整、内容可滚动。",needsHardware:false),
        .init(id:"voiceover",title:"VoiceOver",steps:"逐项读出标题、按钮、材料已处理状态；用屏幕阅读器完成导航与勾选。",needsHardware:false),
        .init(id:"dark",title:"深色模式与减少动态效果",steps:"切换深色模式及减少动态效果，检查文字对比、状态提示和导航反馈。",needsHardware:false),
        .init(id:"split",title:"iPad 分屏",steps:"横屏双栏查看事务；缩窄分屏后应切换单栏，选择事项和返回正常。",needsHardware:false),
        .init(id:"capture",title:"声音、摄像头与中断",steps:"分别开启采集，观察输入状态；遮挡、静音、系统中断和返回前台后，不应声称持续正常识别。",needsHardware:true),
        .init(id:"watch-agenda",title:"Watch 事务与回执",steps:"在配对设备发送一个已保存的普通待办，手表确认后检查手机状态；断线时不能显示确认成功。",needsHardware:true),
        .init(id:"watch-haptic",title:"Watch 触觉",steps:"使用实际手表测试事件提醒触觉，记录静音与佩戴状态，模拟器不能判通过。",needsHardware:true)
    ]
}
struct VerificationRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var checkID:String
    var result:VerificationResult
    var note:String
    var date = Date()
    var device:String
    var simulator:Bool
    func validate() throws {
        guard let check = VerificationCheck.all.first(where:{$0.id == checkID}),note.count <= 500,device.count <= 120,date.timeIntervalSince1970.isFinite,date <= Date().addingTimeInterval(300),!(check.needsHardware && simulator && result == .passed) else { throw DailyError.invalid }
    }
}
enum RecognitionIssueKind:String,Codable,CaseIterable,Identifiable {
    case missed, falseAlarm, stopped, unclear
    var id:String { rawValue }
    var title:String { switch self { case .missed:return "漏报补记";case .falseAlarm:return "误报反馈";case .stopped:return "处理停止";case .unclear:return "结果不清楚" } }
}
struct RecognitionReport: Codable,Identifiable,Equatable {
    var id = UUID()
    var kind:RecognitionIssueKind = .missed
    var category = "声音"
    var environment = ""
    var note = ""
    var date = Date()
    func validate() throws {
        guard ["声音","动作","字幕","提醒","Watch"].contains(category),environment.count <= 120,note.count <= 500,!note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,date.timeIntervalSince1970.isFinite,date <= Date().addingTimeInterval(300) else { throw DailyError.invalid }
    }
}
struct QualityArchive:Codable {
    var version = 1
    var records:[VerificationRecord] = []
    var reports:[RecognitionReport] = []
    func validate() throws {
        guard version == 1,records.count <= 200,reports.count <= 80,Set(records.map(\.id)).count == records.count,Set(reports.map(\.id)).count == reports.count else { throw DailyError.capacity }
        try records.forEach { try $0.validate() };try reports.forEach { try $0.validate() }
    }
}
struct CaptureHealth:Equatable {
    enum State { case off, starting, receiving, waiting, interrupted }
    var state:State
    var title:String
    var detail:String
    static func evaluate(active:Bool,starting:Bool,lastInput:Date?,lastResult:Date?,now:Date,activeSince:Date? = nil) -> CaptureHealth {
        if starting { return .init(state:.starting,title:"正在准备",detail:"等待设备、权限或模型就绪。") }
        if !active { return .init(state:.off,title:"未开启",detail:"当前没有持续采集，不代表环境中没有事件。") }
        guard let lastInput else {
            if activeSince.map({ now.timeIntervalSince($0) > 8 }) == true { return .init(state:.interrupted,title:"尚未取得输入",detail:"开启超过 8 秒仍没有输入更新，请停止后检查设备和权限。") }
            return .init(state:.waiting,title:"等待首段输入",detail:"尚未取得可检查的输入，请检查权限和设备。")
        }
        if now.timeIntervalSince(lastInput) > 8 { return .init(state:.interrupted,title:"输入已停顿",detail:"超过 8 秒没有输入更新，请停止后手动重试。") }
        if lastResult.map({ now.timeIntervalSince($0) <= 8 }) == true { return .init(state:.receiving,title:"输入与处理有更新",detail:"这只说明处理在运行，不保证识别正确或没有漏报。") }
        return .init(state:.waiting,title:"输入有更新，等待结果",detail:"可能仍在处理、画面没有清晰手部或输入不足；不能判断不存在事件。")
    }
}
