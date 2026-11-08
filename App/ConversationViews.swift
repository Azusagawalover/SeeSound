import SwiftUI

struct ConversationPage: View {
    @ObservedObject var audio: AudioProbes
    @ObservedObject var workspace: Workspace
    @Binding private var reply: String
    @State private var panel: ConversationPanel = .reading
    @State private var category: PhraseCategory?
    @State private var phraseQuery = ""
    @State private var appendCards = false
    @State private var showFacing = false
    @State private var editing: ConversationTurn?
    @State private var clearAll = false
    @State private var removal: UUID?
    @State private var frozen: [ConversationTurn]?
    @State private var showSave = false
    @State private var showJourneyClip = false
    @State private var informationDraft: InformationCard?
    @State private var showIntelligence = false
    @State private var historyQuery = ""
    @FocusState private var replyFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize

    init(audio: AudioProbes, workspace: Workspace, startWithReply: Bool = false) {
        self.audio = audio; self.workspace = workspace
        _reply = Binding(get: { workspace.conversationDraft }, set: { workspace.conversationDraft = $0 })
        _panel = State(initialValue: startWithReply ? .response : .reading)
    }
    private var displayed: [ConversationTurn] { frozen ?? audio.conversation.turns }
    private var phrases: [String] { PhraseComposer.visible(preferences: workspace.preferences, category: category, query: phraseQuery) }
    private var quickPhrases: [String] { Array(PhraseComposer.visible(preferences: workspace.preferences, category: nil, query: "").prefix(3)) }

