import Foundation

enum ConversationSpeaker: String, Codable { case partner, me }
enum ConversationOrigin: String, Codable { case speech, typed, demonstration, fileTranscription, imageText, documentText }
enum ConversationTurnState: String, Codable { case partial, completed, interrupted }

struct ConversationTurn: Identifiable, Equatable {
    let id: UUID
    let speaker: ConversationSpeaker
    let origin: ConversationOrigin
    let createdAt: Date
    var text: String
    var state: ConversationTurnState
    var recognitionRevision = 0
    var previousRecognitionText: String?
    var recognitionChange: CaptionTextChange?
    var isEdited = false
    var speakerName: String? = nil
    var replyEventTitle: String? = nil
    var assistedBy: String? = nil
}

/// Ephemeral conversation. This type is deliberately not Codable or disk-backed.
struct ConversationSession {
    private(set) var turns: [ConversationTurn] = []
    private(set) var activeCapture: UUID?
    private var activeSpeakerName: String?
    static let limit = 50
    static let textLimit = 500

    @discardableResult
    mutating func beginCapture(speakerName: String? = nil) -> UUID {
        pauseCapture()
        let id = UUID()
        activeCapture = id
        activeSpeakerName = speakerName.map { String($0.prefix(20)) }
        return id
    }

    @discardableResult
    mutating func receive(_ text: String, capture: UUID, isFinal: Bool, at date: Date = Date()) -> Bool {
        guard capture == activeCapture else { return false }
        let text = Self.clean(text)
        if !text.isEmpty {
            if let index = turns.firstIndex(where: { $0.id == capture }) {
                let difference = CaptionTextChange.compare(old:turns[index].text,new:text)
                if difference.kind == .rewritten { turns[index].previousRecognitionText = turns[index].text;turns[index].recognitionRevision += 1;turns[index].recognitionChange = difference }
                turns[index].text = text
                turns[index].state = isFinal ? .completed : .partial
            } else {
                turns.append(ConversationTurn(id: capture, speaker: .partner, origin: .speech,
                                              createdAt: date, text: text, state: isFinal ? .completed : .partial,
                                              speakerName: activeSpeakerName))
                trim()
            }
        }
        if isFinal {
            if let index = turns.firstIndex(where: { $0.id == capture }) { turns[index].state = .completed }
            activeCapture = nil
        }
        return true
    }

    mutating func pauseCapture() {
        if let id = activeCapture, let index = turns.firstIndex(where: { $0.id == id }) {
            turns[index].state = .interrupted
        }
        activeCapture = nil
    }

    @discardableResult
    mutating func reply(_ text: String, at date: Date = Date(), origin: ConversationOrigin = .typed, replyEventTitle: String? = nil, assistedBy: String? = nil) -> Bool {
        let text = Self.clean(text)
        guard !text.isEmpty else { return false }
        turns.append(ConversationTurn(id: UUID(), speaker: .me, origin: origin,
                                      createdAt: date, text: text, state: .completed,
                                      replyEventTitle: replyEventTitle.map { String($0.prefix(80)) }, assistedBy: assistedBy.map { String($0.prefix(80)) }))
        trim()
        return true
    }

    @discardableResult
    mutating func edit(_ id: UUID, text: String) -> Bool {
        let text = Self.clean(text)
        guard !text.isEmpty, id != activeCapture,
              let index = turns.firstIndex(where: { $0.id == id }) else { return false }
        turns[index].text = text
        turns[index].isEdited = true;turns[index].recognitionChange = nil
        return true
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard id != activeCapture, turns.contains(where: { $0.id == id }) else { return false }
        turns.removeAll { $0.id == id }
        return true
    }

    mutating func clear() { turns.removeAll(); activeCapture = nil }

    mutating func addFileTranscript(_ text: String) {
        let text = Self.clean(text)
        guard !text.isEmpty else { return }
        turns.append(ConversationTurn(id: UUID(), speaker: .partner, origin: .fileTranscription,
                                      createdAt: Date(), text: text, state: .completed))
        trim()
    }

    mutating func labelSpeaker(_ id: UUID, name: String) -> Bool {
        guard id != activeCapture, let index = turns.firstIndex(where: { $0.id == id && $0.speaker == .partner }) else { return false }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        turns[index].speakerName = name.isEmpty ? nil : name
        return true
    }

    mutating func addDemonstration() {
        pauseCapture()
        for (text, name) in [("演示：请问会议几点开始？", "说话者 A"), ("演示：下午三点，在二楼。", "说话者 B")] {
            turns.append(ConversationTurn(id: UUID(), speaker: .partner, origin: .demonstration,
                                          createdAt: Date(), text: text, state: .completed, speakerName: name))
        }
        trim()
    }

    mutating func addScenario(_ scenario: DemoScenario) {
        pauseCapture()
        for (text, name) in scenario.partnerLines {
            turns.append(ConversationTurn(id: UUID(), speaker: .partner, origin: .demonstration,
                createdAt: Date(), text: text, state: .completed, speakerName: name))
        }
        trim()
    }

    private mutating func trim() {
        while turns.count > Self.limit,
              let index = turns.firstIndex(where: { $0.id != activeCapture }) { turns.remove(at: index) }
    }

    private static func clean(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textLimit))
    }
}

enum PhraseCategory: String, Codable, CaseIterable, Identifiable {
    case everyday, request, response, personal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .everyday: return "日常"
        case .request: return "需求"
        case .response: return "回应"
        case .personal: return "自定"
        }
    }
    var symbol: String {
        switch self {
        case .everyday: return "sun.max"
        case .request: return "hand.raised"
        case .response: return "bubble.left"
        case .personal: return "star"
        }
    }
}
