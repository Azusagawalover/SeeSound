import SwiftUI

private enum CounterVisitStep: Int, CaseIterable, Identifiable {
    case prepare, talk, check, result
    var id: Int { rawValue }
    var title: String {
        switch self { case .prepare: return "准备"; case .talk: return "交流"; case .check: return "核对"; case .result: return "结果" }
    }
    var section: JourneySection {
        switch self { case .prepare: return .overview; case .talk: return .communication; case .check: return .confirmation; case .result: return .outcome }
    }
}
private struct CounterDisplay: Identifiable {
    let id = UUID()
    let text: String
    let demonstration: Bool
}

struct CounterVisitPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var studio: WorkroomService
    let id: UUID
    @State private var step: CounterVisitStep = .prepare
    @State private var restored = false
    @State private var selectedQuestionID: UUID?
    @State private var newQuestion = ""
    @State private var answerQuestion: JourneyQuestion?
    @State private var factQuestion: JourneyQuestion?
    @State private var display: CounterDisplay?
    @State private var showClip = false
    @State private var showExcerpt = false
    @State private var showFact = false
    @State private var showOutcome = false
    @State private var error: String?
    @Environment(\.dynamicTypeSize) private var textSize
    private var journey: CampusJourney? { studio.campus.journeys.first { $0.id == id } }

    var body: some View {
        Group {
            if let journey {
                VStack(spacing: 0) {
                    stepPicker.padding(.horizontal, 20).padding(.vertical, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            header(journey)
                            if journey.stage == .paused {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("旅程已暂停，记录仍可查看", systemImage: "pause.circle").font(.headline)
                                    Button("继续这段旅程") {
                                        run { try studio.changeJourney(id) { $0.stage = $0.resumeStage ?? .prepare; $0.resumeStage = nil } }
                                    }.buttonStyle(.bordered)
                                }.modifier(WorkspaceSurface())
                            }
                            switch step {
                            case .prepare: preparation(journey)
                            case .talk: conversation(journey)
                            case .check: confirmation(journey)
                            case .result: result(journey)
                            }
                            if let error { FeatureMessage(title: "这次操作未保存", detail: error) }
                        }.padding(20).frame(maxWidth: 880).frame(maxWidth: .infinity)
                    }.id(step).scrollDismissesKeyboard(.interactively)
                }
            } else { ContentUnavailableView("旅程已移除", systemImage: "doc.badge.clock") }
        }.background(SeePalette.canvas).seePageCanvas()
            .navigationTitle("窗口办事").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { if journey != nil { footer } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink("完整旅程与更多资料") { JourneyDetailPage(workspace: workspace, studio: studio, id: id) }
                        NavigationLink("随身办事单") { JourneyDeparturePage(studio: studio, id: id) }
                        NavigationLink("查看材料与安排变化") { CampusChangeCenter(workspace: workspace, studio: studio, journeyID: id) }
                    } label: { Label("办理工具", systemImage: "ellipsis.circle") }
                }
            }
            .sheet(item: $answerQuestion) { question in CounterAnswerEditor(studio: studio, journeyID: id, questionID: question.id) }
            .sheet(item: $factQuestion) { question in CounterAnswerFactSheet(studio: studio, journeyID: id, questionID: question.id) }
            .sheet(isPresented: $showClip) { JourneyClipPicker(studio: studio, turns: workspace.audio.conversation.turns, activeCapture: workspace.audio.conversation.activeCapture, initialJourneyID: id) }
            .sheet(isPresented: $showExcerpt) { JourneyConversationEditor(workspace: workspace, studio: studio, id: id) }
            .sheet(isPresented: $showFact) { JourneyFactEditor(studio: studio, journeyID: id) }
            .sheet(isPresented: $showOutcome) { JourneyOutcomePage(studio: studio, id: id) }
            .fullScreenCover(item: $display) { value in JourneyDisplayPage(text: value.text, demonstration: value.demonstration) }
            .onAppear { restore() }
            .onChange(of: step) { _, value in try? studio.rememberJourney(id, section: value.section) }
            .modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
    }

    private var stepPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: textSize.isAccessibilitySize ? 2 : 4), spacing: 8) {
            ForEach(CounterVisitStep.allCases) { value in
                Button { step = value } label: {
                    HStack(spacing: 6) {
                        Text("\(value.rawValue + 1)").font(.caption.weight(.bold))
                        Text(value.title).font(.subheadline.weight(.semibold))
                    }.frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(step == value ? Color.seeAccent : SeePalette.secondary)
                        .background(step == value ? SeePalette.surface : .clear, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(step == value ? Color.seeAccent : SeePalette.line, lineWidth: step == value ? 1.5 : 0.6).allowsHitTesting(false))
                }.buttonStyle(.plain).accessibilityAddTraits(step == value ? .isSelected : [])
                    .accessibilityIdentifier("counter.step.\(value.rawValue)")
            }
        }
    }
    private func header(_ journey: CampusJourney) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(journey.demonstration ? "模拟窗口 · 不代表实际规定" : "校园窗口 · 按自己的节奏办理")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.seeAccent)
                Text(journey.title).font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(SeePalette.ink)
                Text(stepDescription).font(.subheadline).foregroundStyle(SeePalette.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !textSize.isAccessibilitySize { SeeArtworkView(artwork: step == .talk ? .speech : step == .check ? .clipboard : .memo, size: 60) }
        }
    }
    private var stepDescription: String {
        switch step {
        case .prepare: return "带好材料，先想清楚要问什么。"
        case .talk: return "把问题给对方看，一次说清一件事。"
        case .check: return "把时间、地点、费用和材料逐项对清楚。"
        case .result: return "记下办到哪一步，以及接下来要做什么。"
        }
    }
    private var footer: some View {
        HStack(spacing: 12) {
            if step != .prepare {
                Button { if let previous = CounterVisitStep(rawValue: step.rawValue - 1) { step = previous } } label: {
                    Image(systemName: "arrow.left").frame(width: 44, height: 44)
                }.buttonStyle(.bordered).accessibilityLabel("上一步")
            }
            Button {
                if let next = CounterVisitStep(rawValue: step.rawValue + 1) { step = next }
                else { showOutcome = true }
            } label: {
                Label(step == .result ? "记录本次办理结果" : "下一步：" + (CounterVisitStep(rawValue: step.rawValue + 1)?.title ?? ""), systemImage: step == .result ? "square.and.pencil" : "arrow.right")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(SeeSecondaryButtonStyle()).accessibilityIdentifier("counter.next")
        }.padding(.horizontal, 20).padding(.vertical, 10).background(SeePalette.surface)
    }

    @ViewBuilder private func preparation(_ journey: CampusJourney) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("到窗口前", systemImage: "bag").font(.headline)
            NavigationLink { JourneySourcesPage(workspace: workspace, studio: studio, id: id) } label: {
                SeeToolRow(title: "随身材料 · \(journey.documents.count) 份", detail: journey.documents.isEmpty ? "可带入通知或办理说明，也可以先去咨询" : "查看原文和已加入的材料", artwork: .folder)
            }.buttonStyle(.plain).accessibilityIdentifier("counter.materials")
            NavigationLink { JourneyPlanDatePage(studio: studio, id: id) } label: {
                Label(journey.plan?.plannedAt.map { "我的办理计划：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "安排自己的办理时间（可选）", systemImage: "calendar")
            }.font(.subheadline).frame(minHeight: 44)
        }.modifier(WorkspaceSurface())
        VStack(alignment: .leading, spacing: 14) {
            Label("要问的事 · \(journey.questions.count)", systemImage: "questionmark.bubble").font(.headline)
            if journey.questions.isEmpty { Text("先写一个问题，例如“这项业务在这里办理吗？”").foregroundStyle(.secondary) }
            ForEach(journey.questions) { question in
                NavigationLink { JourneyQuestionPage(studio: studio, journeyID: id, questionID: question.id) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: question.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "circle" : "text.bubble.fill").foregroundStyle(Color.seeAccent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(question.text).font(.headline).foregroundStyle(SeePalette.ink)
                            Text(question.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "还没问清楚" : "已有手动记录，现场仍可修改").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            TextField("再加一个要问的问题", text: $newQuestion, axis: .vertical).textFieldStyle(.roundedBorder)
                .onChange(of: newQuestion) { _, value in if value.count > 200 { newQuestion = String(value.prefix(200)) } }
                .accessibilityIdentifier("counter.newQuestion")
            Button("加入提问清单", systemImage: "plus.circle") {
                run { try studio.changeJourney(id) { $0.questions.append(.init(text: newQuestion.trimmingCharacters(in: .whitespacesAndNewlines))) }; newQuestion = "" }
            }.disabled(newQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || journey.questions.count >= 30)
        }.modifier(WorkspaceSurface())
    }

    @ViewBuilder private func conversation(_ journey: CampusJourney) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("先说明沟通方式", systemImage: "person.2").font(.headline)
            Text("您好，我听声音不太方便。请面对我交流，重要内容也请写下来。").font(.title3.weight(.medium))
            Button("大字说明，拿给对方看", systemImage: "textformat.size.larger") {
                present("您好，我听声音不太方便。请面对我交流，重要内容也请写下来。", journey: journey)
            }.buttonStyle(SeeSecondaryButtonStyle()).accessibilityIdentifier("counter.introduction")
        }.modifier(WorkspaceSurface())
        questionCard(journey)
        VStack(alignment: .leading, spacing: 14) {
            Label("交流工具", systemImage: "captions.bubble").font(.headline)
            CounterMicrophoneStatus(audio: workspace.audio, demonstration: journey.demonstration)
            NavigationLink { ConversationPage(audio: workspace.audio, workspace: workspace) } label: {
                SeeToolRow(title: "打开字幕与文字回应", detail: "返回后继续这次办理；点击开始才收音", artwork: .speech)
            }.buttonStyle(.plain).accessibilityIdentifier("counter.captions")
            HStack {
                Button("选取字幕留作摘录") { showClip = true }
                Spacer()
                Button("手动记一段交流") { showExcerpt = true }
            }.font(.subheadline).buttonStyle(.borderless).frame(minHeight: 44)
            ViewThatFits(in: .horizontal) {
                HStack { helpPhrases(journey) }
                VStack(alignment: .leading) { helpPhrases(journey) }
            }
        }.modifier(WorkspaceSurface())
    }
    @ViewBuilder private func questionCard(_ journey: CampusJourney) -> some View {
        if let question = selectedQuestion(journey), let index = journey.questions.firstIndex(where: { $0.id == question.id }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("正在问 · 第 \(index + 1) / \(journey.questions.count) 个问题").font(.caption.weight(.semibold)).foregroundStyle(Color.seeAccent)
                    Spacer();Text(question.answer.isEmpty ? "待记录回答" : "已有回答").font(.caption).foregroundStyle(.secondary)
                }
                Text(question.text).font(.system(.title2, design: .rounded, weight: .semibold)).accessibilityIdentifier("counter.currentQuestion")
                Button("大字提问", systemImage: "rectangle.expand.vertical") { present(question.text, journey: journey) }
                    .buttonStyle(SeeSecondaryButtonStyle()).accessibilityIdentifier("counter.ask")
                if !question.answer.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("手动记录的回答").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(question.answer).font(.title3).textSelection(.enabled).accessibilityIdentifier("counter.currentAnswer")
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(SeePalette.sage.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                }
                Button(question.answer.isEmpty ? "请对方输入 / 我来记回答" : "修改这条回答", systemImage: "square.and.pencil") { answerQuestion = question }
                    .frame(minHeight: 44).accessibilityIdentifier("counter.answer")
                HStack {
                    Button("上一个问题") { selectedQuestionID = journey.questions[index - 1].id }.disabled(index == 0)
                    Spacer()
                    Button("下一个问题") { selectedQuestionID = journey.questions[index + 1].id }.disabled(index == journey.questions.count - 1)
                }.buttonStyle(.borderless).font(.subheadline).frame(minHeight: 44)
                Text("翻到下一题不会自动记录回答。").font(.caption).foregroundStyle(.secondary)
            }.modifier(WorkspaceSurface())
        } else {
            FeatureMessage(title: "还没有提问", detail: "回到准备页写下要问的事，也可以直接打开字幕交流。", actionTitle: "准备一个问题", action: { step = .prepare })
        }
    }
    @ViewBuilder private func helpPhrases(_ journey: CampusJourney) -> some View {
        ForEach(["请用文字告诉我。", "请稍等，我看一下。", "请把时间和金额再写一次。"], id: \.self) { phrase in
            Button(phrase) { present(phrase, journey: journey) }.buttonStyle(.bordered).frame(minHeight: 44)
        }
    }

    @ViewBuilder private func confirmation(_ journey: CampusJourney) -> some View {
        let changed = journey.changedCases(studio.cases)
        if !changed.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("关联事项有变化", systemImage: "exclamationmark.circle").font(.headline)
                ForEach(changed, id: \.self) { Text($0).font(.subheadline) }
                NavigationLink("先查看变化，再继续核对") { CampusChangeCenter(workspace: workspace, studio: studio, journeyID: id) }
            }.modifier(WorkspaceSurface())
        }
        VStack(alignment: .leading, spacing: 14) {
            Label("逐项确认安排", systemImage: "rectangle.on.rectangle").font(.headline)
            if journey.facts.isEmpty {
                Text("先从下方已记录的回答中选出时间、地点、费用或材料，做成待核对卡。").foregroundStyle(.secondary)
            } else {
                ForEach(journey.facts.filter { !$0.superseded }) { fact in factLink(fact) }
                let previous = journey.facts.filter(\.superseded)
                if !previous.isEmpty {
                    DisclosureGroup("已失效的旧版记录 · \(previous.count) 项") {
                        Text("旧依据保留供对照，不能继续确认。请按最新回答重新建立核对卡。").font(.caption).foregroundStyle(.secondary)
                        ForEach(previous) { fact in factLink(fact) }
                    }
                }
                NavigationLink("逐张大字核对", destination: JourneyCardCarousel(studio: studio, id: id, currentOnly: true))
                    .frame(minHeight: 44).disabled(!journey.facts.contains { !$0.superseded })
            }
            Button("从已有材料添加核对卡", systemImage: "plus.rectangle") { showFact = true }.disabled(journey.documents.isEmpty)
            Text("自己核对与记录对方确认分别操作。只翻阅卡片不会完成确认。").font(.caption).foregroundStyle(.secondary)
        }.modifier(WorkspaceSurface())
        VStack(alignment: .leading, spacing: 14) {
            Label("把回答留作核对依据", systemImage: "text.bubble").font(.headline)
            ForEach(journey.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.text).font(.headline)
                    if question.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("还没记下，补一条回答") { answerQuestion = question }.frame(minHeight: 44)
                    } else {
                        Text(question.answer).font(.subheadline).foregroundStyle(.secondary)
                        Button("从这条回答建立待核对卡", systemImage: "rectangle.badge.plus") { factQuestion = question }
                            .frame(minHeight: 44).accessibilityIdentifier("counter.answerFact.\(question.id)")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }
            if journey.questions.isEmpty { Button("回去准备问题") { step = .prepare } }
            Text("保存时会预览手动回答的文字依据；新卡仍需你逐项核对。").font(.caption).foregroundStyle(.secondary)
        }.modifier(WorkspaceSurface())
    }
    private func factLink(_ fact: JourneyFact) -> some View {
        NavigationLink { JourneyConfirmationPage(studio: studio, journeyID: id, factID: fact.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(fact.kind.title).font(.caption.weight(.semibold)).foregroundStyle(Color.seeAccent)
                Text(fact.value).font(.title3.weight(.medium)).foregroundStyle(SeePalette.ink)
                Label(fact.superseded ? "内容已变化，请重新核对" : fact.counterpartRecordedAt != nil ? "我已记录对方确认" : fact.isConfirmed ? "我已核对，尚未记录对方确认" : "等待核对", systemImage: fact.superseded ? "arrow.triangle.2.circlepath" : fact.isConfirmed ? "checkmark.circle" : "circle")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func result(_ journey: CampusJourney) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("这次办理留下了什么", systemImage: "checklist").font(.headline)
            Text("\(journey.questions.filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count) / \(journey.questions.count) 个问题已有回答")
            Text("\(journey.facts.filter(\.isConfirmed).count) / \(journey.facts.filter { !$0.superseded }.count) 项当前安排由我核对过")
            if journey.facts.contains(where: \.superseded) { Text("另有 \(journey.facts.filter(\.superseded).count) 项旧记录已失效，请对照最新安排。").font(.caption).foregroundStyle(.secondary) }
            let pending = journey.questions.filter { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !pending.isEmpty {
                Text("还没问清楚").font(.subheadline.weight(.semibold))
                ForEach(pending) { question in Text("• " + question.text).font(.subheadline).foregroundStyle(.secondary) }
            }
            if journey.facts.contains(where: { !$0.isConfirmed }) || !journey.changedCases(studio.cases).isEmpty {
                Button("返回查看待核对与失效的安排") { step = .check }.frame(minHeight: 44)
            }
            NavigationLink("查看随身办事单") { JourneyDeparturePage(studio: studio, id: id) }.frame(minHeight: 44)
        }.modifier(WorkspaceSurface())
        if let outcome = journey.outcomes.last {
            VStack(alignment: .leading, spacing: 12) {
                Label("最近一次办理记录", systemImage: "square.and.pencil").font(.headline)
                Text(outcome.note).font(.title3).accessibilityIdentifier("counter.savedOutcome")
                if !outcome.nextAction.isEmpty { Text("接下来：" + outcome.nextAction).font(.headline) }
                Text(outcome.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                if let caseID = outcome.followUpCaseID, let item = studio.cases.first(where: { $0.id == caseID }) {
                    Button("打开后续事项：" + item.title) { workspace.scheduledDestination = .init(kind: .project, recordID: caseID) }.frame(minHeight: 44)
                }
            }.modifier(WorkspaceSurface())
        } else {
            FeatureMessage(title: "办理结束后，记一句就好", detail: "记录办成了什么、还缺什么。需要补材料或等待回复，也可以留作后续事项。")
        }
    }
    private func selectedQuestion(_ journey: CampusJourney) -> JourneyQuestion? {
        journey.questions.first { $0.id == selectedQuestionID } ?? journey.questions.first { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? journey.questions.first
    }
    private func present(_ text: String, journey: CampusJourney) {
        workspace.stopCapture(); display = .init(text: text, demonstration: journey.demonstration)
    }
    private func restore() {
        guard !restored, let journey else { return }; restored = true
        if let bookmark = studio.campusWorkspace.bookmarks.first(where: { $0.id == id }) {
            step = CounterVisitStep.allCases.first { $0.section == bookmark.section } ?? .prepare
        } else {
            switch journey.stage {
            case .communicate: step = .talk
            case .check: step = .check
            case .finished, .followUp: step = .result
            default: step = .prepare
            }
        }
        selectedQuestionID = selectedQuestion(journey)?.id
        try? studio.visitJourney(id)
    }
    private func run(_ operation: () throws -> Void) {
        do { try operation(); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct CounterMicrophoneStatus: View {
    @ObservedObject var audio: AudioProbes
    let demonstration: Bool
    private var latest: ConversationTurn? {
        audio.conversation.turns.last { $0.speaker == .partner && ($0.origin == .demonstration) == demonstration }
    }
    private var title: String {
        if audio.isScenarioDemo { return "演示文字 · 麦克风关闭" }
        if audio.isStarting { return "麦克风正在准备" }
        switch audio.mode {
        case .idle: return "麦克风未开启"
        case .captions: return "麦克风用于字幕收音"
        case .sound: return "麦克风用于声音关注"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { state; Spacer(); stop }
                VStack(alignment: .leading, spacing: 10) { state; stop }
            }
            if let latest {
                VStack(alignment: .leading, spacing: 8) {
                    Label(latest.origin == .demonstration ? "当前会话的演示文字" : "当前会话的对方文字 · 请核对", systemImage: "captions.bubble").font(.caption).foregroundStyle(.secondary)
                    Text(latest.text).font(.title3).textSelection(.enabled)
                    if latest.state == .partial { Text("字幕正在更新").font(.caption).foregroundStyle(.secondary) }
                    Text("请先核对是否属于这次办理；只有主动选取才会加入。").font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(SeePalette.canvas.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
    private var state: some View { Label(title, systemImage: audio.mode == .idle && !audio.isStarting ? "mic.slash" : "mic").font(.caption).foregroundStyle(Color.seeAccent) }
    @ViewBuilder private var stop: some View {
        if audio.mode != .idle || audio.isStarting { Button("停止收音") { audio.stopEverything() }.font(.subheadline).frame(minHeight: 44) }
    }
}

private struct CounterAnswerEditor: View {
    @ObservedObject var studio: WorkroomService
    let journeyID: UUID
    let questionID: UUID
    @State private var answer = ""
    @State private var original = ""
    @State private var baseline: String?
    @State private var discard = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var journey: CampusJourney? { studio.campus.journeys.first { $0.id == journeyID } }
    private var question: JourneyQuestion? { journey?.questions.first { $0.id == questionID } }
    var body: some View {
        NavigationStack {
            Form {
                if let question {
                    Section("刚才问的是") { Text(question.text).font(.title2.weight(.semibold)) }
                    Section("请对方输入，或核对后手动记录") {
                        TextField("写下这条问题的回答", text: $answer, axis: .vertical).lineLimit(4...10).font(.title3)
                            .accessibilityIdentifier("counter.answerText")
                        Text("\(answer.count) / 500 字").font(.caption).foregroundStyle(.secondary)
                        Text("修改回答后，根据旧回答建立的卡片会重新待核对；原始沟通摘录保留。").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("保存这条回答") { save() }.disabled(baseline == nil || answer.count > 500)
                        .accessibilityIdentifier("counter.answerSave")
                } else { ContentUnavailableView("问题已移除", systemImage: "questionmark.bubble") }
                if let error { Text(error).foregroundStyle(.red) }
            }.seePageCanvas().navigationTitle("记下回答").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { if answer != original { discard = true } else { dismiss() } } } }
                .onAppear { if baseline == nil { baseline = try? journey?.fingerprint(); answer = question?.answer ?? ""; original = answer } }
                .interactiveDismissDisabled(answer != original)
                .confirmationDialog("放弃这次尚未保存的回答？", isPresented: $discard, titleVisibility: .visible) { Button("放弃修改", role: .destructive) { dismiss() } }
                .modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
        }
    }
    private func save() {
        do {
            guard var journey, let baseline, let index = journey.questions.firstIndex(where: { $0.id == questionID }) else { throw CampusError.missing }
            journey.questions[index].answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            try studio.putJourney(journey, baseline: baseline); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct CounterAnswerFactSheet: View {
    @ObservedObject var studio: WorkroomService
    let journeyID: UUID
    let questionID: UUID
    @State private var kind: JourneyFactKind = .other
    @State private var value = ""
    @State private var baseline: String?
    @State private var agreed = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var journey: CampusJourney? { studio.campus.journeys.first { $0.id == journeyID } }
    private var question: JourneyQuestion? { journey?.questions.first { $0.id == questionID } }
    var body: some View {
        NavigationStack {
            Form {
                if let question {
                    Section("依据预览 · 手动记录的窗口回答") {
                        Text(question.text).font(.headline)
                        Text(question.answer).textSelection(.enabled)
                        Text(journey?.demonstration == true ? "这份依据保留演示标记。" : "这是用户核对后的手动记录，不是录音逐字稿。").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("准备核对哪一项") {
                        Picker("类别", selection: $kind) { ForEach(JourneyFactKind.allCases) { Text($0.title).tag($0) } }
                        TextField("从回答里选出要核对的内容", text: $value, axis: .vertical).lineLimit(2...6)
                            .accessibilityIdentifier("counter.factValue")
                        Text("保留回答里的原句或一段原文，最多 300 字。需要改写时，先返回修改回答。").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Toggle("我已检查，同意保存回答依据和待核对卡", isOn: $agreed).accessibilityIdentifier("counter.factConsent")
                        Button("建立待核对卡") {
                            do {
                                guard let baseline else { throw CampusError.stale }
                                try studio.makeJourneyAnswerFact(journeyID, questionID: questionID, kind: kind, value: value, baseline: baseline, consent: agreed)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }.disabled(!agreed || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.count > 300)
                            .accessibilityIdentifier("counter.factSave")
                        Text("建立后仍是待核对状态，不会代替你确认安排。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.seePageCanvas().navigationTitle("从回答建立核对卡").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .onAppear { if baseline == nil { baseline = try? journey?.fingerprint(); value = String((question?.answer ?? "").prefix(300)) } }
                .onChange(of: kind) { _, _ in agreed = false }.onChange(of: value) { _, _ in agreed = false }
                .modifier(KeyboardCloseToolbar()).modifier(WorkroomPrivacy())
        }
    }
}
