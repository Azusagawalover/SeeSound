import SwiftUI
import Security

struct IntelligencePage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var audio: AudioProbes
    @ObservedObject var service: IntelligenceService
    @State private var selected: Set<UUID> = []
    @State private var consent = false
    @State private var configuration = false
    @State private var cardDraft: InformationCard?
    @State private var requiresDateChoice = false
    @State private var routineDraft: RoutineItem?
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    private var available: [ConversationTurn] { Array(audio.conversation.turns.filter { $0.state != .partial }.suffix(6)) }
    private var payload: InsightRequest { InsightRequest(turns: available.filter { selected.contains($0.id) }.map { InsightTurn(id: $0.id, text: $0.text, origin: $0.origin) }) }
    var body: some View {
        List {
            Section {
                Label("让约定更容易整理", systemImage: "text.magnifyingglass").font(.title3.bold())
                Text("选择最多六段已结束文字，主动发送到你配置的服务，再由服务调用 DeepSeek。音频、画面和其他记录不发送。结果是建议，采用前仍需核对。").font(.footnote).foregroundStyle(.secondary)
                Button("服务配置与检查", systemImage: "network") { configuration = true }
                Text(service.status).font(.footnote).foregroundStyle(.secondary)
            }
            Section("将要发送的文字 · \(selected.count) 段") {
                if available.isEmpty {
                    Text("还没有可选文字，先在沟通页输入回应或加入明确标注的演示。").foregroundStyle(.secondary)
                    Button("加入演示文字（不录音）") { audio.addDemonstration() }
                }
                ForEach(available) { turn in
                    Button {
                        service.cancel(); consent = false
                        if !selected.insert(turn.id).inserted { selected.remove(turn.id) }
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: selected.contains(turn.id) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 7) { Text(turn.text).foregroundStyle(.primary); Text(turn.origin.informationSource).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.disabled(service.isBusy)
                }
                Toggle("同意将以上选中文字发送到 DeepSeek", isOn: $consent).disabled(service.isBusy)
                Button("发送并生成整理建议", systemImage: "sparkles") { service.organize(payload) }
                    .disabled(!consent || selected.isEmpty || service.isBusy)
                if service.isBusy { ProgressView("正在整理"); Button("取消整理") { service.cancel() } }
                Text("只点击配置检查不会发送对话。实际生成会使用你账户的 API 额度；失败不自动重试。").font(.caption).foregroundStyle(.secondary)
            }
            if let result = service.result, let source = service.source, source.stillMatches(audio.conversation) {
                Section("DeepSeek 建议 · 未自动采用") {
                    Text(result.model).font(.caption).foregroundStyle(.secondary)
                    if !result.summary.isEmpty { Text(result.summary) }
                    if result.candidates.isEmpty { Text("没有提出可用信息卡或待办，可以继续手动整理。").foregroundStyle(.secondary) }
                    ForEach(result.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(candidate.kind.title + "：" + candidate.value).font(.headline)
                            Text("原文：" + candidate.quote).font(.subheadline).foregroundStyle(.secondary)
                            if candidate.kind == .time && candidate.date == nil { Text("没有确定完整日期，请在编辑器手动选择后再保存。").font(.caption).foregroundStyle(.orange) }
                            Button(candidate.kind == .task ? "编辑待办建议" : "编辑核对卡建议") {
                                guard source.stillMatches(audio.conversation) else { service.cancel(); return }
                                do {
                                    if candidate.kind == .task { routineDraft = try candidate.makeRoutine(request: source) }
                                    else { requiresDateChoice = candidate.kind == .time && candidate.date == nil; cardDraft = try candidate.makeCard(request: source) }
                                } catch { workspace.notify(error.localizedDescription) }
                            }.buttonStyle(.bordered)
                        }.padding(.vertical, 6)
                    }
                }
                Section("回应草稿 · 点击只填入") {
                    if (result.suppressedReplies ?? 0) > 0 {
                        Text("部分草稿声称操作已完成，已隐藏。信息尚未自动保存，也未安排提醒。").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(result.replies, id: \.self) { reply in
                        Button(reply) {
                            guard source.stillMatches(audio.conversation) else { service.cancel(); return }
                            workspace.prepareInsightReply(reply, source: source); dismiss()
                        }
                    }
                }
                if let questions = result.questions, !questions.isEmpty {
                    Section("还需要问清楚") {
                        ForEach(questions) { question in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(question.question).font(.headline)
                                Text("依据：" + question.quote).font(.caption).foregroundStyle(.secondary)
                                Button("把问题填入回应草稿") { workspace.prepareInsightReply(question.question, source: source); dismiss() }
                            }
                        }
                    }
                }
            }
        }.seePageCanvas().navigationTitle("智能整理")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { service.cancel(); dismiss() } } }
            .sheet(isPresented: $configuration) { IntelligenceConfiguration(service: service, onConfigure: workspace.configureIntelligence) }
            .sheet(item: $cardDraft) { InformationCardEditor(service: workspace.information, initial: $0, requiresDateChoice: requiresDateChoice) }
            .sheet(item: $routineDraft) { RoutineEditor(service: workspace.routines, initial: $0) }
            .onReceive(audio.$conversation) { value in
                if let source = service.source, !source.stillMatches(value) {
                    cardDraft = nil; routineDraft = nil; consent = false
                }
                service.invalidate(ifChanged: value)
                selected = selected.intersection(Set(value.turns.filter { $0.state != .partial }.suffix(6).map(\.id)))
            }
            .onChange(of: payload.turns) { _, _ in consent = false; service.cancel(); cardDraft = nil; routineDraft = nil }
            .onChange(of: audio.conversationEpoch) { _, _ in selected.removeAll(); consent = false; service.cancel() }
            .onChange(of: phase) { _, value in if value != .active { service.cancel(); consent = false } }
            .onDisappear { service.cancel(); consent = false }
            .overlay { if phase != .active { DailyPrivacyCover() } }
    }
}