    var body: some View {
        GeometryReader { size in
            let wide = UIDevice.current.userInterfaceIdiom == .pad && size.size.width >= 900
                && size.size.width > size.size.height && !textSize.isAccessibilitySize
            VStack(spacing: 0) {
                sessionBar
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { readingContent.padding(20).frame(maxWidth: .infinity) }
                        Divider()
                        ScrollView { responseContent.padding(20).frame(maxWidth: .infinity) }
                    }
                } else {
                    HStack(spacing: 4) {
                        ForEach(ConversationPanel.allCases) { option in
                            Button { panel = option } label: {
                                Label(option == .reading ? "看字幕" : "写回应 · 沟通卡", systemImage: option == .reading ? "captions.bubble" : "text.bubble")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(panel == option ? Color.seeAccent : Color.primary)
                                    .frame(maxWidth: .infinity, minHeight: 44).padding(.vertical, 4)
                                    .background(panel == option ? SeePalette.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(panel == option ? Color.seeAccent : .clear, lineWidth: 1.5).allowsHitTesting(false))
                            }.buttonStyle(.plain).accessibilityAddTraits(panel == option ? .isSelected : [])
                                .accessibilityIdentifier("conversation.panel." + option.rawValue)
                        }
                    }.padding(4).background(SeePalette.rose.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 20).padding(.bottom, 12)
                    ScrollView {
                        if panel == .reading { readingContent.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity) }
                        else { responseContent.padding(20).frame(maxWidth: 750).frame(maxWidth: .infinity) }
                    }.id(panel)
                }
            }
        }.background(SeePalette.canvas)
            .safeAreaInset(edge: .top) { WorkflowStatusArea(workspace: workspace) }
            .scrollDismissesKeyboard(.interactively)
            .seePageCanvas().navigationTitle("面对面沟通").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("保存当前会话", systemImage: "square.and.arrow.down") { showSave = true }.disabled(audio.conversation.turns.isEmpty)
                        Button("选取字幕加入办事旅程",systemImage:"text.badge.plus") { showJourneyClip = true }.disabled(audio.conversation.turns.isEmpty)
                        Button("面对面阅读", systemImage: "rectangle.split.2x1") { replyFocused = false; showFacing = true }
                        NavigationLink("已保存会话", destination: SavedConversationsPage(service: workspace.conversations))
                        NavigationLink("时间、地点与费用组合核对") { List { KeyFieldsPanel(text:audio.conversation.turns.map(\.text).joined(separator:"\n")) }.seePageCanvas().navigationTitle("组合核对").modifier(WorkroomPrivacy()) }
                        NavigationLink("重要信息核对", destination: InformationCardsPage(workspace: workspace, service: workspace.information))
                        Button("DeepSeek 智能整理", systemImage: "sparkles") { showIntelligence = true }
                        NavigationLink("临时文字共享", destination: TextSharingPage(service: workspace.textSharing, audio: audio, workspace: workspace))
                        NavigationLink("场景演示", destination: ScenarioDemoPage(workspace: workspace, audio: audio, sharing: workspace.textSharing, bridge: workspace.bridge))
                        NavigationLink("字幕快捷纠正", destination: CorrectionSettingsPage(workspace: workspace))
                        NavigationLink("沟通模板库", destination: PhraseLibraryPage(workspace: workspace))
                        NavigationLink("卡片扫码与分享", destination: PhraseTransferPage(workspace: workspace))
                        NavigationLink("音频文件转写", destination: OfflineSpeechPage(service: workspace.offlineSpeech, audio: audio))
                        Button("加入演示文字") { frozen = nil; audio.addDemonstration() }
                        Button("停止采集与朗读", systemImage: "stop.circle") { audio.stopEverything() }
                        Button("清空这次对话", systemImage: "trash", role: .destructive) { clearAll = true }
                    } label: { Label("沟通操作", systemImage: "ellipsis.circle") }
                }
            }
            .sheet(item: $editing) { turn in EditConversationTurn(audio: audio, turn: turn, corrections: workspace.preferences.corrections) }
            .sheet(isPresented: $showSave) { SaveConversationSheet(audio: audio, service: workspace.conversations) }
            .sheet(isPresented:$showJourneyClip) { JourneyClipPicker(studio:workspace.workroom,turns:audio.conversation.turns,activeCapture:audio.conversation.activeCapture) }
            .sheet(item: $informationDraft) { InformationCardEditor(service: workspace.information, initial: $0) }
            .sheet(isPresented: $showIntelligence) { NavigationStack { IntelligencePage(workspace: workspace, audio: audio, service: workspace.intelligence) } }
            .fullScreenCover(isPresented: $showFacing) { FacingConversationView(audio: audio, workspace: workspace, reply: $reply) }
            .onAppear { if workspace.responseContext != nil { panel = .response } }
            .onChange(of: workspace.responseContext) { _, context in if context != nil { panel = .response } }
            .confirmationDialog("清空这次对话与临时回应？", isPresented: $clearAll, titleVisibility: .visible) {
                Button("停止并清空", role: .destructive) { audio.clearTranscript(); reply = ""; frozen = nil }
            } message: { Text("停止采集与朗读，移除当前文字。已保存的会话和常用语不受影响；场景演示中清空只影响演示对话。") }
            .confirmationDialog("移除这段对话？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                Button("移除", role: .destructive) {
                    if let id = removal, audio.removeTurn(id) { frozen?.removeAll { $0.id == id } }
                    removal = nil
                }
            }
            .onChange(of: panel) { _, _ in replyFocused = false }
            .onChange(of: audio.conversationEpoch) { _, _ in frozen = nil; editing = nil; removal = nil; historyQuery = "" }
            .overlay { if scenePhase != .active { privacyCover } }
    }

    private var sessionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack { captureLabel; Spacer(); captureButton }
                VStack(alignment: .leading, spacing: 8) { captureLabel; captureButton }
            }
            ViewThatFits(in: .horizontal) {
                HStack { readingButtons }
                VStack(alignment: .leading, spacing: 8) { readingButtons }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).background(SeePalette.surface)
    }
    private var captureLabel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(audio.isScenarioDemo ? "场景演示 · 麦克风关闭" : audio.isStarting ? "正在准备麦克风" : audio.mode == .captions ? liveSpeakerLabel : audio.mode == .sound ? "麦克风用于声音关注" : "麦克风已关闭",
                  systemImage: audio.mode == .idle && !audio.isStarting ? "mic.slash" : "mic.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.seeAccent)
            Text(audio.isStarting ? "正在准备，随时可以停止" : audio.status)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var captureButton: some View {
        if audio.isScenarioDemo {
            Text("仅演示文字").font(.caption).foregroundStyle(.secondary)
        } else if audio.mode != .idle || audio.isStarting {
            Button("停止采集", systemImage: "stop.fill") { audio.stopEverything() }.buttonStyle(.bordered).frame(minHeight: 44)
        } else {
            Button("开始字幕", systemImage: "mic") { Task { await audio.startCaptions() } }.buttonStyle(.borderedProminent).tint(SeePalette.button).frame(minHeight: 44)
        }
    }
    @ViewBuilder private var readingButtons: some View {
        Button(frozen == nil ? "固定画面" : "回到最新", systemImage: frozen == nil ? "pause.rectangle" : "arrow.clockwise") {
            frozen = frozen == nil ? audio.conversation.turns : nil
        }.buttonStyle(.bordered).frame(minHeight: 44).accessibilityIdentifier("conversation.freeze")
        Text(frozen == nil ? "新文字显示在最上方" : "画面已固定 · 不改变麦克风状态")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var liveSpeakerLabel: String {
        guard let turn = audio.conversation.turns.first(where: { $0.id == audio.conversation.activeCapture }) else { return "正在采集字幕" }
        return "正在采集 · " + (turn.speakerName ?? "对方")
    }
    private var readingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("最新文字").font(.title2.bold())
                Spacer()
                Text("\(displayed.count) / 50 段").font(.caption).foregroundStyle(.secondary)
            }
            if frozen != nil { Notice(text: "已固定阅读画面，开启的字幕与共享仍可更新。点「回到最新」查看后续文字。") }
            if displayed.isEmpty {
                VStack(spacing: 14) {
                    SeeEmptyState(title:"看清对方说的话",detail:"点「开始字幕」后，在这里阅读。\n也可以先写一句话给对方看。",artwork:.speech)
                    Button("写一句给对方看", systemImage: "text.bubble") { panel = .response }
                        .buttonStyle(SeeSecondaryButtonStyle())
                }.modifier(WorkspaceSurface())
            } else {
                ForEach(Array(displayed.suffix(2).reversed())) { turn in
                    conversationRow(turn, emphasized: turn.id == displayed.last?.id)
                }
            }
            quickResponseCards
            if displayed.count > 2 {
                DisclosureGroup("较早的文字") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(displayed.dropLast(2).suffix(10).reversed())) { turn in
                            conversationRow(turn)
                        }
                    }.padding(.top, 12)
                }
            }
            if !displayed.isEmpty {
                NavigationLink("查看与搜索全部 \(displayed.count) 段") { conversationHistory }
                Text("长按已结束文字可改字、标记说话者或移除。").font(.caption).foregroundStyle(.secondary)
            }
            Button("智能整理约定与回应", systemImage: "sparkles") { showIntelligence = true }.buttonStyle(.bordered)
            DisclosureGroup("字幕选项与输入状态") {
                VStack(spacing: 12) {
                    CaptureControl(audio: audio)
                    if audio.mode != .idle { InputSignalView(audio: audio) }
                }.padding(.top, 12)
            }.font(.subheadline).conversationCard()
            Notice(text: "字幕可能识别错误，姓名、数字和地点请双方确认。可选前台连续分段，每次最多 20 分钟 / 60 段；保留最近 50 段。")
            Text("只有主动确认才保存会话。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func conversationRow(_ turn: ConversationTurn, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ConversationBubble(turn: turn, emphasized: emphasized).contextMenu { turnActions(turn) }
            Button("制作核对卡", systemImage: "rectangle.on.rectangle") { makeInformationCard(turn) }
                .font(.caption).frame(minHeight: 44).disabled(turn.id == audio.conversation.activeCapture || workspace.information.cards.count >= 30)
        }
    }
    private var quickResponseCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("快捷回应", systemImage: "text.bubble").font(.headline)
                Spacer()
                Button("全部沟通卡") { category = nil; phraseQuery = ""; panel = .response }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            Text("点选填入草稿，确认后再显示或朗读。").font(.caption).foregroundStyle(.secondary)
            ForEach(quickPhrases, id: \.self) { phrase in
                Button { choose(phrase); panel = .response } label: {
                    HStack(spacing: 12) {
                        Text(phrase).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right").font(.caption).accessibilityHidden(true)
                    }.font(.subheadline.weight(.semibold)).padding(14).frame(minHeight: 48)
                        .background(SeePalette.rose.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityIdentifier("conversation.quickReply." + phrase)
            }
        }.conversationCard()
    }
    private var responseContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Label("写给对方看", systemImage: "square.and.pencil").font(.title2.bold())
                Text("输入一句话，或从下方沟通卡中选择。").font(.subheadline).foregroundStyle(.secondary)
                if let assistant = workspace.draftAssistedBy { Text("\(assistant) 建议草稿 · 请核对后显示或朗读").font(.caption).foregroundStyle(Color.seeAccent) }
                if let context = workspace.responseContext {
                    Text("\(context.demonstration ? "演示 · " : "")回应事件：\(context.title)").font(.subheadline).foregroundStyle(Color.seeAccent)
                    Button("取消事件关联") { workspace.cancelResponseContext() }.font(.caption)
                } else if workspace.draftOrigin == .demonstration {
                    Label("演示草稿 · 发送后保留演示标记", systemImage: "play.rectangle").font(.caption)
                }
                TextField("写下想说的话", text: $reply, axis: .vertical).lineLimit(3...7)
                    .font(.title2).padding(14).background(SeePalette.canvas.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(SeePalette.line, lineWidth: 1))
                    .focused($replyFocused).accessibilityIdentifier("conversation.reply")
                    .onChange(of: reply) { _, value in if value.count > 500 { reply = String(value.prefix(500)) } }
                ViewThatFits(in: .horizontal) {
                    HStack { responseButtons }
                    VStack(alignment: .leading) { responseButtons }
                }.disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("\(reply.count) / 500 字 · 朗读会停止麦克风，结束后不自动恢复。").font(.caption).foregroundStyle(.secondary)
                Button("面对面大字阅读", systemImage: "rectangle.split.2x1") { replyFocused = false; showFacing = true }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                if audio.isSpeaking {
                    Button("停止朗读", systemImage: "stop.circle") { audio.stopSpeaking() }.buttonStyle(.bordered)
                }
                Text(audio.speechStatus).font(.caption).foregroundStyle(.secondary)
            }.conversationCard()
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("常用沟通卡").font(.title3.bold()); Spacer(); Text("点击只填入回应").font(.caption).foregroundStyle(.secondary) }
                Picker("卡片分类", selection: $category) {
                    Text("全部").tag(Optional<PhraseCategory>.none)
                    ForEach(PhraseCategory.allCases) { Text($0.title).tag(Optional($0)) }
                }.pickerStyle(.menu)
                TextField("搜索自己的沟通卡", text: $phraseQuery).textFieldStyle(.roundedBorder)
                Toggle("连续组合到回应", isOn: $appendCards).font(.subheadline)
                if phraseQuery.isEmpty && category == nil && !workspace.preferences.recentPhrases.isEmpty {
                    Text("最近使用").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack { ForEach(workspace.preferences.recentPhrases, id: \.self) { phrase in
                            Button(phrase) { choose(phrase) }.buttonStyle(.bordered).lineLimit(2)
                        } }
                    }
                }
                if phrases.isEmpty { Text("没有匹配的卡片。").foregroundStyle(.secondary) }
                ForEach(phrases, id: \.self) { phrase in
                    HStack(alignment: .center, spacing: 8) {
                        Button { choose(phrase) } label: {
                            Text(phrase).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                .font(.headline).padding(16).frame(minHeight: 56).background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                        Button { workspace.togglePin(phrase) } label: {
                            Image(systemName: workspace.preferences.pinnedPhrases.contains(phrase) ? "pin.fill" : "pin").frame(width: 44, height: 44)
                        }.buttonStyle(.borderless).accessibilityLabel((workspace.preferences.pinnedPhrases.contains(phrase) ? "取消置顶：" : "置顶：") + phrase)
                    }
                }
                NavigationLink("挑选更多沟通模板") { PhraseLibraryPage(workspace: workspace) }
            }
        }
    }
    private var conversationHistory: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(displayed.filter { historyQuery.isEmpty || $0.text.localizedCaseInsensitiveContains(historyQuery) || ($0.speakerName ?? "").localizedCaseInsensitiveContains(historyQuery) }) { turn in
                    ConversationBubble(turn: turn).contextMenu { turnActions(turn) }
                }
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(SeePalette.canvas).seePageCanvas().navigationTitle("本次对话")
            .searchable(text: $historyQuery, prompt: "搜索本次文字或说话者")
            .overlay { if scenePhase != .active { privacyCover } }
    }
    @ViewBuilder private func turnActions(_ turn: ConversationTurn) -> some View {
        Button("制作核对卡", systemImage: "rectangle.on.rectangle") {
            makeInformationCard(turn)
        }.disabled(turn.id == audio.conversation.activeCapture || workspace.information.cards.count >= 30)
        Button("修改文字与说话者", systemImage: "pencil") { editing = turn }.disabled(turn.id == audio.conversation.activeCapture)
        Button("移除这段", systemImage: "trash", role: .destructive) { removal = turn.id }.disabled(turn.id == audio.conversation.activeCapture)
    }
    private func makeInformationCard(_ turn: ConversationTurn) {
        var card = InformationCard(); card.kind = .place; card.value = String(turn.text.prefix(120)); card.sourceQuote = turn.text; card.origin = turn.origin
        informationDraft = card
    }
    private var privacyCover: some View { DailyPrivacyCover() }
    private func send(aloud: Bool) {
        if workspace.sendDraft(aloud: aloud) { frozen = nil; replyFocused = false; panel = .reading }
    }
    private func choose(_ phrase: String) {
        reply = appendCards ? PhraseComposer.append(phrase, to: reply) : phrase
        replyFocused = false; workspace.usePhrase(phrase)
    }
    @ViewBuilder private func responseButton(aloud: Bool) -> some View {
        if aloud {
            Button("朗读并显示", systemImage: "speaker.wave.2") { send(aloud: true) }
                .buttonStyle(SeeSecondaryButtonStyle())
        } else {
            Button("显示回应", systemImage: "bubble.left") { send(aloud: false) }
                .buttonStyle(SeePrimaryButtonStyle())
        }
    }
    @ViewBuilder private var responseButtons: some View {
        if workspace.preferences.reading.leftHanded { responseButton(aloud: true); responseButton(aloud: false) }
        else { responseButton(aloud: false); responseButton(aloud: true) }
    }
}

