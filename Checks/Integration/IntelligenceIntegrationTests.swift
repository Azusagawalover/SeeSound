import Foundation
import XCTest
@testable import SeeSoundData

final class IntelligenceIntegrationTests: XCTestCase {
    private let pairing = "local-test-pairing-1234567890123456"
    private func sample() -> (ConversationSession, InsightRequest) {
        var conversation = ConversationSession()
        conversation.reply("演示：明天下午三点去二楼，带12元，电话12345678。", origin: .demonstration)
        let turn = conversation.turns[0]
        let request = InsightRequest(turns: [.init(id: turn.id, text: turn.text, origin: turn.origin)],
                                     at: Date(timeIntervalSince1970: 1_792_940_400), timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        return (conversation, request)
    }
    private func result(_ request: InsightRequest) -> InsightResult {
        InsightResult(version: 1, provider: "DeepSeek", model: "test-model", summary: "演示约定",
                      candidates: [.init(kind: .amount, value: "12", sourceID: request.turns[0].id, quote: "带12元", dateISO: nil, currency: "CNY")],
                      replies: ["请再核对一下时间。"])
    }
    func testOnlyValidSelectedCompletedTextMatchesItsSource() throws {
        var (conversation, request) = sample()
        XCTAssertNoThrow(try request.validate())
        XCTAssertTrue(request.stillMatches(conversation))
        conversation.edit(request.turns[0].id, text: "改为后天")
        XCTAssertFalse(request.stillMatches(conversation))
        request.turns.append(request.turns[0]); XCTAssertThrowsError(try request.validate())
        request.turns = []; XCTAssertThrowsError(try request.validate())
    }
    func testSuggestionsKeepDemoSourceAndDoNotConfirmCardsOrCompleteTasks() throws {
        let (_, request) = sample()
        let response = result(request); try response.validate(request: request)
        let card = try response.candidates[0].makeCard(request: request)
        XCTAssertEqual(card.origin, .demonstration); XCTAssertEqual(card.assistedBy, "DeepSeek")
        XCTAssertFalse(card.reviewed); XCTAssertEqual(card.sourceQuote, "带12元")
        let candidate = InsightCandidate(kind: .task, value: "去二楼", sourceID: request.turns[0].id, quote: "去二楼", dateISO: nil)
        let task = try candidate.makeRoutine(request: request)
        XCTAssertTrue(task.isDemonstration); XCTAssertFalse(task.completed)
        XCTAssertNil(task.sourceCardID); XCTAssertEqual(task.assistedBy, "DeepSeek")
    }
    func testUnsupportedQuotesAmountsPhonesAndDuplicateCandidatesAreRejected() throws {
        let (_, request) = sample()
        var response = result(request)
        response.candidates[0].value = "120"; XCTAssertThrowsError(try response.validate(request: request))
        response = result(request); response.candidates[0].quote = "不存在的原文"; XCTAssertThrowsError(try response.validate(request: request))
        response = result(request); response.candidates[0].sourceID = UUID(); XCTAssertThrowsError(try response.validate(request: request))
        response = result(request); response.candidates += response.candidates; XCTAssertThrowsError(try response.validate(request: request))
        response = result(request); response.candidates = [.init(kind: .phone, value: "87654321", sourceID: request.turns[0].id, quote: "电话12345678", dateISO: nil)]
        XCTAssertThrowsError(try response.validate(request: request))
        response.candidates[0].value = "12345678"; XCTAssertNoThrow(try response.validate(request: request))
    }
    func testServiceAddressesRejectPlainInternetAndEmbeddedCredentials() throws {
        for endpoint in ["https://example.com", "http://localhost:8765", "http://127.0.0.1:8765"] {
            XCTAssertNoThrow(try InsightError.endpoint(endpoint))
        }
        for endpoint in ["http://192.168.1.5:8765", "http://example.com", "https://user:secret@example.com", "https://example.com?key=x", "https://example.com/other"] {
            XCTAssertThrowsError(try InsightError.endpoint(endpoint))
        }
    }
    func testAmountsUseAdjacentCurrencyAndDifferentCurrenciesHaveDifferentIDs() throws {
        for (quote, value, currency) in [("12美元","12","USD"),("12元人民币","12.00","CNY"),
                ("USD 1,200.50","1200.50","USD"),("人民币12元","12","CNY"),("12美元和20元人民币","20","CNY") ] {
            XCTAssertTrue(InsightEvidence.groundedAmount(value: value, currency: currency, quote: quote), quote)
        }
        for (quote, value, currency) in [("12美元","12","CNY"),("12美元和20元人民币","12","CNY"),
                ("12日元","12","CNY"),("12港元","12","CNY"),("12欧元","12","CNY"),
                ("USD12元","12","USD"),("1,2元","12","CNY"),("-12元","12","CNY"),("12.345元","12.34","CNY") ] {
            XCTAssertFalse(InsightEvidence.groundedAmount(value: value, currency: currency, quote: quote), quote)
        }
        let id = UUID()
        let dollar = InsightCandidate(kind: .amount, value: "12", sourceID: id, quote: "12美元", dateISO: nil, currency: "USD")
        let yuan = InsightCandidate(kind: .amount, value: "12", sourceID: id, quote: "12元", dateISO: nil, currency: "CNY")
        XCTAssertNotEqual(dollar.id, yuan.id)
    }
    func testUnfilteredActionClaimsAreRejectedAndSuppressionCountIsBounded() throws {
        let (_, payload) = sample()
        var response = result(payload)
        response.replies = ["已保存这些信息。"]
        XCTAssertThrowsError(try response.validate(request: payload))
        response.replies = ["会提醒你带证件。"]
        XCTAssertThrowsError(try response.validate(request: payload))
        response.replies = ["请再确认一下时间。"]
        response.suppressedReplies = 2
        XCTAssertNoThrow(try response.validate(request: payload))
        response.suppressedReplies = 3
        XCTAssertThrowsError(try response.validate(request: payload))
    }
    func testCapturedRealAPIResponsesDecodeAndCreateOnlyUnreviewedDemoDrafts() throws {
        struct Record: Decodable {
            struct Case: Decodable { var name: String; var request: InsightRequest; var result: InsightResult?; var passed: Bool }
            var cases: [Case]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "DeepSeekLive", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 6)
        for item in fixture.cases {
            XCTAssertTrue(item.passed, item.name)
            let output = try XCTUnwrap(item.result, item.name)
            try output.validate(request: item.request)
            for candidate in output.candidates {
                if candidate.kind == .task {
                    let draft = try candidate.makeRoutine(request: item.request)
                    XCTAssertFalse(draft.completed); XCTAssertTrue(draft.isDemonstration)
                } else {
                    let draft = try candidate.makeCard(request: item.request)
                    XCTAssertFalse(draft.reviewed); XCTAssertEqual(draft.origin, .demonstration)
                }
            }
        }
    }
    @MainActor
    private func service() throws -> IntelligenceService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InsightStub.self]
        let service = IntelligenceService(session: URLSession(configuration: configuration))
        try service.configure(endpoint: "https://seesound.invalid", pairing: pairing)
        return service
    }
    @MainActor
    private func finish(_ service: IntelligenceService) async throws {
        for _ in 0..<400 {
            if !service.isBusy { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Mock request did not finish")
    }
    @MainActor
    func testSendingUsesOnlySelectedTextAndNeverAutoAdoptsResult() async throws {
        let (_, payload) = sample()
        let expected = result(payload)
        InsightStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/organize"); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.pairing)
            let sent = try JSONDecoder().decode(InsightRequest.self, from: InsightStub.body(request))
            XCTAssertEqual(sent, payload)
            return .response(200, try JSONEncoder().encode(expected), 0)
        }
        let service = try service(); service.organize(payload); try await finish(service)
        XCTAssertNotNil(service.result); XCTAssertEqual(service.source, payload)
        XCTAssertFalse(try XCTUnwrap(service.result).candidates[0].makeCard(request: payload).reviewed)
        var invalid = payload; invalid.turns = []
        service.organize(invalid)
        XCTAssertNil(service.result); XCTAssertNil(service.source)
    }
    @MainActor
    func testErrorsAndTimeoutDoNotRetryOrLeavePreviousResults() async throws {
        let (_, payload) = sample()
        let success = try JSONEncoder().encode(result(payload))
        InsightStub.handler = { _ in .response(200, success, 0) }
        let service = try service(); service.organize(payload); try await finish(service)
        XCTAssertNotNil(service.result)
        var calls = 0
        InsightStub.handler = { _ in calls += 1; return .failure(URLError(.timedOut)) }
        service.organize(payload); try await finish(service)
        XCTAssertEqual(calls, 1); XCTAssertNil(service.result); XCTAssertFalse(service.isBusy)
        InsightStub.handler = { _ in .response(401, Data("{\"error\":\"pairing_required\"}".utf8), 0) }
        service.organize(payload); try await finish(service)
        XCTAssertNil(service.result); XCTAssertTrue(service.status.contains("配对码"))
        InsightStub.handler = { _ in .response(200, Data("{\"broken\":true}".utf8), 0) }
        service.organize(payload); try await finish(service)
        XCTAssertNil(service.result)
    }
    @MainActor
    func testSourceChangesAndCancellationDiscardLateOutput() async throws {
        var (conversation, payload) = sample()
        let response = try JSONEncoder().encode(result(payload))
        InsightStub.handler = { _ in .response(200, response, 0.1) }
        let service = try service(); service.organize(payload)
        conversation.edit(payload.turns[0].id, text: "已更改原文")
        service.invalidate(ifChanged: conversation)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(service.isBusy); XCTAssertNil(service.result); XCTAssertNil(service.source)
        XCTAssertTrue(service.status.contains("变化"))
        service.organize(payload); service.cancel()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(service.result); XCTAssertNil(service.source)
    }
    @MainActor
    func testTranslationUsesSelectedSourceAndRejectsWrongOrCancelledOutput() async throws {
        let payload=TranslationRequest(text:"【演示】费用12美元。",target:.english,origin:.demonstration)
        let expected=TranslationResult(version:1,provider:"DeepSeek",model:"test-model",sourceID:payload.sourceID,target:.english,text:"[Demo] The fee is 12 USD.")
        InsightStub.handler = { request in
            XCTAssertEqual(request.url?.path,"/v1/translate")
            XCTAssertEqual(try JSONDecoder().decode(TranslationRequest.self,from:InsightStub.body(request)),payload)
            return .response(200,try JSONEncoder().encode(expected),0)
        }
        let service=try service();service.translate(payload);try await finish(service)
        XCTAssertNotNil(service.translation);XCTAssertNil(service.result);XCTAssertEqual(service.translationSource,payload)
        var wrong=expected;wrong.sourceID=UUID()
        InsightStub.handler={ _ in .response(200,try JSONEncoder().encode(wrong),0) }
        service.translate(payload);try await finish(service);XCTAssertNil(service.translation)
        InsightStub.handler={ _ in .response(200,try JSONEncoder().encode(expected),0.1) }
        service.translate(payload);service.cancel();try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertNil(service.translation);XCTAssertNil(service.translationSource)
    }
}

private final class InsightStub: URLProtocol {
    enum Outcome { case response(Int, Data, TimeInterval), failure(Error) }
    static var handler: ((URLRequest) throws -> Outcome)?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            switch try handler(request) {
            case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
            case .response(let status, let data, let delay):
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                    lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
                    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
