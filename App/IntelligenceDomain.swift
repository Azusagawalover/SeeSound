import Foundation

struct InsightTurn: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let origin: ConversationOrigin
}
struct InsightRequest: Codable, Equatable {
    var version = 1
    var turns: [InsightTurn]
    var referenceTime: String
    var timeZone: String
    var includeCasePlan: Bool? = nil
    enum CodingKeys: String, CodingKey { case version, turns; case referenceTime = "reference_time", timeZone = "time_zone", includeCasePlan = "include_case_plan" }
    init(turns: [InsightTurn], at now: Date = Date(), timeZone: TimeZone = .current, includeCasePlan: Bool = false) {
        self.turns = turns; referenceTime = ISO8601DateFormatter().string(from: now); self.timeZone = timeZone.identifier; self.includeCasePlan = includeCasePlan ? true : nil
    }
    func validate() throws {
        guard version == 1, (1...6).contains(turns.count), Set(turns.map(\.id)).count == turns.count,
              turns.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 500 }),
              ISO8601DateFormatter().date(from: referenceTime) != nil, TimeZone(identifier: timeZone) != nil else { throw InsightError.invalid }
    }
    func stillMatches(_ conversation: ConversationSession) -> Bool {
        turns.allSatisfy { source in conversation.turns.contains { $0.id == source.id && $0.text == source.text && $0.origin == source.origin && $0.state != .partial } }
    }
}

enum InsightKind: String, Codable { case time, place, amount, phone, task
    var cardKind: InformationKind? { InformationKind(rawValue: rawValue) }
    var title: String { self == .task ? "待办" : cardKind?.title ?? "建议" }
}
struct InsightCandidate: Codable, Identifiable, Equatable {
    var id: String { "\(sourceID.uuidString):\(kind.rawValue):\(currency ?? ""):\(dateISO ?? ""):\(value):\(quote)" }
    var kind: InsightKind
    var value: String
    var sourceID: UUID
    var quote: String
    var dateISO: String?
    var currency: String?
    enum CodingKeys: String, CodingKey { case kind, value, quote, currency; case sourceID = "source_id", dateISO = "date_iso" }
    var date: Date? {
        guard let dateISO else { return nil }
        let f = ISO8601DateFormatter()
        if let result = f.date(from: dateISO) { return result }
        f.formatOptions.insert(.withFractionalSeconds); return f.date(from: dateISO)
    }
    func validate(request: InsightRequest) throws {
        guard let turn = request.turns.first(where: { $0.id == sourceID }), !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              quote.count <= 200, turn.text.contains(quote), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= (kind == .task ? 100 : 120), dateISO == nil || date != nil else { throw InsightError.invalid }
        if kind == .task { return }
        var card = InformationCard(); card.kind = kind.cardKind!; card.value = value
        if kind == .amount { guard let currency else { throw InsightError.invalid }; card.currency = currency }
        if let date { card.dateValue = date }
        try card.validate()
        if kind == .amount {
            guard let currency, InsightEvidence.groundedAmount(value: value, currency: currency, quote: quote) else { throw InsightError.invalid }
        }
        if kind == .phone {
            let phones = matches(#"\+?[0-9][0-9() -]{1,38}[0-9]"#, in: quote)
            guard phones.contains(where: { $0.filter(\.isNumber) == value.filter(\.isNumber) }) else { throw InsightError.invalid }
        }
    }
    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in Range(result.range, in: text).map { String(text[$0]) } }
    }
    func makeCard(request: InsightRequest, assistant: String = "DeepSeek") throws -> InformationCard {
        try validate(request: request)
        guard let cardKind = kind.cardKind, let source = request.turns.first(where: { $0.id == sourceID }) else { throw InsightError.invalid }
        var card = InformationCard(); card.kind = cardKind; card.value = value
        card.origin = source.origin; card.sourceQuote = quote; card.assistedBy = assistant
        if let currency { card.currency = currency }
        if let date { card.dateValue = date }
        try card.validate(); return card
    }
    func makeRoutine(request: InsightRequest, assistant: String = "DeepSeek") throws -> RoutineItem {
        try validate(request: request)
        guard kind == .task, let source = request.turns.first(where: { $0.id == sourceID }) else { throw InsightError.invalid }
        var item = RoutineItem(); item.title = value; item.origin = source.origin; item.sourceSnapshot = quote
        item.assistedBy = assistant; item.dueAt = date
        try item.validate(); return item
    }
}

struct InsightResult: Codable {
    var version: Int
    var provider: String
    var model: String
    var summary: String
    var candidates: [InsightCandidate]
    var replies: [String]
    var suppressedReplies: Int? = nil
    var questions: [InsightQuestion]? = nil
    var casePlan: CasePlan? = nil
    var assistantTitle: String { provider == "LocalRules" ? "本地规则" : "DeepSeek" }
    enum CodingKeys: String, CodingKey { case version, provider, model, summary, candidates, replies, questions; case suppressedReplies = "suppressed_replies", casePlan = "case_plan" }
    func validate(request: InsightRequest) throws {
        try request.validate()
        guard version == 1, ["DeepSeek","LocalRules"].contains(provider), !model.isEmpty, model.count <= 80, summary.count <= 300,
              candidates.count <= 8, Set(candidates.map(\.id)).count == candidates.count,
              (0...3).contains(suppressedReplies ?? 0), replies.count + (suppressedReplies ?? 0) <= 3,
              Set(replies).count == replies.count, replies.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 80 && !InsightEvidence.claimsAction($0) }) else { throw InsightError.invalid }
        try candidates.forEach { try $0.validate(request: request) }
        guard (questions ?? []).count <= 4, Set((questions ?? []).map(\.id)).count == (questions ?? []).count else { throw InsightError.invalid }
        try (questions ?? []).forEach { try $0.validate(request: request) }
        if let casePlan { guard request.includeCasePlan == true else { throw InsightError.invalid }; try casePlan.validate(request: request) }
    }
}

