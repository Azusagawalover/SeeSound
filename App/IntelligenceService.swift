import Foundation
import Combine

@MainActor
final class IntelligenceService: ObservableObject {
    @Published private(set) var result: InsightResult?
    @Published private(set) var source: InsightRequest?
    @Published private(set) var isBusy = false
    @Published private(set) var failure:String?
    @Published private(set) var status = "仅主动发送选中的文字，不发送音视频。"
    @Published private(set) var isReady = false
    @Published private(set) var translation: TranslationResult?
    @Published private(set) var translationSource: TranslationRequest?
    private var endpoint: URL?
    private var pairing = ""
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let session: URLSession
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 50
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: NoInsightRedirects(), delegateQueue: nil)
    }
    func configure(endpoint: String, pairing: String) throws {
        let url = try InsightError.endpoint(endpoint)
        guard (24...200).contains(pairing.count), !pairing.contains(where: \.isWhitespace) else { throw InsightError.configuration }
        cancel(); self.endpoint = url; self.pairing = pairing; isReady = false; status = "配置已更新，可检查服务；尚未发送对话。"
    }
    func check() {
        guard let endpoint else { status = InsightError.configuration.localizedDescription;failure = status; return }
        begin()
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: endpoint.appendingPathComponent("health")); self.authorize(&request)
                let (data, response) = try await self.session.data(for: request)
                try self.validateHTTP(data, response)
                struct Health: Decodable { var version: Int; var provider: String; var configured: Bool; var model: String }
                let health = try JSONDecoder().decode(Health.self, from: data)
                guard self.generation == token else { return }
                self.isReady = health.version == 1 && health.provider == "DeepSeek" && health.configured
                self.status = self.isReady ? "DeepSeek 服务已配置（尚未验证账户请求）：\(health.model)" : InsightError.server("deepseek_key_missing").localizedDescription
            } catch { if self.generation == token { self.status = self.message(error);self.failure = self.status; self.isReady = false } }
            if self.generation == token { self.isBusy = false }
        }
    }
    func organize(_ payload: InsightRequest) {
        guard let endpoint else { status = InsightError.configuration.localizedDescription;failure = status; return }
        do { try payload.validate() } catch { cancel(); status = error.localizedDescription; return }
        begin(); source = payload
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: endpoint.appendingPathComponent("v1/organize"))
                request.httpMethod = "POST"; self.authorize(&request)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(payload)
                let (data, response) = try await self.session.data(for: request)
                try self.validateHTTP(data, response)
                let result = try JSONDecoder().decode(InsightResult.self, from: data); try result.validate(request: payload)
                guard result.provider == "DeepSeek" else { throw InsightError.invalid }
                guard self.generation == token, !Task.isCancelled else { return }
                self.result = result; self.status = "DeepSeek 已返回整理建议；未保存、未确认、未发送回应。"
            } catch { if self.generation == token { self.status = self.message(error);self.failure = self.status } }
            if self.generation == token { self.isBusy = false }
        }
    }
    func invalidate(ifChanged conversation: ConversationSession) {
        if let source, !source.stillMatches(conversation) { cancel(); status = InsightError.stale.localizedDescription }
    }
    func translate(_ payload: TranslationRequest) {
        guard let endpoint else { status = InsightError.configuration.localizedDescription;failure = status; return }
        do { try payload.validate() } catch { cancel(); status = error.localizedDescription; return }
        begin(); translationSource = payload; let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: endpoint.appendingPathComponent("v1/translate"))
                request.httpMethod = "POST"; self.authorize(&request); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(payload)
                let (data,response) = try await self.session.data(for: request); try self.validateHTTP(data,response)
                let result = try JSONDecoder().decode(TranslationResult.self, from: data); try result.validate(request: payload)
                guard self.generation == token, !Task.isCancelled else { return }
                self.translation = result; self.status = "译文已返回，请对照原文核对姓名、数字和含义。"
            } catch { if self.generation == token { self.status = self.message(error);self.failure = self.status } }
            if self.generation == token { self.isBusy = false }
        }
    }
    func cancel() {
        failure = nil;generation = UUID(); operation?.cancel(); operation = nil; isBusy = false; result = nil; source = nil; translation = nil; translationSource = nil
        status = "整理已停止；原文和已采用的内容保留。"
    }
    private func begin() { cancel(); isBusy = true; status = "正在连接服务…" }
    private func authorize(_ request: inout URLRequest) { request.setValue("Bearer " + pairing, forHTTPHeaderField: "Authorization"); request.cachePolicy = .reloadIgnoringLocalCacheData }
    private func validateHTTP(_ data: Data, _ response: URLResponse) throws {
        guard data.count <= 65_536, let response = response as? HTTPURLResponse else { throw InsightError.invalid }
        if response.statusCode != 200 {
            struct Failure: Decodable { var error: String }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "unknown"
            throw InsightError.server(code)
        }
    }
    private func message(_ error: Error) -> String {
        if error is DecodingError { return InsightError.invalid.localizedDescription }
        return (error as? InsightError)?.localizedDescription ?? InsightError.network.localizedDescription
    }
}

private final class NoInsightRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
