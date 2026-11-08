import SwiftUI
import Combine

@MainActor
final class Workspace: ObservableObject {
    private let initialRecoveryMessage = LibraryRepository.recoverDefault()
    @Published private(set) var libraryRecoveryMessage:String?
    @Published private(set) var libraryStatus:String?
    @Published private(set) var isRestoringLibrary = false
    @Published private(set) var ledger = EventLedger()
    @Published private(set) var preferences = AppPreferences()
    @Published private(set) var annotations: [UUID: EventAnnotation] = [:]
    @Published private(set) var storageMessage: String?
    @Published var feedback: String?
    @Published var conversationDraft = ""
    @Published var navigationRequest: ProbePage?
    @Published var scheduledDestination: ScheduledDestination?
    @Published private(set) var demoRun: DemoRun?
    @Published private(set) var demoLedger = EventLedger()
    @Published private(set) var responseContext: EventResponseContext?
    @Published private(set) var draftOrigin: ConversationOrigin?
    @Published private(set) var draftAssistedBy: String?
    @Published private(set) var suppressedLinks: [EventPair] = []
    @Published private(set) var demoSuppressedLinks: [EventPair] = []
    @Published private(set) var demoAnnotations: [UUID: EventAnnotation] = [:]
    private var draftBeforeDemo: String?
    private var responseBeforeDemo: EventResponseContext?
    private var originBeforeDemo: ConversationOrigin?
    private var assistantBeforeDemo: String?
    private let journal = LocalJournal()
    private var storageNeedsRecovery = false
    let audio = AudioProbes()
    let hand = HandProbe()
    let bridge = ConnectivityBridge()
    let offlineSpeech = OfflineSpeechBridge()
    let samples = SoundSampleLibrary()
    let environment = EnvironmentalService()
    let intelligence = IntelligenceService()
    let workroom = WorkroomService()
    let workroomImporter = WorkroomImporter()
    @Published var pendingExampleImport:PendingExampleImport?
    let workroomAPI = IntelligenceService()
    let translationAPI = IntelligenceService()
    let caseUpdateAPI = IntelligenceService()
    let reminders = ReminderService()
    let agenda = AppointmentReminderService(client: SystemAgendaNotificationClient())
    let conversations = ConversationArchiveService()
    let information = InformationCardService()
    let routines = RoutineService()
    let quality = QualityService()
    let textSharing = TextSharingService()
    private var conversationSubscription: AnyCancellable?
    private var agendaSubscriptions: Set<AnyCancellable> = []