enum InsightEvidence {
    private static let tokens = #"人民币|美元|美金|欧元|日元|港元|港币|￥|€|(?<![A-Za-z])(?:CNY|RMB|USD|EUR|JPY|HKD)(?![A-Za-z])|(?<![美日港欧])元"#
    private static let amount = try! NSRegularExpression(pattern:
        "(?:(?<prefix>" + tokens + #")\s*)?(?<![0-9.,+\-])(?<number>(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,2})?)(?![0-9.,])(?:\s*(?<suffix>"# + tokens + "))?", options: .caseInsensitive)
    private static let action = try! NSRegularExpression(pattern: #"(?:已经|已)(?:为你|帮你)?(?:保存|记录|记下|设置|安排|创建|添加|发送|转账|付款|拨打|拨号)|(?:会|将会|到时会)(?:帮你|为你)?提醒你"#)
    static func claimsAction(_ text: String) -> Bool {
        action.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func amounts(in quote: String) -> [(value: String, currency: String, quote: String)] {
        let groups: [String: Set<String>] = ["CNY":["人民币","元","￥","CNY","RMB"],"USD":["美元","美金","USD"],
            "EUR":["欧元","€","EUR"],"JPY":["日元","JPY"],"HKD":["港元","港币","HKD"]]
        func currencyFor(_ token: String?) -> String? { guard let token else { return nil }; return groups.first { $0.value.contains(token.uppercased()) }?.key }
        return amount.matches(in: quote, range: NSRange(quote.startIndex..., in: quote)).compactMap { match in
            func group(_ name: String) -> String? { Range(match.range(withName: name), in: quote).map { String(quote[$0]) } }
            let before = currencyFor(group("prefix")), after = currencyFor(group("suffix"))
            guard before == nil || after == nil || before == after, let currency = before ?? after,
                  let raw = group("number"), let value = Decimal(string: raw.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")),
                  let range = Range(match.range, in: quote) else { return nil }
            return (NSDecimalNumber(decimal: value).stringValue, currency, String(quote[range]))
        }
    }
    static func groundedAmount(value: String, currency: String, quote: String) -> Bool {
        let groups: [String: Set<String>] = ["CNY":["人民币","元","￥","CNY","RMB"],"USD":["美元","美金","USD"],
            "EUR":["欧元","€","EUR"],"JPY":["日元","JPY"],"HKD":["港元","港币","HKD"]]
        func currencyFor(_ token: String?) -> String? { guard let token else { return nil }; return groups.first { $0.value.contains(token.uppercased()) }?.key }
        let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
        return amount.matches(in: quote, range: NSRange(quote.startIndex..., in: quote)).contains { match in
            func group(_ name: String) -> String? { Range(match.range(withName: name), in: quote).map { String(quote[$0]) } }
            let before = currencyFor(group("prefix")), after = currencyFor(group("suffix"))
            guard before == nil || after == nil || before == after,
                  (before ?? after) == currency, let raw = group("number") else { return false }
            return Decimal(string: raw.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) == number
        }
    }
}

enum InsightError: LocalizedError {
    case invalid, configuration, stale, cancelled, network, server(String)
    var errorDescription: String? {
        switch self {
        case .invalid: return "建议内容不完整或与选中原文不符，已拒绝采用。"
        case .configuration: return "请先设置 HTTPS 服务地址与配对码；模拟器可使用本机回环地址。"
        case .stale: return "原对话已经变化，请重新选择文字整理。"
        case .cancelled: return "整理已取消，未采用任何结果。"
        case .network: return "连接未完成，请检查服务地址和网络；原文字保留，不自动重试。"
        case .server(let code):
            switch code {
            case "deepseek_key_missing": return "服务尚未配置 DeepSeek 密钥，请在电脑上完成私密配置。"
            case "pairing_required": return "服务配对码不正确，请重新配置。"
            case "provider_auth": return "DeepSeek 密钥未通过验证，请在服务端检查。"
            case "provider_balance": return "DeepSeek 额度不足，请检查 API 账户。"
            case "rate_limited", "provider_busy": return "请求较多，请稍后手动重试。"
            default: return "DeepSeek 返回未完成或不可用的结果，没有采用建议。"
            }
        }
    }
    static func endpoint(_ text: String) throws -> URL {
        guard let url = URL(string: text), let host = url.host, !host.isEmpty, url.port.map({ (1...65535).contains($0) }) ?? true, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.scheme == "https" || url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host) else { throw InsightError.configuration }
        return url
    }
}
