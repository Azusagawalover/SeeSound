import Foundation

enum EvaluationKind:String,Codable,CaseIterable,Identifiable {
    case speech, ocr
    var id:String { rawValue }
    var title:String { self == .speech ? "中文文件转写" : "公告图片识字" }
}
struct CampusEvaluationSample:Codable,Equatable,Identifiable {
    var id:String
    var title:String
    var kind:EvaluationKind
    var reference:String
    var keywords:[String]
    var filename:String?
    var source:String
    var license:String
    var note:String
    static var notices:[CampusEvaluationSample] {
        [
            .init(id:"notice-counter",title:"窗口办理说明",kind:.ocr,reference:"模拟校园通知\n办理地点：学生服务中心二楼\n受理时间：2026年11月3日 09:30\n请携带校园卡和证件照。\n材料费：12元",keywords:["学生服务中心二楼","2026","09:30","12"],source:"本项目原创模拟材料",license:"CC0-1.0",note:"规则、日期与费用均为模拟内容。"),
            .init(id:"notice-activity",title:"活动报名通知",kind:.ocr,reference:"模拟活动通知\n活动：校园读书会\n报名截止：2026年11月5日 18:00\n地点：图书馆三楼\n请携带学生证。\n费用：免费",keywords:["校园读书会","18:00","图书馆三楼","学生证"],source:"本项目原创模拟材料",license:"CC0-1.0",note:"检查小字与关键字段；不代表学校实际规定。"),
            .init(id:"notice-update",title:"改期与补充材料",kind:.ocr,reference:"模拟补充通知\n办理时间改为2026年11月6日 14:20。\n办理地点改为行政楼101室。\n请补交一张证件照，原有校园卡仍需携带。",keywords:["14:20","101","证件照","校园卡"],source:"本项目原创模拟材料",license:"CC0-1.0",note:"内容有改期表达；识字结果不能直接替代安排核对。")
        ]
    }
}
struct CharacterEvaluation:Equatable {
    var edits:Int
    var referenceCount:Int
    var rate:Double { Double(edits)/Double(referenceCount) }
    static func normalize(_ text:String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }.map(String.init).joined()
    }
    static func compare(reference:String,observed:String) -> CharacterEvaluation? {
        let a = Array(normalize(reference)),b = Array(normalize(observed))
        guard !a.isEmpty,a.count <= 1500,b.count <= 1500 else { return nil }
        var previous = Array(0...b.count)
        for (i,left) in a.enumerated() {
            var row = [i+1] + Array(repeating:0,count:b.count)
            for (j,right) in b.enumerated() { row[j+1] = min(row[j]+1,previous[j+1]+1,previous[j]+(left == right ? 0 : 1)) }
            previous = row
        }
        return .init(edits:previous.last ?? a.count,referenceCount:a.count)
    }
}
struct CampusEvaluationRecord:Codable,Equatable,Identifiable {
    var id = UUID()
    var date = Date()
    var sampleID:String
    var title:String
    var kind:EvaluationKind
    var model:String
    var reference:String
    var observed:String
    var elapsed:Double
    var failure:String?
    var correction = ""
    var note = ""
    var reviewed = false
    var keywords:[String]?
    var score:CharacterEvaluation? { failure == nil ? CharacterEvaluation.compare(reference:reference,observed:observed) : nil }
    func validate() throws {
        guard !sampleID.isEmpty,sampleID.count <= 100,!title.isEmpty,title.count <= 100,
              !model.isEmpty,model.count <= 100,reference.count <= 12000,observed.count <= 12000,
              correction.count <= 12000,note.count <= 500,(failure?.count ?? 0) <= 500,
              elapsed.isFinite,elapsed >= 0,date.timeIntervalSince1970.isFinite,
              (keywords?.count ?? 0) <= 20,(keywords ?? []).allSatisfy({!$0.isEmpty && $0.count <= 100}) else { throw CampusError.invalid }
    }
}
struct CampusEvaluationStore {
    var directory:URL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("SeeSoundEvaluation")
    private var file:URL { directory.appendingPathComponent("records.json") }
    func load() throws -> [CampusEvaluationRecord] {
        guard FileManager.default.fileExists(atPath:file.path) else { return [] }
        guard try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 4_000_000 else { throw CampusError.limit }
        let records = try JSONDecoder().decode([CampusEvaluationRecord].self,from:Data(contentsOf:file))
        guard records.count <= 100,Set(records.map(\.id)).count == records.count else { throw CampusError.limit }
        try records.forEach{try $0.validate()};return records
    }
    func save(_ records:[CampusEvaluationRecord]) throws {
        guard records.count <= 100,Set(records.map(\.id)).count == records.count else { throw CampusError.limit }
        try records.forEach{try $0.validate()}
        let data = try JSONEncoder().encode(records);guard data.count <= 4_000_000 else { throw CampusError.limit }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var url = directory,values = URLResourceValues();values.isExcludedFromBackup = true;try url.setResourceValues(values)
        try data.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func clear() throws { if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) } }
}