    init() {
        libraryRecoveryMessage = initialRecoveryMessage
        storageNeedsRecovery = initialRecoveryMessage != nil
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--workroom-demo") {
            try? workroom.use(.demonstrationDraft())
            var item = WorkroomCase(); item.title = "演示 · 参加读书会"; item.demonstration = true
            item.note = "核对报名截止时间，准备材料，再参加活动。"
            item.dueAt = Date().addingTimeInterval(7200);item.priority = .important;item.pinned = true
            item.materials = [CaseStep(title: "学生证"), CaseStep(title: "一本喜欢的书", done: true)]
            item.steps = [CaseStep(title: "向组织者确认报名截止时间"), CaseStep(title: "完成报名"), CaseStep(title: "按约定到图书馆二楼")]
            try? workroom.putCase(item, saveLocally: false)
        }
        if ProcessInfo.processInfo.arguments.contains("--workspace-upgrade-demo") {
            var before = WorkroomDraft.demonstrationDraft();before.title = "演示 · 原活动通知"
            before.text = "【演示】\n时间：2026-11-02 15:00\n地点：图书馆二楼\n材料费：12元\n请带学生证。"
            var after = before;after.id = UUID();after.title = "演示 · 补充通知";after.text = "【演示补充通知】\n时间：2026-11-03 16:00\n地点：图书馆三楼\n材料费：20元\n请带学生证和报名凭证。"
            let oldDocument = CaseDocument(draft:before),newDocument = CaseDocument(draft:after)
            var item = WorkroomCase();item.title = "演示 · 活动改期与跟进";item.demonstration = true;item.pinned = true
            item.sources = [oldDocument,newDocument];item.materials = [.init(title:"学生证")];item.steps = [.init(title:"完成报名",done:true),.init(title:"按确认安排参加活动")]
            item.arrangements = CaseUpdateComparison.localCandidates(source:oldDocument).map { .init(kind:$0.kind,value:$0.value,documentID:oldDocument.id,quote:$0.quote) }
            var flow = CaseFlow();flow.disposition = .waiting;flow.waitingFor = "组织者确认改期";flow.waitingSince = Date().addingTimeInterval(-172800);flow.followUpAt = Date().addingTimeInterval(3600);item.flow = flow
            try? workroom.use(after);try? workroom.putCase(item,saveLocally:false)
        }
        if ProcessInfo.processInfo.arguments.contains("--reset-campus-examples") { try? workroom.updateEnhancements { $0.campus?.journeys.removeAll { $0.demonstration && $0.title == "补办学生证 · 示例" } } }
        if ProcessInfo.processInfo.arguments.contains("--reset-experience") { try? workroom.clearExampleExperience();workroom.clearNotice() }
        #endif
        do {
            preferences = try journal.loadPreferences()
            let archive = try journal.loadHistory(preferences: preferences)
            ledger = EventLedger(events: archive.events)
            annotations = archive.annotations
            suppressedLinks = archive.suppressedLinks
            if preferences.saveHistory && libraryRecoveryMessage == nil { persist() }
        } catch {
            storageNeedsRecovery = true
            storageMessage = "本地记录读取失败：\(error.localizedDescription)。已暂停写入以保留原文件；可在「我的」删除全部记录后重置。"
        }
        audio.configure(sounds: preferences.sounds, sensitivity: preferences.sensitivity, engine: preferences.soundEngine)
        if let endpoint = UserDefaults.standard.string(forKey: "SeeSoundInsightEndpoint"), let pairing = InsightPairingStore.read() {
            try? configureIntelligence(endpoint, pairing)
        }
        audio.onSoundEvent = { [weak self] category, title in
            self?.register(category: category, title: title, source: .sound)
        }
        hand.onWave = { [weak self] in
            self?.register(category: "wave", title: "画面内出现挥手样式", source: .gesture)
        }
        bridge.onConfirmation = { [weak self] id in self?.confirm(id, notifyWatch: false) ?? false }
        bridge.isLocallyConfirmed = { [weak self] id in self?.event(id)?.status == .confirmed }
        bridge.onQuickReply = { [weak self] id, _ in
            guard let event = self?.event(id) else { return false }
            return event.status == .pending && Date().timeIntervalSince(event.lastSeen) <= 300
        }
        bridge.onAgendaConnection = { [weak self] in
            guard let self else { return }
            self.bridge.refreshAgendaVersions(self.watchAgendaItems)
        }
        bridge.onAgendaAction = { [weak self] id,digest,action in self?.handleWatchAgenda(id,digest:digest,action:action) ?? .init(accepted:false,message:"手机资料当前不可用。",item:nil) }
        reminders.onOpenScheduled = { [weak self] destination in self?.scheduledDestination = destination }
        if libraryRecoveryMessage != nil { agenda.suspend() }
        agenda.update(routines:routines.items,savedRoutineIDs:routines.savedIDs,cases:workroom.cases,savedCaseIDs:workroom.savedCaseIDs)
        Publishers.CombineLatest4(workroom.$cases, workroom.$savedCaseIDs, routines.$items, routines.$savedIDs)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] cases, caseIDs, items, itemIDs in
                self?.agenda.update(routines: items, savedRoutineIDs: itemIDs, cases: cases, savedCaseIDs: caseIDs)
                let projects = cases.filter { caseIDs.contains($0.id) && $0.isActive }.compactMap { try? $0.watchSummary(routines:items) }
                let tasks = items.filter { itemIDs.contains($0.id) && !$0.completed }.compactMap { try? $0.watchSummary() }
                self?.bridge.refreshAgendaVersions(self?.watchAgendaItems ?? (projects+tasks))
            }.store(in: &agendaSubscriptions)
        workroom.$enhancements.debounce(for:.milliseconds(150),scheduler:DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return };self.bridge.refreshAgendaVersions(self.watchAgendaItems)
        }.store(in:&agendaSubscriptions)
        reminders.cancelAll()
        conversationSubscription = audio.$conversation
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] conversation in self?.textSharing.publish(conversation); self?.intelligence.invalidate(ifChanged: conversation) }
    }

    @discardableResult
    func register(category: String, title: String, source: EventSource) -> SenseEvent {
        prune()
        let event = ledger.register(category: category, title: title, source: source)
        reminders.retain(Set((ledger.events + demoLedger.events).map(\.id)))
        persist()
        reminders.deliver(event, rule: preferences.reminderRule(for: ReminderGate.category(for: event)))
        return event
    }

    @discardableResult
    func confirm(_ id: UUID, notifyWatch: Bool = true) -> Bool {
        let isDemo = demoLedger.events.contains { $0.id == id }
        let found = isDemo ? demoLedger.confirm(id) : ledger.confirm(id)
        if found {
            reminders.confirm(id)
            if !isDemo { persist() }
            notify("提醒已确认")
            if notifyWatch { bridge.syncConfirmation(id) }
        }
        return found
    }
    func clear() { storageNeedsRecovery = false; reminders.cancelAll(); ledger.clear(); annotations.removeAll(); suppressedLinks.removeAll(); responseContext = nil; persist() }
    func remove(_ id: UUID) {
        if responseContext?.eventID == id { responseContext = nil }
        suppressedLinks.removeAll { $0.contains(id) }; demoSuppressedLinks.removeAll { $0.contains(id) }
        reminders.cancel(id)
        if demoLedger.events.contains(where: { $0.id == id }) { demoLedger.remove(id); demoAnnotations[id] = nil }
        else { ledger.remove(id); annotations[id] = nil; persist() }
    }
    func stopCapture() { audio.stopEverything(); hand.stop(); offlineSpeech.cancel(); samples.cancelCapture(); environment.stop(); intelligence.cancel(); workroomAPI.cancel(); translationAPI.cancel();caseUpdateAPI.cancel(); workroomImporter.cancel() }
    func configureIntelligence(_ endpoint: String, _ pairing: String) throws {
        try intelligence.configure(endpoint: endpoint, pairing: pairing)
        try workroomAPI.configure(endpoint: endpoint, pairing: pairing)
        try translationAPI.configure(endpoint: endpoint, pairing: pairing)
        try caseUpdateAPI.configure(endpoint:endpoint,pairing:pairing)
    }
    func stop() { stopCapture(); textSharing.stop(); finishDemo() }
    func event(_ id: UUID) -> SenseEvent? { (demoLedger.events + ledger.events).first { $0.id == id } }
    func startDemo(_ scenario: DemoScenario) {
        stopCapture(); textSharing.stop()
        information.discardUnsavedDemonstrations(); routines.discardUnsavedDemonstrations()
        for event in demoLedger.events { reminders.cancel(event.id) }
        demoLedger.clear(); demoSuppressedLinks.removeAll(); demoAnnotations.removeAll()
        if demoRun == nil { draftBeforeDemo = conversationDraft; responseBeforeDemo = responseContext; originBeforeDemo = draftOrigin; assistantBeforeDemo = draftAssistedBy }
        draftAssistedBy = nil
        responseContext = nil; draftOrigin = .demonstration
        audio.beginScenario(scenario); conversationDraft = scenario.suggestedReply
        var run = DemoRun(scenario: scenario)
        if scenario == .visitor {
            for (category, title) in [("doorbell", "演示：有人按门铃"), ("knock", "演示：随后传来敲门"), ("wave", "演示：画面内出现挥手样式") ] {
                let event = demoLedger.register(category: "demo-" + category, title: title, source: .demonstration)
                run.eventIDs.append(event.id); reminders.deliverDemonstration(event)
            }
        }
        run.turnIDs = audio.conversation.turns.map(\.id); demoRun = run
        if let id = run.eventIDs.first { reminders.show(id) }
    }
    func finishDemo() {
        guard demoRun != nil else { return }
        intelligence.cancel()
        textSharing.stop()
        for event in demoLedger.events { reminders.cancel(event.id) }
        demoLedger.clear(); demoSuppressedLinks.removeAll(); demoAnnotations.removeAll(); responseContext = nil; demoRun = nil; audio.endScenario()
        information.discardUnsavedDemonstrations()
        routines.discardUnsavedDemonstrations()
        conversationDraft = draftBeforeDemo ?? ""; draftBeforeDemo = nil
        responseContext = responseBeforeDemo; draftOrigin = originBeforeDemo; responseBeforeDemo = nil; originBeforeDemo = nil
        draftAssistedBy = assistantBeforeDemo; assistantBeforeDemo = nil
    }
    func prepareDemoInformation() {
        guard var run = demoRun else { return }
        guard run.informationIDs.isEmpty else { notify("本演示已准备过信息卡，请打开核对；重新开始可再体验"); return }
        let cards = run.scenario.informationCards()
        guard information.cards.count + cards.count <= 30 else { notify("信息卡已接近上限，请先整理"); return }
        do {
            try cards.forEach { try $0.validate() }
            for card in cards { try information.put(card, saveLocally: false) }
            run.informationIDs = cards.map(\.id); demoRun = run
            notify("已准备演示信息卡，尚未标记核对")
        } catch { notify(error.localizedDescription) }
    }
    func phaseChanged(_ phase: ScenePhase) {
        bridge.appIsActive = phase == .active
        if phase != .active { stopCapture() }
        if phase == .background { textSharing.stop() }
        textSharing.foreground = phase == .active
        if phase == .active { refresh(); textSharing.publish(audio.conversation) }
    }
    func usePhrase(_ phrase: String) {
        updatePreferences {
            $0.recentPhrases.removeAll { $0 == phrase }; $0.recentPhrases.insert(phrase, at: 0)
            $0.recentPhrases = Array($0.recentPhrases.prefix(8))
        }
    }

    func notify(_ message: String) { feedback = message }

    @discardableResult
    func addPhrases(_ items: [SharedPhrase]) -> Int {
        var added = 0
        updatePreferences { preferences in
            for item in items where !preferences.phrases.contains(item.text) {
                guard preferences.phrases.count < PhraseCollection.limit else { break }
                preferences.phrases.append(item.text)
                preferences.phraseCategories[item.text] = item.category
                added += 1
            }
        }
        if storageMessage == nil { notify(added == 0 ? "没有新增卡片" : "已加入 \(added) 张沟通卡") }
        return added
    }

    func updatePreferences(_ change: (inout AppPreferences) -> Void) {
        let wasSaving = preferences.saveHistory
        let previousRules = preferences.reminderRules
        change(&preferences)
        for category in SoundKind.allCases.map(\.rawValue) + ["wave"] {
            let before = previousRules[category] ?? ReminderRule()
            let after = preferences.reminderRule(for: category)
            if before != after { reminders.rulesChanged(category, hideVisual: !after.visual, priority: after.priority) }
        }
        preferences.phraseCategories = preferences.phraseCategories.filter { preferences.phrases.contains($0.key) }
        preferences.pinnedPhrases = preferences.pinnedPhrases.filter { preferences.phrases.contains($0) }
        preferences.recentPhrases = preferences.recentPhrases.filter { preferences.phrases.contains($0) }
        if wasSaving && !preferences.saveHistory { storageNeedsRecovery = false }
        audio.configure(sounds: preferences.sounds, sensitivity: preferences.sensitivity, engine: preferences.soundEngine)
        prune()
        persist()
    }

    func applyScene(_ scene: ListeningScene) {
        stopCapture()
        updatePreferences { $0.apply(scene) }
    }

    func saveProfile(_ profile: SceneProfile) throws {
        guard !storageNeedsRecovery else {
            throw NSError(domain: "SeeSoundStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: storageMessage ?? "本地设置需要先恢复，原文件已保留。"])
        }
        var draft = preferences; try draft.saveProfile(profile)
        updatePreferences { $0 = draft }
        if let storageMessage { throw NSError(domain: "SeeSoundStorage", code: 2, userInfo: [NSLocalizedDescriptionKey: storageMessage]) }
        notify("场景已保存")
    }
    func applyProfile(_ id: UUID) {
        do {
            var draft = preferences; try draft.applyProfile(id)
            stopCapture(); updatePreferences { $0 = draft }; notify("已切换场景；采集需要手动开启")
        } catch { notify(error.localizedDescription) }
    }
    func deleteProfile(_ id: UUID) { updatePreferences { $0.deleteProfile(id) } }
    @discardableResult
    func prepareResponse(to eventID: UUID, text: String) -> Bool {
        guard let event = event(eventID) else { notify("这条事件已移除，请重新选择"); return false }
        guard demoRun == nil || event.isDemonstration else { notify("请先结束场景演示，再回应真实事件"); return false }
        responseContext = EventResponseContext(event); conversationDraft = String(text.prefix(500))
        draftAssistedBy = nil
        draftOrigin = event.isDemonstration ? .demonstration : .typed
        navigationRequest = .captions; return true
    }
    func cancelResponseContext() { responseContext = nil }
    func prepareJourneyPhrase(_ text:String,demonstration:Bool) {
        guard demoRun == nil || demonstration else { notify("请先结束场景演示，再使用普通旅程的表达。");return }
        responseContext = nil;draftAssistedBy = nil;conversationDraft = String(text.prefix(500));draftOrigin = demonstration ? .demonstration : .typed
        navigationRequest = .captions
    }
    func prepareInsightReply(_ text: String, source: InsightRequest) {
        guard source.stillMatches(audio.conversation) else { notify(InsightError.stale.localizedDescription); return }
        responseContext = nil; conversationDraft = String(text.prefix(500))
        draftOrigin = source.turns.contains { $0.origin == .demonstration } ? .demonstration : .typed
        draftAssistedBy = "DeepSeek"
        navigationRequest = .captions
    }
    @discardableResult
    func sendDraft(aloud: Bool) -> Bool {
        if let context = responseContext {
            guard event(context.eventID) != nil else { notify("事件已移除，请取消关联后重新发送"); return false }
            guard demoRun == nil || context.demonstration else { notify("请先结束场景演示"); return false }
        }
        let ok = audio.respond(conversationDraft, aloud: aloud,
                               origin: draftOrigin,
                               replyEventTitle: responseContext?.title, assistedBy: draftAssistedBy)
        if ok { conversationDraft = ""; responseContext = nil; draftOrigin = nil; draftAssistedBy = nil }
        return ok
    }
    func addInformationToConversation(_ card: InformationCard) {
        guard demoRun == nil || card.origin == .demonstration else { notify("请先结束演示，再加入真实信息卡"); return }
        guard (try? card.validate()) != nil else { notify("信息卡格式不完整"); return }
        _ = audio.respond(String(card.exportText.prefix(500)), aloud: false, origin: card.origin == .demonstration ? .demonstration : .typed)
        notify("已加入对话；已连接的文字共享设备也会收到")
    }
    var associations: [EventAssociation] {
        EventAssociation.group(ledger.events + demoLedger.events, window: preferences.associationWindow,
                               suppressed: Set(suppressedLinks + demoSuppressedLinks))
    }
    func detach(_ eventID: UUID, from group: EventAssociation) {
        guard let event = event(eventID) else { return }
        let links = group.events.filter { $0.id != eventID }.map { EventPair($0.id, eventID) }
        if event.isDemonstration && demoLedger.events.contains(where: { $0.id == eventID }) {
            demoSuppressedLinks = Array(Set(demoSuppressedLinks + links))
        } else { suppressedLinks = Array(Set(suppressedLinks + links)); persist() }
    }
    func restoreAssociations() { suppressedLinks.removeAll(); demoSuppressedLinks.removeAll(); persist(); notify("已恢复按时间整理") }

    func togglePin(_ phrase: String) {
        updatePreferences { prefs in
            if prefs.pinnedPhrases.contains(phrase) { prefs.pinnedPhrases.removeAll { $0 == phrase } }
            else if prefs.phrases.contains(phrase) { prefs.pinnedPhrases.append(phrase) }
        }
    }

    func annotate(_ id: UUID, verdict: EventVerdict, note: String) {
        if demoLedger.events.contains(where: { $0.id == id }) {
            demoAnnotations[id] = EventAnnotation(verdict: verdict, note: String(note.prefix(500))); return
        }
        guard ledger.events.contains(where: { $0.id == id }) else { return }
        annotations[id] = EventAnnotation(verdict: verdict, note: String(note.prefix(500)))
        persist()
    }

    func annotation(for id: UUID) -> EventAnnotation? { demoAnnotations[id] ?? annotations[id] }

    func refresh() { prune(); persist(); bridge.refresh(); reminders.refreshQueue(); agenda.refresh() }

    private func prune() {
        let before = Set(ledger.events.map(\.id))
        ledger.retain(since: Date().addingTimeInterval(-Double(preferences.retentionDays) * 86_400))
        let ids = Set(ledger.events.map(\.id))
        for id in before.subtracting(ids) { reminders.cancel(id) }
        annotations = annotations.filter { ids.contains($0.key) }
        suppressedLinks = suppressedLinks.filter { ids.contains($0.first) && ids.contains($0.second) }
    }

    private func persist() {
        guard !storageNeedsRecovery,!isRestoringLibrary else { return }
        let ids = Set(ledger.events.map(\.id))
        annotations = annotations.filter { ids.contains($0.key) }
        suppressedLinks = suppressedLinks.filter { ids.contains($0.first) && ids.contains($0.second) }
        do {
            if !preferences.saveHistory { try journal.deleteHistory() }
            try journal.savePreferences(preferences)
            if preferences.saveHistory {
                try journal.saveHistory(JournalArchive(events: ledger.events, annotations: annotations, suppressedLinks: suppressedLinks))
            }
            storageMessage = nil
        } catch { storageMessage = "本地保存或删除未完成：\(error.localizedDescription)。请重试，不要据此认为记录已删除。" }
    }
}