private extension View {
    func conversationCard() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct CaptureControl: View {
    @ObservedObject var audio: AudioProbes
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(audio.mode == .captions ? "字幕正在采集" : audio.mode == .sound ? "麦克风用于声音关注" : "麦克风已关闭", systemImage: audio.mode == .idle ? "mic.slash" : "mic.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.seeAccent)
                Spacer()
                if audio.isStarting { ProgressView() }
            }
            Text(audio.status).font(.caption).foregroundStyle(.secondary)
            Toggle("前台连续字幕", isOn: Binding(get: { audio.continuousMode }, set: { audio.setContinuousMode($0) }))
            Picker("下一段说话者（手动标签）", selection: $audio.selectedSpeakerName) {
                ForEach(["对方", "说话者 A", "说话者 B"], id: \.self) { Text($0).tag($0) }
            }
            if audio.continuousActive { Text("连续分段中 · 最多 20 分钟 / 60 段；停止、后台或识别错误后需手动开启。") .font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(audio.mode == .captions ? "结束这一段" : audio.conversation.turns.contains(where: { $0.origin == .speech }) ? "继续下一段" : "开始端侧字幕", systemImage: audio.mode == .captions ? "pause.fill" : "mic") {
                    if audio.mode == .captions { audio.stop(reason: "本段已暂停；已有文字保留为未完成") }
                    else { Task { await audio.startCaptions() } }
                }.buttonStyle(.borderedProminent).tint(SeePalette.button).disabled(audio.isStarting || audio.isScenarioDemo)
                Spacer()
                Text("仅本机").font(.caption).foregroundStyle(.secondary)
            }
        }.conversationCard()
    }
}