struct IntelligenceConfiguration: View {
    @ObservedObject var service: IntelligenceService
    var onConfigure: ((String,String) throws -> Void)? = nil
    @State private var endpoint = UserDefaults.standard.string(forKey: "SeeSoundInsightEndpoint") ?? "http://127.0.0.1:8765"
    @State private var pairing = InsightPairingStore.read() ?? ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Form {
                Section("你自己的文字整理服务") {
                    TextField("服务地址", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("服务配对码（不是 DeepSeek 密钥）", text: $pairing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("DeepSeek 密钥仅配置在电脑或服务器上。模拟器可用本机回环地址；真机填写可信 HTTPS 服务地址。配对码保存在本机钥匙串。").font(.caption).foregroundStyle(.secondary)
                    Button("保存服务配置") {
                        do {
                            _ = try InsightError.endpoint(endpoint)
                            guard (24...200).contains(pairing.count), !pairing.contains(where: \.isWhitespace) else { throw InsightError.configuration }
                            try InsightPairingStore.save(pairing)
                            if let onConfigure { try onConfigure(endpoint,pairing) } else { try service.configure(endpoint: endpoint,pairing: pairing) }
                            UserDefaults.standard.set(endpoint, forKey: "SeeSoundInsightEndpoint")
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    Button("检查服务（不发送对话）") { service.check() }.disabled(service.isBusy)
                    Text(service.status).font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section("配置密钥") {
                    Text("在 Mac 的终端运行工程 Server/configure.py，隐藏输入 DeepSeek 密钥。脚本会生成供 App 使用的配对码，再运行 Server/server.py。完整步骤在工程使用说明中。")
                        .font(.footnote)
                }
            }.seePageCanvas().navigationTitle("DeepSeek 服务")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .overlay { if phase != .active { DailyPrivacyCover() } }
        }
    }
}

enum InsightPairingStore {
    private static var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword,
        kSecAttrService as String:"com.azusagawalover.SeeSound.insight", kSecAttrAccount as String:"proxy-pairing"] }
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let attributes: [String:Any] = [kSecValueData as String:Data(value.utf8), kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var q = query; attributes.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw InsightError.configuration }
        } else if result != errSecSuccess { throw InsightError.configuration }
    }
}