@main
struct SeeSoundApp: App {
    @StateObject private var workspace = Workspace()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ReadingRoot(workspace: workspace)
                .disabled(workspace.isRestoringLibrary)
                .overlay {
                    if workspace.isRestoringLibrary {
                        ZStack { Color(.systemBackground).opacity(0.96).ignoresSafeArea();ProgressView("正在恢复资料，请稍候…").padding(30) }.accessibilityAddTraits(.isModal)
                    } else if let message = workspace.libraryRecoveryMessage {
                        ZStack {
                            Color(.systemBackground).ignoresSafeArea()
                            VStack(spacing:20) { Label("需要恢复资料",systemImage:"externaldrive.badge.exclamationmark").font(.title2);Text(message);Button("重试恢复原资料") { Task { await workspace.retryLibraryRecovery() } }.buttonStyle(.borderedProminent).tint(SeePalette.button) }.padding(30).frame(maxWidth:600)
                        }.accessibilityAddTraits(.isModal)
                    }
                }
                .tint(.seeAccent)
                .onChange(of: scenePhase) { _, phase in
                    workspace.phaseChanged(phase)
                }
        }
    }
}


extension Workspace {
    @discardableResult func restoreLibrary(_ preview:LibraryRestorePreview) async -> Bool {
        guard !isRestoringLibrary else { return false }
        let caseIDs = Set(preview.target.workroom.cases.map(\.id)),cardIDs = Set(preview.target.cards.map(\.id)),taskIDs = Set(preview.target.routines.map(\.id))
        guard !workroom.cases.contains(where:{ !workroom.savedCaseIDs.contains($0.id) && caseIDs.contains($0.id) }),
              !information.cards.contains(where:{ !information.savedIDs.contains($0.id) && cardIDs.contains($0.id) }),
              !routines.items.contains(where:{ !routines.savedIDs.contains($0.id) && taskIDs.contains($0.id) }) else {
            libraryStatus = "文件中有与本机临时记录相同的标识。请先保存这些临时修改，再重新生成恢复预览。";return false
        }
        guard preview.target.workroom.cases.count+workroom.cases.filter({ !workroom.savedCaseIDs.contains($0.id) && !caseIDs.contains($0.id) }).count <= 100,
              preview.target.cards.count+information.cards.filter({ !information.savedIDs.contains($0.id) && !cardIDs.contains($0.id) }).count <= 30,
              preview.target.routines.count+routines.items.filter({ !routines.savedIDs.contains($0.id) && !taskIDs.contains($0.id) }).count <= 80 else { libraryStatus = "合并后连同临时记录超过容量，请先整理后重新预览。";return false }
        stop();isRestoringLibrary = true;agenda.suspend();libraryStatus = nil
        var succeeded = false
        do {
            try journal.closeDatabase()
            try await Task.detached(priority:.userInitiated) { try LibraryRepository().commit(preview) }.value
            try reloadLibraryState()
            libraryStatus = "资料已合并到本机。提醒按你在恢复预览中的选择处理。"
            succeeded = true
        } catch { libraryStatus = "恢复未完成："+error.localizedDescription;libraryRecoveryMessage = LibraryRepository.recoverDefault();try? reloadLibraryState() }
        isRestoringLibrary = false;agenda.update(routines:routines.items,savedRoutineIDs:routines.savedIDs,cases:workroom.cases,savedCaseIDs:workroom.savedCaseIDs);if libraryRecoveryMessage == nil { agenda.resume() }
        return succeeded
    }
    func retryLibraryRecovery() async {
        guard !isRestoringLibrary else { return };stop();isRestoringLibrary = true;agenda.suspend()
        do {
            try journal.closeDatabase();_ = try await Task.detached { try LibraryRepository().recover() }.value
            try reloadLibraryState();libraryRecoveryMessage = nil;storageNeedsRecovery = false;libraryStatus = "已恢复上次写入前的资料。"
        } catch { libraryStatus = "仍未能完成回退，恢复日志已保留。" }
        isRestoringLibrary = false;agenda.update(routines:routines.items,savedRoutineIDs:routines.savedIDs,cases:workroom.cases,savedCaseIDs:workroom.savedCaseIDs);if libraryRecoveryMessage == nil { agenda.resume() }
    }
    private func reloadLibraryState() throws {
        try workroom.reloadFromDisk();try information.reloadFromDisk();try routines.reloadFromDisk();conversations.reload();quality.reload()
        preferences = try journal.loadPreferences()
        let archive = try journal.loadHistory(preferences:preferences);ledger = EventLedger(events:archive.events);annotations = archive.annotations;suppressedLinks = archive.suppressedLinks
        audio.configure(sounds:preferences.sounds,sensitivity:preferences.sensitivity,engine:preferences.soundEngine)
    }
    private func handleWatchAgenda(_ id:UUID,digest:String,action:WatchAgendaAction) -> WatchAgendaResolution {
        guard !isRestoringLibrary,libraryRecoveryMessage == nil else { return .init(accepted:false,message:"手机资料正在恢复或需要回退，请稍后重新发送。",item:nil) }
        do {
            if let journey = workroom.campus.journeys.first(where:{$0.id == id}),journey.stage != .finished,action == .seen {
                let summary = try journey.watchJourneySummary()
                if let reason = WatchAgendaActionPolicy.rejection(item:summary,fingerprint:digest,action:action) { return .init(accepted:false,message:reason,item:nil) }
                try workroom.updateCampusWorkspace { $0.watchSeenVersions[id.uuidString] = digest }
                var updated = summary;updated.seen = true
                return .init(accepted:true,message:"手机收到旅程查看回执，没有自动确认安排或完成事务。",item:updated)
            }
            if var item = workroom.cases.first(where:{$0.id == id}),workroom.savedCaseIDs.contains(id),item.isActive,action == .seen {
                if let reason = WatchAgendaActionPolicy.rejection(item:try item.watchSummary(routines:routines.items),fingerprint:digest,action:action) { return .init(accepted:false,message:reason,item:nil) }
                item.watchSeenVersion = try item.watchViewVersion(routines:routines.items);item.watchSeenAt = Date();try workroom.putCase(item,saveLocally:true)
                return .init(accepted:true,message:"手机已接收查看回执，事务步骤没有自动完成。",item:try item.watchSummary(routines:routines.items))
            }
            if let item = routines.items.first(where:{$0.id == id}),routines.savedIDs.contains(id),!item.completed,action == .complete {
                if let reason = WatchAgendaActionPolicy.rejection(item:try item.watchSummary(),fingerprint:digest,action:action) { return .init(accepted:false,message:reason,item:nil) }
                guard item.sourceWarning(cards:information.cards) == nil else { return .init(accepted:false,message:"原信息有变化，请先在手机核对再完成。",item:nil) }
                try routines.complete(id,completed:true)
                guard let updated = routines.items.first(where:{$0.id == id}) else { throw DailyError.stale }
                return .init(accepted:true,message:"手机已保存待办完成状态。",item:try updated.watchSummary())
            }
            return .init(accepted:false,message:"对应记录已改变、已移除或不可处理，请重新发送。",item:nil)
        } catch { return .init(accepted:false,message:"手机没有保存本次操作，请在手机检查后重试。",item:nil) }
    }
    var watchAgendaItems:[WatchAgendaItem] {
        let projects = workroom.cases.filter{workroom.savedCaseIDs.contains($0.id) && $0.isActive}.compactMap{try? $0.watchSummary(routines:routines.items)}
        let tasks = routines.items.filter{routines.savedIDs.contains($0.id) && !$0.completed}.compactMap{try? $0.watchSummary()}
        let journeys = workroom.campus.journeys.filter{$0.stage != .finished}.compactMap { journey -> WatchAgendaItem? in
            guard var item = try? journey.watchJourneySummary() else { return nil }
            item.seen = workroom.campusWorkspace.watchSeenVersions[journey.id.uuidString] == item.fingerprint;return item
        }
        return projects+tasks+journeys
    }
}