private struct ConversationBubble: View {
    let turn: ConversationTurn
    var emphasized = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(turn.speaker == .me ? "我的回应" : turn.speakerName ?? "对方的话", systemImage: turn.speaker == .me ? "bubble.left" : "captions.bubble")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(turn.createdAt, style: .time).font(.caption2)
            }.foregroundStyle(Color.seeAccent)
            Text(captionChangeHighlight(turn)).font(emphasized ? .title2 : .body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(emphasized ? "conversation.latestText" : "conversation.turn." + turn.id.uuidString)
            if turn.recognitionRevision > 0 {
                Label(turn.isEdited ? "识别曾改写 \(turn.recognitionRevision) 次 · 当前文字已人工修改" : "已有文字被改写 \(turn.recognitionRevision) 次 · 请核对变化",systemImage:"arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange)
                if let previous = turn.previousRecognitionText { DisclosureGroup("上一次识别文字") { Text(previous).font(.caption).foregroundStyle(.secondary) } }
            }
            Text(source).font(.caption2).foregroundStyle(.secondary)
            if let title = turn.replyEventTitle { Text("回应事件：\(title)").font(.caption).foregroundStyle(Color.seeAccent) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(turn.speaker == .me ? SeePalette.sage : SeePalette.surface, in: RoundedRectangle(cornerRadius: 19))
    }
    private var source: String {
        var text = turn.origin == .typed ? "手动输入" : turn.origin == .demonstration ? "演示文字"
            : turn.origin == .fileTranscription ? "WhisperKit 本地文件转写" : "系统端侧识别"
        if turn.state == .partial { text += " · 仍在更新" }
        if turn.state == .interrupted { text += " · 未完成" }
        if turn.isEdited { text += " · 已人工修改" }
        if let assistant = turn.assistedBy { text += " · \(assistant) 整理建议" }
        return text
    }
}

private struct EditConversationTurn: View {
    @ObservedObject var audio: AudioProbes
    let turn: ConversationTurn
    let corrections: [TextCorrection]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var failed = false
    @State private var speakerName = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("修改这段文字") {
                    TextField("输入文字", text: $text, axis: .vertical).lineLimit(5...12)
                        .onChange(of: text) { _, value in if value.count > 500 { text = String(value.prefix(500)) } }
                    Text("保存后会标注「已人工修改」，不会改变原始来源，也不会用于训练。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if failed { Text("这段文字已移除或正在采集，无法保存修改。").foregroundStyle(.red) }
                    if turn.speaker == .partner {
                        TextField("说话者（手动填写，最多 20 字）", text: $speakerName)
                            .onChange(of: speakerName) { _, value in speakerName = String(value.prefix(20)) }
                    }
                }
                if !corrections.isEmpty {
                    Section("点击应用快捷纠正") {
                        ForEach(corrections) { item in
                            Button("\(item.from) → \(item.to)") { text = item.apply(to: text) }.disabled(!text.contains(item.from))
                        }
                    }
                }
            }.seePageCanvas().navigationTitle("修改文字").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            let changed = text != turn.text
                            guard audio.conversation.turns.contains(where: { $0.id == turn.id }), audio.conversation.activeCapture != turn.id else { failed = true; return }
                            if !changed || audio.editTurn(turn.id, text: text) {
                                if turn.speaker == .partner { audio.labelSpeaker(turn.id, name: speakerName) }
                                dismiss()
                            } else { failed = true }
                        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { text = turn.text; speakerName = turn.speakerName ?? "" }
                .overlay {
                    if scenePhase != .active {
                        Color(.systemBackground).ignoresSafeArea().overlay { Label("沟通已暂停", systemImage: "lock") }
                    }
                }
        }
    }
}

