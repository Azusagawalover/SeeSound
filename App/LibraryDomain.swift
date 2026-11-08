import Foundation

enum PhraseCollection { static let limit = 48 }

enum PhraseComposer {
    static func visible(preferences: AppPreferences, category: PhraseCategory?, query: String) -> [String] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = preferences.phrases.filter {
            (category == nil || preferences.category(for: $0) == category) &&
            (term.isEmpty || $0.localizedCaseInsensitiveContains(term))
        }
        return items.filter { preferences.pinnedPhrases.contains($0) } + items.filter { !preferences.pinnedPhrases.contains($0) }
    }
    static func append(_ phrase: String, to draft: String) -> String {
        let combined = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((combined.isEmpty ? phrase : combined + " " + phrase).prefix(500))
    }
}

struct SharedPhrase: Codable, Equatable, Identifiable {
    var text: String
    var category: PhraseCategory
    var id: String { text }
}

struct PhraseBundle: Codable, Equatable, Identifiable {
    var format = "SeeSoundCards"
    var version = 1
    var phrases: [SharedPhrase]
    var id: String { phrases.map { "\($0.text.utf8.count):\($0.text):\($0.category.rawValue)" }.joined(separator: ";") }
}

enum PhraseTransferError: LocalizedError {
    case size, format, content
    var errorDescription: String? {
        switch self {
        case .size: return "每张分享码最多 8 句、4096 字节，请减少选择。"
        case .format: return "这不是支持的见声沟通卡分享码。"
        case .content: return "卡片包含空内容、重复内容或超过 80 字的句子。"
        }
    }
}

enum PhraseTransferCodec {
    static func encode(_ phrases: [SharedPhrase]) throws -> String {
        let bundle = PhraseBundle(phrases: phrases)
        try validate(bundle)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bundle)
        guard data.count <= 4096 else { throw PhraseTransferError.size }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) throws -> PhraseBundle {
        let data = Data(text.utf8)
        guard data.count <= 4096 else { throw PhraseTransferError.size }
        guard let bundle = try? JSONDecoder().decode(PhraseBundle.self, from: data) else {
            throw PhraseTransferError.format
        }
        try validate(bundle)
        return bundle
    }

    private static func validate(_ bundle: PhraseBundle) throws {
        guard bundle.format == "SeeSoundCards", bundle.version == 1 else { throw PhraseTransferError.format }
        guard (1...8).contains(bundle.phrases.count) else { throw PhraseTransferError.size }
        let texts = bundle.phrases.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard texts.allSatisfy({ !$0.isEmpty && $0.count <= 80 }), Set(texts).count == texts.count,
              zip(texts, bundle.phrases).allSatisfy({ $0.0 == $0.1.text }) else { throw PhraseTransferError.content }
    }
}

struct VocablePhrase: Codable, Identifiable {
    var id: String
    var text: String
    var english: String
    var group: String
}

struct VocableCatalog: Codable {
    var sourceCommit: String
    var phrases: [VocablePhrase]

    static func load() throws -> VocableCatalog {
        guard let url = Bundle.main.url(forResource: "VocablePhrases", withExtension: "json") else {
            throw PhraseTransferError.format
        }
        return try JSONDecoder().decode(VocableCatalog.self, from: Data(contentsOf: url))
    }
}