private struct FacingConversationView: View {
    @ObservedObject var audio: AudioProbes
    @ObservedObject var workspace: Workspace
    @Binding var reply: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var flipped = true
    @State private var largeText = false
    @Environment(\.seeLeftHanded) private var leftHanded
    @FocusState private var replyFocused: Bool
    @ScaledMetric(relativeTo: .title) private var baseSize = 28

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                readingPanel("给对方看", text: audio.conversation.turns.last(where: { $0.speaker == .me })?.text ?? "你的回应会显示在这里")
                    .rotationEffect(.degrees(flipped ? 180 : 0))
                Divider()
                readingPanel(partnerTitle, text: audio.conversation.turns.last(where: { $0.speaker == .partner })?.text ?? "开启字幕后，在这里阅读对方的话")
            }.padding(16).background(SeePalette.canvas)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 10) {
                        TextField("写一句回应", text: $reply, axis: .vertical).lineLimit(1...3)
                            .focused($replyFocused).textFieldStyle(.roundedBorder)
                            .onChange(of: reply) { _, value in if value.count > 500 { reply = String(value.prefix(500)) } }
                        HStack {
                            if leftHanded { facingResponse(aloud: true); facingResponse(aloud: false) }
                            else { facingResponse(aloud: false); facingResponse(aloud: true) }
                            Spacer()
                            Button(audio.mode == .captions ? "停字幕" : "开字幕") {
                                if audio.mode == .captions { audio.stop() }
                                else { Task { await audio.startCaptions() } }
                            }.disabled(audio.isStarting)
                        }.font(.subheadline)
                        Text(audio.isSpeaking ? audio.speechStatus : audio.status)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        Text("字幕可能出错，请核对姓名和数字。").font(.caption2).foregroundStyle(.secondary)
                    }.padding(14).background(SeePalette.surface)
                }
                .seePageCanvas().navigationTitle("面对面阅读").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Toggle("翻转给对方看的区域", isOn: $flipped)
                            Toggle("更大文字", isOn: $largeText)
                            Button("停止采集与朗读", systemImage: "stop.circle") { audio.stopEverything() }
                        } label: { Label("阅读设置", systemImage: "textformat.size") }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { replyFocused = false } }
                }
                .overlay {
                    if scenePhase != .active {
                        Color(.systemBackground).ignoresSafeArea().overlay { Label("沟通已暂停", systemImage: "lock") }
                    }
                }
        }
    }

    private func readingPanel(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.seeAccent)
            ScrollView {
                Text(text).font(.system(size: baseSize * (largeText ? 1.35 : 1), weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SeePalette.surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private func respond(aloud: Bool) {
        if workspace.sendDraft(aloud: aloud) { replyFocused = false }
    }
    private func facingResponse(aloud: Bool) -> some View {
        Button(aloud ? "朗读" : "显示") { respond(aloud: aloud) }.buttonStyle(.bordered)
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var partnerTitle: String {
        guard let turn = audio.conversation.turns.last(where: { $0.speaker == .partner }) else { return "对方的话" }
        if turn.isEdited { return "对方的话 · 已人工修改" }
        if turn.state == .partial { return "对方的话 · 正在更新" }
        if turn.state == .interrupted { return "对方的话 · 未完成" }
        return "对方的话"
    }
}

private func captionChangeHighlight(_ turn:ConversationTurn) -> AttributedString {
    var text = captionHighlight(turn.text)
    guard let change = turn.recognitionChange,!change.newChanged.isEmpty else { return text }
    let offset = change.prefix.count
    guard turn.text.hasPrefix(change.prefix+change.newChanged) else { return text }
    let lower = text.index(text.startIndex,offsetByCharacters:offset)
    let upper = text.index(lower,offsetByCharacters:change.newChanged.count)
    text[lower..<upper].backgroundColor = .orange.opacity(0.3);text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
    return text
}
